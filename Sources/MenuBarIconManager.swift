import AppKit
import CoreGraphics
import Foundation
import IOKit

// MARK: - Menu Bar Icon Manager (菜单栏图标管理)

// 实现要点（全部在 macOS 27 上实测验证；26 的 ControlCenter 托管 + 合成 ⌘ 拖拽方案已废弃）：
// - macOS 27 起菜单栏由独立的 MenuBarAgent 进程整体托管：不再是每图标一个 layer-25
//   CG 窗口，而是整条菜单栏几个大窗口。图标位置持久化在 com.apple.MenuBarAgent 的
//   TrailingItemPreferredPositions 字典里：键 = "status:<签名标识>::<autosaveName>"
//   （正规签名 App 用 bundleID，ad-hoc/无签名用可执行名，故自家条目两种前缀都写），
//   值 = 距右缘的偏好位置，越大越靠左。外部改写该字典 0.5s 内实时生效（cfprefsd
//   通知），无需重启 agent、无需任何合成事件。
// - 系统布局算法 = 贪心跳洞：按 position 从小到大自右向左排布，放不下的项跳进
//   「«」溢出区（chevron 点击展开），然后继续排后面的。没有"截断"——超宽项只会
//   自己被跳过，挡不住任何人（10000pt hider 方案在 27 上无效，已删除）。
// - 隐藏 = 赋一个比所有可见项都大的 position（隐藏区 1100+）：拥挤的菜单栏
//   （刘海 + 行情条这类宽图标）放不下最左侧的它们 → 稳定折叠进溢出区。
//   局限：空间充裕时隐藏项会重新可见（27 上没有强制隐藏的原语）。
// - 警惕：agent 会在状态项注册/注销等扰动后用自己算出的"实际距离"整体重写字典
//   （含溢出/展开态下的瞬态坐标），所以字典数值绝不能当成用户的隐藏意图来采纳
//   ——隐藏/显示意图只来自本管理器的 UI；字典只用来采纳"可见项的左右顺序"
//   （实际值忠实反映真实排列，无害）。语义不一致（该隐没隐/顺序不对/条目缺失）
//   时下一轮回写纠正即可自愈，数值上的漂移不管，避免与 agent 互写打架。
// - 身份仍走各 App 的 AXExtrasMenuBar（title/desc），持久化键沿用 bundleID|序号；
//   系统模块经 module:* 条目管理（时钟/控制中心被系统钉死，除外）。

private let mbaPrefDomain = "com.apple.MenuBarAgent" as CFString
private let mbaPositionsKey = "TrailingItemPreferredPositions" as CFString

/// 菜单栏图标管理器：枚举/识别图标、维护隐藏集合、钉住 Bento 主图标
class MenuBarIconManager: NSObject {
    /// 给管理界面用的一行数据
    struct Row: Equatable {
        let key: String
        let name: String
        let isHidden: Bool
        let canHide: Bool // Bento 本尊只可排序，不可隐藏
    }

    private let queue = DispatchQueue(label: "com.sz.bento.iconmgr")
    private var timer: Timer?
    private var managerWindow: NSWindow?
    private var tableView: NSTableView?

