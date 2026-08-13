import AppKit
import CoreGraphics
import Foundation

// MARK: - Window Tiling (分屏)

// 坐标系说明（本模块最重要的约定，踩坑重灾区）：
// - AppKit（NSScreen / NSWindow / NSView）：原点在整个桌面的左下角，y 轴向上
// - CG / AX（CGEvent 位置、AXUIElement 的 position/size）：原点在主屏左上角，y 轴向下
// 布局计算、格子命中、浮层/编辑面绘制全部在 AppKit 坐标系进行；
// 只有读写其它 App 窗口的 frame（AX）和读取事件位置时才涉及 CG 坐标，
// 所有换算统一走 CoordConv，别处禁止自行翻转 y。

private enum CoordConv {
    /// 换算基准 = 主屏（NSScreen.screens[0]，即 CG 坐标原点所在屏）的高度
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// AppKit 矩形 → CG/AX 矩形（AX 的 position 是矩形左上角）
    static func toCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// CG/AX 矩形 → AppKit 矩形
    static func fromCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// CG/AX 点 → AppKit 点
    static func fromCG(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

private extension CGRect {
    /// 近似相等（吸附/还原判断允许的误差）
    func approxEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

// MARK: 分屏：布局模型（递归二叉分割树）

/// 分割方向：V = 左右分割（一条竖线，a=左 b=右）；H = 上下分割（一条横线，a=上 b=下）
enum SplitDir: String, Codable {
    case v = "V"
    case h = "H"
}

/// 布局树节点：叶子为格子；split 为二叉分割。
/// JSON 结构：{"type":"cell"} 或 {"type":"split","dir":"V"|"H","ratio":0.5,"a":…,"b":…}
indirect enum LayoutNode {
    case cell
    case split(dir: SplitDir, ratio: CGFloat, a: LayoutNode, b: LayoutNode)
}

extension LayoutNode {
    static let minRatio: CGFloat = 0.08
    static let maxRatio: CGFloat = 0.92

    /// 把 rect 按 dir/ratio 切成 (a, b) 两块（AppKit 几何，y 轴向上）
    static func splitRect(_ r: CGRect, dir: SplitDir, ratio: CGFloat) -> (CGRect, CGRect) {
        switch dir {
        case .v:
            let w = r.width * ratio
            return (CGRect(x: r.minX, y: r.minY, width: w, height: r.height),
                    CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
        case .h:
            // a 取上半部分（AppKit y 向上，上半部分 y 更大）
            let h = r.height * ratio
            return (CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h),
                    CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - h))
        }
    }

    /// 递归求所有叶格子矩形。path 元素 0=a 1=b，标识格子在树中的位置（编辑器操作用）
    func cellRects(in rect: CGRect, path: [Int] = []) -> [(path: [Int], rect: CGRect)] {
        switch self {
        case .cell:
            return [(path, rect)]
        case .split(let dir, let ratio, let a, let b):
            let (ra, rb) = LayoutNode.splitRect(rect, dir: dir, ratio: ratio)
            return a.cellRects(in: ra, path: path + [0]) + b.cellRects(in: rb, path: path + [1])
        }
    }

    /// 一条可拖动的分隔线：所在分割节点 path、线本身、父矩形、方向
    struct SplitLine {
        let path: [Int]
        let line: CGRect
        let parentRect: CGRect
        let dir: SplitDir
    }

    /// 递归求所有分隔线（编辑器拖拽调比例用）
    func splitLines(in rect: CGRect, path: [Int] = []) -> [SplitLine] {
        guard case .split(let dir, let ratio, let a, let b) = self else { return [] }
        let (ra, rb) = LayoutNode.splitRect(rect, dir: dir, ratio: ratio)
        let line: CGRect
        switch dir {
        case .v: line = CGRect(x: ra.maxX, y: rect.minY, width: 0, height: rect.height)
        case .h: line = CGRect(x: rect.minX, y: ra.minY, width: rect.width, height: 0)
        }
        return [SplitLine(path: path, line: line, parentRect: rect, dir: dir)]
            + a.splitLines(in: ra, path: path + [0])
            + b.splitLines(in: rb, path: path + [1])
    }

    /// 取 path 处的子树
    func subtree(at path: [Int]) -> LayoutNode? {
        guard let head = path.first else { return self }
        guard case .split(_, _, let a, let b) = self else { return nil }
        return (head == 0 ? a : b).subtree(at: Array(path.dropFirst()))
    }

    /// 用 node 替换 path 处的子树
    func replacing(at path: [Int], with node: LayoutNode) -> LayoutNode {
        guard let head = path.first else { return node }
        guard case .split(let dir, let ratio, let a, let b) = self else { return self }
        let rest = Array(path.dropFirst())
        return head == 0
            ? .split(dir: dir, ratio: ratio, a: a.replacing(at: rest, with: node), b: b)
            : .split(dir: dir, ratio: ratio, a: a, b: b.replacing(at: rest, with: node))
    }

    /// 调整 path 处分割节点的比例
    func settingRatio(at path: [Int], to newRatio: CGFloat) -> LayoutNode {
        guard let head = path.first else {
            guard case .split(let dir, _, let a, let b) = self else { return self }
            return .split(dir: dir, ratio: newRatio, a: a, b: b)
        }
        guard case .split(let dir, let ratio, let a, let b) = self else { return self }
        let rest = Array(path.dropFirst())
        return head == 0
            ? .split(dir: dir, ratio: ratio, a: a.settingRatio(at: rest, to: newRatio), b: b)
            : .split(dir: dir, ratio: ratio, a: a, b: b.settingRatio(at: rest, to: newRatio))
    }
}

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey { case type, dir, ratio, a, b }

    /// 防御式解析：字段缺失/损坏一律回退安全值，绝不让整棵树解析失败
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // type 也得用 try?：这是根节点唯一会抛的字段，而 TilingConfig 对 layouts 是
        // 整体 try? 兜底 —— 单个显示器条目的 type 坏掉会让**所有**显示器的布局
        // 一起静默清空（且吞掉错误不写日志）。坏字段回退成普通格子，只影响它自己
        let type = (try? c.decode(String.self, forKey: .type)) ?? "cell"
        switch type {
        case "cell":
            self = .cell
        case "split":
            let dir = SplitDir(rawValue: (try? c.decode(String.self, forKey: .dir)) ?? "") ?? .v
            let rawRatio = (try? c.decode(CGFloat.self, forKey: .ratio)) ?? 0.5
            // ratio 非有限值/越界 → 0.5
            let ratio = rawRatio.isFinite
                && (LayoutNode.minRatio...LayoutNode.maxRatio).contains(rawRatio) ? rawRatio : 0.5
            // 子节点缺失/损坏 → 回退普通格子
            let a = (try? c.decode(LayoutNode.self, forKey: .a)) ?? .cell
            let b = (try? c.decode(LayoutNode.self, forKey: .b)) ?? .cell
            self = .split(dir: dir, ratio: ratio, a: a, b: b)
        default:
            self = .cell
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cell:
            try c.encode("cell", forKey: .type)
        case .split(let dir, let ratio, let a, let b):
            try c.encode("split", forKey: .type)
            try c.encode(dir.rawValue, forKey: .dir)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
        }
    }
}

// MARK: 分屏：配置持久化

/// 持久化到 ~/Library/Application Support/Bento/config.json
struct TilingConfig: Codable {
    var masterEnabled = true
    /// key = 显示器 UUID（见 DisplayKeys）
    var layouts: [String: LayoutNode] = [:]

    private enum CodingKeys: String, CodingKey {
        case masterEnabled, layouts
    }

    init() {}

    /// 单条目宽容解码的包装：某个显示器的布局值损坏（不是对象等）只丢那一条，
    /// 不让整个字典解码失败把所有屏的布局清空
    private struct TolerantNode: Decodable {
        let node: LayoutNode?
        init(from decoder: Decoder) throws { node = try? LayoutNode(from: decoder) }
    }

