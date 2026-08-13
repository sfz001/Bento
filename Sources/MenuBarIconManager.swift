import AppKit
import CoreGraphics
import Foundation

// MARK: - Menu Bar Icon Manager (菜单栏图标管理)

// 实现要点（Beta 4 = 26A5388g 实测基线，Beta 5 = 26A5406e 增补；26 的 ControlCenter
// 托管 + 合成 ⌘ 拖拽方案已废弃）：
// - macOS 27 起菜单栏由独立的 MenuBarAgent 进程整体托管（Beta 5 起已沙盒化）：不再是
//   每图标一个 layer-25 CG 窗口，而是整条菜单栏几个大窗口。图标位置持久化在
//   com.apple.MenuBarAgent 的 TrailingItemPreferredPositions 字典里：键 =
//   "status:<签名标识>::<autosaveName>"（正规签名 App 用 bundleID，ad-hoc/无签名用
//   可执行名），值 = 距右缘的偏好位置，越大越靠左。外部改写该字典 ~2s 内实时生效
//   （cfprefsd 通知），无需重启 agent、无需任何合成事件。
// - 系统布局算法 = 贪心跳洞：按 position 从小到大自右向左排布，放不下的项跳进
//   「«」溢出区（chevron 点击展开），然后继续排后面的。没有"截断"——超宽项只会
//   自己被跳过，挡不住任何人（10000pt hider 方案在 27 上无效，已删除）。
// - 隐藏 = 赋一个比所有可见项都大的 position（隐藏区 1100+）：拥挤的菜单栏
//   （刘海 + 行情条这类宽图标）放不下最左侧的它们 → 稳定折叠进溢出区。
//   局限：空间充裕时隐藏项会重新可见（27 上没有强制隐藏的原语）。
// - Beta 5 起字典不再是菜单栏的镜像（2026-08-13 实测）：agent 既不动态回收空间
//   （图标因瞬时拥挤沉进溢出区后，空间空出来也不回来），也几乎不把真实布局回写进
//   字典（实测 30h 保持外部写入的原值而真实菜单栏早已变化）。全量重排只由字典写入
//   或状态项注册/注销扰动触发。因此：只信字典的语义校验会长期"看起来全对"而菜单栏
//   跑偏 → UI 动作后必须无条件回写（forceRewriteOnce + gridPhase 抖动保证字典真的
//   变了），60s 兜底轮用 AX frame 做真实布局校验兜底。另实测 module:Battery 的写入
//   在 Beta 5 上被无视（com.apple.controlcenter 域冒出了 NSStatusItem Preferred
//   Position Battery 等新键 + HasAttemptedMenuBarWorkflowMigration=1，电池可能迁回
//   ControlCenter 托管，未深挖）——电池被排除在真实布局校验之外，回写救不了它。
// - 警惕：agent 在扰动后重写字典时用的是自己算出的"实际距离"（含溢出/展开态下的
//   瞬态坐标），所以字典数值绝不能当成用户的隐藏意图来采纳——隐藏/显示意图只来自
//   本管理器的 UI；字典只用来采纳"可见项的左右顺序"。语义不一致（该隐没隐/顺序
//   不对/条目缺失）时回写纠正，数值上的漂移不管，避免与 agent 互写打架。
// - 身份仍走各 App 的 AXExtrasMenuBar（title/desc），持久化键沿用 bundleID|序号；
//   系统模块经 module:* 条目管理（时钟/控制中心被系统钉死，除外）。

private let mbaPrefDomain = "com.apple.MenuBarAgent" as CFString
private let mbaPositionsKey = "TrailingItemPreferredPositions" as CFString

/// 菜单栏图标管理器：枚举/识别图标、维护隐藏集合、钉住 Bento 主图标
class MenuBarIconManager: NSObject {
    /// 功能总开关。macOS 27 Beta 5 的拖拽式管理实测后判定太繁琐（每次操作 = 展开溢出条
    /// → 合成拖拽 → 收起 → 校验，比手工 ⌘ 拖还麻烦），按物主决定停用（2026-08-14）。
    /// 代码与文档全部保留：恢复时改回 true 即可（菜单入口 / 定时纠偏 / 退出恢复会一并回来）。
    static let featureEnabled = false

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
    private var emptyIconView: NSImageView?
    private var emptyTitleLabel: NSTextField?
    private var emptySubLabel: NSTextField?
    private var emptyActionButton: NSButton?
    private var footnoteLabel: NSTextField?

    // —— 线程约定 ——
    // 下面这组模型状态（hiddenKeys / iconOrder / iconNames / lastEntryKeys 及各类缓存）
    // 一律**只在 queue 上读写**。enforce 每 3s 在 queue 上整体遍历它们，Swift 的
    // Set/Array/Dictionary 不支持并发读写——UI 侧（开关、拖拽排序、全部恢复）曾经直接
    // 在主线程改这些集合，和轮询撞上就是撕裂/崩溃。UI 现在只发 queue.async 表达意图，
    // 反向只通过 publishRows 往主线程投递不可变快照（rows）。
    // 主线程独占的是另一组：rows / rowIconCache / 各 UI 出口。

