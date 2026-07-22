import AppKit
import CoreGraphics
import Foundation

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
    private var emptyView: NSView?
    private var footnoteLabel: NSTextField?

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
    /// AX 探测记忆：探测过的 pid / 确认有菜单栏图标的 pid（常规轮跳过确认无图标的进程）
    private var probedPIDs = Set<pid_t>()
    private var extrasPIDs = Set<pid_t>()
    /// bundleID → CFBundleName 缓存（读 bundle 是磁盘操作）
    private var bundleNameCache: [String: String] = [:]
    /// 键 → 最近一次解析出的条目键（退出恢复用）；配对失败只记一次日志
    private var lastEntryKeys: [String: [String]] = [:]
    private var loggedPairingIssues = Set<String>()
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

    /// 自家状态栏项在 agent 字典里的条目键：先认字典里现存的候选；都不存在时只写
    /// 可执行名前缀（实测：agent 对 ad-hoc 签名用可执行名 "Bento"，bundleID 变体
    /// 它永不消费且会在自己的整体重写时丢弃——别再制造幻影键）
    private func ownEntryKeys(_ autosave: String, positions: [String: Double]) -> [String] {
        var candidates = ["status:\(ProcessInfo.processInfo.processName)::\(autosave)"]
        if let bid = Bundle.main.bundleIdentifier { candidates.append("status:\(bid)::\(autosave)") }
        let existing = candidates.filter { positions[$0] != nil }
        return existing.isEmpty ? [candidates[0]] : existing
    }

    // MARK: 图标枚举与身份识别（后台线程）

    private struct ExtraItem {
        let title: String
        let desc: String
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
            var title: AnyObject?, desc: AnyObject?, size: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &desc)
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size)
            var s = CGSize.zero
            if let size { AXValueGetValue(size as! AXValue, .cgSize, &s) }
            guard s.width > 0 else { continue } // 无尺寸的是占位/系统隐藏项
            out.append(ExtraItem(title: (title as? String) ?? "",
                                 desc: (desc as? String) ?? ""))
        }
        return out
    }

    /// 单个已识别图标
    private struct LiveItem {
        let key: String          // 持久化键：bundleID|序号（title 可能是动态角标，不能入键）
        let displayName: String
        let stableName: String   // 不含易变部分（行情/角标）的名字，进 iconNames 持久化缓存
        let entryKeys: [String]  // 它在 agent 字典里的条目键（现有配对的，或新建候选）
    }

    /// 枚举所有第三方图标，并解析每个图标在 agent 字典里的条目键。
    /// Spotlight/输入法/Siri 等系统代理的图标也是普通 extras 项，一并纳入；
    /// 只排除控制中心与 MenuBarAgent 自身（它们的 extras 是系统模块的宿主）。
    /// fullProbe = false 时只探测「已知有图标的 pid + 首次见到的 pid」；
    /// 60s 兜底全量轮传 true，覆盖“App 启动很久后才创建图标”的场景
    private func enumerateItems(positions: [String: Double],
                                runningApps: [NSRunningApplication],
                                fullProbe: Bool) -> (items: [LiveItem], junkKeys: [String]) {
        var out: [LiveItem] = []
        var junk: [String] = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        var alivePIDs = Set<pid_t>()
        for app in runningApps {
            let pid = app.processIdentifier
            guard pid != myPID, let bundleID = app.bundleIdentifier,
                  bundleID != "com.apple.controlcenter",
                  bundleID != "com.apple.MenuBarAgent" else { continue }
            alivePIDs.insert(pid)
            // 大多数进程没有菜单栏图标：探测过且确认没有的，常规轮直接跳过 AX 往返
            if !fullProbe, probedPIDs.contains(pid), !extrasPIDs.contains(pid) { continue }
            let items = extras(of: pid)
            probedPIDs.insert(pid)
            if items.isEmpty {
                extrasPIDs.remove(pid)
                continue
            }
            extrasPIDs.insert(pid)
            let appName = app.localizedName ?? bundleID
            // 条目键前缀：正规签名 App 用 bundleID，ad-hoc/无签名用 CFBundleName（≈可执行名）。
            // CFBundleName 按 bundleID 缓存，避免每轮读磁盘 bundle
            var prefixes = ["status:\(bundleID)::"]
            let cfName: String
            if let cached = bundleNameCache[bundleID] {
                cfName = cached
            } else {
                cfName = (app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }) ?? ""
                bundleNameCache[bundleID] = cfName
            }
            if !cfName.isEmpty, cfName != bundleID {
                prefixes.append("status:\(cfName)::")
            }
            // 选定生效前缀：哪个前缀在字典里有条目用哪个（都有则取 bundleID——正规签名
            // App 的规范前缀），另一个前缀的条目是幻影键，标记清除；都没有时用 bundleID
            // 合成（几乎所有第三方菜单栏 App 都是正规签名）。原则：宁可不写，不写错键
            let byPrefix = prefixes.map { pf in (pf, positions.keys.filter { $0.hasPrefix(pf) }.sorted()) }
            let active = byPrefix.first(where: { !$0.1.isEmpty }) ?? (prefixes[0], [])
            for (pf, keys) in byPrefix where pf != active.0 && !keys.isEmpty {
                junk.append(contentsOf: keys)
            }
            let existing = active.1
            for (idx, extra) in items.enumerated() {
                let human = !extra.title.isEmpty ? extra.title : (!extra.desc.isEmpty ? extra.desc : appName)
                let name = human == appName ? human : "\(appName) · \(human)"
                // 配对阶梯：唯一现存键直配 → 数量相等按序配 → 数量不等按 Item-N 序号配，
                // 配不上就跳过写入并记一次日志 → 无现存键才合成
                let entryKeys: [String]
                if existing.count == 1, items.count == 1 {
                    entryKeys = [existing[0]]
                } else if existing.count == items.count {
                    entryKeys = [existing[idx]]
                } else if !existing.isEmpty {
                    let numbered = "\(active.0)Item-\(idx)"
                    if existing.contains(numbered) {
                        entryKeys = [numbered]
                    } else {
                        entryKeys = []
                        if !loggedPairingIssues.contains(bundleID) {
                            loggedPairingIssues.insert(bundleID)
                            ErrorLog.log("图标管理: \(appName) 键配对失败（现有 \(existing.count) 键 vs \(items.count) 图标），跳过写入")
                        }
                    }
                } else {
                    entryKeys = ["\(active.0)Item-\(idx)"]
                }
                out.append(LiveItem(key: "\(bundleID)|\(idx + 1)", displayName: name,
                                    stableName: appName, entryKeys: entryKeys))
            }
        }
        // 只保留还活着的 pid，防止长时间运行后集合无限膨胀（pid 会被系统复用）
        probedPIDs.formIntersection(alivePIDs)
        extrasPIDs.formIntersection(alivePIDs)
        return (out, junk)
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
    private func enumerateModules(positions: [String: Double], mbaApp: NSRunningApplication) -> [LiveItem] {
        let mba = mbaApp
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
            let display = clean.isEmpty ? name : clean
            out.append(LiveItem(key: entryKey, displayName: display, stableName: display, entryKeys: [entryKey]))
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
        let runningApps = NSWorkspace.shared.runningApplications
        // MenuBarAgent 不在 = 不是 macOS 27 的菜单栏机制，本模块不适用
        guard let mbaApp = runningApps.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" })
        else { return }
        let skipAdoption = suppressAdoptionOnce
        suppressAdoptionOnce = false

        var raw = readRawPositions()
        let positions = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let runningIDs = runningApps.compactMap(\.bundleIdentifier).sorted()

        // —— 门控：agent 字典和运行 App 集都没变且未超兜底间隔，就不跑 AX 枚举（重活）——
        var hasher = Hasher()
        hasher.combine(positions)
        hasher.combine(runningIDs)
        let signature = hasher.finalize()
        let stale = Date().timeIntervalSince(lastFullPass) > 60
        guard force || stale || signature != lastSignature else { return }
        lastFullPass = Date()

        let (thirdParty, junkKeys) = enumerateItems(positions: positions, runningApps: runningApps, fullProbe: stale)
        var items = thirdParty
        items += enumerateModules(positions: positions, mbaApp: mbaApp)
        // Bento 本尊也作为一行参与排序（不可隐藏，setRowHidden 与采纳都有防御）
        items.append(LiveItem(key: "bento:main", displayName: "Bento", stableName: "Bento",
                              entryKeys: ownEntryKeys("BentoMain", positions: positions)))
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        for item in items where !item.entryKeys.isEmpty { lastEntryKeys[item.key] = item.entryKeys }
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
        // 在本地副本上改，循环外一次性赋值：didSet 每次赋值都写 UserDefaults，逐元素改会写放大
        let posOrder = placed.sorted { $0.pos > $1.pos }.map(\.key) // 左→右
        var order = iconOrder
        for key in posOrder.reversed() where !order.contains(key) {
            if let idx = posOrder.firstIndex(of: key),
               let successor = posOrder.dropFirst(idx + 1).first(where: { order.contains($0) }),
               let insertAt = order.firstIndex(of: successor) {
                order.insert(key, at: insertAt)
            } else {
                order.append(key)
            }
        }
        // 连字典条目都还没有的全新图标：追加到末尾
        for item in items where !order.contains(item.key) { order.append(item.key) }
        if order != iconOrder { iconOrder = order }
        // 名字缓存（App 退出后隐藏行还得有名字）：只存稳定名，行情/角标这类易变文本不进磁盘
        var names = iconNames
        for item in items { names[item.key] = item.stableName }
        if names != iconNames { iconNames = names }

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
        // 配对失败（entryKeys 为空）的项旁观语义校验：写不进正确的键，别拿它反复置位
        var writeReasons: [String] = []
        for key in visibleList {
            guard let item = byKey[key], !item.entryKeys.isEmpty else { continue }
            let pos = currentPos(of: item, in: positions)
            if pos == nil { writeReasons.append("\(key) 缺条目") }
            else if pos! > hiddenThreshold { writeReasons.append("\(key) 该显未显") }
        }
        for key in hiddenList {
            guard let item = byKey[key], !item.entryKeys.isEmpty else { continue }
            let pos = currentPos(of: item, in: positions)
            if pos == nil || pos! <= hiddenThreshold { writeReasons.append("\(key) 该隐未隐") }
        }
        let currentVisibleOrder = visibleList
            .compactMap { k in currentPos(of: byKey[k]!, in: positions).map { (k, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
        if currentVisibleOrder != visibleList.filter({ k in
            currentPos(of: byKey[k]!, in: positions) != nil
        }) { writeReasons.append("可见顺序不符") }
        if !junkKeys.isEmpty { writeReasons.append("清理幻影键 \(junkKeys.count) 个") }

        var finalPositions = positions
        if !writeReasons.isEmpty {
            for entry in desired {
                for k in entry.keys {
                    raw[k] = entry.pos
                    finalPositions[k] = entry.pos
                }
            }
            // 清掉历史方案的旧条目 + 本轮识别出的幻影键（agent 永不消费的前缀变体）
            for legacy in ["status:Bento::Item-0", "status:Bento::Item-1",
                           "status:Bento::BentoHider", "status:com.sz.bento::BentoHider",
                           "status:com.sz.bento::BentoMain"] + junkKeys {
                raw.removeValue(forKey: legacy)
                finalPositions.removeValue(forKey: legacy)
            }
            writeRawPositions(raw)
            ErrorLog.log("图标管理: 回写字典（\(writeReasons.joined(separator: "、"))）")
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
    /// 溢出区展开态的 chevron（»，desc = "Double forward chevron"）存在时，点它一下收起。
    /// AXPress 不可用（实测 chevron 及其祖先链全部无 AXPress 动作，返回 -25206），
    /// 只能坐标点击；点击前校验 frame 合法性，防止 AX 鬼影坐标误点到别的图标。
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
        // frame 合法性：chevron 是菜单栏里 ~18x30 的小图形，越界/离谱的都是鬼影，不点
        guard chevron.width > 8, chevron.width < 48, chevron.height < 48,
              chevron.minY >= 0, chevron.maxY <= 44 else {
            ErrorLog.log("图标管理: chevron frame 异常 \(chevron)，放弃收起点击")
            return
        }
        let saved = CGEvent(source: nil)?.location
        let p = CGPoint(x: chevron.midX, y: chevron.midY)
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        if let saved { CGWarpMouseCursorPosition(saved) }
        ErrorLog.log("图标管理: 已点击收起展开的溢出区")
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

    // MARK: 退出恢复（仅菜单主动退出时调用）

    /// 把隐藏项写回可见网格：用户主动退出（可能是要卸载）后图标不再沉在溢出区。
    /// hiddenKeys 保留——下次启动会重新隐藏，语义不变。
    /// 不放 applicationWillTerminate：重启/关机也会走那里，每次都制造 agent 重写扰动。
    func prepareForQuit() {
        queue.sync {
            guard !hiddenKeys.isEmpty else { return }
            var raw = readRawPositions()
            var moved = 0
            for (i, key) in hiddenKeys.enumerated() {
                for entryKey in lastEntryKeys[key] ?? [] where raw[entryKey] != nil {
                    raw[entryKey] = 500.0 + Double(i) * 8 // 可见区左端，一次性值，重启会重排
                    moved += 1
                }
            }
            guard moved > 0 else { return }
            writeRawPositions(raw)
            ErrorLog.log("图标管理: 退出前已把 \(moved) 个隐藏条目写回可见区")
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "菜单栏图标管理"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        window.center()

        // 普通窗口没有双行标题，提示放窗口内顶部
        let hint = NSTextField(labelWithString: "拖动排序（上 = 菜单栏左）· 关闭开关 = 收进「«」溢出区")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 44 // 双行（名称 + 副标题）
        table.style = .inset
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 380
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([.string])
        tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 底部脚注（动态统计 + 固定说明）+ 逃生舱按钮
        let footnote = NSTextField(wrappingLabelWithString: "")
        footnote.font = NSFont.systemFont(ofSize: 10)
        footnote.textColor = .tertiaryLabelColor
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnoteLabel = footnote

        let showAll = NSButton(title: "全部恢复显示", target: self, action: #selector(showAllRows))
        showAll.bezelStyle = .rounded
        showAll.controlSize = .small
        showAll.font = NSFont.systemFont(ofSize: 11)
        showAll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(footnote)
        content.addSubview(showAll)

        // 空态：图标 + 两行说明，一个图标都没识别到时不至于一片空白
        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField(labelWithString: "未识别到菜单栏图标")
        emptyTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        let emptySub = NSTextField(labelWithString: "第三方 App 的菜单栏图标会出现在这里")
        emptySub.font = NSFont.systemFont(ofSize: 11)
        emptySub.textColor = .tertiaryLabelColor
        let emptyStack = NSStackView(views: [emptyIcon, emptyTitle, emptySub])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 6
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyStack)
        emptyView = emptyStack

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: showAll.topAnchor, constant: -8),
            footnote.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footnote.centerYAnchor.constraint(equalTo: showAll.centerYAnchor),
            footnote.trailingAnchor.constraint(lessThanOrEqualTo: showAll.leadingAnchor, constant: -12),
            showAll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            showAll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            emptyStack.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window.contentView = content

        onRowsChanged = { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.emptyView?.isHidden = !self.rows.isEmpty
            self.updateFootnote()
            self.tableView?.reloadData()
        }
        window.delegate = self
        managerWindow = window
        emptyStack.isHidden = !rows.isEmpty
        updateFootnote()
        table.reloadData()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 打开时立刻刷新一次列表
        queue.async { self.enforce(force: true) }
    }

    /// 底部脚注：动态统计 + 固定说明（主线程）
    private func updateFootnote() {
        let hiddenCount = rows.filter { $0.isHidden }.count
        footnoteLabel?.stringValue = rows.isEmpty
            ? "时钟与控制中心由系统固定 · Bento 本尊不可隐藏"
            : "共 \(rows.count) 项 · \(hiddenCount) 已隐藏\n时钟与控制中心由系统固定 · Bento 本尊不可隐藏"
    }

    /// 行副标题：模块/本尊给类型说明，第三方给 bundleID（名字以外的稳定识别信息）
    private func rowSubtitle(for key: String) -> String {
        if key == "bento:main" { return "Bento 本尊 · 不可隐藏" }
        if key.hasPrefix("module:") { return "系统模块" }
        return String(key.split(separator: "|").first ?? "")
    }

    /// 行图标：第三方用应用图标，系统模块/本尊用 SF Symbol。
    /// 按键缓存——App 图标会话内不变，别每次 reloadData 都走磁盘查询
    private var rowIconCache: [String: NSImage] = [:]

    private func rowIcon(for key: String) -> NSImage? {
        if let cached = rowIconCache[key] { return cached }
        let icon = resolveRowIcon(for: key)
        if let icon { rowIconCache[key] = icon }
        return icon
    }

    private func resolveRowIcon(for key: String) -> NSImage? {
        if key == "bento:main" {
            return NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        }
        if key.hasPrefix("module:") {
            let name = key.dropFirst("module:".count)
            let symbol: String
            if name.hasPrefix("Battery") { symbol = "battery.100" }
            else if name.hasPrefix("WiFi") { symbol = "wifi" }
            else if name.hasPrefix("UserSwitcher") { symbol = "person.crop.circle" }
            else if name.hasPrefix("Sound") { symbol = "speaker.wave.2" }
            else if name.hasPrefix("NowPlaying") { symbol = "play.circle" }
            else { symbol = "gearshape" }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        let bundleID = String(key.split(separator: "|").first ?? "")
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            return icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    @objc private func rowToggled(_ sender: NSSwitch) {
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

        let iconView = NSImageView()
        iconView.image = rowIcon(for: r.key)
        iconView.alphaValue = r.isHidden ? 0.45 : 1.0 // 隐藏行图标同步压暗
        if r.key.hasPrefix("module:") || r.key == "bento:main" {
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            iconView.contentTintColor = .secondaryLabelColor
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: r.name)
        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.textColor = r.isHidden ? .secondaryLabelColor : .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(nameLabel)

        let subLabel = NSTextField(labelWithString: rowSubtitle(for: r.key))
        subLabel.font = NSFont.systemFont(ofSize: 11)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(subLabel)

        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = r.isHidden ? .off : .on
        toggle.identifier = NSUserInterfaceItemIdentifier(r.key)
        toggle.target = self
        toggle.action = #selector(rowToggled(_:))
        toggle.isEnabled = r.canHide
        toggle.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(toggle)

        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序")!)
        grip.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        grip.contentTintColor = .tertiaryLabelColor
        grip.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(grip)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            nameLabel.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: -1),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            subLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subLabel.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: grip.leadingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            grip.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
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
        emptyView = nil
        footnoteLabel = nil
        onRowsChanged = nil
    }
}