    /// 防御式解析：任何字段缺失/类型错误都回退默认值，绝不抛异常
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterEnabled = (try? c.decode(Bool.self, forKey: .masterEnabled)) ?? true
        let tolerant = (try? c.decode([String: TolerantNode].self, forKey: .layouts)) ?? [:]
        let bad = tolerant.filter { $0.value.node == nil }.keys.sorted()
        if !bad.isEmpty {
            ErrorLog.log("分屏配置: 丢弃损坏的布局条目 \(bad)")
        }
        layouts = tolerant.compactMapValues(\.node)
    }

    static var configURL: URL { ErrorLog.directory.appendingPathComponent("config.json") }

    static func load() -> TilingConfig {
        guard let data = try? Data(contentsOf: configURL) else { return TilingConfig() }
        do {
            return try JSONDecoder().decode(TilingConfig.self, from: data)
        } catch {
            // 损坏 JSON → 回退默认并记日志，不让 App 崩溃或功能静默失效
            ErrorLog.log("分屏配置损坏，回退默认布局: \(error.localizedDescription)")
            return TilingConfig()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else {
            ErrorLog.log("分屏配置编码失败，未保存")
            return
        }
        do {
            try data.write(to: TilingConfig.configURL, options: .atomic)
        } catch {
            // 磁盘满/权限问题静默吞掉的话，用户以为保存成功、重启后布局回退
            ErrorLog.log("分屏配置保存失败: \(error.localizedDescription)")
        }
    }
}

// MARK: 分屏：显示器持久化键

enum DisplayKeys {
    private static var cache: [CGDirectDisplayID: String] = [:]

    /// 持久化键用 CGDisplay UUID：displayID / NSScreen 索引在重启、插拔后会变，UUID 不变
    static func uuid(for displayID: CGDirectDisplayID) -> String {
        if let cached = cache[displayID] { return cached }
        let result: String
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) {
            result = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
        } else {
            result = "display-\(displayID)" // 极端兜底，正常不会发生
        }
        cache[displayID] = result
        return result
    }

    static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return uuid(for: CGDirectDisplayID(number.uint32Value))
    }

    /// 显示器配置变化时调用
    static func invalidateCache() { cache.removeAll() }
}

// MARK: 分屏：AX 窗口操作

/// 通过私有 API 把 AX 窗口元素映射回 CGWindowID（还原记忆的稳定 key）
@_silgen_name("_AXUIElementGetWindow")
private func axGetCGWindowID(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

struct TitlebarHit {
    let pid: pid_t
    let windowID: CGWindowID
    let bounds: CGRect // CG 坐标
}

struct OnScreenWindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect // CG 坐标
}

/// 对其它 App 窗口的 AX 读写集中在这里
class WindowManager {
    private let myPid = ProcessInfo.processInfo.processIdentifier
    // 短 TTL 缓存：标题栏点击很常见，每次都全量 CGWindowList 枚举太浪费；
    // 80ms 内的连续调用（含 Shift 双击路径的两次背靠背查询）复用同一份快照
    private var windowsCache: [OnScreenWindowInfo] = []
    private var windowsCacheAt = Date.distantPast

    /// 当前屏幕上 layer-0 窗口（front-to-back），排除本进程（避免拦到自己）
    func onScreenWindows() -> [OnScreenWindowInfo] {
        if Date().timeIntervalSince(windowsCacheAt) < 0.08 { return windowsCache }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var result: [OnScreenWindowInfo] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPid,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            result.append(OnScreenWindowInfo(id: number, pid: pid, bounds: bounds))
        }
        windowsCache = result
        windowsCacheAt = Date()
        return result
    }

    /// 全部窗口 ID（含其它 Space / 最小化的）：还原记忆判活专用，不走 80ms 缓存
    func allWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    /// 零成本几何预过滤：点是否落在某窗口顶部标题栏高度带内（纯窗口列表几何判断，不做 AX 调用）
    func titlebarHit(at cgPoint: CGPoint, bandHeight: CGFloat) -> TitlebarHit? {
        for w in onScreenWindows() {
            // 过滤过小的工具/辅助窗口
            guard w.bounds.width >= 50, w.bounds.height >= 50 else { continue }
            // CG 坐标 y 向下，标题栏在窗口顶部 bandHeight 像素内
            guard cgPoint.x >= w.bounds.minX, cgPoint.x <= w.bounds.maxX,
                  cgPoint.y >= w.bounds.minY, cgPoint.y <= w.bounds.minY + bandHeight
            else { continue }
            return TitlebarHit(pid: w.pid, windowID: w.id, bounds: w.bounds) // front-to-back 首个命中即最上层
        }
        return nil
    }

    /// 点是否落在窗口边缘 ~12pt 缩放带内（顶部边缘除外——那里属于标题栏移动带）。
    /// 滚动条的拖拽也发生在这条带里，调用方需要用 AX 尺寸比对来区分真实缩放
    func resizeEdgeHit(at cgPoint: CGPoint) -> TitlebarHit? {
        for w in onScreenWindows() {
            guard w.bounds.width >= 50, w.bounds.height >= 50 else { continue }
            guard w.bounds.contains(cgPoint) else { continue }
            guard !w.bounds.insetBy(dx: 12, dy: 12).contains(cgPoint) else { continue }
            guard cgPoint.y > w.bounds.minY + 12 else { continue } // 顶部交给标题栏移动带
            return TitlebarHit(pid: w.pid, windowID: w.id, bounds: w.bounds)
        }
        return nil
    }

    /// CGWindowID → AX 窗口元素（先按 windowID 精确匹配，兜底按 frame 近似匹配）
    func axWindow(pid: pid_t, windowID: CGWindowID, bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty
        else { return nil }
        for w in windows {
            var wid: CGWindowID = 0
            if axGetCGWindowID(w, &wid) == .success, wid == windowID { return w }
        }
        if bounds != .zero {
            for w in windows {
                if let f = frame(of: w), f.approxEquals(bounds, tolerance: 2) { return w }
            }
        }
        return nil
    }

    /// 只吸附标准、非全屏、非最小化、可调整大小的窗口
    func isSnappable(_ window: AXUIElement) -> Bool {
        var subrole: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
           let s = subrole as? String, s != kAXStandardWindowSubrole {
            return false
        }
        var fullscreen: AnyObject?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen) == .success,
           (fullscreen as? Bool) == true {
            return false
        }
        var minimized: AnyObject?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            return false
        }
        var sizeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
        return sizeSettable.boolValue
    }

    // MARK: 诊断辅助（仅 TilingDebug 打开时调用）

    /// 点附近的窗口候选（判断是否几何预过滤把目标漏掉了）
    func debugWindowsNear(_ p: CGPoint) -> String {
        let near = onScreenWindows().filter {
            $0.bounds.insetBy(dx: -4, dy: -4).contains(p) || abs($0.bounds.minY - p.y) < 120
        }
        return near.prefix(4).map { "pid=\($0.pid) bounds=\($0.bounds)" }.joined(separator: " | ")
    }

    func debugAXWindows(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return "AXWindows err=\(err.rawValue)" }
        let parts = windows.prefix(6).map { w -> String in
            var wid: CGWindowID = 0
            let e = axGetCGWindowID(w, &wid)
            return "wid=\(wid)/err\(e.rawValue) frame=\(frame(of: w).map { "\($0)" } ?? "nil")"
        }
        return "共 \(windows.count) 个窗口: " + parts.joined(separator: " | ")
    }

    func debugSnappable(_ window: AXUIElement) -> String {
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        var fullscreen: AnyObject?
        AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreen)
        var minimized: AnyObject?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        var sizeSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
        var posSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &posSettable)
        return "subrole=\(subrole as? String ?? "nil") fullscreen=\(String(describing: fullscreen as? Bool)) "
            + "minimized=\(String(describing: minimized as? Bool)) sizeSettable=\(sizeSettable.boolValue) posSettable=\(posSettable.boolValue)"
    }

    /// 读窗口 frame（CG 坐标）
    func frame(of window: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posRef = posValue, let sizeRef = sizeValue,
              // 外部 App 的 AX 树不可信：自绘窗口（Electron/Java）可能对这些属性
              // 返回非 AXValue 的东西，不查类型直接强转就是给别人送崩溃
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// 写窗口 frame（CG 坐标）。写入顺序固定 **尺寸 → 位置 → 尺寸**：
    /// 先写位置时窗口还是旧尺寸，"移过去会超出屏幕"的 App（终端类实测：Ghostty、
    /// Terminal）会把位置夹回屏内（x 被夹成 0），尺寸随后缩小也补不回来。
    /// 先缩到目标尺寸再移动即可绕开这个钳制，末尾再写一次尺寸兜住
    /// 移动过程中 App 自己的重排。
    /// 部分 App（实测）会**异步**应用 frame：同步读回是中间态（尺寸变了、位置还停在
    /// 旧坐标），要隔一小段时间再读才是真实结果——所以每轮写入后都等 60ms 再读回，
    /// 最多 3 轮；尺寸已到位但位置被回退的，最后单独补一次位置写。返回读回的实际 frame。
    @discardableResult
    func setFrame(_ window: AXUIElement, to rect: CGRect) -> CGRect? {
        var pos = rect.origin
        var size = rect.size
        guard let posValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return frame(of: window) }
        var lastRead: CGRect?
        for _ in 0..<3 {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            Thread.sleep(forTimeInterval: 0.06) // 等异步应用，别读中间态
            lastRead = frame(of: window)
            // 容差 4：App 的像素取整（如 855 vs 851.24）不值得再来一轮写入——
            // 多轮写入会让窗口肉眼可见地"再来一下"
            if let actual = lastRead, actual.approxEquals(rect, tolerance: 4) {
                return actual
            }
        }
        // 收敛失败（部分 App 只应用了一半写入）：缺哪个轴补哪个轴，各补一次再读回
        if let last = lastRead {
            let posOff = abs(last.minX - rect.minX) > 4 || abs(last.minY - rect.minY) > 4
            let sizeOff = abs(last.width - rect.width) > 4 || abs(last.height - rect.height) > 4
            if posOff {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
                Thread.sleep(forTimeInterval: 0.12)
            }
            if sizeOff {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
                Thread.sleep(forTimeInterval: 0.12)
            }
            if posOff || sizeOff { lastRead = frame(of: window) }
        }
        return lastRead ?? frame(of: window)
    }
}