    /// 持久化的隐藏键集合
    private var hiddenKeys: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "HiddenMenuBarItemKeys") ?? [])
    }() {
        didSet { UserDefaults.standard.set(Array(hiddenKeys), forKey: "HiddenMenuBarItemKeys") }
    }

    /// 图标顺序（左→右，与菜单栏一致），持久化。
    /// 读盘即去重：重复键会让下面的顺序采纳多消费一次 pending 而越界
    private var iconOrder: [String] = {
        var seen = Set<String>()
        return (UserDefaults.standard.stringArray(forKey: "MenuBarIconOrder") ?? []).filter { seen.insert($0).inserted }
    }() {
        didSet { UserDefaults.standard.set(iconOrder, forKey: "MenuBarIconOrder") }
    }
    /// 键 → 显示名缓存（App 退出后其隐藏行仍能显示名字），持久化
    private var iconNames: [String: String] = (UserDefaults.standard.dictionary(forKey: "MenuBarIconNames") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(iconNames, forKey: "MenuBarIconNames") }
    }
    /// UI 操作触发的一轮 enforce 跳过顺序采纳（别把用户刚拖好的顺序又用旧位置覆盖回去）
    private var suppressAdoptionOnce = false
    /// UI 操作触发的一轮 enforce 无条件纠正。字典模式=回写字典；拖拽模式=跑拖拽纠偏 session
    private var forceRewriteOnce = false
    /// 强制回写时抖动网格基准（100↔101）：desired 与字典现值逐字节相同时，写入
    /// 可能不产生 cfprefsd 变更通知，agent 便不会重排；抖 1pt 保证字典真的变了（仅字典模式）
    private var gridPhase = 0.0
    /// 杠杆：字典（Beta 4 及更早：TrailingItemPreferredPositions 写入被 agent 消费）
    /// 或合成 ⌘ 拖拽（Beta 5 起：写入只被 cfprefsd 接受、不被 agent 消费，实测菜单栏纹丝不动；
    /// 拖拽 = 与手工 ⌘ 拖同源的系统手势，实测有效且持久）
    private enum Lever { case dict, drag }
    private var lever: Lever = .dict
    /// 字典模式连续多少轮真实布局纠偏后仍未收敛——达到 3 就永久切换拖拽模式
    /// （覆盖未知构建：若后续版本恢复消费字典，拖拽模式同样正确，只是动作更多）
    private var consecutiveRealityCorrections = 0
    /// 拖拽纠偏 session 进行中（防重入：session 在 queue 上同步执行数秒，
    /// 期间 3s 计时器照常排队，别让多个 session 叠加）
    private var correctionInProgress = false
    /// Bento 状态菜单是否开着：菜单窗口悬在菜单栏下方，合成拖拽会与它打架，开着就跳过纠偏
    private let menuOpenLock = NSLock()
    private var _statusMenuOpen = false
    /// 拖拽模式：键 → pid（读实时 frame 用），enumerateItems 每轮全量刷新
    private var pidByKey: [String: pid_t] = [:]
    /// 拖拽模式：放弃集合——连续多次拖不动/校验不过的键不再每轮纠偏（只观测 + 记一次日志），
    /// UI 动作（开关/排序/全部恢复）时清空重试
    private var dragFailCounts: [String: Int] = [:]
    private var dragGiveUp: Set<String> = []
    /// 首次观察到溢出条展开的时间（60s 宽限后由 enforcer 收起）
    private var stripExpandedSince: Date?
    /// 拥挤接受集合：菜单栏空间不足时（该可见宽度总和 > 在栏宽度总和 + 余量），
    /// 沉底是物理必然，纠偏只会让最左项轮流沉底——这些键只观测不再纠偏；
    /// 空间恢复（用户隐藏了别的项）或 UI 操作时清空重试
    private var acceptedSunk: Set<String> = []
    /// 真实布局校验（60s 兜底轮）状态：上次发现的问题集合 + 指数退避的下次纠偏时间。
    /// 真放不下的项（或 module:Battery 这类写入被无视的键）会让纠偏回写永远无效，
    /// 不退避就是每分钟白写一次、每次还把隐藏项抖出来
    private var lastRealityProblems: Set<String> = []
    private var realityBackoff: TimeInterval = 60
    private var nextRealityRewrite = Date.distantPast
    /// 隐藏项因菜单栏宽松而弹出可见（无解，只观测）：集合变化时才记日志
    private var loggedPopoutHidden: Set<String> = []
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
    /// 管理界面数据（主线程独占：publishRows 投递，表格与脚注读取）
    fileprivate(set) var rows: [Row] = []
    /// 缺辅助功能权限（主线程独占）。enforce 无权限时是完全静默 return 的，
    /// 管理窗口只显示「未识别到菜单栏图标」——和滚动/分屏的显式权限引导不一致，
    /// 用户会当成 bug。空态据此换文案并给出去系统设置的入口
    fileprivate(set) var needsAccessibility = false
    /// 列表更新回调（在主线程调用）
    var onRowsChanged: (() -> Void)?

    // MARK: 生命周期

    func start() {
        guard Self.featureEnabled else { return }
        lever = Self.decideInitialLever()
        if lever == .drag {
            ErrorLog.log("图标管理: 本构建菜单栏字典杠杆已失效，启用拖拽模式（合成 ⌘ 拖拽）")
        }
        // 首次延迟 2s，等菜单栏和自己图标就位
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.enforce() }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.queue.async { self?.enforce() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 初始杠杆选择：26A5406e（Beta 5）起字典写入不再被消费，直接走拖拽；
    /// 更早构建走字典；未知的未来构建先走字典，连续纠偏无效时自动切换（见 enforce）
    private static func decideInitialLever() -> Lever {
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        guard let r = v.range(of: "(Build ") else { return .dict }
        let rest = v[r.upperBound...]
        let build = String(rest.prefix(while: { $0 != ")" }))
        return build >= "26A5406e" ? .drag : .dict
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

    /// 字典写入失败已记过日志（恢复时记恢复）——失败会让每 3s 的语义校验反复回写，逐轮记会刷屏
    private var loggedWriteFailure = false

    private func writeRawPositions(_ dict: [String: Any]) {
        CFPreferencesSetAppValue(mbaPositionsKey, dict as CFDictionary, mbaPrefDomain)
        let ok = CFPreferencesAppSynchronize(mbaPrefDomain)
        if ok == loggedWriteFailure { // 状态翻转才记
            loggedWriteFailure = !ok
            ErrorLog.log(ok ? "图标管理: 字典写入已恢复" : "图标管理: 字典写入失败（cfprefsd 拒绝），语义校验将反复重试")
        }
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
        let frame: CGRect? // AX 全局坐标（左上原点）；读不到 position 时 nil
    }

    /// 读某个进程的 AXExtrasMenuBar 子元素
    private func extras(of pid: pid_t) -> [ExtraItem] {
        let app = AXUIElementCreateApplication(pid)
        var extrasValue: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extrasValue) == .success,
              let bar = extrasValue,
              // 外部 App 的 AX 返回值不可信，且这里跑在 3s 轮询里——类型不对
              // 直接强转等于反复崩溃
              CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return [] }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        var out: [ExtraItem] = []
        for el in children as? [AXUIElement] ?? [] {
            var title: AnyObject?, desc: AnyObject?, size: AnyObject?, pos: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &desc)
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size)
            AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos)
            var s = CGSize.zero
            if let size, CFGetTypeID(size) == AXValueGetTypeID() {
                AXValueGetValue(size as! AXValue, .cgSize, &s)
            }
            guard s.width > 0 else { continue } // 无尺寸的是占位/系统隐藏项
            var frame: CGRect?
            var p = CGPoint.zero
            if let pos, CFGetTypeID(pos) == AXValueGetTypeID(), AXValueGetValue(pos as! AXValue, .cgPoint, &p) {
                frame = CGRect(origin: p, size: s)
            }
            out.append(ExtraItem(title: (title as? String) ?? "",
                                 desc: (desc as? String) ?? "",
                                 frame: frame))
        }
        return out
    }

    /// 单个已识别图标
    private struct LiveItem {
        let key: String          // 持久化键：bundleID|序号（title 可能是动态角标，不能入键）
        let displayName: String
        let stableName: String   // 不含易变部分（行情/角标）的名字，进 iconNames 持久化缓存
        let entryKeys: [String]  // 它在 agent 字典里的条目键（现有配对的，或新建候选）
        var frame: CGRect? = nil // AX 真实 frame（真实布局校验用）；nil = 读不到/不适用
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
                let rowKey = "\(bundleID)|\(idx + 1)"
                pidByKey[rowKey] = pid // 拖拽模式读实时 frame 用
                out.append(LiveItem(key: rowKey, displayName: name,
                                    stableName: appName, entryKeys: entryKeys,
                                    frame: extra.frame))
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
        "com.apple.menuextra.now-playing": "NowPlaying",
    ]
    /// 系统钉死、完全动不了的模块（时钟/控制中心实测连拖拽都不吃）——不纳入管理。
    /// 电池在 Beta 5 对字典写入免疫，但合成 ⌘ 拖拽与手工拖拽同源、实测可动，
    /// 所以只有字典模式才把它当钉死（拖拽模式恢复正常管理）
    private var pinnedModules: Set<String> {
        var pinned: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]
        if lever == .dict { pinned.insert("com.apple.menuextra.battery") }
        return pinned
    }

    /// 枚举 MenuBarAgent 托管的系统模块（电池/Wi‑Fi/用户切换…），键直接用 module: 条目键。
    /// 顺路带回「«」按钮（AXButton，desc 含"隐藏菜单栏项目"）的 frame：收起态溢出项的
    /// AX frame 是堆叠在这个按钮矩形上的鬼影（AssignCollapsedOverflowFramesPass），
    /// 与它相交 = 沉在溢出区——真实布局校验的关键判据
    private func enumerateModules(positions: [String: Double], mbaApp: NSRunningApplication) -> (items: [LiveItem], chevron: CGRect?) {
        let mba = mbaApp
        var found: [(id: String, desc: String, frame: CGRect?)] = []
        var chevron: CGRect?
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth <= 5 else { return }
            var roleV: AnyObject?, identV: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleV)
            // 第二个宿主窗口里挂着各 App 的 AX 代理树，別往里钻（又大又慢）
            if depth > 0, roleV as? String == "AXApplication" { return }
            if chevron == nil, roleV as? String == "AXButton" {
                var descV: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descV)
                if let desc = descV as? String, desc.contains("隐藏菜单栏项目") || desc.lowercased().contains("hidden menu bar") {
                    var posV: AnyObject?, sizeV: AnyObject?
                    AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV)
                    AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV)
                    var p = CGPoint.zero
                    var s = CGSize.zero
                    if let posV, CFGetTypeID(posV) == AXValueGetTypeID(),
                       let sizeV, CFGetTypeID(sizeV) == AXValueGetTypeID(),
                       AXValueGetValue(posV as! AXValue, .cgPoint, &p),
                       AXValueGetValue(sizeV as! AXValue, .cgSize, &s), s.width > 0 {
                        chevron = CGRect(origin: p, size: s)
                    }
                }
            }
            AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &identV)
            if let ident = identV as? String, ident.hasPrefix("com.apple.menuextra.") {
                var descV: AnyObject?, posV: AnyObject?, sizeV: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descV)
                AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV)
                AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV)
                var p = CGPoint.zero
                var s = CGSize.zero
                var frame: CGRect?
                if let posV, CFGetTypeID(posV) == AXValueGetTypeID(),
                   let sizeV, CFGetTypeID(sizeV) == AXValueGetTypeID(),
                   AXValueGetValue(posV as! AXValue, .cgPoint, &p),
                   AXValueGetValue(sizeV as! AXValue, .cgSize, &s),
                   s.width > 0 {
                    frame = CGRect(origin: p, size: s)
                }
                if !found.contains(where: { $0.id == ident }) {
                    found.append((ident, (descV as? String) ?? "", frame))
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
        for (id, desc, frame) in found where !pinnedModules.contains(id) {
            let short = String(id.dropFirst("com.apple.menuextra.".count))
            let name = Self.moduleKeyMap[id] ?? (short.prefix(1).uppercased() + short.dropFirst())
            // 实例可能带 -0 后缀（如 module:BentoBox-0）。字典模式只在字典里有条目时管理；
            // 拖拽模式不依赖字典（写入已被 agent 无视），但只对已知映射的 id 合成条目，
            // 未知 id 的模块不冒然纳入
            let entryKey: String
            if let k = ["module:\(name)", "module:\(name)-0"].first(where: { positions[$0] != nil }) {
                entryKey = k
            } else if lever == .drag, Self.moduleKeyMap[id] != nil {
                entryKey = "module:\(name)"
            } else {
                continue
            }
            // desc 可能带实时状态（"Wi‑Fi，已接入，3格"），截到第一个逗号
            let clean = desc.split(separator: "，").first.map(String.init) ?? desc
            let display = clean.isEmpty ? name : clean
            out.append(LiveItem(key: entryKey, displayName: display, stableName: display,
                                entryKeys: [entryKey], frame: frame))
        }
        return (out, chevron)
    }

    /// 图标当前生效位置：条目键的任一现值
    private func currentPos(of item: LiveItem, in positions: [String: Double]) -> Double? {
        for k in item.entryKeys {
            if let v = positions[k] { return v }
        }
        return nil
    }

    /// 收起态 frame 是否在栏（含 chevron 鬼影卫兵）。收起态下溢出项的鬼影堆叠在
    /// chevron 上、看起来完全在栏（y=5、x 合理）；但宽图标（行情条 200pt）会真实地
    /// 横跨 chevron——两者都「与 chevron 相交」，只能用「窄 + 左缘贴着 chevron」区分鬼影
    private func onBarCollapsed(_ f: CGRect?, chevron: CGRect?, mainWidth: CGFloat) -> Bool {
        guard let f, f.width > 0 else { return false }
        if let ch = chevron, f.width <= 90, f.minX > ch.minX - 36, f.intersects(ch) { return false }
        return f.minY >= 0 && f.maxY <= 44 && f.minX >= 0 && f.maxX <= mainWidth
    }

    // MARK: 状态纠正（每 3s，后台线程）

    private func enforce(force: Bool = false) {
        guard Self.featureEnabled else { return }
        guard AXIsProcessTrustedWithOptions(nil) else {
            publishPermissionState(missing: true)
            return
        }
        publishPermissionState(missing: false)
        let runningApps = NSWorkspace.shared.runningApplications
        // MenuBarAgent 不在 = 不是 macOS 27 的菜单栏机制，本模块不适用
        guard let mbaApp = runningApps.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" })
        else { return }
        let skipAdoption = suppressAdoptionOnce
        suppressAdoptionOnce = false
        let uiForcedRewrite = forceRewriteOnce
        forceRewriteOnce = false

        // 溢出条开着时收起态判定不可信（隐藏项在展开条里拿到真实 frame，会被当成"该隐未隐"），
        // 先收起再评估。Beta 5 实测展开条不会自动收起——不主动收，纠偏会永久停摆。
        // 但用户刚点开的展开条可能是想手动拖图标，给 60s 宽限再收（别秒收跟用户打架）
        if lever == .drag, !correctionInProgress, !statusMenuOpen {
            if isStripExpanded() {
                if stripExpandedSince == nil { stripExpandedSince = Date() }
                if Date().timeIntervalSince(stripExpandedSince!) > 60 {
                    if let ch = chevronRect(false) { click(CGPoint(x: ch.midX, y: ch.midY)) }
                    Thread.sleep(forTimeInterval: 1.5)
                    stripExpandedSince = nil
                }
            } else {
                stripExpandedSince = nil
            }
        }

        let positions = readRawPositions().compactMapValues { ($0 as? NSNumber)?.doubleValue }
        let runningIDs = runningApps.compactMap(\.bundleIdentifier).sorted()

        // —— 门控：agent 字典和运行 App 集都没变且未超兜底间隔，就不跑 AX 枚举（重活）——
        var hasher = Hasher()
        hasher.combine(positions)
        hasher.combine(runningIDs)
        let signature = hasher.finalize()
        let stale = Date().timeIntervalSince(lastFullPass) > 60
        guard force || stale || signature != lastSignature else { return }
        // 只在真的跑了全量探测（fullProbe = stale）时才记时间戳。原先每个通过
        // 门控的轮次都重置它——菜单栏频繁扰动（行情图标每轮改位置）时 stale
        // 永不为真，「60s 兜底全量探测」被无限推迟，晚建图标的 App 永远发现不了
        if stale { lastFullPass = Date() }

        let (thirdParty, junkKeys) = enumerateItems(positions: positions, runningApps: runningApps, fullProbe: stale)
        var items = thirdParty
        let (moduleItems, chevronFrame) = enumerateModules(positions: positions, mbaApp: mbaApp)
        items += moduleItems
        // Bento 本尊也作为一行参与排序（不可隐藏，setRowHidden 与采纳都有防御）
        items.append(LiveItem(key: "bento:main", displayName: "Bento", stableName: "Bento",
                              entryKeys: ownEntryKeys("BentoMain", positions: positions)))
        // uniquingKeysWith 而非 uniqueKeysWithValues：后者遇重复键直接 trap，而
        // 同一 bundleID 跑多份实例（open -n / 两份拷贝）时第三方键 "bundleID|序号"
        // 真的会重复。取先出现的那个（runningApplications 的顺序），别崩
        let byKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items where !item.entryKeys.isEmpty { lastEntryKeys[item.key] = item.entryKeys }
        if hiddenKeys.contains("bento:main") { hiddenKeys.remove("bento:main") }

        // —— 布局参数（数值只有相对意义）：统一网格 base+8i 覆盖第三方与系统模块；
        //    隐藏区远大于可见区，靠拥挤的菜单栏放不下它们实现折叠。
        //    被钉死的模块（时钟/控制中心）无视这一切 ——
        let base = 100.0
        let hiddenBase = 1100.0             // 隐藏区起点
        let hiddenThreshold = 1050.0        // 隐藏区判定线（仅用于语义校验，不用于采纳意图）

        // —— 采纳（只采纳顺序，绝不采纳隐藏状态）：菜单栏实际排列是顺序的事实来源，
        // 决不能反过来用陈旧的持久化顺序去重排用户的菜单栏。
        // 字典模式的位置源 = 字典位置值（越大越靠左）；拖拽模式 = 收起态真实 frame 的 x
        // （左小右大，与 chevron 相交的沉底鬼影剔除）。
        // 溢出条展开时（用户点开了「«」）frame 是展开态布局，不作为采纳依据——顺序会错乱
        let stripExpandedNow = isStripExpanded()
        let mainWidth = CGDisplayBounds(CGMainDisplayID()).width
        let placed: [(key: String, pos: Double)]
        let posDescending: Bool
        if lever == .drag {
            placed = items.compactMap { it in
                onBarCollapsed(it.frame, chevron: chevronFrame, mainWidth: mainWidth)
                    ? (it.key, Double(it.frame!.midX)) : nil
            }
            posDescending = false
        } else {
            placed = items.compactMap { it in
                currentPos(of: it, in: positions).map { (it.key, $0) }
            }
            posDescending = true
        }
        if !skipAdoption, !stripExpandedNow {
            // 可见图标按位置排序 = 左→右；只重排 iconOrder 中这些键的相对顺序
            let newVisibleOrder = placed.filter { !hiddenKeys.contains($0.key) }
                .sorted { posDescending ? $0.pos > $1.pos : $0.pos < $1.pos }.map(\.key)
            let visibleSet = Set(newVisibleOrder).intersection(iconOrder)
            var pending = newVisibleOrder.filter { visibleSet.contains($0) }
            var reordered = iconOrder
            // pending 用尽即停：iconOrder 理论上无重复（读盘去重 + 各处 contains 守卫），
            // 但它来自 UserDefaults，外部写入不该换来一次 removeFirst 越界
            for (i, k) in reordered.enumerated() where visibleSet.contains(k) {
                guard !pending.isEmpty else { break }
                reordered[i] = pending.removeFirst()
            }
            if reordered != iconOrder { iconOrder = reordered }
        }
        // 新出现的键按当前实际位置插入顺序表：从右往左处理，各自插到右邻之前，
        // 顺序表首次接管系统模块/本尊时不会打乱它们的现有排列
        // 在本地副本上改，循环外一次性赋值：didSet 每次赋值都写 UserDefaults，逐元素改会写放大
        let posOrder = placed.sorted { posDescending ? $0.pos > $1.pos : $0.pos < $1.pos }.map(\.key) // 左→右
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
        // 连位置都还没有的全新图标：追加到末尾
        for item in items where !order.contains(item.key) { order.append(item.key) }
        // 拖拽模式的新键按真实 membership 初始化意图（在栏=可见，沉底=隐藏）：Beta 5 字典
        // 不再反映真实布局，没有历史意图的图标（比如系统刚冒出来的模块）不能默认弹到栏上
        if lever == .drag, !stripExpandedNow {
            for item in items where !iconOrder.contains(item.key) && !hiddenKeys.contains(item.key) {
                if !onBarCollapsed(item.frame, chevron: chevronFrame, mainWidth: mainWidth) {
                    hiddenKeys.insert(item.key)
                }
            }
        }
        if order != iconOrder { iconOrder = order }
        // 名字缓存（App 退出后隐藏行还得有名字）：只存稳定名，行情/角标这类易变文本不进磁盘
        var names = iconNames
        for item in items { names[item.key] = item.stableName }
        if names != iconNames { iconNames = names }

        let present = Set(items.map(\.key))
        let visibleList = iconOrder.filter { present.contains($0) && !hiddenKeys.contains($0) }
        let hiddenList = iconOrder.filter { present.contains($0) && hiddenKeys.contains($0) }

        // —— 真实布局校验（60s 兜底轮，Beta 5 起必需）：agent 不再动态回收空间、也不把
        // 真实布局回写字典，字典可以长期"看起来全对"而真实菜单栏早已跑偏（可见项沉在
        // 溢出区、左右顺序不符）。唯一的真相来源是 AX frame。发现问题就强制回写触发
        // 全量重排；问题集合不变时指数退避（60s→30min）——真放不下的项会让回写永远
        // 无效，不退避就是每分钟白写一次、每次还可能把隐藏项抖出来。
        // 判定假设主屏菜单栏（x ∈ [0, 主屏宽]，y ∈ [0, 44]，与 chevron 卫兵一致）；
        // 溢出区展开态（»）下沉底项会短暂拿到在栏 frame 而漏判——瞬态，无害
        // 显示器休眠时 agent 的 AX 树整体为空（实测：窗口在、无子元素、frame 全无）——
        // 此时所有项都会被误判"沉底"，整夜做无意义纠偏。有任何一个 frame 才可信
        var realityForced = false
        if stale, !stripExpandedNow, items.contains(where: { $0.frame != nil }) {
            // 收起态溢出项的 frame 是堆叠在「«」按钮矩形上的鬼影（看起来完全"在栏上"，
            // y=5、x 合理）——与 chevron 相交即视为沉底，不算在栏（宽图标横跨 chevron
            // 的例外见 onBarCollapsed）。「«」不存在（无溢出）时按无鬼影处理
            func onBar(_ f: CGRect?) -> Bool {
                onBarCollapsed(f, chevron: chevronFrame, mainWidth: mainWidth)
            }
            // 问题签名只含键与顺序（不含坐标——行情图标宽度每轮都在变，坐标进签名会
            // 让退避永远重置）；坐标只进日志
            var problems = Set<String>()
            var details: [String] = []
            let onBarKeys = visibleList.filter { onBar(byKey[$0]?.frame) }
            // 拥挤判定（仅拖拽模式）：该可见的宽度总和明显大于目前在栏的宽度总和 = 栏真满了。
            // agent 的 pack 上限 + 200pt 行情条下，最左项沉底是物理必然，纠偏只会轮流沉底
            let intendedWidth = visibleList.reduce(0.0) { $0 + (byKey[$1]?.frame?.width ?? 0) }
            let onBarWidth = onBarKeys.reduce(0.0) { $0 + (byKey[$1]!.frame!.width) }
            if lever == .drag, intendedWidth > onBarWidth + 30 {
                let sunk = visibleList.filter { !onBarKeys.contains($0) && byKey[$0]?.frame != nil }
                let newly = sunk.filter { !acceptedSunk.contains($0) }
                if !newly.isEmpty {
                    ErrorLog.log("图标管理: 菜单栏空间不足，接受沉底（不再纠偏）：\(newly.sorted().joined(separator: "、"))")
                }
                acceptedSunk = Set(sunk)
            } else {
                acceptedSunk = []
            }
            for key in visibleList {
                // Bento 本尊经自家 AX 读不到 frame，排除。拖拽模式不依赖字典条目
                // （entryKeys 只对字典回写有意义），配对失败的第三方也能纠偏。
                // 拥挤被接受的键跳过（纠偏只会轮流沉底）
                guard let item = byKey[key],
                      lever == .drag || !item.entryKeys.isEmpty,
                      key != "bento:main",
                      !acceptedSunk.contains(key),
                      !onBar(item.frame) else { continue }
                problems.insert("沉底:\(key)")
                let f = item.frame.map { "(\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))×\(Int($0.height)))" } ?? "无frame"
                details.append("\(key)\(f) 沉底")
            }
            let realOrder = onBarKeys.sorted { byKey[$0]!.frame!.minX < byKey[$1]!.frame!.minX }
            if realOrder != onBarKeys {
                problems.insert("实序:" + realOrder.joined(separator: ">"))
                details.append("实际顺序 \(realOrder.joined(separator: " > ")) ≠ 期望 \(onBarKeys.joined(separator: " > "))")
            }
            if !problems.isEmpty, problems != lastRealityProblems || Date() >= nextRealityRewrite {
                realityForced = true
                ErrorLog.log("图标管理: 真实布局校验不符（\(details.joined(separator: "、"))），强制纠偏")
                realityBackoff = problems == lastRealityProblems ? min(realityBackoff * 2, 1800) : 60
                nextRealityRewrite = Date().addingTimeInterval(realityBackoff)
            } else if problems.isEmpty, !lastRealityProblems.isEmpty {
                ErrorLog.log("图标管理: 真实布局校验恢复正常")
                realityBackoff = 60
                nextRealityRewrite = .distantPast
            }
            lastRealityProblems = problems
            // 隐藏项因菜单栏空间充裕被贪心填充带出来：27 无强制隐藏原语，回写无解，只观测
            let popped = Set(hiddenList.filter { onBar(byKey[$0]?.frame) })
            if !popped.isEmpty, popped != loggedPopoutHidden {
                ErrorLog.log("图标管理: 隐藏项因菜单栏空间充裕而可见：\(popped.sorted().joined(separator: "、"))（需拥挤才折叠）")
            }
            loggedPopoutHidden = popped
        }

        // —— 拖拽模式：问题 → 拖拽纠偏 session。绝不写字典：Beta 5 起字典写入不被
        // agent 消费，写了只会触发无意义重排
        if lever == .drag {
            if uiForcedRewrite || realityForced {
                runDragCorrection(visibleList: visibleList, hiddenList: hiddenList,
                                  byKey: byKey, chevronFrame: chevronFrame,
                                  enforceOrder: uiForcedRewrite)
            }
            lastSignature = signature
            publishRows(byKey: byKey)
            return
        }

        // —— 字典模式（Beta 4 及更早：写入被 agent 消费）——
        if uiForcedRewrite || realityForced { gridPhase = gridPhase == 0 ? 1 : 0 }

        // —— 期望布局（右端位置值最小；间距 8 留出手动拖拽的插入空间）——
        var desired: [(keys: [String], pos: Double)] = []
        for (i, key) in visibleList.reversed().enumerated() {
            desired.append((byKey[key]!.entryKeys, base + gridPhase + Double(i) * 8))
        }
        for (j, key) in hiddenList.reversed().enumerated() {
            desired.append((byKey[key]!.entryKeys, hiddenBase + gridPhase + Double(j) * 8))
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
        // Beta 5 起 agent 只在字典写入时才全量重排：UI 动作与真实布局纠偏都无条件回写，
        // 不依赖上面的字典语义校验（字典已不再镜像真实菜单栏，"看起来全对"不可信）
        if uiForcedRewrite { writeReasons.append("UI 操作强制重排") }
        if realityForced { writeReasons.append("真实布局纠偏") }

        var finalPositions = positions
        if !writeReasons.isEmpty {
            // 写前重读最新字典：从开头那次读取到这里隔着整段慢速 AX 枚举（可达数百 ms），
            // 期间 agent 重写 / 新 App 注册 / 用户拖动产生的条目若被旧副本整体盖掉，
            // 就是真丢数据。只把本轮管理的键合并到最新副本上，别的键保持人家的现值
            var freshRaw = readRawPositions()
            for entry in desired {
                for k in entry.keys { freshRaw[k] = entry.pos }
            }
            // 清掉历史方案的旧条目 + 本轮识别出的幻影键（agent 永不消费的前缀变体）
            for legacy in ["status:Bento::Item-0", "status:Bento::Item-1",
                           "status:Bento::BentoHider", "status:com.sz.bento::BentoHider",
                           "status:com.sz.bento::BentoMain"] + junkKeys {
                freshRaw.removeValue(forKey: legacy)
            }
            writeRawPositions(freshRaw)
            finalPositions = freshRaw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
            ErrorLog.log("图标管理: 回写字典（\(writeReasons.joined(separator: "、"))）")
        }
        // 签名以回写后的字典为准，别把自己的写入当成下一轮的外部变化
        var finalHasher = Hasher()
        finalHasher.combine(finalPositions)
        finalHasher.combine(runningIDs)
        lastSignature = finalHasher.finalize()

        // 连续真实布局纠偏无效 → 字典杠杆已死（agent 不再消费写入），永久切拖拽模式。
        // 拖拽模式同样正确、只是动作更多；未知的未来构建靠这个兜底
        if realityForced {
            consecutiveRealityCorrections += 1
            if consecutiveRealityCorrections >= 3 {
                lever = .drag
                consecutiveRealityCorrections = 0
                ErrorLog.log("图标管理: 字典杠杆连续 3 轮纠偏无效（agent 不再消费写入），切换为拖拽模式")
            }
        } else {
            consecutiveRealityCorrections = 0
        }

        // UI 操作后若溢出区正处于展开态（»），主动收起，让用户立刻看到隐藏结果；
        // 否则展开条会把刚隐藏的图标继续显示最长约一分钟（自动收起前），像是隐藏没生效
        if skipAdoption, lever == .dict {
            queue.asyncAfter(deadline: .now() + 0.8) { self.collapseChevronIfExpanded() }
        }

        publishRows(byKey: byKey)
        // 刚在上一段从字典模式切换过来：当轮就补一次拖拽纠偏，别让用户再等 60s
        if lever == .drag, uiForcedRewrite || realityForced {
            runDragCorrection(visibleList: visibleList, hiddenList: hiddenList,
                              byKey: byKey, chevronFrame: chevronFrame,
                              enforceOrder: uiForcedRewrite)
        }
    }

    // MARK: - 拖拽杠杆（Beta 5+：字典写入已不被 agent 消费）

    /// 合成输入必须跑在主线程：实测后台队列线程上的 warp+post 会被窗口服务器静默丢弃
    /// （同样的序列在主线程上正常）。队列线程只做逻辑/AX/runloop 等待，投递统一桥过来。
    /// 桥接用 semaphore 阻塞队列线程：主线程正在等队列的唯一场景是 prepareForQuit，
    /// 那里改成了 RunLoop 轮转等待，不会互相锁死
    private func onMainSync(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body(); return }
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { body(); sem.signal() }
        sem.wait()
    }

    /// Bento 状态菜单开着时不做纠偏（菜单窗口悬在菜单栏下，合成拖拽会与它打架）
    func setStatusMenuOpen(_ open: Bool) {
        menuOpenLock.lock(); _statusMenuOpen = open; menuOpenLock.unlock()
    }
    private var statusMenuOpen: Bool {
        menuOpenLock.lock(); defer { menuOpenLock.unlock() }
        return _statusMenuOpen
    }

    /// 实时窗口：agent 的三个 AX 窗口里唯一挂状态项 AXButton 的那个（另两个是收起视图的
    /// AXApplication 占位代理）。它的内容跟随当前状态：收起=真实按钮+chevron 鬼影，展开=展开条
    private func liveWindow() -> AXUIElement? {
        guard let mba = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return nil }
        let app = AXUIElementCreateApplication(mba.processIdentifier)
        var windowsV: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsV) == .success,
              let wins = windowsV as? [AXUIElement] else { return nil }
        for w in wins {
            var children: AnyObject?
            AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &children)
            for wrap in children as? [AXUIElement] ?? [] {
                var kids: AnyObject?
                AXUIElementCopyAttributeValue(wrap, kAXChildrenAttribute as CFString, &kids)
                for kid in kids as? [AXUIElement] ?? [] {
                    var role: AnyObject?
                    AXUIElementCopyAttributeValue(kid, kAXRoleAttribute as CFString, &role)
                    if role as? String == "AXButton" { return w }
                }
            }
        }
        return wins.count >= 2 ? wins[1] : wins.first
    }

    /// 实时窗口里的状态元素（模块 AXMenuBarItem / Bento 按钮 / chevron 按钮）
    private struct AgentElement {
        let role: String
        let ident: String
        let desc: String
        let frame: CGRect
    }

    private func agentElements() -> [AgentElement] {
        guard let w = liveWindow() else { return [] }
        var out: [AgentElement] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth <= 6 else { return }
            var roleV: AnyObject?, identV: AnyObject?, descV: AnyObject?, pV: AnyObject?, sV: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleV)
            AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &identV)
            AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descV)
            AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pV)
            AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sV)
            let role = roleV as? String ?? ""
            var p = CGPoint.zero, s = CGSize.zero
            if let pV, CFGetTypeID(pV) == AXValueGetTypeID() { AXValueGetValue(pV as! AXValue, .cgPoint, &p) }
            if let sV, CFGetTypeID(sV) == AXValueGetTypeID() { AXValueGetValue(sV as! AXValue, .cgSize, &s) }
            if s.width > 0 {
                out.append(AgentElement(role: role, ident: (identV as? String) ?? "",
                                        desc: (descV as? String) ?? "", frame: CGRect(origin: p, size: s)))
            }
            if depth > 0, role == "AXApplication" { return }
            var children: AnyObject?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
            for kid in children as? [AXUIElement] ?? [] { walk(kid, depth + 1) }
        }
        walk(w, 0)
        return out
    }

    /// 找 chevron 按钮：expand = 「显示隐藏菜单栏项目」（点击=展开），否则「隐藏菜单栏项目」（点击=收起）
    private func chevronRect(_ expand: Bool) -> CGRect? {
        let wanted = expand ? "显示隐藏菜单栏项目" : "隐藏菜单栏项目"
        return agentElements().first { $0.role == "AXButton" && $0.desc == wanted }?.frame
    }

    /// 溢出条是否处于展开态：出现「隐藏菜单栏项目」（收起按钮）即展开。
    /// 没有任何隐藏项时系统不显示 chevron——没有展开/收起之分，视为已展开
    private func isStripExpanded() -> Bool {
        guard let mba = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return false }
        let app = AXUIElementCreateApplication(mba.processIdentifier)
        var windowsV: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsV) == .success,
              let wins = windowsV as? [AXUIElement] else { return false }
        var hasChevron = false
        var expanded = false
        for w in wins {
            func walk(_ el: AXUIElement, _ depth: Int) {
                guard depth <= 6, !expanded else { return }
                var roleV: AnyObject?, descV: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleV)
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &descV)
                if roleV as? String == "AXButton", let d = descV as? String {
                    if d == "显示隐藏菜单栏项目" { hasChevron = true; return }
                    if d == "隐藏菜单栏项目" { hasChevron = true; expanded = true; return }
                }
                if depth > 0, roleV as? String == "AXApplication" { return }
                var children: AnyObject?
                AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children)
                for kid in children as? [AXUIElement] ?? [] { walk(kid, depth + 1) }
            }
            walk(w, 0)
            if expanded { break }
        }
        return !hasChevron || expanded
    }

    /// 合成坐标点击（chevron 展开/收起专用；frame 由 chevronRect 现读现用）。
    /// 先投 ESC 再点：误投的 up 可能点开某个状态项菜单（悬浮在菜单栏上），
    /// 打开着的菜单会吞掉 chevron 点击——ESC 关掉它
    private func click(_ p: CGPoint) {
        onMainSync {
            guard let src = CGEventSource(stateID: .hidSystemState) else { return }
            if let escDown = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true) {
                escDown.post(tap: .cghidEventTap)
            }
            usleep(60_000)
            if let escUp = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
                escUp.post(tap: .cghidEventTap)
            }
            usleep(100_000)
            let saved = CGEvent(source: nil)?.location
            CGWarpMouseCursorPosition(p)
            usleep(100_000)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(80_000)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(100_000)
            if let saved { CGWarpMouseCursorPosition(saved) }
        }
    }

    /// 合成 ⌘ 拖拽单个图标。**不做抓取校验**：实测拖拽进行中整个 AX 树纹丝不动
    /// （按钮/module/extras 全部不变，只有松手落定后才重排），任何中途校验都是
    /// 纯噪音——既误报（行情条宽度变化让整排按钮移位，看着像抓起来了）也漏报
    /// （真正抓起来时反而看不到变化）。抓取是否成功只看事后归属/顺序校验 + 重试。
    /// 源点 frame 由调用方现读现用，把"下按时源图标已移位"的概率压到最低。
    /// 事件投递必须桥到主线程（队列线程投递会被窗口服务器静默丢弃——实测）
    private func postDrag(from: CGPoint, to: CGPoint) {
        onMainSync {
            guard let src = CGEventSource(stateID: .hidSystemState) else { return }
            let saved = CGEvent(source: nil)?.location
            CGWarpMouseCursorPosition(from)
            usleep(120_000)
            func post(_ type: CGEventType, _ p: CGPoint, _ cmd: Bool) {
                guard let e = CGEvent(mouseEventSource: src, mouseType: type,
                                      mouseCursorPosition: p, mouseButton: .left) else { return }
                e.flags = cmd ? .maskCommand : []
                e.post(tap: .cghidEventTap)
                usleep(20_000)
            }
            post(.leftMouseDown, from, true)
            let steps = 10
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                CGWarpMouseCursorPosition(p)
                post(.leftMouseDragged, p, true)
            }
            usleep(120_000)
            post(.leftMouseUp, to, false)
            usleep(150_000)
            if let saved { CGWarpMouseCursorPosition(saved) }
        }
    }

    /// 展开溢出条（需要时）。没有 chevron（无隐藏项）视为无需展开。
    /// 每次点击前先投一个 ESC：误投的 up 可能点开某个状态项菜单（悬浮在菜单栏上），
    /// 打开着的菜单会吞掉后续 chevron 点击——ESC 关掉它再点
    private func expandStrip() -> Bool {
        if isStripExpanded() { return true }
        for attempt in 0..<3 {
            guard let ch = chevronRect(true) else {
                ErrorLog.log("图标管理: 展开点击 #\(attempt + 1)：找不到展开按钮，视为无需展开")
                return true
            }
            click(CGPoint(x: ch.midX, y: ch.midY))
            Thread.sleep(forTimeInterval: 1.5)
            let exp = isStripExpanded()
            ErrorLog.log("图标管理: 展开点击 #\(attempt + 1) chevron=(\(Int(ch.minX)),\(Int(ch.minY)),\(Int(ch.width))×\(Int(ch.height))) → 展开=\(exp)")
            if exp { return true }
        }
        return false
    }

    /// 展开态下读全部实时 frame：第三方走各 App 的 AXExtrasMenuBar（带身份、展开态下
    /// 返回展开条里的真实槽位），模块/Bento 走实时窗口
    private func liveFrames(items: [LiveItem]) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for el in agentElements() {
            if el.role == "AXMenuBarItem", let name = Self.moduleKeyMap[el.ident] {
                out["module:\(name)"] = el.frame
            }
            if el.role == "AXButton", el.desc == "Bento" {
                out["bento:main"] = el.frame
            }
        }
        for item in items where !item.key.hasPrefix("module:") && item.key != "bento:main" {
            guard let pid = pidByKey[item.key] else { continue }
            let idx = (Int(item.key.split(separator: "|").last ?? "1") ?? 1) - 1
            let extras = extras(of: pid)
            if extras.indices.contains(idx), let f = extras[idx].frame { out[item.key] = f }
        }
        return out
    }

    /// 单键实时 frame（每次拖拽前现读——行情图标宽度每轮都在变，展开条会不断重排）
    private func liveFrame(ofKey key: String) -> CGRect? {
        if key == "bento:main" {
            return agentElements().first { $0.role == "AXButton" && $0.desc == "Bento" }?.frame
        }
        if key.hasPrefix("module:") {
            let name = String(key.dropFirst("module:".count))
            guard let ident = Self.moduleKeyMap.first(where: { $0.value == name })?.key else { return nil }
            return agentElements().first { $0.role == "AXMenuBarItem" &&
                ($0.ident == ident || $0.ident.hasPrefix(ident + "-")) }?.frame
        }
        guard let pid = pidByKey[key] else { return nil }
        let idx = (Int(key.split(separator: "|").last ?? "1") ?? 1) - 1
        let extras = extras(of: pid)
        return extras.indices.contains(idx) ? extras[idx].frame : nil
    }

    private func markDragFailure(_ key: String) {
        let n = (dragFailCounts[key] ?? 0) + 1
        dragFailCounts[key] = n
        if n >= 3, dragGiveUp.insert(key).inserted {
            ErrorLog.log("图标管理: \(key) 连续 3 次拖拽失败，暂停纠偏（可能不可拖拽，改观测）；下次 UI 操作会重试")
        }
    }

    /// 拖拽纠偏 session：展开 → 先修归属（该隐没隐 / 该显未显）→ 收起 → 事后校验；
    /// 顺序纠偏只在用户操作的轮次（enforceOrder）做——漂移轮的顺序下一轮会自动从
    /// 真实菜单栏采纳（顺序的事实来源是真实栏，强行在漂移轮旋转反而制造沉底乒乓）。
    /// 在 enforcer 的串行队列上同步执行（数秒），correctionInProgress 防重入。
    /// 归属判定用传入的收起态 frame（byKey[].frame + chevronFrame），展开态只用来取源/落点坐标
    private func runDragCorrection(visibleList: [String], hiddenList: [String],
                                   byKey: [String: LiveItem], chevronFrame: CGRect?,
                                   enforceOrder: Bool) {
        guard !correctionInProgress, !statusMenuOpen else { return }
        correctionInProgress = true
        defer { correctionInProgress = false }

        let mainWidth = CGDisplayBounds(CGMainDisplayID()).width
        func onBar(_ f: CGRect?) -> Bool { onBarCollapsed(f, chevron: chevronFrame, mainWidth: mainWidth) }
        // 该显未显（沉底/无 frame）与该隐未隐（在栏）——归属判定只用收起态 frame；
        // 拥挤被接受的键（acceptedSunk）不再纠偏
        let toShow = visibleList.filter { $0 != "bento:main" && !acceptedSunk.contains($0) && !onBar(byKey[$0]?.frame) }
        let toHide = hiddenList.filter { onBar(byKey[$0]?.frame) }

        var dragCount = 0
        let maxDrags = 14
        func drag(_ key: String, to target: CGPoint) -> Bool {
            guard dragCount < maxDrags, !dragGiveUp.contains(key) else { return false }
            guard let f = liveFrame(ofKey: key) else {
                ErrorLog.log("图标管理: \(key) 读不到实时 frame，跳过拖拽")
                markDragFailure(key)
                return false
            }
            ErrorLog.log("图标管理: 拖拽 \(key) (\(Int(f.midX)),\(Int(f.midY))) → (\(Int(target.x)),\(Int(target.y)))")
            postDrag(from: CGPoint(x: f.midX, y: f.midY), to: target)
            dragCount += 1
            Thread.sleep(forTimeInterval: 2.0) // 等 agent 落位 + AX 刷新（1s 实测不够，AX 给旧 frame）
            // 落定校验：源 frame 应该已经变了。没变 = 抓错了对象（源坐标读到的是上一轮
            // 的旧位置）或落点被弹回——再往下拖只会继续抓错，本轮止损
            if let after = liveFrame(ofKey: key), abs(after.midX - f.midX) < 4 {
                ErrorLog.log("图标管理: \(key) 拖后 frame 未变（抓错对象或落点被弹回），本轮止损")
                return false
            }
            return true
        }

        let items = Array(byKey.values)
        var frames = liveFrames(items: items)

        // 1) 归属纠偏（需要展开条）：先展开（用户自己展开的保持原状）
        var startedExpanded = false
        if !toHide.isEmpty || !toShow.isEmpty {
            startedExpanded = isStripExpanded()
            if !startedExpanded, !expandStrip() {
                ErrorLog.log("图标管理: 拖拽纠偏中止（溢出条无法展开）")
                return
            }
            frames = liveFrames(items: items)
            guard frames.values.contains(where: { $0.width > 0 }) else {
                ErrorLog.log("图标管理: 拖拽纠偏中止（展开态读不到任何 frame，可能显示器休眠）")
                if !startedExpanded, let ch = chevronRect(false) { click(CGPoint(x: ch.midX, y: ch.midY)) }
                return
            }
            // 隐藏：投进展开条区域（实测：落进展开条 = 进溢出集；还没有隐藏项时投到最左）
            for key in toHide {
                let stripFrames = hiddenList.compactMap { frames[$0] }
                let target: CGPoint
                if let leftmost = stripFrames.min(by: { $0.minX < $1.minX }) {
                    target = CGPoint(x: leftmost.midX, y: leftmost.midY)
                } else {
                    target = CGPoint(x: 200, y: 16)
                }
                if drag(key, to: target) { ErrorLog.log("图标管理: 拖拽隐藏 \(key)") }
                frames = liveFrames(items: items)
            }
            // 显示：投到最右可见槽位右侧。实测右端落点即"回到可见区最右"（wifi 实证），
            // 缝隙不够时 agent 会把整条链向左平移让位——栏不满时谁也不会沉底；
            // 真满时最左项沉底 = 拥挤语义本身，下一轮退避接管，不做旋转预防
            for key in toShow {
                var rightEdge: CGFloat = 0
                for (k, f) in frames where visibleList.contains(k) && k != key {
                    if f.maxX > rightEdge { rightEdge = f.maxX }
                }
                let target = CGPoint(x: rightEdge > 0 ? min(rightEdge + 8, mainWidth - 60) : 1270, y: 16)
                if drag(key, to: target) { ErrorLog.log("图标管理: 拖拽显示 \(key)") }
                frames = liveFrames(items: items)
            }
            // 收起（只在本次 session 自己展开的情况下）
            if !startedExpanded {
                if let ch = chevronRect(false) {
                    click(CGPoint(x: ch.midX, y: ch.midY))
                    Thread.sleep(forTimeInterval: 1.5)
                }
            }
            // 收起后 agent 的全量重排需要几秒（AX 树会先给出过渡态/鬼影），
            // 立即校验会把刚成功的操作误判成失败——等它落定
            Thread.sleep(forTimeInterval: 3.5)
        }

        // 2) 顺序纠偏（只在用户操作的轮次做，且只在收起态做）：展开态下可见项的真实槽位
        //    可能落在展开条区域（行情条 200pt 的展开槽位就在那里），展开态 x 序 ≠ 收起态
        //    x 序。漂移轮不强制顺序——顺序的事实来源是真实菜单栏，下一轮采纳会同步
        var orderAttempts = 0
        if enforceOrder {
            while orderAttempts < 6, dragCount < maxDrags {
                frames = liveFrames(items: items)
                let candidates = visibleList.filter { onBar(frames[$0]) && !dragGiveUp.contains($0) }
                let current = candidates.sorted { frames[$0]!.minX < frames[$1]!.minX }
                if current == candidates { break }
                var fixedOne = false
                for (i, key) in candidates.enumerated() where current[i] != key {
                    guard let targetF = frames[current[i]] else { continue }
                    if drag(key, to: CGPoint(x: targetF.midX, y: targetF.midY)) {
                        ErrorLog.log("图标管理: 拖拽排序 \(key) → 第 \(i + 1) 位")
                    }
                    fixedOne = true
                    break
                }
                if !fixedOne { break }
                orderAttempts += 1
            }
        }
        // 事后校验（收起态）：轻量重读，报告残留（供日志；下一轮退避逻辑接管）
        var residual: [String] = []
        for key in toShow {
            if let f = liveFrame(ofKey: key), !onBar(f) { residual.append("\(key) 仍未显示") }
        }
        for key in toHide {
            if let f = liveFrame(ofKey: key), onBar(f) { residual.append("\(key) 仍未隐藏") }
        }
        // 校验不通过的键计入失败次数：真拖不动的项（系统区钉住的那些）连续 3 轮后暂停纠偏
        for key in toShow {
            if let f = liveFrame(ofKey: key), !onBar(f) { markDragFailure(key) }
        }
        for key in toHide {
            if let f = liveFrame(ofKey: key), onBar(f) { markDragFailure(key) }
        }
        ErrorLog.log("图标管理: 拖拽纠偏完成（\(dragCount) 次拖拽\(residual.isEmpty ? "" : "，残留：\(residual.joined(separator: "、"))")）")
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
                if let pos, CFGetTypeID(pos) == AXValueGetTypeID() {
                    AXValueGetValue(pos as! AXValue, .cgPoint, &p)
                }
                if let size, CFGetTypeID(size) == AXValueGetTypeID() {
                    AXValueGetValue(size as! AXValue, .cgSize, &s)
                }
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
        // frame 合法性：chevron 是菜单栏里 ~18x30 的小图形，越界/离谱的都是鬼影，不点。
        // X 轴也要卡在主屏范围内——这是合成点击，点错位置就是替用户误操作
        let screenWidth = CGDisplayBounds(CGMainDisplayID()).width
        guard chevron.width > 8, chevron.width < 48, chevron.height < 48,
              chevron.minY >= 0, chevron.maxY <= 44,
              chevron.minX >= 0, chevron.maxX <= screenWidth else {
            ErrorLog.log("图标管理: chevron frame 异常 \(chevron)，放弃收起点击")
            return
        }
        // 合成点击必须走主线程桥（队列线程投递会被窗口服务器丢弃，见 onMainSync）
        click(CGPoint(x: chevron.midX, y: chevron.midY))
        ErrorLog.log("图标管理: 已点击收起展开的溢出区")
    }

    /// 队列侧记住上次发布过的值：这个调用点在签名门之前（无权限时根本走不到门），
    /// 若无脑每轮 main.async 一次，稳态下就是每 3s 白白唤醒一次主线程 —— 而签名门
    /// 存在的意义正是让稳态的 enforce 什么都不做
    private var lastPublishedPermissionMissing: Bool?

    private func publishPermissionState(missing: Bool) {
        guard lastPublishedPermissionMissing != missing else { return }
        lastPublishedPermissionMissing = missing
        DispatchQueue.main.async {
            self.needsAccessibility = missing
            // 权限没了还挂着旧列表的话，开关/拖拽全是无效操作；清掉让权限空态顶上
            if missing { self.rows = [] }
            self.onRowsChanged?()
        }
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
        guard Self.featureEnabled else { return }
        // 有界等待而非 queue.sync：queue 可能正卡在对无响应 App 的 AX 往返上，
        // 退出不该无限转菊花。拖拽模式逐个拖出最慢（≈1s/项），预算放宽到 12s。
        // 等待用 RunLoop 轮转而不是干等：拖拽纠偏的内部 onMainSync 桥需要主队列
        // 持续排水，主线程 park 在 semaphore 上会互相锁死
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            writeBackHiddenEntries()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if done.wait(timeout: .now() + 0.05) == .success { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        ErrorLog.log("图标管理: 退出写回等待超时，放弃")
    }

    private func writeBackHiddenEntries() {
        guard !hiddenKeys.isEmpty else { return }
        if lever == .dict {
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
            return
        }
        // 拖拽模式：展开一次，把隐藏项逐个拖回右端可见区（尽力而为）。
        // 与 26 时代 hider 销毁自动恢复不同：27 的溢出集持久在 agent 内部，退出后
        // 不会自动回来，只有主动拖出能兜住「卸载后图标沉底」的场景
        guard !statusMenuOpen, !correctionInProgress, expandStrip() else {
            ErrorLog.log("图标管理: 退出恢复中止（溢出条无法展开）")
            return
        }
        let runningApps = NSWorkspace.shared.runningApplications
        let positions = readRawPositions().compactMapValues { ($0 as? NSNumber)?.doubleValue }
        guard let mba = runningApps.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) else { return }
        let (thirdParty, _) = enumerateItems(positions: positions, runningApps: runningApps, fullProbe: true)
        var items = thirdParty
        items += enumerateModules(positions: positions, mbaApp: mba).items
        var frames = liveFrames(items: items)
        let mainWidth = CGDisplayBounds(CGMainDisplayID()).width
        var restored = 0
        let deadline = Date().addingTimeInterval(9) // 预算：退出等太久体验差，超时放弃剩余
        for key in hiddenKeys where Date() < deadline {
            guard let f = frames[key] ?? liveFrame(ofKey: key) else { continue }
            var rightEdge: CGFloat = 0
            for (k, v) in frames where !hiddenKeys.contains(k) && v.maxX > rightEdge { rightEdge = v.maxX }
            let target = CGPoint(x: rightEdge > 0 ? min(rightEdge + 8, mainWidth - 60) : 1270, y: 16)
            postDrag(from: CGPoint(x: f.midX, y: f.midY), to: target)
            restored += 1
            Thread.sleep(forTimeInterval: 0.6)
            frames = liveFrames(items: items)
        }
        if let ch = chevronRect(false) { click(CGPoint(x: ch.midX, y: ch.midY)) }
        ErrorLog.log("图标管理: 退出前恢复显示 \(restored)/\(hiddenKeys.count) 个隐藏项（拖拽模式）")
    }

    // MARK: 对外操作（主线程）

    /// 主线程只表达意图，集合本身在 queue 上改（见类顶部的线程约定）
    func setRowHidden(_ key: String, _ hidden: Bool) {
        guard key != "bento:main" else { return } // 本尊不可隐藏
        queue.async {
            if hidden {
                self.hiddenKeys.insert(key)
            } else {
                self.hiddenKeys.remove(key)
            }
            self.suppressAdoptionOnce = true
            self.forceRewriteOnce = true
            self.dragGiveUp.removeAll() // 用户明确操作 = 重试之前放弃的键
            self.dragFailCounts.removeAll()
            self.acceptedSunk.removeAll()
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

        // 空态：图标 + 两行说明，一个图标都没识别到时不至于一片空白。
        // 缺辅助功能权限是其中一种空态，文案和图标换掉并补一个去系统设置的按钮
        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!)
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        let emptyTitle = NSTextField(labelWithString: "")
        emptyTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        let emptySub = NSTextField(labelWithString: "")
        emptySub.font = NSFont.systemFont(ofSize: 11)
        emptySub.textColor = .tertiaryLabelColor
        emptySub.alignment = .center
        emptySub.maximumNumberOfLines = 2
        let emptyAction = NSButton(title: "打开「辅助功能」设置", target: self,
                                   action: #selector(openAccessibilitySettings))
        emptyAction.bezelStyle = .rounded
        emptyAction.controlSize = .small
        emptyAction.font = NSFont.systemFont(ofSize: 11)
        let emptyStack = NSStackView(views: [emptyIcon, emptyTitle, emptySub, emptyAction])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 6
        emptyStack.setCustomSpacing(12, after: emptySub)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyStack)
        emptyView = emptyStack
        emptyIconView = emptyIcon
        emptyTitleLabel = emptyTitle
        emptySubLabel = emptySub
        emptyActionButton = emptyAction

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
            self.updateEmptyState()
            self.updateFootnote()
            self.tableView?.reloadData()
        }
        window.delegate = self
        managerWindow = window
        updateEmptyState()
        updateFootnote()
        table.reloadData()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 打开时立刻刷新一次列表
        queue.async { self.enforce(force: true) }
    }

    /// 空态（主线程）：区分「有权限但没识别到图标」和「压根没辅助功能权限」
    private func updateEmptyState() {
        emptyView?.isHidden = !rows.isEmpty
        let missing = needsAccessibility
        emptyIconView?.image = NSImage(
            systemSymbolName: missing ? "lock.shield" : "app.dashed", accessibilityDescription: nil)
        emptyTitleLabel?.stringValue = missing ? "需要辅助功能权限" : "未识别到菜单栏图标"
        emptySubLabel?.stringValue = missing
            ? "菜单栏图标的识别与排序依赖辅助功能权限。\n授权后列表会自动出现，无需重启 Bento"
            : "第三方 App 的菜单栏图标会出现在这里"
        emptyActionButton?.isHidden = !missing
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
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
        queue.async {
            self.hiddenKeys.removeAll()
            self.suppressAdoptionOnce = true
            self.forceRewriteOnce = true
            self.dragGiveUp.removeAll()
            self.dragFailCounts.removeAll()
            self.acceptedSunk.removeAll()
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
        tableView.reloadData() // 拖拽的即时反馈由主线程独占的 rows 提供
        // 行顺序写回 iconOrder 得在 queue 上做：清单里没展示的键（App 已退出等）
        // 保持相对位置追加在末尾，那份合并要读 iconOrder，不能在主线程碰
        let visibleOrder = rows.map(\.key)
        queue.async {
            var newOrder = visibleOrder
            for k in self.iconOrder where !newOrder.contains(k) { newOrder.append(k) }
            self.iconOrder = newOrder
            self.suppressAdoptionOnce = true
            self.forceRewriteOnce = true
            self.dragGiveUp.removeAll()
            self.dragFailCounts.removeAll()
            self.acceptedSunk.removeAll()
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
        emptyIconView = nil
        emptyTitleLabel = nil
        emptySubLabel = nil
        emptyActionButton = nil
        footnoteLabel = nil
        onRowsChanged = nil
    }
}