    /// 持久化的隐藏键集合
    private var hiddenKeys: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "HiddenMenuBarItemKeys") ?? [])
    }() {
        didSet { UserDefaults.standard.set(Array(hiddenKeys), forKey: "HiddenMenuBarItemKeys") }
    }

    /// 图标顺序（左→右，与菜单栏一致），持久化
    private var iconOrder: [String] = UserDefaults.standard.stringArray(forKey: "MenuBarIconOrder") ?? [] {
        didSet { UserDefaults.standard.set(iconOrder, forKey: "MenuBarIconOrder") }
    }
    /// 键 → 显示名缓存（App 退出后其隐藏行仍能显示名字），持久化
    private var iconNames: [String: String] = (UserDefaults.standard.dictionary(forKey: "MenuBarIconNames") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(iconNames, forKey: "MenuBarIconNames") }
    }
    /// UI 操作触发的一轮 enforce 跳过顺序采纳（别把用户刚拖好的顺序又用旧位置覆盖回去）
    private var suppressAdoptionOnce = false
    /// 变更检测：agent 字典 + 运行中 App 集合的签名；没变且未超兜底间隔就跳过 AX 枚举（重活）
    private var lastSignature = 0
    private var lastFullPass = Date.distantPast
    /// 管理界面数据（主线程发布）
    fileprivate(set) var rows: [Row] = []
    /// 列表更新回调（在主线程调用）
    var onRowsChanged: (() -> Void)?

    // MARK: 生命周期

    func start() {
        // 首次延迟 2s，等菜单栏和自己图标就位
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.enforce() }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.queue.async { self?.enforce() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: agent 字典读写（后台线程）

    private func readRawPositions() -> [String: Any] {
        CFPreferencesAppSynchronize(mbaPrefDomain)
        return (CFPreferencesCopyAppValue(mbaPositionsKey, mbaPrefDomain) as? [String: Any]) ?? [:]
    }

    private func writeRawPositions(_ dict: [String: Any]) {
        CFPreferencesSetAppValue(mbaPositionsKey, dict as CFDictionary, mbaPrefDomain)
        CFPreferencesAppSynchronize(mbaPrefDomain)
    }

    /// 自家状态栏项在 agent 字典里的候选键（签名标识可能是 bundleID 或可执行名，两种都管）
    private func ownEntryKeys(_ autosave: String) -> [String] {
        var out = ["status:\(ProcessInfo.processInfo.processName)::\(autosave)"]
        if let bid = Bundle.main.bundleIdentifier { out.append("status:\(bid)::\(autosave)") }
        return out
    }

    // MARK: 图标枚举与身份识别（后台线程）

    private struct ExtraItem {
        let midX: CGFloat
        let title: String
        let desc: String
        let axIdentifier: String
    }

    /// 读某个进程的 AXExtrasMenuBar 子元素
    private func extras(of pid: pid_t) -> [ExtraItem] {
        let app = AXUIElementCreateApplication(pid)
        var extrasValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasValue) == .success,
              let bar = extrasValue
        else { return [] }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        var out: [ExtraItem] = []
        for el in children as? [AXUIElement] ?? [] {
            var title: AnyObject?, desc: AnyObject?, pos: AnyObject?, size: AnyObject?, ident: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &desc)
            AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos)
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size)
            AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &ident)
            var p = CGPoint.zero
            var s = CGSize.zero
            if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
            if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
            guard s.width > 0 else { continue } // 无尺寸的是占位/系统隐藏项
            out.append(ExtraItem(midX: p.x + s.width / 2,
                                 title: (title as? String) ?? "",
                                 desc: (desc as? String) ?? "",
                                 axIdentifier: (ident as? String) ?? ""))
        }
        return out
    }

    /// 单个已识别图标
    private struct LiveItem {
        let key: String          // 持久化键：bundleID|序号（title 可能是动态角标，不能入键）
        let displayName: String
        let entryKeys: [String]  // 它在 agent 字典里的条目键（现有配对的，或新建候选）
    }

    /// 枚举所有第三方图标，并解析每个图标在 agent 字典里的条目键。
    /// Spotlight/输入法/Siri 等系统代理的图标也是普通 extras 项，一并纳入；
    /// 只排除控制中心与 MenuBarAgent 自身（它们的 extras 是系统模块的宿主）。
    private func enumerateItems(positions: [String: Double]) -> [LiveItem] {
        var out: [LiveItem] = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != myPID, let bundleID = app.bundleIdentifier,
                  bundleID != "com.apple.controlcenter",
                  bundleID != "com.apple.MenuBarAgent" else { continue }
            let items = extras(of: pid)
            guard !items.isEmpty else { continue }
            let appName = app.localizedName ?? bundleID
            // 条目键前缀：正规签名 App 用 bundleID，ad-hoc/无签名用 CFBundleName（≈可执行名）
            var prefixes = ["status:\(bundleID)::"]
            if let url = app.bundleURL,
               let name = Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String,
               !name.isEmpty, name != bundleID {
                prefixes.append("status:\(name)::")
            }
            // 该 App 现有条目数与图标数一致时按序配对（覆盖 "Siri"/"Item-1" 这类非默认 autosaveName）
            let existing = positions.keys.filter { k in prefixes.contains { k.hasPrefix($0) } }.sorted()
            for (idx, extra) in items.enumerated() {
                let human = !extra.title.isEmpty ? extra.title : (!extra.desc.isEmpty ? extra.desc : appName)
                let name = human == appName ? human : "\(appName) · \(human)"
                let entryKeys = existing.count == items.count
                    ? [existing[idx]]
                    : prefixes.map { $0 + "Item-\(idx)" }
                out.append(LiveItem(key: "\(bundleID)|\(idx + 1)", displayName: name, entryKeys: entryKeys))
            }
        }
        return out
    }

    /// 系统模块 AX id → agent 字典键名（已知映射；其余用去前缀首字母大写兜底）
    private static let moduleKeyMap: [String: String] = [
        "com.apple.menuextra.battery": "Battery",
        "com.apple.menuextra.wifi": "WiFi",
        "com.apple.menuextra.clock": "Clock",
        "com.apple.menuextra.user": "UserSwitcher",
        "com.apple.menuextra.controlcenter": "BentoBox", // 控制中心的内部名，纯属巧合
    ]
    /// 系统钉死不吃 position 写入的模块（实测：改写被无视、frame 不动）——不纳入管理
    private static let pinnedModules: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
    ]

    /// 枚举 MenuBarAgent 托管的系统模块（电池/Wi‑Fi/用户切换…），键直接用 module: 条目键
    private func enumerateModules(positions: [String: Double]) -> [LiveItem] {
        guard let mba = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return [] }
        var found: [(id: String, desc: String)] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth <= 5 else { return }
            var roleV: AnyObject?, identV: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleV)
            // 第二个宿主窗口里挂着各 App 的 AX 代理树，別往里钻（又大又慢）
            if depth > 0, roleV as? String == "AXApplication" { return }
            AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &identV)
            if let ident = identV as? String, ident.hasPrefix("com.apple.menuextra.") {
                var descV: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descV)
                if !found.contains(where: { $0.id == ident }) {
                    found.append((ident, (descV as? String) ?? ""))
                }
                return
            }
            var children: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            for kid in children as? [AXUIElement] ?? [] { walk(kid, depth + 1) }
        }
        var windows: AnyObject?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(mba.processIdentifier),
                                      kAXWindowsAttribute as CFString, &windows)
        for w in windows as? [AXUIElement] ?? [] { walk(w, 0) }

        var out: [LiveItem] = []
        for (id, desc) in found where !Self.pinnedModules.contains(id) {
            let short = String(id.dropFirst("com.apple.menuextra.".count))
            let name = Self.moduleKeyMap[id] ?? (short.prefix(1).uppercased() + short.dropFirst())
            // 实例可能带 -0 后缀（如 module:BentoBox-0）；字典里找不到条目就不管理
            guard let entryKey = ["module:\(name)", "module:\(name)-0"].first(where: { positions[$0] != nil })
            else { continue }
            // desc 可能带实时状态（"Wi‑Fi，已接入，3格"），截到第一个逗号
            let clean = desc.split(separator: "，").first.map(String.init) ?? desc
            out.append(LiveItem(key: entryKey, displayName: clean.isEmpty ? name : clean, entryKeys: [entryKey]))
        }
        return out
    }

    /// 图标当前生效位置：条目键的任一现值
    private func currentPos(of item: LiveItem, in positions: [String: Double]) -> Double? {
        for k in item.entryKeys {
            if let v = positions[k] { return v }
        }
        return nil
    }

    // MARK: 状态纠正（每 3s，后台线程）

    private func enforce(force: Bool = false) {
        guard AXIsProcessTrustedWithOptions(nil) else { return }
        // MenuBarAgent 不在 = 不是 macOS 27 的菜单栏机制，本模块不适用
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").isEmpty
        else { return }
        let skipAdoption = suppressAdoptionOnce
        suppressAdoptionOnce = false

        var raw = readRawPositions()
        let positions = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let runningIDs = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).sorted()

        // —— 门控：agent 字典和运行 App 集都没变且未超兜底间隔，就不跑 AX 枚举（重活）——
        var hasher = Hasher()
        hasher.combine(positions)
        hasher.combine(runningIDs)
        let signature = hasher.finalize()
        let stale = Date().timeIntervalSince(lastFullPass) > 60
        guard force || stale || signature != lastSignature else { return }
        lastFullPass = Date()

        var items = enumerateItems(positions: positions)
        items += enumerateModules(positions: positions)
        // Bento 本尊也作为一行参与排序（不可隐藏，setRowHidden 与采纳都有防御）
        items.append(LiveItem(key: "bento:main", displayName: "Bento", entryKeys: ownEntryKeys("BentoMain")))
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        if hiddenKeys.contains("bento:main") { hiddenKeys.remove("bento:main") }

        // —— 布局参数（数值只有相对意义）：统一网格 base+8i 覆盖第三方与系统模块；
        //    隐藏区远大于可见区，靠拥挤的菜单栏放不下它们实现折叠。
        //    被钉死的模块（时钟/控制中心）无视这一切 ——
        let base = 100.0
        let hiddenBase = 1100.0             // 隐藏区起点
        let hiddenThreshold = 1050.0        // 隐藏区判定线（仅用于语义校验，不用于采纳意图）

        // —— 采纳（只采纳顺序，绝不采纳隐藏状态）：agent 会在状态项注册/注销后
        // 用瞬态实际坐标整体重写字典，位置数值不能当隐藏意图；隐藏/显示只听 UI。
        // 顺序采纳每轮必做（含启动首轮）：菜单栏实际排列是顺序的事实来源，
        // 决不能反过来用陈旧的持久化顺序去重排用户的菜单栏。
        // UI 操作触发的一轮跳过（别把用户刚拖好的顺序又用旧位置覆盖回去）
        let placed: [(key: String, pos: Double)] = items.compactMap { it in
            currentPos(of: it, in: positions).map { (it.key, $0) }
        }
        if !skipAdoption {
            // 可见图标按位置降序 = 左→右；只重排 iconOrder 中这些键的相对顺序
            let newVisibleOrder = placed.filter { !hiddenKeys.contains($0.key) }
                .sorted { $0.pos > $1.pos }.map(\.key)
            let visibleSet = Set(newVisibleOrder).intersection(iconOrder)
            var pending = newVisibleOrder.filter { visibleSet.contains($0) }
            var reordered = iconOrder
            for (i, k) in reordered.enumerated() where visibleSet.contains(k) {
                reordered[i] = pending.removeFirst()
            }
            if reordered != iconOrder { iconOrder = reordered }
        }
        // 新出现的键按当前实际位置插入顺序表：从右往左处理，各自插到右邻之前，
        // 顺序表首次接管系统模块/本尊时不会打乱它们的现有排列
        let posOrder = placed.sorted { $0.pos > $1.pos }.map(\.key) // 左→右
        for key in posOrder.reversed() where !iconOrder.contains(key) {
            if let idx = posOrder.firstIndex(of: key),
               let successor = posOrder.dropFirst(idx + 1).first(where: { iconOrder.contains($0) }),
               let insertAt = iconOrder.firstIndex(of: successor) {
                iconOrder.insert(key, at: insertAt)
            } else {
                iconOrder.append(key)
            }
        }
        // 连字典条目都还没有的全新图标：追加到末尾
        for item in items where !iconOrder.contains(item.key) { iconOrder.append(item.key) }
        // 名字缓存（App 退出后隐藏行还得有名字）
        for item in items where iconNames[item.key] != item.displayName { iconNames[item.key] = item.displayName }

        let present = Set(items.map(\.key))
        let visibleList = iconOrder.filter { present.contains($0) && !hiddenKeys.contains($0) }
        let hiddenList = iconOrder.filter { present.contains($0) && hiddenKeys.contains($0) }

        // —— 期望布局（右端位置值最小；间距 8 留出手动拖拽的插入空间）——
        var desired: [(keys: [String], pos: Double)] = []
        for (i, key) in visibleList.reversed().enumerated() {
            desired.append((byKey[key]!.entryKeys, base + Double(i) * 8))
        }
        for (j, key) in hiddenList.reversed().enumerated() {
            desired.append((byKey[key]!.entryKeys, hiddenBase + Double(j) * 8))
        }

        // —— 语义校验：只在“该隐没隐/该显没显/顺序不对/条目缺失/没钉住”时才回写，
        //    数值上的细微差异不管（agent 可能改写数值，逐字节强求会互写打架）。
        //    启动时状态通常已正确 → 不写 → 避免每次启动都让 agent 重排菜单栏
        var writeNeeded = false
        for key in visibleList {
            let pos = currentPos(of: byKey[key]!, in: positions)
            if pos == nil || pos! > hiddenThreshold { writeNeeded = true }
        }
        for key in hiddenList {
            let pos = currentPos(of: byKey[key]!, in: positions)
            if pos == nil || pos! <= hiddenThreshold { writeNeeded = true }
        }
        let currentVisibleOrder = visibleList
            .compactMap { k in currentPos(of: byKey[k]!, in: positions).map { (k, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
        if currentVisibleOrder != visibleList.filter({ k in
            currentPos(of: byKey[k]!, in: positions) != nil
        }) { writeNeeded = true }

        var finalPositions = positions
        if writeNeeded {
            for entry in desired {
                for k in entry.keys {
                    raw[k] = entry.pos
                    finalPositions[k] = entry.pos
                }
            }
            // 清掉历史方案的旧条目（默认 autosaveName 时代 + 已废弃的 hider）
            for legacy in ["status:Bento::Item-0", "status:Bento::Item-1",
                           "status:Bento::BentoHider", "status:com.sz.bento::BentoHider"] {
                raw.removeValue(forKey: legacy)
                finalPositions.removeValue(forKey: legacy)
            }
            writeRawPositions(raw)
        }
        // 签名以回写后的字典为准，别把自己的写入当成下一轮的外部变化
        var finalHasher = Hasher()
        finalHasher.combine(finalPositions)
        finalHasher.combine(runningIDs)
        lastSignature = finalHasher.finalize()

        // UI 操作后若溢出区正处于展开态（»），主动收起，让用户立刻看到隐藏结果；
        // 否则展开条会把刚隐藏的图标继续显示最长约一分钟（自动收起前），像是隐藏没生效
        if skipAdoption {
            queue.asyncAfter(deadline: .now() + 0.8) { self.collapseChevronIfExpanded() }
        }

        publishRows(byKey: byKey)
    }

    /// 溢出区展开态的 chevron（»，desc = "Double forward chevron"）存在时，点它一下收起。
    /// 这是本模块仅剩的合成事件：单次点击、目标是系统自己的收起按钮，无拖拽风险。
    private func collapseChevronIfExpanded() {
        guard let mba = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return }
        var chevron: CGRect?
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard chevron == nil, depth <= 4 else { return }
            var role: AnyObject?, desc: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &desc)
            if role as? String == "AXImage", (desc as? String)?.contains("forward chevron") == true {
                var pos: AnyObject?, size: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos)
                AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size)
                var p = CGPoint.zero
                var s = CGSize.zero
                if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
                if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
                if s.width > 0 { chevron = CGRect(origin: p, size: s) }
                return
            }
            var children: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            for kid in children as? [AXUIElement] ?? [] { walk(kid, depth + 1) }
        }
        var windows: AnyObject?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(mba.processIdentifier),
                                      kAXWindowsAttribute as CFString, &windows)
        for w in windows as? [AXUIElement] ?? [] { walk(w, 0) }
        guard let chevron else { return } // 没展开，无事可做
        let saved = CGEvent(source: nil)?.location
        let p = CGPoint(x: chevron.midX, y: chevron.midY)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        if let saved { CGWarpMouseCursorPosition(saved) }
    }

    private func publishRows(byKey: [String: LiveItem]) {
        var newRows: [Row] = []
        for key in iconOrder {
            if let item = byKey[key] {
                newRows.append(Row(key: key, name: item.displayName,
                                   isHidden: hiddenKeys.contains(key), canHide: key != "bento:main"))
            } else if hiddenKeys.contains(key) {
                // 已隐藏但 App 没在运行：保留行，保证还能取消隐藏
                newRows.append(Row(key: key, name: iconNames[key] ?? key, isHidden: true, canHide: true))
            }
        }
        DispatchQueue.main.async {
            // 内容没变就不动 UI：管理窗口开着时，每轮重建复选框会把主线程打满
            guard self.rows != newRows else { return }
            self.rows = newRows
            self.onRowsChanged?()
        }
    }

    // MARK: 对外操作（主线程）

    func setRowHidden(_ key: String, _ hidden: Bool) {
        guard key != "bento:main" else { return } // 本尊不可隐藏
        if hidden {
            hiddenKeys.insert(key)
        } else {
            hiddenKeys.remove(key)
        }
        queue.async {
            self.suppressAdoptionOnce = true
            self.enforce(force: true)
        }
    }

    func openManagerWindow() {
        if let managerWindow {
            managerWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "菜单栏图标管理"
        window.isReleasedWhenClosed = false
        window.center()

        let hint = NSTextField(wrappingLabelWithString: "勾选 = 显示，取消勾选 = 隐藏（收进菜单栏「«」溢出区）；拖动行调整顺序（上 = 菜单栏左）\n时钟与控制中心被系统固定，无法管理；Bento 本尊只可排序")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 26
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 340
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.string])
        tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false

        // 逃生舱：一键全部恢复显示（比如状态不收敛、或想推倒重来）
        let showAll = NSButton(title: "全部恢复显示", target: self, action: #selector(showAllRows))
        showAll.bezelStyle = .rounded
        showAll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(showAll)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: showAll.topAnchor, constant: -10),
            showAll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            showAll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content

        onRowsChanged = { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.tableView?.reloadData()
        }
        window.delegate = self
        managerWindow = window
        table.reloadData()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 打开时立刻刷新一次列表
        queue.async { self.enforce(force: true) }
    }

    @objc private func rowToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        setRowHidden(key, sender.state == .off)
    }

    @objc private func showAllRows() {
        hiddenKeys.removeAll()
        queue.async {
            self.suppressAdoptionOnce = true
            self.enforce(force: true)
        }
    }
}