// MARK: 分屏：网格浮层（拖动吸附时显示，鼠标穿透、不抢焦点）

private class GridOverlayView: NSView {
    var layout: LayoutNode = .cell { didSet { needsDisplay = true } }
    var highlighted: CGRect? { didSet { needsDisplay = true } } // 视图局部坐标

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
        for (_, rect) in layout.cellRects(in: bounds.insetBy(dx: 1, dy: 1)) {
            NSColor.white.withAlphaComponent(0.4).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
        if let h = highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: h).fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: h)
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}

private class GridOverlayWindow: NSWindow {
    private let gridView: GridOverlayView

    init(screen: NSScreen, layout: LayoutNode) {
        let frame = screen.visibleFrame
        gridView = GridOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        ignoresMouseEvents = true // 鼠标穿透
        isReleasedWhenClosed = false
        gridView.layout = layout
        contentView = gridView
    }

    /// 高亮一个格子（传入 AppKit 全局坐标，内部转成视图局部坐标）
    func setHighlight(globalRect: CGRect?) {
        if let r = globalRect {
            gridView.highlighted = r.offsetBy(dx: -frame.origin.x, dy: -frame.origin.y)
        } else {
            gridView.highlighted = nil
        }
    }
}

// MARK: 分屏：布局编辑器（盖在每个真实显示器上的半透明全屏编辑面，所见即所得）

