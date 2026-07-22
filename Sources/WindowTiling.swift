import AppKit
import CoreGraphics
import Foundation
import IOKit

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
        let type = try c.decode(String.self, forKey: .type)
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

    /// 防御式解析：任何字段缺失/类型错误都回退默认值，绝不抛异常
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterEnabled = (try? c.decode(Bool.self, forKey: .masterEnabled)) ?? true
        layouts = (try? c.decode([String: LayoutNode].self, forKey: .layouts)) ?? [:]
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
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: TilingConfig.configURL, options: .atomic)
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

    /// 当前屏幕上 layer-0 窗口（front-to-back），排除本进程（避免拦到自己）
    func onScreenWindows() -> [OnScreenWindowInfo] {
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
        return result
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

    /// 读窗口 frame（CG 坐标）
    func frame(of window: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posRef = posValue, let sizeRef = sizeValue
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// 写窗口 frame（CG 坐标）。设置后读回实际值：部分 App 会按自身约束
    ///（最小尺寸、步进）修正，误差大就再设一次，最多 2 次收敛。
    /// 返回读回的实际 frame。
    @discardableResult
    func setFrame(_ window: AXUIElement, to rect: CGRect) -> CGRect? {
        for _ in 0..<2 {
            var pos = rect.origin
            var size = rect.size
            if let posValue = AXValueCreate(.cgPoint, &pos),
               let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }
            if let actual = frame(of: window), actual.approxEquals(rect, tolerance: 3) {
                return actual
            }
        }
        return frame(of: window)
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
    var layout: LayoutNode = .cell { didSet { needsDisplay = true } }
    var selectedPath: [Int]? { didSet { needsDisplay = true } }
    private var dragging: (path: [Int], parentRect: CGRect, dir: SplitDir)?

    /// 绘制/命中统一使用的内容区（留 2px 边，贴边线才画得出）
    private var contentRect: CGRect { bounds.insetBy(dx: 2, dy: 2) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        for (path, rect) in layout.cellRects(in: contentRect) {
            if path == selectedPath {
                NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: rect).fill()
            }
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
        let hint = "点击选中格子 · 拖动分隔线调比例 · 右键分割/合并 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 12),
                  withAttributes: attrs)
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
        contentView = editorView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private class EditorToolbarPanel: NSPanel {
    init(session: LayoutEditorSession) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 48),
                   styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "分屏布局编辑"
        // 编辑面是 .screenSaver 级，工具条必须更高，否则被编辑面盖住、按钮点不到
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        let specs: [(String, Selector)] = [
            ("左右分割", #selector(LayoutEditorSession.splitVertical)),
            ("上下分割", #selector(LayoutEditorSession.splitHorizontal)),
            ("合并", #selector(LayoutEditorSession.mergeSelected)),
            ("重置此屏", #selector(LayoutEditorSession.resetScreen)),
            ("复制到所有屏", #selector(LayoutEditorSession.copyToAllScreens)),
            ("保存并应用", #selector(LayoutEditorSession.saveAndApply)),
            ("取消", #selector(LayoutEditorSession.cancelEditing)),
        ]
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for (title, action) in specs {
            let button = NSButton(title: title, target: session, action: action)
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
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
        // Esc 随时取消
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.end(save: false)
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

// MARK: 分屏：控制器（event tap、双击/拖动状态机、吸附与还原）

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
    /// 修饰键拖动会话
    private var drag: DragSnapSession?
    private var overlays: [String: GridOverlayWindow] = [:] // key = 显示器 UUID
    private var editor: LayoutEditorSession?

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
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tilingEventCallback,
            userInfo: userInfo
        ) else {
            ErrorLog.log("分屏: 鼠标事件 tap 创建失败")
            return
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
        axNegativeCache.removeAll()
        hideOverlays()
    }

    // MARK: 设置（菜单动作调用，改完即落盘）

    func setMasterEnabled(_ v: Bool) {
        config.masterEnabled = v
        config.save()
        if !v { resetInputState() }
    }

    // MARK: 事件处理（event tap 回调，必须极快：默认路径零 AX 调用）

    func handleMouse(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .leftMouseDown: return handleMouseDown(event)
        case .leftMouseUp: return handleMouseUp(event)
        case .leftMouseDragged, .mouseMoved: return handleMouseMoved(event)
        default: return Unmanaged.passUnretained(event)
        }
    }

    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard config.masterEnabled, editor == nil else { return Unmanaged.passUnretained(event) }
        let point = event.location // CG 坐标
        let clickState = event.getIntegerValueField(.mouseEventClickState)

        // 新的真实按下：先清掉旧的吞噬标志，避免错吞正常点击的抬起造成"鼠标卡住"
        if clickState <= 1 {
            streakAnchor = nil
            pendingSwallowUp = false
        }

        // 修饰键 + 标题栏按下 → 开始拖动吸附会话（事件不吞，窗口正常跟随系统拖动）
        if modifierMatches(event) {
            beginDragIfOnTitlebar(at: point)
        }

        guard clickState >= 2 else {
            return Unmanaged.passUnretained(event)
        }

        // 已吞过一次双击：仍在系统双击时间窗内且位置未变的第 3 次及后续按下继续吞
        //（系统可能把第 1、3 次配对成另一次双击），但不再重复触发吸附
        if let anchor = streakAnchor,
           Date().timeIntervalSince(anchor.time) <= NSEvent.doubleClickInterval,
           abs(point.x - anchor.point.x) <= 4, abs(point.y - anchor.point.y) <= 4 {
            swallowClick(at: point)
            return nil
        }

        // AX 负缓存：刚失败/无响应的目标在短时间内直接放行
        guard !isAxNegativeCached(point) else { return Unmanaged.passUnretained(event) }

        // 零成本几何预过滤：不命中任何标题栏高度带就不做 AX 调用
        guard let hit = windowMgr.titlebarHit(at: point, bandHeight: TilingController.titleBarBandHeight) else {
            return Unmanaged.passUnretained(event)
        }

        // 红绿灯按钮区（窗口左上 ~70pt）不参与双击吸附：双击关闭/最小化的第二击
        // 必须原样到达 App——按钮的多击跟踪要等最后一个抬起才触发动作，吞掉它
        // 会导致"点击关闭没反应"，窗口反而被吸附走
        guard point.x > hit.bounds.minX + 70 else {
            return Unmanaged.passUnretained(event)
        }

        guard ensurePermission() else { return Unmanaged.passUnretained(event) }

        // 通过预过滤才做 AX 命中测试
        guard let window = windowMgr.axWindow(pid: hit.pid, windowID: hit.windowID, bounds: hit.bounds),
              windowMgr.isSnappable(window),
              let frame = windowMgr.frame(of: window) else {
            cacheAxNegative(point)
            return Unmanaged.passUnretained(event)
        }

        toggleSnap(window: window, id: hit.windowID, current: frame, clickPointCG: point)
        swallowClick(at: point)
        return nil // 吞掉这次按下，阻止系统默认的缩放/最小化
    }

    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        if drag != nil { finishDrag() }
        if pendingSwallowUp {
            // 吞掉与被吞按下配对的抬起（新的真实按下会先清标志，不会错吞正常抬起）
            pendingSwallowUp = false
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleMouseMoved(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard drag != nil else { return Unmanaged.passUnretained(event) }
        drag?.didMove = true
        updateDragHighlight(at: event.location)
        return Unmanaged.passUnretained(event)
    }

    private func swallowClick(at point: CGPoint) {
        streakAnchor = (point, Date())
        pendingSwallowUp = true
    }

    private func modifierMatches(_ event: CGEvent) -> Bool {
        event.flags.contains(.maskCommand) // 拖动吸附固定用 ⌘
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
        "\(Int(p.x / 8)):\(Int(p.y / 8))" // 8px 网格量化，避免轻微移动击穿缓存
    }

    private func isAxNegativeCached(_ p: CGPoint) -> Bool {
        let key = negCacheKey(p)
        if let expiry = axNegativeCache[key], expiry > Date() { return true }
        axNegativeCache[key] = nil
        return false
    }

    private func cacheAxNegative(_ p: CGPoint) {
        axNegativeCache[negCacheKey(p)] = Date().addingTimeInterval(0.75)
        if axNegativeCache.count > 64 { axNegativeCache.removeAll() } // 防膨胀
    }

    // MARK: 吸附 / 还原

    private func toggleSnap(window: AXUIElement, id: CGWindowID, current: CGRect, clickPointCG: CGPoint) {
        // 已处于上次吸附后的实际位置 → 还原（判断用吸附后实际 frame，兼容有最小尺寸限制的窗口）
        if let rec = snapMemory[id], current.approxEquals(rec.snapped, tolerance: 4) {
            windowMgr.setFrame(window, to: clampedToCurrentScreens(rec.original))
            snapMemory.removeValue(forKey: id)
            return
        }
        // 所在格子 = 与窗口当前可见边界重叠面积最大的格子；无重叠时取光标所在格子
        guard let cell = bestCell(for: CoordConv.fromCG(current), fallbackAppKit: CoordConv.fromCG(clickPointCG))
        else { return }
        snap(window: window, id: id, current: current, to: cell)
    }

    private func snap(window: AXUIElement, id: CGWindowID, current: CGRect, to cellAppKit: CGRect) {
        // 只在首次吸附时记录原始位置；反复吸附/在格子间移动不得覆盖
        if snapMemory[id] == nil {
            snapMemory[id] = SnapRecord(original: current, snapped: .zero, lastUsed: Date())
        }
        if let actual = windowMgr.setFrame(window, to: CoordConv.toCG(cellAppKit)) {
            snapMemory[id]?.snapped = actual
            snapMemory[id]?.lastUsed = Date()
        }
    }

    private func bestCell(for windowAppKit: CGRect, fallbackAppKit: CGPoint) -> CGRect? {
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
            guard screen.visibleFrame.contains(fallbackAppKit),
                  let uuid = DisplayKeys.uuid(for: screen)
            else { continue }
            let layout = config.layouts[uuid] ?? .cell
            for (_, rect) in layout.cellRects(in: screen.visibleFrame) where rect.contains(fallbackAppKit) {
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

    /// 清理已失效窗口句柄和 30 分钟未用的记忆条目
    private func cleanSnapMemory() {
        let alive = Set(windowMgr.onScreenWindows().map { $0.id })
        let cutoff = Date().addingTimeInterval(-1800)
        snapMemory = snapMemory.filter { alive.contains($0.key) && $0.value.lastUsed > cutoff }
    }

    // MARK: 修饰键拖动吸附

    private func beginDragIfOnTitlebar(at cgPoint: CGPoint) {
        guard drag == nil else { return }
        guard let hit = windowMgr.titlebarHit(at: cgPoint, bandHeight: TilingController.titleBarBandHeight)
        else { return }
        drag = DragSnapSession(pid: hit.pid, windowID: hit.windowID)
        showOverlays()
        updateDragHighlight(at: cgPoint)
    }

    private func updateDragHighlight(at cgPoint: CGPoint) {
        let p = CoordConv.fromCG(cgPoint)
        var foundUUID: String?
        var foundRect: CGRect?
        for screen in NSScreen.screens {
            guard screen.visibleFrame.contains(p), let uuid = DisplayKeys.uuid(for: screen) else { continue }
            let layout = config.layouts[uuid] ?? .cell
            for (_, rect) in layout.cellRects(in: screen.visibleFrame) where rect.contains(p) {
                foundUUID = uuid
                foundRect = rect
                break
            }
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
        guard let window = windowMgr.axWindow(pid: session.pid, windowID: session.windowID, bounds: .zero),
              windowMgr.isSnappable(window),
              let current = windowMgr.frame(of: window)
        else { return }
        snap(window: window, id: session.windowID, current: current, to: cell)
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