// MARK: 管理列表（NSTableView：复选框行 + 拖拽排序）

extension MenuBarIconManager: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let cell = NSTableCellView()
        let checkbox = NSButton(checkboxWithTitle: r.name, target: self, action: #selector(rowToggled(_:)))
        checkbox.state = r.isHidden ? .off : .on
        checkbox.identifier = NSUserInterfaceItemIdentifier(r.key)
        checkbox.isEnabled = r.canHide
        checkbox.lineBreakMode = .byTruncatingTail
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(checkbox)
        let grip = NSTextField(labelWithString: "≡")
        grip.textColor = .tertiaryLabelColor
        grip.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(grip)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: grip.leadingAnchor, constant: -6),
            checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            grip.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            grip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        rows.indices.contains(row) ? rows[row].key as NSString : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let key = info.draggingPasteboard.string(forType: .string),
              let from = rows.firstIndex(where: { $0.key == key }) else { return false }
        var to = row
        if from < to { to -= 1 }
        guard to != from else { return false }
        let moved = rows.remove(at: from)
        rows.insert(moved, at: min(max(to, 0), rows.count))
        // 行顺序写回 iconOrder（清单里没展示的键保持相对位置，追加在末尾）
        var newOrder = rows.map(\.key)
        for k in iconOrder where !newOrder.contains(k) { newOrder.append(k) }
        iconOrder = newOrder
        tableView.reloadData()
        queue.async {
            self.suppressAdoptionOnce = true
            self.enforce(force: true)
        }
        return true
    }
}

extension MenuBarIconManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        managerWindow = nil
        tableView = nil
        onRowsChanged = nil
    }
}