private class EditorView: NSView {
    weak var session: LayoutEditorSession?
    var screenUUID = ""
    var layout: LayoutNode = .cell {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var selectedPath: [Int]? { didSet { needsDisplay = true } }
    private var dragging: (path: [Int], parentRect: CGRect, dir: SplitDir)?
    /// 鼠标悬停的分隔线（2px accent 高亮 + 光标变形，提示"这条线能拖"）
    private var hoveredLinePath: [Int]? { didSet { needsDisplay = true } }

    /// 绘制/命中统一使用的内容区（留 2px 边，贴边线才画得出）
    private var contentRect: CGRect { bounds.insetBy(dx: 2, dy: 2) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        for (path, rect) in layout.cellRects(in: contentRect) {
            let selected = path == selectedPath
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: rect).fill()
            }
            // 选中格 accent 描边，和其他格一眼区分开
            (selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.6)).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = selected ? 2 : 1
            outline.stroke()
        }
        // 悬停/拖拽中的分隔线高亮
        let activeLinePath = dragging?.path ?? hoveredLinePath
        for line in layout.splitLines(in: contentRect) where line.path == activeLinePath {
            NSColor.controlAccentColor.setStroke()
            let highlight = NSBezierPath(rect: line.line.insetBy(dx: -1, dy: -1))
            highlight.lineWidth = 2
            highlight.stroke()
        }
        let hint = "点击选中格子 · 拖动分隔线调比例 · 右键分割/合并 · Esc 取消 · ⏎ 保存"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let size = hint.size(withAttributes: attrs)
        // 提示文字垫一个圆角胶囊底，亮壁纸下也可读；放底部（顶部是工具条的地盘）
        let pill = NSRect(x: (bounds.width - size.width) / 2 - 12, y: 24,
                          width: size.width + 24, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        hint.draw(at: NSPoint(x: pill.minX + 12, y: pill.minY + 7), withAttributes: attrs)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // 分隔线左右/上下 4px 抓取带内的拖拽光标（AppKit 托管，不用手动 push/pop）
        for line in layout.splitLines(in: contentRect) {
            addCursorRect(line.line.insetBy(dx: -4, dy: -4),
                          cursor: line.dir == .v ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredLinePath = layout.splitLines(in: contentRect)
            .first { $0.line.insetBy(dx: -4, dy: -4).contains(p) }?.path
    }

    private func cellPath(at p: NSPoint) -> [Int]? {
        layout.cellRects(in: contentRect).first { $0.rect.contains(p) }?.path
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        session?.activateScreen(screenUUID)
        // 优先命中分隔线（4px 抓取范围）
        for line in layout.splitLines(in: contentRect)
        where line.line.insetBy(dx: -4, dy: -4).contains(p) {
            dragging = (line.path, line.parentRect, line.dir)
            return
        }
        selectedPath = cellPath(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let ratio: CGFloat
        switch d.dir {
        case .v: ratio = (p.x - d.parentRect.minX) / d.parentRect.width
        case .h: ratio = (d.parentRect.maxY - p.y) / d.parentRect.height // a=上方
        }
        // clamp 0.08–0.92
        let clamped = min(LayoutNode.maxRatio, max(LayoutNode.minRatio, ratio))
        session?.updateLayout(uuid: screenUUID) { $0.settingRatio(at: d.path, to: clamped) }
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let path = cellPath(at: p) else { return }
        selectedPath = path
        session?.activateScreen(screenUUID)

        let menu = NSMenu()
        let splitV = NSMenuItem(title: "左右分割", action: #selector(LayoutEditorSession.splitVertical), keyEquivalent: "")
        splitV.target = session
        let splitH = NSMenuItem(title: "上下分割", action: #selector(LayoutEditorSession.splitHorizontal), keyEquivalent: "")
        splitH.target = session
        let merge = NSMenuItem(title: "合并（取消上级分割）", action: #selector(LayoutEditorSession.mergeSelected), keyEquivalent: "")
        merge.target = session
        merge.isEnabled = !path.isEmpty // 根格子没有上级分割可取消
        menu.addItem(splitV)
        menu.addItem(splitH)
        menu.addItem(.separator())
        menu.addItem(merge)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

private class EditorWindow: NSWindow {
    let screenUUID: String
    let editorView: EditorView

    init(screen: NSScreen, uuid: String, layout: LayoutNode, session: LayoutEditorSession) {
        screenUUID = uuid
        editorView = EditorView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size))
        // 只盖 visibleFrame，不遮 Dock 和菜单栏
        editorView.screenUUID = uuid
        editorView.layout = layout
        editorView.session = session
        super.init(contentRect: screen.visibleFrame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true // 分隔线悬停高亮/光标变形依赖 mouseMoved
        contentView = editorView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private class EditorToolbarPanel: NSPanel {
    init(session: LayoutEditorSession) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 48),
                   // 注意：不加 .hudWindow——HUD 外观会强制改写按钮样式，主按钮的
                   // bezelColor 蓝色被吞掉；普通面板才能显出主操作层次
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "分屏布局编辑"
        // 编辑面是 .screenSaver 级，工具条必须更高，否则被编辑面盖住、按钮点不到
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        // 分组排布：格子的编辑 | 整屏布局操作 | 取消/保存（主操作最右、蓝色强调）
        let groups: [[(title: String, action: Selector, primary: Bool)]] = [
            [("左右分割", #selector(LayoutEditorSession.splitVertical), false),
             ("上下分割", #selector(LayoutEditorSession.splitHorizontal), false),
             ("合并", #selector(LayoutEditorSession.mergeSelected), false)],
            [("重置此屏", #selector(LayoutEditorSession.resetScreen), false),
             ("复制到所有屏", #selector(LayoutEditorSession.copyToAllScreens), false)],
            [("取消", #selector(LayoutEditorSession.cancelEditing), false),
             ("保存并应用", #selector(LayoutEditorSession.saveAndApply), true)],
        ]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        for (index, group) in groups.enumerated() {
            for (title, action, primary) in group {
                let button = NSButton(title: title, target: session, action: action)
                button.bezelStyle = .rounded
                if primary { button.bezelColor = .controlAccentColor }
                stack.addArrangedSubview(button)
            }
            if index < groups.count - 1, let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(22, after: last)
            }
        }
        contentView = stack
        // 初始位置：主屏顶部居中（标题栏可拖动）
        if let main = NSScreen.screens.first {
            let f = main.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 16))
        }
    }
}

/// 一次布局编辑会话：工作副本在内存里改，保存才落盘；Esc/取消直接丢弃
class LayoutEditorSession: NSObject {
    private weak var controller: TilingController?
    private var windows: [EditorWindow] = []
    private var toolbar: EditorToolbarPanel?
    private var escMonitor: Any?
    private var working: [String: LayoutNode] = [:]
    private var activeUUID: String?

    init(controller: TilingController) {
        self.controller = controller
        super.init()
    }

    func begin() {
        working = controller?.config.layouts ?? [:]
        for screen in NSScreen.screens {
            guard let uuid = DisplayKeys.uuid(for: screen) else { continue }
            let w = EditorWindow(screen: screen, uuid: uuid, layout: working[uuid] ?? .cell, session: self)
            w.orderFrontRegardless()
            windows.append(w)
        }
        let panel = EditorToolbarPanel(session: self)
        panel.orderFrontRegardless()
        toolbar = panel
        // Esc 取消 / Return 保存（本地监听：编辑面是 key 窗口，工具条按钮的 keyEquivalent 接不到）
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.end(save: false)
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return / 小键盘 Enter
                self?.end(save: true)
                return nil
            }
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
    }

    func end(save: Bool) {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
        for w in windows { w.close() }
        windows.removeAll()
        toolbar?.close()
        toolbar = nil
        if save { controller?.applyEditedLayouts(working) }
        controller?.editorClosed(self)
    }

    // MARK: 视图回调

    func activateScreen(_ uuid: String) { activeUUID = uuid }

    func updateLayout(uuid: String, _ transform: (LayoutNode) -> LayoutNode) {
        let current = working[uuid] ?? .cell
        working[uuid] = transform(current)
        for w in windows where w.screenUUID == uuid {
            w.editorView.layout = working[uuid] ?? .cell
        }
    }

    private func targetUUID() -> String? {
        if let activeUUID { return activeUUID }
        return NSScreen.screens.first.flatMap { DisplayKeys.uuid(for: $0) }
    }

    private func selectedPath(for uuid: String) -> [Int] {
        windows.first { $0.screenUUID == uuid }?.editorView.selectedPath ?? []
    }

    // MARK: 工具条 / 右键菜单动作

    @objc func splitVertical() { split(dir: .v) }
    @objc func splitHorizontal() { split(dir: .h) }

    private func split(dir: SplitDir) {
        guard let uuid = targetUUID() else { return }
        let path = selectedPath(for: uuid)
        updateLayout(uuid: uuid) { node in
            let old = node.subtree(at: path) ?? .cell
            return node.replacing(at: path, with: .split(dir: dir, ratio: 0.5, a: old, b: .cell))
        }
        // 分割后选中新的 a 侧格子
        windows.first { $0.screenUUID == uuid }?.editorView.selectedPath = path + [0]
    }

    @objc func mergeSelected() {
        guard let uuid = targetUUID() else { return }
        let path = selectedPath(for: uuid)
        guard !path.isEmpty else { return }
        let parent = Array(path.dropLast())
        updateLayout(uuid: uuid) { $0.replacing(at: parent, with: .cell) }
        windows.first { $0.screenUUID == uuid }?.editorView.selectedPath = parent
    }

    @objc func resetScreen() {
        guard let uuid = targetUUID() else { return }
        updateLayout(uuid: uuid) { _ in .cell }
    }

    @objc func copyToAllScreens() {
        guard let uuid = targetUUID() else { return }
        let layout = working[uuid] ?? .cell
        for w in windows {
            working[w.screenUUID] = layout
            w.editorView.layout = layout
        }
    }

    @objc func saveAndApply() { end(save: true) }
    @objc func cancelEditing() { end(save: false) }
}

// MARK: 分屏：控制器（event tap、双击/Shift 双击/Shift 拖动/甩动手势状态机、吸附/还原/最大化）

// 手势一览（全部经由标题栏，红绿灯区与无权限时放行）：
// - 双击标题栏        = 吸进光标所在格子（窗口已在格子里 → 还原到吸附前）
// - Shift + 双击标题栏 = 铺满当前屏幕（永远最大化，不还原）
// - Shift + 拖标题栏   = 网格浮层高亮吸附
// - 甩标题栏（1.2s 内来回 ≥2 折返、行程 ≥60pt）= 铺满当前屏幕
// - 普通拖 / 边缘缩放  = 取消吸附状态（下一个双击重新吸附）

private struct SnapRecord {
    var original: CGRect // 吸附前位置（CG 坐标）
    var snapped: CGRect  // 吸附后实际位置（读回值，CG 坐标）
    var lastUsed: Date
}

private struct DragSnapSession {
    let pid: pid_t
    let windowID: CGWindowID
    var didMove = false
    var highlightedCellAppKit: CGRect?
    /// 各屏格子快照（uuid, visibleFrame, rects）：布局在拖拽期间不变，开始时算一次
    var cellRectsByScreen: [(uuid: String, frame: CGRect, rects: [CGRect])] = []
}

private func tilingEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<TilingController>.fromOpaque(userInfo).takeUnretainedValue()
    // event tap 被系统静默禁用（回调超时/用户输入超时）：立即重启并复位状态机
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.tapDisabled()
        return Unmanaged.passUnretained(event)
    }
    return controller.handleMouse(type: type, event: event)
}

class TilingController: NSObject {
    /// 标题栏高度带（几何预过滤用）
    static let titleBarBandHeight: CGFloat = 28

    private(set) var config = TilingConfig.load()
    private let windowMgr = WindowManager()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var memoryCleaner: Timer?
    /// 辅助功能权限状态变化回调（参数 = 是否已授权）
    var onPermissionStateChange: ((Bool) -> Void)?
    private var permissionOK = false
    var isPermissionOK: Bool { permissionOK }

    // —— 双击吞噬状态机 ——
    /// 最近一次被吞的双击按下（位置+时间），用于三连击继续吞
    private var streakAnchor: (point: CGPoint, time: Date)?
    /// 有被吞的按下等待配对抬起
    private var pendingSwallowUp = false
    /// AX 命中失败的短 TTL 负缓存
    private var axNegativeCache: [String: Date] = [:]
    /// 还原记忆：windowID → (原始 frame, 吸附后实际 frame)
    private var snapMemory: [CGWindowID: SnapRecord] = [:]
    /// 手动拖动/缩放候选：无修饰键的按下后若发生明显移动 = 用户改了窗口几何，
    /// 抬起时取消该窗口的吸附记忆（移动/缩放本身就取消了"最大化"状态）
    private struct PlainDragCandidate {
        var down: CGPoint
        var pid: pid_t
        var windowID: CGWindowID
        var resizeZone: Bool // 按下落在窗口边缘缩放带（滚动条也在这里，抬起时需 AX 尺寸比对区分）
        var moved = false
    }
    private var plainDrag: PlainDragCandidate?
    /// 甩动最大化跟踪：无修饰键标题栏拖拽的轨迹（折返次数 + 行程），用于"甩一甩 = 铺满屏幕"
    private final class WiggleTracker {
        var downAt: Date
        var points: [(p: CGPoint, t: Date)] = []
        var lastDirUnit = CGVector.zero
        var reversals = 0
        var travel: CGFloat = 0
        init(downAt: Date) { self.downAt = downAt }
    }
    private var wiggle: WiggleTracker?
    /// 自跟踪双击兜底：上一次 clickState=1 的按下（时间+位置+是否带 Shift）。
    /// 系统偶尔把双击的两次按下都报成 clickState=1，此时只能自己按时间窗+同点距离判定
    private var lastSingleDown: (point: CGPoint, time: Date, mod: Bool)?
    /// 修饰键拖动会话
    private var drag: DragSnapSession?
    private var overlays: [String: GridOverlayWindow] = [:] // key = 显示器 UUID
    private var editor: LayoutEditorSession?
    /// tap 创建失败已记过日志（恢复时复位并记恢复）
    private var loggedTapFailure = false

    // MARK: 生命周期

    func start() {
        permissionOK = AXIsProcessTrustedWithOptions(nil)
        installTap()

        // 看门狗兜底：tap 被静默禁用则重启；同时低速复查权限状态
        let dog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.watchdogTick() }
        RunLoop.main.add(dog, forMode: .common)
        watchdog = dog

        // 定期清理失效窗口的还原记忆
        let cleaner = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.cleanSnapMemory() }
        RunLoop.main.add(cleaner, forMode: .common)
        memoryCleaner = cleaner

        // 睡眠唤醒 / 锁屏解锁 / 会话切换：重建 tap 并复位所有点击状态机
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(sessionChanged), name: NSWorkspace.didWakeNotification, object: nil)
        wc.addObserver(self, selector: #selector(sessionChanged), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        wc.addObserver(self, selector: #selector(sessionChanged), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        // 显示器配置变化：关闭编辑会话、失效显示器键缓存
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func stop() {
        removeTap()
        watchdog?.invalidate()
        memoryCleaner?.invalidate()
        hideOverlays()
        editor?.end(save: false)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func installTap() {
        removeTap()
        // 不订阅 mouseMoved：Shift 拖拽期间系统发的是 leftMouseDragged，
        // 订阅 mouseMoved 只会让每次鼠标移动都空跑一趟回调（稳态纯浪费）
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tilingEventCallback,
            userInfo: userInfo
        ) else {
            // 只在失败态翻转时记一次：watchdog 每 2s 重试，无权限时逐次记日志
            // 是每分钟 30 条，256KB 滚动上限下会把别的模块的真错误冲掉
            if !loggedTapFailure {
                loggedTapFailure = true
                ErrorLog.log("分屏: 鼠标事件 tap 创建失败（多为缺辅助功能权限；恢复前不再重复记录）")
            }
            return
        }
        if loggedTapFailure {
            loggedTapFailure = false
            ErrorLog.log("分屏: 鼠标事件 tap 已恢复")
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
    }

    func tapDisabled() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        resetInputState()
    }

    private func watchdogTick() {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                resetInputState()
            }
        } else {
            installTap() // tap 创建失败过（如权限刚授予）则重试
        }
        let trusted = AXIsProcessTrustedWithOptions(nil)
        if trusted != permissionOK {
            permissionOK = trusted
            onPermissionStateChange?(trusted)
        }
    }

    @objc private func sessionChanged() {
        installTap()       // 唤醒/解锁后重建 tap
        resetInputState()  // 拖动中/待吞的 up 等残留状态必须清零
    }

    @objc private func screenParametersChanged() {
        editor?.end(save: false)
        DisplayKeys.invalidateCache()
        hideOverlays()
        resetInputState()
    }

    /// 复位所有点击状态机
    private func resetInputState() {
        streakAnchor = nil
        pendingSwallowUp = false
        drag = nil
        plainDrag = nil
        wiggle = nil
        lastSingleDown = nil
        axNegativeCache.removeAll()
        hideOverlays()
    }

    /// Bento 自己的状态栏菜单展开期间，分屏整体让路。
    /// 菜单窗口是本进程的高 layer 窗口，被 onScreenWindows() 的 layer==0 + pid != myPid 过滤掉了，
    /// tap 只看得见菜单「底下」那个别家窗口的标题栏带——于是落在菜单项上的第 2 次点击
    /// 会被当成标题栏双击吞掉（自定义视图菜单项因此收不到双击），还顺手把那个无关窗口吸附走。
    /// 记「最后一次菜单活动的时间」而不是记 bool：万一 menuDidClose 没送到，
    /// 分屏不能就此永久瘫痪。菜单里每次高亮变化都会续期，所以这是无活动超时，
    /// 不是绝对超时——菜单被晾着开很久也不会让路失效
    private var menuTrackingSince: Date?
    private let menuTrackingGrace: TimeInterval = 120

    /// - Parameter tracking: true = 菜单打开或菜单内有交互（可重复调用，每次续期）
    func setMenuTracking(_ tracking: Bool) {
        guard tracking else {
            menuTrackingSince = nil
            return
        }
        // 首次进入时清干净：菜单开之前攒下的 streak/吞噬标志不该跨过这段
        if menuTrackingSince == nil { resetInputState() }
        menuTrackingSince = Date()
    }

    // MARK: 设置（菜单动作调用，改完即落盘）

    func setMasterEnabled(_ v: Bool) {
        config.masterEnabled = v
        config.save()
        if !v { resetInputState() }
    }

    // MARK: 事件处理（event tap 回调，必须极快：默认路径零 AX 调用）

    func handleMouse(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if let since = menuTrackingSince {
            if Date().timeIntervalSince(since) < menuTrackingGrace {
                return Unmanaged.passUnretained(event)
            }
            // 这么久没有菜单活动，多半是 menuDidClose 丢了——恢复正常，别让分屏一直瘫着
            menuTrackingSince = nil
        }
        switch type {
        case .leftMouseDown: return handleMouseDown(event)
        case .leftMouseUp: return handleMouseUp(event)
        case .leftMouseDragged, .mouseMoved: return handleMouseMoved(event)
        default: return Unmanaged.passUnretained(event)
        }
    }

    /// 诊断日志开关：defaults write com.sz.bento TilingDebug -bool YES（重启生效）
    private let debugEnabled = UserDefaults.standard.bool(forKey: "TilingDebug")
    private func dlog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        ErrorLog.log("分屏调试: \(message())")
    }

    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard config.masterEnabled, editor == nil else { return Unmanaged.passUnretained(event) }
        let point = event.location // CG 坐标
        let clickState = event.getIntegerValueField(.mouseEventClickState)
        if debugEnabled, clickState >= 2 {
            dlog("按下 clickState=\(clickState) point=\(point)")
        }

        // 新的真实按下：先清掉旧的吞噬标志，避免错吞正常点击的抬起造成"鼠标卡住"
        if clickState <= 1 {
            streakAnchor = nil
            pendingSwallowUp = false
        }

        // 修饰键 + 标题栏按下 → 开始拖动吸附会话（事件不吞，窗口正常跟随系统拖动）。
        // clickState≥2 的按下是双击的第二击，不启动拖动会话（否则 Shift 双击会闪网格浮层）
        if modifierMatches(event), clickState < 2 {
            beginDragIfOnTitlebar(at: point)
        }

        // 手动拖动/缩放跟踪（无修饰键、单击按下）：候选窗口只做几何判断，零 AX 成本。
        // 双击吸附的第二击不设候选——它后面不会跟拖动
        let singleHit: TitlebarHit?
        if clickState <= 1, !modifierMatches(event) {
            singleHit = windowMgr.titlebarHit(at: point, bandHeight: TilingController.titleBarBandHeight)
            if let hit = singleHit {
                plainDrag = PlainDragCandidate(down: point, pid: hit.pid, windowID: hit.windowID,
                                               resizeZone: false)
                // 甩动跟踪：标题栏按下即开始记录轨迹
                wiggle = WiggleTracker(downAt: Date())
            } else if let edge = windowMgr.resizeEdgeHit(at: point) {
                // 窗口边缘缩放带按下（滚动条的拖拽也落在这条带里，抬起时用 AX 尺寸比对区分）
                plainDrag = PlainDragCandidate(down: point, pid: edge.pid, windowID: edge.windowID,
                                               resizeZone: true)
            } else {
                plainDrag = nil
            }
        } else {
            singleHit = nil
        }

        if clickState >= 2 {
            // 已吞过一次双击：仍在系统双击时间窗内且位置未变的第 3 次及后续按下继续吞
            //（系统可能把第 1、3 次配对成另一次双击），但不再重复触发吸附
            if let anchor = streakAnchor,
               Date().timeIntervalSince(anchor.time) <= NSEvent.doubleClickInterval,
               abs(point.x - anchor.point.x) <= 4, abs(point.y - anchor.point.y) <= 4 {
                swallowClick(at: point)
                return nil
            }
            lastSingleDown = nil // 系统已把这次配对成双击，自跟踪候选作废
            // Shift + 双击 = 铺满屏幕；普通双击 = 吸进光标所在格子
            return performDoubleClickAction(event, at: point, maximize: modifierMatches(event))
        }
        // clickState 失灵兜底：实测系统偶尔把双击的两次按下都报成 clickState=1，
        // 这类"该执行却没执行"在日志里完全无痕。自己用时间窗 + 同点距离判定第二次按下
        if let last = lastSingleDown,
           last.mod == modifierMatches(event),
           Date().timeIntervalSince(last.time) <= NSEvent.doubleClickInterval,
           abs(point.x - last.point.x) <= 4, abs(point.y - last.point.y) <= 4 {
            lastSingleDown = nil
            dlog("自跟踪双击（clickState 未递增）point=\(point)")
            return performDoubleClickAction(event, at: point, maximize: modifierMatches(event))
        }
        lastSingleDown = (point, Date(), modifierMatches(event))
        if debugEnabled, singleHit != nil { dlog("单击按下（自跟踪候选）point=\(point)") }
        return Unmanaged.passUnretained(event)
    }

    /// 双击动作的完整流程（负缓存 → 几何预过滤 → AX 命中 → 异步执行 → 吞击）。
    /// maximize = Shift 双击（铺满屏幕）；否则普通双击（吸进光标所在格子）。
    /// 系统 clickState 路径与自跟踪兜底共用同一段逻辑
    private func performDoubleClickAction(_ event: CGEvent, at point: CGPoint, maximize: Bool) -> Unmanaged<CGEvent>? {
        // AX 负缓存：刚失败/无响应的目标在短时间内直接放行
        guard !isAxNegativeCached(point) else {
            dlog("放行：AX 负缓存命中")
            return Unmanaged.passUnretained(event)
        }

        // 零成本几何预过滤：不命中任何标题栏高度带就不做 AX 调用
        guard let hit = windowMgr.titlebarHit(at: point, bandHeight: TilingController.titleBarBandHeight) else {
            dlog("放行：不在任何窗口标题栏带内；候选=\(windowMgr.debugWindowsNear(point))")
            return Unmanaged.passUnretained(event)
        }
        dlog("命中窗口 pid=\(hit.pid) id=\(hit.windowID) bounds=\(hit.bounds)")

        // 红绿灯按钮区（窗口左上 ~80pt；zoom 右缘实测可到 ~68pt，留足余量）不参与
        // 双击吸附：双击关闭/最小化/缩放的第二击必须原样到达 App——按钮的多击跟踪
        // 要等最后一个抬起才触发动作，吞掉它会导致"点击没反应"，窗口反而被吸附走
        guard point.x > hit.bounds.minX + 80 else {
            dlog("放行：落在红绿灯区")
            return Unmanaged.passUnretained(event)
        }

        guard ensurePermission() else {
            dlog("放行：无辅助功能权限")
            return Unmanaged.passUnretained(event)
        }

        // 通过预过滤才做 AX 命中测试
        guard let window = windowMgr.axWindow(pid: hit.pid, windowID: hit.windowID, bounds: hit.bounds) else {
            dlog("放行：AX 未找到对应窗口（\(windowMgr.debugAXWindows(pid: hit.pid))）")
            cacheAxNegative(point)
            return Unmanaged.passUnretained(event)
        }
        guard windowMgr.isSnappable(window) else {
            dlog("放行：窗口不可吸附（\(windowMgr.debugSnappable(window))）")
            cacheAxNegative(point)
            return Unmanaged.passUnretained(event)
        }
        guard let frame = windowMgr.frame(of: window) else {
            dlog("放行：读不到窗口 frame")
            cacheAxNegative(point)
            return Unmanaged.passUnretained(event)
        }
        dlog("准备吸附 frame=\(frame)")

        // 写 frame 要多次 AX 往返，在 tap 回调里同步做有回调超时被系统摘掉 tap 的风险；
        // 回调只管吞掉这次点击，动作放到下一个主队列 tick（tap 回调本来就跑在主 runloop 上）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if maximize {
                // Shift 双击：窗口与 frame 已解析，直接复用，少一轮 AX 往返
                self.maximizeToScreen(window: window, current: frame, tag: "Shift双击最大化")
            } else {
                self.toggleSnap(window: window, id: hit.windowID, current: frame, clickPointCG: point)
            }
        }
        swallowClick(at: point)
        return nil // 吞掉这次按下，阻止系统默认的缩放/最小化
    }

    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if drag != nil { finishDrag() }
        // 手动拖动结束：拖过的窗口取消吸附记忆——用户拖动就代表"最大化状态已取消"，
        // 下次双击应重新吸附，而不是还原到拖动前的位置
        if let plain = plainDrag, plain.moved {
            lastSingleDown = nil // 这次手势消费了按下，别让它跟后续点击配成双击
            layoutStamp = Date() // 手动改动窗口几何：作废所有在途布局追踪，别把窗口拽回去
            // 甩动判定优先：标题栏来回甩 = 铺满屏幕（永远最大化，不做还原切换）
            if !plain.resizeZone, let w = wiggle, w.reversals >= 2, w.travel >= 60 {
                dlog("甩动手势触发 id=\(plain.windowID) 折返=\(w.reversals) 行程=\(Int(w.travel))")
                snapMemory.removeValue(forKey: plain.windowID) // 窗口被甩动了，格子吸附状态作废
                let pid = plain.pid, wid = plain.windowID
                DispatchQueue.main.async { [weak self] in
                    self?.wiggleMaximize(pid: pid, windowID: wid)
                }
            } else if plain.resizeZone {
                // 缩放带手势：滚动条的拖拽也在边缘带里——AX 确认尺寸真的变了才失效
                DispatchQueue.main.async { [weak self] in
                    guard let self, let rec = self.snapMemory[plain.windowID] else { return }
                    guard let window = self.windowMgr.axWindow(pid: plain.pid, windowID: plain.windowID, bounds: .zero),
                          let f = self.windowMgr.frame(of: window) else { return }
                    if abs(f.width - rec.snapped.width) > 3 || abs(f.height - rec.snapped.height) > 3,
                       self.snapMemory.removeValue(forKey: plain.windowID) != nil {
                        self.dlog("手动缩放取消吸附状态 id=\(plain.windowID)")
                    }
                }
            } else if snapMemory.removeValue(forKey: plain.windowID) != nil {
                dlog("手动拖动取消吸附状态 id=\(plain.windowID)")
            }
        }
        wiggle = nil
        plainDrag = nil
        if pendingSwallowUp {
            // 吞掉与被吞按下配对的抬起（新的真实按下会先清标志，不会错吞正常抬起）
            pendingSwallowUp = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleMouseMoved(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if drag != nil {
            if !(drag!.didMove) { showOverlays() } // 第一次实际拖动才弹网格（Shift 双击不闪浮层）
            drag?.didMove = true
            updateDragHighlight(at: event.location)
        }
        // 手动拖动候选 + 明显移动 = 用户在拖窗口（移动超过 6pt 才算拖动，滤掉微抖）
        if plainDrag != nil, !modifierMatches(event) {
            let dx = event.location.x - plainDrag!.down.x
            let dy = event.location.y - plainDrag!.down.y
            if dx * dx + dy * dy > 36 { plainDrag?.moved = true }
            if plainDrag?.resizeZone == false { updateWiggle(at: event.location) }
        }
        return Unmanaged.passUnretained(event)
    }

    /// 甩动轨迹跟踪：相邻段方向夹角 ≥120° 记一次折返；段长 ≥12pt 才算段（滤微抖）；
    /// 超过 1.2s 的轨迹点作废（甩动要快，慢拖不算）
    private func updateWiggle(at p: CGPoint) {
        guard let w = wiggle else { return }
        let now = Date()
        w.points.removeAll { now.timeIntervalSince($0.t) > 1.2 }
        if let last = w.points.last {
            let seg = hypot(p.x - last.p.x, p.y - last.p.y)
            guard seg >= 12 else { return }
            w.travel += seg
            let u = CGVector(dx: (p.x - last.p.x) / seg, dy: (p.y - last.p.y) / seg)
            if w.lastDirUnit != .zero {
                let cosAngle = u.dx * w.lastDirUnit.dx + u.dy * w.lastDirUnit.dy
                if cosAngle < -0.5 { w.reversals += 1 } // 夹角 ≥ 120°
            }
            w.lastDirUnit = u
        }
        w.points.append((p, now))
    }

    private func swallowClick(at point: CGPoint) {
        streakAnchor = (point, Date())
        pendingSwallowUp = true
    }

    private func modifierMatches(_ event: CGEvent) -> Bool {
        event.flags.contains(.maskShift) // 拖动吸附固定用 Shift（Shift+双击=铺满屏幕）
    }

    private func ensurePermission() -> Bool {
        let trusted = AXIsProcessTrustedWithOptions(nil)
        if trusted != permissionOK {
            permissionOK = trusted
            onPermissionStateChange?(trusted)
        }
        return trusted
    }

    // MARK: AX 负缓存

    private func negCacheKey(_ p: CGPoint) -> String {
        // 合成事件可以带 NaN/inf 坐标，Int(非有限 Double) 直接 trap
        guard p.x.isFinite, p.y.isFinite else { return "nonfinite" }
        return "\(Int(p.x / 8)):\(Int(p.y / 8))" // 8px 网格量化，避免轻微移动击穿缓存
    }

    private func isAxNegativeCached(_ p: CGPoint) -> Bool {
        let key = negCacheKey(p)
        if let expiry = axNegativeCache[key], expiry > Date() { return true }
        axNegativeCache[key] = nil
        return false
    }

    private func cacheAxNegative(_ p: CGPoint) {
        // 0.4s：只覆盖用户连击的间隙。TTL 太长会把紧跟着的第二次双击也放行掉，
        // 表现为"该执行的时候完全没有执行"
        axNegativeCache[negCacheKey(p)] = Date().addingTimeInterval(0.4)
        if axNegativeCache.count > 64 { axNegativeCache.removeAll() } // 防膨胀
    }

    // MARK: 吸附 / 还原

    private func toggleSnap(window: AXUIElement, id: CGWindowID, current: CGRect, clickPointCG: CGPoint) {
        layoutStamp = Date() // 双击吸附/还原同样作废甩动路径的在途追踪
        // 「处于最大化状态」直接比对格子，而不是比对记忆里的吸附后 frame：记忆可能被
        // App 钳制/记录陈旧；用户手动移动或缩放过后（哪怕只差一点），窗口就不再算
        // 最大化——双击一律重新最大化，只有精确落在格子里才还原
        if let rec = snapMemory[id],
           let cell = bestCell(for: CoordConv.fromCG(current), clickAppKit: CoordConv.fromCG(clickPointCG), clickFirst: true),
           CoordConv.toCG(cell).approxEquals(current, tolerance: 4) {
            dlog("还原到 \(rec.original)")
            let target = clampedToCurrentScreens(rec.original)
            let stamp = layoutStamp // 入口已 bump；回调时若又有新动作则作废本次结果
            onLayoutQueue({ [weak self] in
                self?.windowMgr.setFrame(window, to: target)
            }) { [weak self] result in
                guard let self, self.layoutStamp == stamp else { return }
                // 「读到 frame」≠「写入生效」：到达目标附近，或至少离开了所在格子
                //（App 按最小尺寸等自身约束钳制过）才算还原完成；读回 nil 或纹丝不动
                // 说明写入被拒——保留记忆，下次双击还能再试
                let cellCG = CoordConv.toCG(cell)
                if let result, result.approxEquals(target, tolerance: 8) || !result.approxEquals(cellCG, tolerance: 4) {
                    self.snapMemory.removeValue(forKey: id)
                } else {
                    self.dlog("还原写入未生效，保留记忆")
                }
            }
            return
        }
        // 所在格子：双击 = 光标所在格子优先（窗口横跨多个格子时，用户点的是标题栏的
        // 哪一段就该进哪个格子，而不是按重叠面积猜）；光标不在任何格子里（点在分隔线上）
        // 才退化为重叠面积最大
        guard let cell = bestCell(for: CoordConv.fromCG(current), clickAppKit: CoordConv.fromCG(clickPointCG), clickFirst: true)
        else {
            dlog("放行：没找到目标格子")
            return
        }
        dlog("目标格子(AppKit)=\(cell)")
        snap(window: window, id: id, current: current, to: cell)
    }

    /// 甩动最大化：总是铺满窗口当前所在屏幕的 visibleFrame（普通最大化，不是全屏空间）。
    /// 不做还原切换——甩动只表达"最大化"这一个意图；已最大化时再甩 = 幂等地再写一次
    private func wiggleMaximize(pid: pid_t, windowID: CGWindowID) {
        guard let window = windowMgr.axWindow(pid: pid, windowID: windowID, bounds: .zero),
              let current = windowMgr.frame(of: window)
        else { return }
        maximizeToScreen(window: window, current: current, tag: "甩动最大化")
    }

    /// 铺满屏幕的核心：Shift 双击路径复用已解析的窗口与 frame，少一轮 AX 往返
    private func maximizeToScreen(window: AXUIElement, current: CGRect, tag: String) {
        let point = CoordConv.fromCG(CGPoint(x: current.midX, y: current.midY))
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(point) }) ?? NSScreen.main
        else { return }
        let fullCG = CoordConv.toCG(screen.visibleFrame)
        let stamp = Date()
        layoutStamp = stamp // 作废所有在途的落定追踪
        dlog("\(tag) 目标=\(fullCG)")
        writeFrameTracked(window, to: fullCG, stamp: stamp, tag: tag)
    }

    /// 全局布局戳：任何新的布局动作（吸附/还原/甩动/手动拖动）都会 bump，让旧的
    /// 落定追踪作废——否则一次甩动后的补写会把用户紧跟着的双击吸附给盖掉
    private var layoutStamp = Date()

    /// 布局写入串行队列：AX 写入与 setFrame 的重试睡眠（3 轮 × 60ms）都在这里做——
    /// 同步放在主线程会让 UI 短暂卡顿；状态（snapMemory 等）仍在主线程更新
    private let layoutQueue = DispatchQueue(label: "com.sz.bento.tiling.layout")

    /// 在布局队列上执行 AX 读写，完成后回主线程
    private func onLayoutQueue<T>(_ body: @escaping () -> T, then: @escaping (T) -> Void) {
        layoutQueue.async {
            let result = body()
            DispatchQueue.main.async { then(result) }
        }
    }

    /// 写 frame + 落定追踪（0.15/0.7s 两次补写兜底，容差 6）：异步应用 frame 的 App
    /// 会只应用一半写入（尺寸变大、位置丢半路）——补写要快，甩动的"铺满"才不拖沓。
    /// 写入与补写都在布局队列执行（不在主线程睡眠）
    private func writeFrameTracked(_ window: AXUIElement, to target: CGRect, stamp: Date, tag: String) {
        onLayoutQueue({ [weak self] in
            self?.windowMgr.setFrame(window, to: target)
        }) { _ in }
        for rc in [(0.15, true), (0.35, false), (0.7, true), (1.3, false)] {
            DispatchQueue.main.asyncAfter(deadline: .now() + rc.0) { [weak self] in
                guard let self, self.layoutStamp == stamp,
                      let settled = self.windowMgr.frame(of: window)
                else { return }
                if rc.1, !settled.approxEquals(target, tolerance: 6) {
                    self.onLayoutQueue({ [weak self] in
                        self?.windowMgr.setFrame(window, to: target)
                    }) { [weak self] again in
                        guard let self, self.layoutStamp == stamp, let again else { return }
                        self.dlog("\(tag)落定补写 目标=\(target) 实际=\(again)")
                    }
                }
            }
        }
    }

    private func snap(window: AXUIElement, id: CGWindowID, current: CGRect, to cellAppKit: CGRect) {
        layoutStamp = Date() // 作废甩动路径的在途追踪
        // 只在首次吸附时记录原始位置；反复吸附/在格子间移动不得覆盖
        if snapMemory[id] == nil {
            snapMemory[id] = SnapRecord(original: current, snapped: .zero, lastUsed: Date())
        }
        let target = CoordConv.toCG(cellAppKit)
        let stamp = Date()
        layoutStamp = stamp
        snapMemory[id]?.lastUsed = stamp
        onLayoutQueue({ [weak self] in
            self?.windowMgr.setFrame(window, to: target)
        }) { [weak self] actual in
            guard let self, self.snapMemory[id]?.lastUsed == stamp else { return }
            if let actual {
                self.dlog("写入 frame 目标=\(target) 实际=\(actual)")
                if !actual.approxEquals(target, tolerance: 3) {
                    // App 自身约束（最小尺寸/步进）钳制，或异步应用还没完成——后续落定重读会再校正
                    self.dlog("写入与目标偏差大（App 约束钳制/异步应用？）目标=\(target) 实际=\(actual)")
                }
                self.snapMemory[id]?.snapped = actual
            } else {
                self.dlog("写入 frame 失败 目标=\(target)")
            }
        }

        // 落定追踪：异步应用 frame 的 App 只应用一半写入时（尺寸到位、位置丢在半路），
        // 窗口会以错误状态挂着——纠偏要快，但补写也不能堆（每补一次就是一次可见动作）。
        // 折中：0.35s 第一次补（错误状态只挂一瞬），0.7s 只观察让 App 应用，1.2s 还不齐
        // 再补一次，之后只记录不再动手。容差 6：App 的像素取整（如 855 vs 851.24）
        // 不算偏离，避免无谓的"再来一下"。stamp 比对：期间还原/再吸附/手动拖动
        //（记忆被删）都会让本次追踪作废
        let rechecks: [(delay: TimeInterval, allowRewrite: Bool)] = [
            (0.35, true), (0.7, false), (1.2, true), (2.8, false),
        ]
        for rc in rechecks {
            DispatchQueue.main.asyncAfter(deadline: .now() + rc.delay) { [weak self] in
                guard let self, self.snapMemory[id]?.lastUsed == stamp,
                      let settled = self.windowMgr.frame(of: window)
                else { return }
                if settled != self.snapMemory[id]?.snapped {
                    self.dlog("落定 frame=\(settled)")
                }
                self.snapMemory[id]?.snapped = settled
                if rc.allowRewrite, !settled.approxEquals(target, tolerance: 6) {
                    onLayoutQueue({ [weak self] in
                        self?.windowMgr.setFrame(window, to: target)
                    }) { [weak self] again in
                        guard let self, self.snapMemory[id]?.lastUsed == stamp, let again else { return }
                        self.dlog("落定补写 目标=\(target) 实际=\(again)")
                        self.snapMemory[id]?.snapped = again
                    }
                }
            }
        }
    }

    private func bestCell(for windowAppKit: CGRect, clickAppKit: CGPoint, clickFirst: Bool) -> CGRect? {
        // 双击吸附：光标所在格子优先——窗口横跨多个格子时，按重叠面积猜会猜错
        // （点右边那段标题栏却吸进左边格子，窗口右缘还可能溢出到隔壁格子里）
        if clickFirst {
            for screen in NSScreen.screens {
                guard screen.visibleFrame.contains(clickAppKit),
                      let uuid = DisplayKeys.uuid(for: screen)
                else { continue }
                let layout = config.layouts[uuid] ?? .cell
                for (_, rect) in layout.cellRects(in: screen.visibleFrame) where rect.contains(clickAppKit) {
                    return rect
                }
            }
        }
        var bestRect = CGRect.zero
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            guard let uuid = DisplayKeys.uuid(for: screen) else { continue }
            let layout = config.layouts[uuid] ?? .cell
            for (_, rect) in layout.cellRects(in: screen.visibleFrame) {
                let inter = rect.intersection(windowAppKit)
                let area = inter.isNull ? 0 : inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    bestRect = rect
                }
            }
        }
        if bestArea > 0 { return bestRect }
        // 无重叠 → 取光标所在格子
        for screen in NSScreen.screens {
            guard screen.visibleFrame.contains(clickAppKit),
                  let uuid = DisplayKeys.uuid(for: screen)
            else { continue }
            let layout = config.layouts[uuid] ?? .cell
            for (_, rect) in layout.cellRects(in: screen.visibleFrame) where rect.contains(clickAppKit) {
                return rect
            }
        }
        return nil
    }

    /// 还原前校验原始 frame：仍与某屏相交则原样还原；显示器已拔掉则钳制到最近屏幕的 visibleFrame 内
    private func clampedToCurrentScreens(_ cgRect: CGRect) -> CGRect {
        let screensCG = NSScreen.screens.map { CoordConv.toCG($0.visibleFrame) }
        for s in screensCG where !s.intersection(cgRect).isNull { return cgRect }
        guard let nearest = screensCG.min(by: { distanceToFrame($0, from: cgRect) < distanceToFrame($1, from: cgRect) })
        else { return cgRect }
        var r = cgRect
        r.size.width = min(r.width, nearest.width)
        r.size.height = min(r.height, nearest.height)
        r.origin.x = min(max(r.minX, nearest.minX), nearest.maxX - r.width)
        r.origin.y = min(max(r.minY, nearest.minY), nearest.maxY - r.height)
        return r
    }

    private func distanceToFrame(_ frame: CGRect, from r: CGRect) -> CGFloat {
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = c.x < frame.minX ? frame.minX - c.x : max(0, c.x - frame.maxX)
        let dy = c.y < frame.minY ? frame.minY - c.y : max(0, c.y - frame.maxY)
        return dx + dy
    }

    /// 清理已失效窗口句柄和 30 分钟未用的记忆条目。
    /// 判活必须用全量窗口列表：onScreenOnly 会把「只是切去了别的 Space」的窗口
    /// 当成已关闭，用户切走待一分钟回来，吸附还原记忆就被误删了
    private func cleanSnapMemory() {
        let alive = windowMgr.allWindowIDs()
        guard !alive.isEmpty else { return } // 枚举失败别当成全部窗口都关了
        let cutoff = Date().addingTimeInterval(-1800)
        snapMemory = snapMemory.filter { alive.contains($0.key) && $0.value.lastUsed > cutoff }
    }

    // MARK: 修饰键拖动吸附

    private func beginDragIfOnTitlebar(at cgPoint: CGPoint) {
        guard drag == nil else { return }
        guard let hit = windowMgr.titlebarHit(at: cgPoint, bandHeight: TilingController.titleBarBandHeight)
        else { return }
        var session = DragSnapSession(pid: hit.pid, windowID: hit.windowID)
        for screen in NSScreen.screens {
            guard let uuid = DisplayKeys.uuid(for: screen) else { continue }
            let layout = config.layouts[uuid] ?? .cell
            session.cellRectsByScreen.append((uuid, screen.visibleFrame,
                                              layout.cellRects(in: screen.visibleFrame).map(\.rect)))
        }
        drag = session
        // 浮层延迟到第一次实际拖动再显示：Shift 双击时按下就建会话，立刻弹网格会闪一下
    }

    private func updateDragHighlight(at cgPoint: CGPoint) {
        let p = CoordConv.fromCG(cgPoint)
        var foundUUID: String?
        var foundRect: CGRect?
        for entry in drag?.cellRectsByScreen ?? [] {
            guard entry.frame.contains(p) else { continue }
            if let rect = entry.rects.first(where: { $0.contains(p) }) {
                foundUUID = entry.uuid
                foundRect = rect
            }
            break
        }
        for (uuid, overlay) in overlays {
            overlay.setHighlight(globalRect: uuid == foundUUID ? foundRect : nil)
        }
        drag?.highlightedCellAppKit = foundRect
    }

    private func finishDrag() {
        guard let session = drag else { return }
        drag = nil
        hideOverlays()
        // 没有实际拖动就不吸附（避免修饰键+单击误触发）
        guard session.didMove, let cell = session.highlightedCellAppKit else { return }
        guard ensurePermission() else { return }
        // 同 handleMouseDown：AX 往返不放在 tap 回调里同步做
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.windowMgr.axWindow(pid: session.pid, windowID: session.windowID, bounds: .zero),
                  self.windowMgr.isSnappable(window),
                  let current = self.windowMgr.frame(of: window)
            else { return }
            self.snap(window: window, id: session.windowID, current: current, to: cell)
        }
    }

    // MARK: 网格浮层

    private func showOverlays() {
        hideOverlays()
        for screen in NSScreen.screens {
            guard let uuid = DisplayKeys.uuid(for: screen) else { continue }
            let w = GridOverlayWindow(screen: screen, layout: config.layouts[uuid] ?? .cell)
            overlays[uuid] = w
            w.orderFrontRegardless()
        }
    }

    private func hideOverlays() {
        for (_, w) in overlays { w.orderOut(nil) }
        overlays.removeAll()
    }

    // MARK: 布局编辑器

    func openLayoutEditor() {
        guard editor == nil else { return }
        hideOverlays()
        let session = LayoutEditorSession(controller: self)
        editor = session
        session.begin()
    }

    func applyEditedLayouts(_ layouts: [String: LayoutNode]) {
        config.layouts = layouts
        config.save()
    }

    func editorClosed(_ session: LayoutEditorSession) {
        if editor === session { editor = nil }
    }
}
