import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusMenuItem: NSMenuItem!

    private let screenCtl: ScreenController
    private let lockCheck: () -> Bool
    private let lockWaitBudget: TimeInterval
    private lazy var scrollReverser = ScrollReverser()
    private var remoteMonitorEnabled = UserDefaults.standard.object(forKey: "RemoteMonitorEnabled") as? Bool ?? true
    private var scrollPermissionItem: NSMenuItem!
    private var openAccessibilityItem: NSMenuItem!
    private var permissionHelpItem: NSMenuItem!
    private var retryScrollPermissionsItem: NSMenuItem!
    private var reverseMouseItem: NSMenuItem!
    private var reverseTrackpadItem: NSMenuItem!
    // 分屏
    private lazy var tiling = TilingController()
    // 远程熄屏监控开关（默认开）
    private var remoteMonitorItem: NSMenuItem!
    private var tilingMasterItem: NSMenuItem!
    private var tilingPermissionItem: NSMenuItem!
    private var tilingPermissionMissing = false
    private var autoLaunchItem: NSMenuItem!
    private lazy var claudeGuard = ClaudeGuardController()
    private var claudeGuardItem: NSMenuItem!
    private var claudeGuardStatusItem: NSMenuItem!
    // 菜单栏图标管理
    private lazy var iconMgr = MenuBarIconManager()
    // 防止睡眠
    private lazy var sleepGuard = SleepGuard()
    private var permanentSleepItem: NSMenuItem!
    private var timedSleepItem: NSMenuItem!
    private var timedSleepSubmenu: NSMenu?
    private var pollTimer: DispatchSourceTimer?
    /// 上一轮轮询的连接状态（nil = 尚未轮询过），用于边沿触发
    private var lastPolledConnected: Bool?
    private let pollQueue = DispatchQueue(label: "com.sz.bento.connection-poll")
    private var hasShownPermissionHelp = false
    private var permissionChecksStarted = false
    private lazy var permissionRecoveryModel = PermissionRecoveryModel()
    private var permissionRecoveryWindow: PermissionRecoveryWindow?
    private var relaunchInFlight = false

    private let launchAgentLabel = "com.sz.bento"
    private var launchAgentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    init(screenController: ScreenController = ScreenController(),
         lockCheck: @escaping () -> Bool = ScreenController.isScreenLocked,
         lockWaitBudget: TimeInterval = 6) {
        self.screenCtl = screenController
        self.lockCheck = lockCheck
        self.lockWaitBudget = lockWaitBudget
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先收拾上次非正常退出留下的分辨率/Dock 残留，再启动轮询：
        // 首轮轮询若真的检测到连接，它会在恢复后的干净状态上重新取快照
        screenCtl.recoverFromUncleanExit()
        setupStatusBar()
        installAutoLaunchIfFirstRun()
        startScrollReverser(showAlert: true)
        startTiling()
        permissionChecksStarted = true
        updatePermissionRecovery()
        // 用户从系统设置返回时马上检测；不请求授权、不自动重启或重置权限。
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(permissionSettingsDeactivated(_:)),
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        iconMgr.start()
        sleepGuard.onStateChange = { [weak self] in self?.refreshSleepGuardState() }
        claudeGuard.onUpdate = { [weak self] in self?.refreshClaudeGuard() }
        claudeGuard.start()
        // 远程会话中热插显示器：新屏是正常 gamma、不在镜像组，会直接亮出真实桌面。
        // 拓扑一变就重新镜像（快照有「不覆盖」规则，不会污染断开时的还原目标；
        // 快照里没有新屏的条目，恢复时它会被正确地拆出镜像）并对全部在线屏重压 gamma
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reassertScreenOffState()
        }
        // 唤醒也要重压：部分机型睡眠会重置 gamma 表，而单内屏 MacBook 的唤醒
        // 不保证触发 didChangeScreenParameters——两个通道都挂，处理幂等
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reassertScreenOffState()
        }
        // 锁定确认的第二路信号（见 pollLockThenRestore）：loginwindow 上锁时发这个分布式通知
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastLockNotificationAt = Date()
        }
        if remoteMonitorEnabled { startPollTimer() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPollTimer()
        cancelRehearsal()
        claudeGuard.stop()
        iconMgr.stop()
        tiling.stop()
        scrollReverser.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        sessionPrepared = false
        screenCtl.restoreDock()
        screenCtl.restoreDisplaySettings()
        screenCtl.restore()
        // Dock 还原最多等待 2 秒；超时由下次启动按快照补偿。
        screenCtl.waitForPendingDockWork()
    }

    // MARK: - Status Bar

    /// 带 SF Symbol 图标的菜单项
    private func makeItem(_ title: String, symbol: String?, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Bento")
        statusItem.button?.setAccessibilityLabel("Bento")
        // 显式 autosaveName：图标管理靠它构造 MenuBarAgent 字典里自己的条目键（status:…::BentoMain）
        statusItem.autosaveName = "BentoMain"

        statusMenu = NSMenu()

        statusMenuItem = NSMenuItem(title: "监控中", action: nil, keyEquivalent: "")
        statusMenu.addItem(statusMenuItem)

        statusMenu.addItem(.sectionHeader(title: "远程熄屏"))

        remoteMonitorItem = makeItem("远程连接自动熄屏", symbol: "eye.slash", action: #selector(toggleRemoteMonitor))
        remoteMonitorItem.state = remoteMonitorEnabled ? .on : .off
        statusMenu.addItem(remoteMonitorItem)

        // 熄屏模块的手动兜底：把镜像强制拆回扩展桌面（自动恢复失灵时用）
        statusMenu.addItem(makeItem("恢复扩展显示器", symbol: "display.2", action: #selector(restoreExtendedDisplays)))

        statusMenu.addItem(makeItem("熄屏流程演练…", symbol: "play.circle", action: #selector(rehearseScreenOff)))

        // 远程场景配件：认证重启，跳过 FileVault 开机解锁界面，重启后远程还能连回来
        statusMenu.addItem(makeItem("FileVault 免密重启", symbol: "lock.rotation", action: #selector(authRestart)))

        statusMenu.addItem(.sectionHeader(title: "滚动方向"))

        reverseMouseItem = makeItem("反转鼠标滚动", symbol: "computermouse", action: #selector(toggleReverseMouse))
        reverseMouseItem.state = scrollReverser.reverseMouse ? .on : .off
        statusMenu.addItem(reverseMouseItem)

        reverseTrackpadItem = makeItem("反转触控板滚动", symbol: "hand.point.up.left", action: #selector(toggleReverseTrackpad))
        reverseTrackpadItem.state = scrollReverser.reverseTrackpad ? .on : .off
        statusMenu.addItem(reverseTrackpadItem)

        scrollPermissionItem = NSMenuItem(title: "滚动控制授权尚未生效", action: nil, keyEquivalent: "")
        scrollPermissionItem.isEnabled = false
        scrollPermissionItem.isHidden = true
        statusMenu.addItem(scrollPermissionItem)

        let permissionSettingsName = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "设备控制和数据访问" : "辅助功能"
        openAccessibilityItem = makeItem("打开「\(permissionSettingsName)」设置", symbol: "accessibility", action: #selector(openAccessibilitySettings))
        openAccessibilityItem.isHidden = true
        statusMenu.addItem(openAccessibilityItem)

        permissionHelpItem = makeItem("已开启权限仍无效？…", symbol: "questionmark.circle", action: #selector(showPermissionRecovery))
        permissionHelpItem.isHidden = true
        statusMenu.addItem(permissionHelpItem)

        retryScrollPermissionsItem = makeItem("重新检测滚动权限", symbol: "arrow.clockwise", action: #selector(retryScrollPermissions))
        retryScrollPermissionsItem.isHidden = true
        statusMenu.addItem(retryScrollPermissionsItem)

        statusMenu.addItem(.sectionHeader(title: "分屏（窗口吸附）"))

        tilingPermissionItem = makeItem("分屏授权尚未生效（点击查看恢复方法）", symbol: "exclamationmark.triangle", action: #selector(showPermissionRecovery))
        tilingPermissionItem.isHidden = true
        statusMenu.addItem(tilingPermissionItem)

        // 单一总开关：开 = 双击吸附 / Shift 双击铺满屏幕 / Shift 拖动网格吸附 / 甩动铺满屏幕 全部可用
        tilingMasterItem = makeItem("启用分屏", symbol: "uiwindow.split.2x1", action: #selector(toggleTilingMaster))
        statusMenu.addItem(tilingMasterItem)

        statusMenu.addItem(makeItem("编辑分屏布局…", symbol: "squareshape.split.2x2.dotted", action: #selector(editTilingLayouts)))

        // 手势提示行（不可点，仅展示）：小字号 + 拆成两行，避免撑宽整个菜单
        for text in ["双击=吸进格子 · Shift拖=吸附", "Shift双击/甩动=铺满屏幕"] {
            let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            hint.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            hint.isEnabled = false
            statusMenu.addItem(hint)
        }

        statusMenu.addItem(.sectionHeader(title: "防止睡眠"))

        installSleepGuardItems()

        statusMenu.addItem(.sectionHeader(title: "Claude 防直连"))
        claudeGuardStatusItem = NSMenuItem(title: "Claude 防护已关闭", action: nil, keyEquivalent: "")
        claudeGuardStatusItem.isEnabled = false
        statusMenu.addItem(claudeGuardStatusItem)
        claudeGuardItem = makeItem("Claude 防直连保护", symbol: "shield.lefthalf.filled", action: #selector(toggleClaudeGuard))
        statusMenu.addItem(claudeGuardItem)
        statusMenu.addItem(makeItem("防护说明与排错…", symbol: "questionmark.circle", action: #selector(openClaudeGuardHelp)))
        statusMenu.addItem(makeItem("恢复 hosts 并卸载守护…", symbol: "trash", action: #selector(cleanUpClaudeGuard)))
        refreshClaudeGuard()

        // 图标管理已停用（MenuBarIconManager.featureEnabled = false），菜单入口一并隐藏；
        // 恢复功能时把开关改回 true，这一段就会回来
        if MenuBarIconManager.featureEnabled {
            statusMenu.addItem(.sectionHeader(title: "菜单栏图标"))
            statusMenu.addItem(makeItem("管理菜单栏图标…", symbol: "menubar.rectangle", action: #selector(openIconManager)))
        }

        updateTilingMenuStates()

        statusMenu.addItem(.separator())

        autoLaunchItem = makeItem("开机自启", symbol: "power", action: #selector(toggleAutoLaunch))
        refreshAutoLaunchItem()
        statusMenu.addItem(autoLaunchItem)

        statusMenu.addItem(makeItem("退出 Bento", symbol: nil, action: #selector(quitApp), key: "q"))

        statusItem.menu = statusMenu
    }

    // MARK: - 防睡接线

    /// 两个普通菜单项：永久防睡（勾选切换）+ 定时防睡（预设子菜单）。
    /// 全是原生 NSMenuItem —— 早前那版靠自定义视图区分单击/双击，为一个开关背了
    /// 乐观 UI、时序锚点、高亮转发、菜单几何反推一整套状态机，还和分屏的事件 tap 打架。
    private func installSleepGuardItems() {
        permanentSleepItem = makeItem("永久防睡", symbol: "cup.and.saucer",
                                      action: #selector(togglePermanentSleep))
        statusMenu.addItem(permanentSleepItem)

        timedSleepItem = NSMenuItem(title: "定时防睡", action: nil, keyEquivalent: "")
        timedSleepItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let submenu = NSMenu()
        for preset in SleepGuard.timedPresets {
            let item = NSMenuItem(title: preset.title, action: #selector(startTimedSleep(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.minutes // 时长直接存 tag，动作里读回来
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        // 设置窗口收进子菜单：里面的自定义分钟数本来就属于「定时」这一档，
        // 模式/低电量都是低频项，不值得在主菜单常驻一行
        submenu.addItem(makeItem("防睡设置…", symbol: "gearshape", action: #selector(openSleepGuardSettings)))
        timedSleepItem.submenu = submenu
        timedSleepSubmenu = submenu
        statusMenu.addItem(timedSleepItem)

        statusMenu.delegate = self
    }

    /// 只刷新菜单内的文案与勾选态。**不要**在这里碰 statusItem.button —— 给它重新赋
    /// image/title 会在菜单正要定位的瞬间改动状态栏按钮几何，菜单会按错位的锚点弹出
    /// （表现为下拉菜单跑到屏幕右边）。状态栏那一侧由 refreshSleepGuardState 负责。
    private func updateSleepGuardMenu() {
        permanentSleepItem?.state = sleepGuard.isPermanent ? .on : .off
        timedSleepItem?.title = sleepGuard.timedMenuTitle
        let timedRunning = sleepGuard.isActive && sleepGuard.deadline != nil
        for item in timedSleepSubmenu?.items ?? [] where item.tag > 0 {
            item.state = (timedRunning && sleepGuard.sessionMinutes == item.tag) ? .on : .off
        }
        SleepGuardSettingsWindow.shared.refreshStatus()
    }

    /// 防睡状态真的变了才走这条：菜单 + 状态栏图标/tooltip 一起刷
    private func refreshSleepGuardState() {
        updateSleepGuardMenu()
        updateStatus()
    }

    @objc private func togglePermanentSleep() {
        sleepGuard.togglePermanent()
    }

    /// 点已勾选的那项 = 停止，否则按新时长重开
    @objc private func startTimedSleep(_ sender: NSMenuItem) {
        sleepGuard.toggleTimed(minutes: sender.tag)
    }

    @objc private func openSleepGuardSettings() {
        sleepGuard.openSettingsWindow()
    }

    // MARK: - Connection Detection (3s process poll)

    private func startPollTimer() {
        stopPollTimer()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        // 3s 足够快（远程连接不是亚秒级事件），进程创建开销降到 1/3
        timer.schedule(deadline: .now(), repeating: 3, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            self?.pollConnectionState()
        }
        timer.resume()
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private let connectionDetector = RemoteConnectionDetector()

    private func probeRustDesk() -> ConnectionProbe { connectionDetector.rustDesk() }
    private func probeScreenSharing() -> ConnectionProbe { connectionDetector.screenSharing() }

    /// Runs on pollQueue: the pgrep spawns block, so they stay off the
    /// main thread; state changes are applied back on main.
    /// 探测健康度（noteProbeHealth）只记本轮真正跑过的那几路：RustDesk 已连接时
    /// 第二路不跑，它的计数保持原样，既不清零也不累加
    private func pollConnectionState() {
        let rustdesk = probeRustDesk()
        if case .connected(let source) = rustdesk {
            DispatchQueue.main.async { [weak self] in
                self?.noteProbeHealth("RustDesk", rustdesk)
                self?.applyConnected(source)
            }
            return // 已确定连接就不用再跑第二路探测
        }
        let screenSharing = probeScreenSharing()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.noteProbeHealth("RustDesk", rustdesk)
            self.noteProbeHealth("屏幕共享", screenSharing)
            if case .connected(let source) = screenSharing {
                self.applyConnected(source)
            } else {
                self.applyNotConnected(rustdesk: rustdesk, screenSharing: screenSharing)
            }
        }
    }

    /// 远程会话中热插显示器 / 睡眠唤醒：重新镜像 + 重压 gamma（都幂等）
    private func reassertScreenOffState() {
        guard sessionPrepared, screenCtl.isScreenBlack else { return }
        screenCtl.resetMirrorRetries()
        screenCtl.enableMirroring()
        screenCtl.reassertBlackIfNeeded()
    }

    /// 连续确定断开的轮数；恢复亮屏要求 ≥2（单次假阴性不暴露桌面）
    private var disconnectStreak = 0
    /// 断开后延迟撤黑屏的任务（等锁屏接管）；重新连上要取消
    private var pendingRestore: DispatchWorkItem?
    /// 延迟撤黑的代际令牌。cancel 只能拦「还没开跑」的任务，且极端主线程阻塞下
    /// 可能积压多个任务而 cancel 只够得着最后一个——过期代际的任务自己作废
    private var restoreGeneration = 0
    /// 镜像/分辨率/Dock 已为本次会话配置过。和 isScreenBlack 分开记：
    /// setBlack 部分失败时轮询要重试 gamma，但重活（尤其 killall Dock）绝不能每 3s 来一遍
    private var sessionPrepared = false
    /// 激活当前会话的来源（"RustDesk" / "Screen Sharing"）；断开确认只看这一路的探测
    private var activeSource: String?
    private var loggedUnknownProbe = false

    // MARK: 探测健康度（主线程）
    //
    // 一路探测连续 unknown 到阈值就是「该来源的检测已失效」，必须进状态行 + 换状态栏
    // 图标，不能只进日志：netstat 那一路在 macOS 27 上永久失效、error.log 每次启动都
    // 记了、状态行却一直写「监控中」，就这样沉默了六周。只更新本轮真正跑过的探测
    private var probeUnknownStreak: [String: Int] = [:]
    private let probeBrokenThreshold = 10 // 3s 一轮 × 10 = 30s，瞬时故障不闪警告
    private var brokenProbes: [String] {
        ["RustDesk", "屏幕共享"].filter { (probeUnknownStreak[$0] ?? 0) >= probeBrokenThreshold }
    }

    private func noteProbeHealth(_ name: String, _ probe: ConnectionProbe) {
        let before = probeUnknownStreak[name] ?? 0
        let after: Int
        if case .unknown = probe {
            after = min(before + 1, probeBrokenThreshold) // 封顶：够判定即可，不用无限累加
        } else {
            after = 0
        }
        probeUnknownStreak[name] = after
        let wasBroken = before >= probeBrokenThreshold
        let isBroken = after >= probeBrokenThreshold
        guard wasBroken != isBroken else { return }
        ErrorLog.log(isBroken
            ? "远程检测: \(name) 探测连续 \(probeBrokenThreshold) 轮异常（进程或认证检查失败/超时），该来源的连接检测已失效，状态栏已标记"
            : "远程检测: \(name) 探测已恢复", key: "probe-\(name)")
        updateStatus()
    }

    // 两个 apply 共用的闸门语义：pollConnectionState 是异步交回主线程的，用户在
    // 这中间关掉远程熄屏时 stopPollTimer 只停了后续轮次，拦不住已经算完的这一份。
    // 放行的话它会重新镜像 + 改 Dock + 黑屏，而定时器已停——没有路径再恢复回来

    private func applyConnected(_ source: String) {
        guard remoteMonitorEnabled else { return }
        // 真实远程连接接管演练，取消演练的自动收尾，保持隐私黑屏。
        if source != "演练" { cancelRehearsal() }
        disconnectStreak = 0
        loggedUnknownProbe = false
        activeSource = source
        restoreGeneration += 1 // 作废一切在途的延迟撤黑任务
        pendingRestore?.cancel()
        pendingRestore = nil
        if !screenCtl.isScreenBlack {
            NSLog("[POLL] \(source) connection active — activating screen off")
            // 先压黑；失败时仍记为本次会话，断开后可撤销部分成功的 gamma。
            screenCtl.setBlack()
            if !sessionPrepared {
                sessionPrepared = true
                screenCtl.resetMirrorRetries()
                screenCtl.prepareResolutionSnapshot()
                screenCtl.enableMirroring()
                screenCtl.switchResolution()
                screenCtl.saveDockAndSetLeft()
            }
            // 显示重配置可能重置 gamma，完成后立即补压。
            screenCtl.reassertBlackIfNeeded()
            updateStatus()
        } else if sessionPrepared {
            // 会话中每轮补镜像：屏休眠时首轮镜像失败后没有别的入口（见 ScreenController
            // .ensureMirroringWhileConnected）。动了显示器就重压一次 gamma
            if screenCtl.ensureMirroringWhileConnected() {
                screenCtl.reassertBlackIfNeeded()
            }
        }
        lastPolledConnected = true
    }

    /// 两路探测都不是「确定连接」时的处理。关键规则：黑屏会话的断开确认
    /// **只看激活这次会话的那一路探测**——另一路可能在本机永远不可用
    /// （旧的 netstat 探测在 macOS 27 上就是永远 unknown，见 probeScreenSharing），
    /// 要求它也「确定断开」等于 RustDesk 会话结束后黑屏永不恢复。
    /// 它既然从来探不到连接，也不可能是这次会话的激活来源
    private func applyNotConnected(rustdesk: ConnectionProbe, screenSharing: ConnectionProbe) {
        guard remoteMonitorEnabled, !rehearsalActive, pendingRestore == nil else { return }
        if screenCtl.isScreenBlack || sessionPrepared {
            let sourceProbe = activeSource == "Screen Sharing" ? screenSharing : rustdesk
            if case .disconnected = sourceProbe {
                loggedUnknownProbe = false
                disconnectStreak += 1
                if disconnectStreak >= 2 { confirmedDisconnect() }
            } else {
                // 激活来源的探测手段故障：维持黑屏，绝不据此恢复亮屏
                disconnectStreak = 0
                if !loggedUnknownProbe {
                    loggedUnknownProbe = true
                    ErrorLog.log("远程检测: 激活来源探测异常（进程失败/超时），维持熄屏状态")
                }
            }
        } else {
            // 空闲态：镜像清理是幂等兜底（只在有残留快照时动手），unknown 也照走
            // ——某一路探测永久 unknown 时，启动首轮的镜像恢复不能被卡住
            // 边沿触发 + 「还有未完成的恢复就继续重试」：断开那一刻屏幕若正好睡着，
            // 镜像恢复会失败，只靠边沿触发就再也不会有第二次尝试（无快照时是空操作）
            if lastPolledConnected != false || screenCtl.hasPendingDisplayRestore {
                screenCtl.restoreDisplaySettings()
            }
            lastPolledConnected = false
            // 空闲态的探测故障不在这里记：noteProbeHealth 按连续轮数判定并进状态栏
        }
    }

    /// 确认断开：先锁再撤黑。原顺序（恢复 → 锁）在屏保接管前有一段真实桌面
    /// 直接可见；现在 gamma 黑幕垫底，锁定确认后才撤，全程无裸露窗口。
    /// 期间若重新连上，pendingRestore 会被取消、代际作废，黑幕原样保留
    private func confirmedDisconnect() {
        disconnectStreak = 0
        activeSource = nil
        NSLog("[POLL] No active connection — locking, then restoring screen")
        screenCtl.lockScreen()
        restoreGeneration += 1
        pollLockThenRestore(generation: restoreGeneration, startedAt: Date())
    }

    // MARK: 撤黑前的锁定确认
    //
    // 原来固定等 1.2s：`open -a ScreenSaverEngine` 退出码 0 只说明请求被接受，屏保是否
    // 盖上、盖上后是否上锁（取决于「屏保开始后要求密码」的延迟设置）代码一概不知，
    // 而这正是隐私工具最后一道门。现在每 0.25s 查一次会话字典的 CGSSessionScreenIsLocked，
    // 另收 loginwindow 上锁时发的 com.apple.screenIsLocked 分布式通知作第二路信号；
    // 确认上锁后再留 0.3s 让屏保画面落定才撤黑。超过预算仍未上锁：记日志 + 状态栏标记，
    // 然后照旧撤黑——一直黑着的话本地用户回来连菜单都看不见，比裸露更糟
    /// 最近一次收到 com.apple.screenIsLocked 的时刻；只信本次锁屏请求之后到达的
    private var lastLockNotificationAt: Date?
    /// 上次断开后未能确认锁定：进状态行，直到下一次确认成功或用户重新开启监控
    private var lockWarning: String?

    private func pollLockThenRestore(generation gen: Int, startedAt: Date) {
        guard gen == restoreGeneration else { return }
        let notified = (lastLockNotificationAt ?? .distantPast) >= startedAt.addingTimeInterval(-1)
        let locked = notified || lockCheck()
        let waited = Date().timeIntervalSince(startedAt)
        if locked {
            if lockWarning != nil {
                lockWarning = nil
                updateStatus()
            }
            NSLog("[POLL] Screen lock confirmed after \(String(format: "%.2f", waited))s — restoring")
            scheduleRestore(generation: gen, after: 0.3)
            return
        }
        if waited >= lockWaitBudget {
            lockWarning = "上次断开后锁屏未确认"
            ErrorLog.log("锁屏: 断开后 \(Int(lockWaitBudget))s 内未确认锁定，已照常撤黑。请检查「锁定屏幕」设置里屏保开始后要求密码是否为「立即」")
            scheduleRestore(generation: gen, after: 0)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pollLockThenRestore(generation: gen, startedAt: startedAt)
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func scheduleRestore(generation gen: Int, after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.restoreGeneration else { return }
            self.pendingRestore = nil
            self.sessionPrepared = false
            self.screenCtl.restoreDock()
            self.screenCtl.restoreDisplaySettings()
            self.screenCtl.restore()
            self.updateStatus()
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - UI Updates

    /// 状态栏按钮当前显示的 symbol 名。
    /// **重复赋同一个 image 也会让 NSStatusItem 重算按钮几何** —— 而防睡的 60s
    /// 心跳经 refreshSleepGuardState 会走到 updateStatus，万一撞上菜单正在定位的
    /// 瞬间，菜单就会按错位的锚点弹出（跑到屏幕右边）。这正是 updateSleepGuardMenu
    /// 注释里记过的那个坑，只是触发源更冷门。symbol 没变就不碰 image；
    /// title/toolTip 不参与几何，照常刷新
    private var currentStatusSymbol: String?

    private func setStatusSymbol(_ name: String, description: String? = nil) {
        guard currentStatusSymbol != name else { return }
        currentStatusSymbol = name
        // 符号名在旧系统上可能不存在：回退到 eye，绝不让状态栏按钮变成空图标
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: description)
        statusItem.button?.title = ""
    }

    private func updateStatus() {
        guard statusItem != nil, statusMenuItem != nil else { return }
        if tilingPermissionMissing {
            // 系统开关可能已开启但仍绑定旧签名；只描述当前进程的实际状态。
            statusMenuItem.title = "当前版本的设备控制授权尚未生效"
            statusMenuItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            setStatusSymbol("exclamationmark.triangle", description: "Bento 授权尚未生效")
            statusItem.button?.toolTip = "Bento 授权尚未生效；可在菜单中查看恢复方法"
            return
        }
        if !remoteMonitorEnabled {
            statusMenuItem.title = "远程熄屏监控已停用"
            statusMenuItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
            setStatusSymbol("eye", description: "Bento")
            statusItem.button?.toolTip = tooltip("远程熄屏监控已停用")
            return
        }
        // 探测失效 / 锁屏未确认：进状态行 + 换状态栏图标。只进日志的故障等于没报
        var warnings: [String] = []
        let broken = brokenProbes
        if !broken.isEmpty { warnings.append("\(broken.joined(separator: "/"))探测不可用") }
        if let lockWarning { warnings.append(lockWarning) }
        let suffix = warnings.isEmpty ? "" : " · " + warnings.joined(separator: " · ")
        if screenCtl.isScreenBlack {
            let activity = rehearsalActive ? "演练中 · 10 秒后自动锁屏恢复" : "远程已连接 · 已熄屏"
            statusMenuItem.title = activity + suffix
            statusMenuItem.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
            // 熄屏态只换图标不加文字：菜单栏空间是稀缺资源（尤其拥挤栏），语义放 tooltip
            setStatusSymbol("eye.slash.fill", description: "Bento 已熄屏")
            statusItem.button?.toolTip = activity + suffix
        } else {
            statusMenuItem.title = "监控中" + suffix
            statusMenuItem.image = NSImage(systemSymbolName: warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
                                           accessibilityDescription: nil)
            setStatusSymbol(warnings.isEmpty ? "eye" : "eye.trianglebadge.exclamationmark",
                            description: warnings.isEmpty ? "Bento" : "Bento · " + warnings.joined(separator: "，"))
            statusItem.button?.toolTip = tooltip("Bento" + suffix)
        }
    }

    /// 防睡是菜单以外唯一的状态出口，tooltip 得带上。
    /// 「缺权限」「已熄屏」两条分支不带——那两条的信息优先级更高
    private func tooltip(_ base: String) -> String {
        guard let short = sleepGuard.shortStatus else { return base }
        return "\(base) · \(short)"
    }

    // MARK: - 分屏接线

    private func startTiling() {
        tiling.onPermissionStateChange = { [weak self] trusted in
            self?.setTilingPermissionMissing(!trusted)
        }
        tiling.start()
        setTilingPermissionMissing(!tiling.isPermissionOK)
    }

    private func setTilingPermissionMissing(_ missing: Bool) {
        tilingPermissionMissing = missing
        tilingPermissionItem.isHidden = !missing
        updatePermissionRecovery()
        updateStatus()
    }

    private func updateTilingMenuStates() {
        tilingMasterItem.state = tiling.config.masterEnabled ? .on : .off
    }

    private func startScrollReverser(showAlert: Bool) {
        scrollReverser.onStateChange = { [weak self] in self?.updateScrollStatus() }
        if !scrollReverser.start(promptForPermissions: showAlert), showAlert {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.hasShownPermissionHelp,
                      self.scrollReverser.startupFailure != nil || self.tilingPermissionMissing else { return }
                self.hasShownPermissionHelp = true
                self.showPermissionRecovery()
            }
        }
    }

    private func updateScrollStatus() {
        let failure = scrollReverser.startupFailure
        let unavailable = failure != nil
        scrollPermissionItem.isHidden = !unavailable
        openAccessibilityItem.isHidden = !unavailable
        permissionHelpItem.isHidden = !unavailable && !tilingPermissionMissing
        retryScrollPermissionsItem.isHidden = !unavailable
        scrollPermissionItem.title = failure == .eventTap
            ? "滚动功能暂不可用（请重试，仍失败请重启 Bento）"
            : "滚动控制授权尚未生效"
        retryScrollPermissionsItem.title = failure == .eventTap ? "重试滚动功能" : "重新检测滚动权限"

        let suffix = failure == .eventTap ? "（暂不可用）" : unavailable ? "（授权待生效）" : ""
        reverseMouseItem.title = "反转鼠标滚动" + suffix
        reverseTrackpadItem.title = "反转触控板滚动" + suffix
        reverseMouseItem.isEnabled = !unavailable
        reverseTrackpadItem.isEnabled = !unavailable
        reverseMouseItem.state = scrollReverser.reverseMouse ? .on : .off
        reverseTrackpadItem.state = scrollReverser.reverseTrackpad ? .on : .off
        updatePermissionRecovery()
    }

    private func updatePermissionRecovery() {
        guard permissionChecksStarted else { return }
        let condition: PermissionRecoveryCondition
        if tilingPermissionMissing || scrollReverser.startupFailure == .authorization {
            condition = .authorization
        } else if scrollReverser.startupFailure == .eventTap {
            condition = .eventTap
        } else {
            condition = .ready
        }
        if !tilingPermissionMissing, let access = scrollReverser.accessSnapshot,
           access.accessibility, access.postEvent {
            permissionRecoveryModel.recordAuthorizationGranted()
        }
        permissionHelpItem?.isHidden = condition == .ready
        permissionRecoveryWindow?.update(permissionRecoveryModel.presentation(for: condition))
    }

    @objc private func showPermissionRecovery() {
        if permissionRecoveryWindow == nil {
            permissionRecoveryWindow = PermissionRecoveryWindow(
                onOpenSettings: { [weak self] in self?.openAccessibilitySettings() },
                onRevealApp: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
                onRetry: { [weak self] in self?.retryScrollPermissions() },
                onRestart: { [weak self] in self?.restartForPermissions() })
        }
        updatePermissionRecovery()
        permissionRecoveryWindow?.show()
    }

    @objc private func permissionSettingsDeactivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.systempreferences" else { return }
        retryScrollPermissions()
    }

    private func restartForPermissions() {
        guard !relaunchInFlight else { return }
        // 等当前 PID 正常退出后才 open，避免单实例保护挡掉新进程。
        // 路径和 PID 作为独立参数传入，不拼进 shell 代码；不发送强制退出信号。
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", """
            attempt=0
            while kill -0 "$1" 2>/dev/null; do
                attempt=$((attempt + 1))
                [ "$attempt" -lt 200 ] || exit 1
                sleep 0.1
            done
            exec /usr/bin/open "$2"
            """, "bento-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        do {
            try launcher.run()
            relaunchInFlight = true
            NSApp.terminate(nil)
        } catch {
            ErrorLog.log("权限恢复: 无法重启 Bento：\(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "无法自动重启 Bento"
            alert.informativeText = "请从菜单退出 Bento，再重新打开当前应用。"
            alert.runModal()
        }
    }

    private func openPrivacySettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Actions

    private var authRestartInFlight = false

    @objc private func authRestart() {
        // 重入保护：osascript 等自动化授权对话框期间（最长 300s），重复点菜单
        // 会叠加 spawn 出多个 osascript / 多个 Terminal 标签
        guard !authRestartInFlight else { return }
        authRestartInFlight = true
        // 两点都和 osascript 会阻塞有关：首次控制 Terminal 时系统弹「自动化」授权
        // 对话框，osascript 一直等到用户回答为止。
        // 1) 不能占着主线程——那段时间整个 App 转菊花
        // 2) 不能用 runProcess 默认的 10s 看门狗——会在用户读对话框时把它杀掉，
        //    表现成"点了菜单毫无反应"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            runProcess("/usr/bin/osascript", [
                "-e", "tell application \"Terminal\" to do script \"sudo fdesetup authrestart\"",
                "-e", "tell application \"Terminal\" to activate",
            ], timeout: 300)
            DispatchQueue.main.async { self?.authRestartInFlight = false }
        }
    }

    @objc private func quitApp() {
        iconMgr.prepareForQuit() // 主动退出（可能要卸载）：隐藏图标写回可见区
        NSApplication.shared.terminate(nil)
    }

    @objc private func toggleReverseMouse() {
        scrollReverser.reverseMouse.toggle()
        reverseMouseItem.state = scrollReverser.reverseMouse ? .on : .off
    }

    /// 远程熄屏总开关：停用时若正黑屏则立即恢复（不锁屏，用户在本地操作）
    @objc private func toggleRemoteMonitor() {
        remoteMonitorEnabled.toggle()
        UserDefaults.standard.set(remoteMonitorEnabled, forKey: "RemoteMonitorEnabled")
        remoteMonitorItem?.state = remoteMonitorEnabled ? .on : .off
        if remoteMonitorEnabled {
            lockWarning = nil // 用户重新开启 = 重新给一次机会，旧警告不再挂着
            startPollTimer()
        } else {
            cancelRehearsal()
            stopPollTimer()
            restoreGeneration += 1
            pendingRestore?.cancel()
            pendingRestore = nil
            disconnectStreak = 0
            let hadSession = screenCtl.isScreenBlack || sessionPrepared
            sessionPrepared = false
            activeSource = nil
            if hadSession {
                screenCtl.restoreDock()
                screenCtl.restoreDisplaySettings()
                screenCtl.restore()
            }
        }
        updateStatus()
    }

    @objc private func toggleReverseTrackpad() {
        scrollReverser.reverseTrackpad.toggle()
        reverseTrackpadItem.state = scrollReverser.reverseTrackpad ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        openPrivacySettingsPane("Privacy_Accessibility")
    }

    @objc private func retryScrollPermissions() {
        scrollReverser.refreshPermissions()
        tiling.refreshPermissions()
        setTilingPermissionMissing(!tiling.isPermissionOK)
        updatePermissionRecovery()
    }

    private var rehearsalActive = false
    private var rehearsalEnd: DispatchWorkItem?

    private func cancelRehearsal() {
        rehearsalEnd?.cancel()
        rehearsalEnd = nil
        rehearsalActive = false
    }

    @objc private func rehearseScreenOff() {
        let alert = NSAlert()
        guard remoteMonitorEnabled, !sessionPrepared, !screenCtl.isScreenBlack, pendingRestore == nil else {
            alert.messageText = "当前无法开始演练"
            alert.informativeText = "请开启远程熄屏监控，并等待当前远程会话或恢复流程结束后再试。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        alert.messageText = "演练远程熄屏流程"
        alert.informativeText = "屏幕将变黑并调整显示器与 Dock，10 秒后自动锁屏并恢复。请先保存工作；解锁后即可检查恢复结果。期间真实远程连接会接管演练，保持熄屏。"
        alert.addButton(withTitle: "开始演练")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = beginRehearsal()
    }

    @discardableResult
    private func beginRehearsal(duration: TimeInterval = 10) -> Bool {
        // 对话框期间状态可能改变，真正执行前再检查一次。
        guard remoteMonitorEnabled, !rehearsalActive, !sessionPrepared,
              !screenCtl.isScreenBlack, pendingRestore == nil else { return false }
        rehearsalActive = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.rehearsalActive else { return }
            self.cancelRehearsal()
            self.confirmedDisconnect()
        }
        // 先安排恢复，再施加变更；走真实连接与锁定确认的同一套代码。
        rehearsalEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        applyConnected("演练")
        return true
    }

    @objc private func restoreExtendedDisplays() {
        guard let failure = screenCtl.restoreExtendedDisplays() else { return }
        let alert = NSAlert()
        alert.messageText = "未能恢复扩展显示器"
        alert.informativeText = failure
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 分屏动作

    @objc private func toggleTilingMaster() {
        tiling.setMasterEnabled(!tiling.config.masterEnabled)
        updateTilingMenuStates()
    }

    @objc private func editTilingLayouts() {
        tiling.openLayoutEditor()
    }

    @objc private func openIconManager() {
        iconMgr.openManagerWindow()
    }

    @objc private func toggleClaudeGuard() {
        claudeGuard.setEnabled(!claudeGuard.snapshot.enabled)
    }

    @objc private func openClaudeGuardHelp() {
        ClaudeGuardHelpWindow.shared.show()
    }

    @objc private func cleanUpClaudeGuard() {
        let alert = NSAlert()
        alert.messageText = "恢复 hosts 并卸载 Claude 防护守护？"
        alert.informativeText = "将移除 Bento 添加的 hosts 阻断和 Clash Merge 规则，然后注销后台守护。其他 hosts、Clash 和 Claude 数据不会删除。"
        alert.addButton(withTitle: "清理并卸载")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        claudeGuard.cleanupAndUnregister()
    }

    private func refreshClaudeGuard() {
        claudeGuardStatusItem?.title = claudeGuard.statusText
        claudeGuardItem?.state = claudeGuard.menuState
        claudeGuardItem?.isEnabled = !claudeGuard.operationInFlight
    }

    /// 菜单里的开机自启行随 SMAppService 实际状态走。requiresApproval 单独呈现：
    /// 系统把注册挂起等用户批准时，开关自己 register/unregister 都动不了，
    /// 不提示的话这一行表现为"点了没反应"的死开关
    private func refreshAutoLaunchItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            autoLaunchItem.title = "开机自启"
            autoLaunchItem.state = .on
        case .requiresApproval:
            autoLaunchItem.title = "开机自启（待系统设置批准）"
            autoLaunchItem.state = .mixed
        default:
            autoLaunchItem.title = "开机自启"
            autoLaunchItem.state = .off
        }
    }

    @objc private func toggleAutoLaunch() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                // 卡在待批准：这里能做的只有把用户带到批准入口
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            ErrorLog.log("开机自启切换失败: \(error.localizedDescription)")
        }
        refreshAutoLaunchItem()
    }

    // MARK: - Auto Launch (SMAppService)

    /// 首次启动默认开启自启；之后完全由菜单开关决定，不覆盖用户选择。
    /// 顺带做一次性迁移：老版手写 LaunchAgent plist + launchctl → 官方 SMAppService
    /// （与 系统设置 → 通用 → 登录项 集成）。
    private func installAutoLaunchIfFirstRun() {
        if FileManager.default.fileExists(atPath: launchAgentPath) {
            runProcess("/bin/launchctl", ["unload", launchAgentPath])
            try? FileManager.default.removeItem(atPath: launchAgentPath)
            register(reason: "LaunchAgent 迁移")
        }
        let key = "LaunchAtLoginConfigured"
        if !UserDefaults.standard.bool(forKey: key) {
            register(reason: "首次启动")
            // 注册真的生效（或进入待批准）才记「已配置」：先置位的话，
            // 首次注册失败就永远不会再试，开机自启静默失效
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval {
                UserDefaults.standard.set(true, forKey: key)
            }
        }
        refreshAutoLaunchItem()
    }

    private func register(reason: String) {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            NSLog("开机自启已注册（\(reason)）")
        } catch {
            ErrorLog.log("开机自启注册失败（\(reason)）: \(error.localizedDescription)")
        }
    }

}

extension AppDelegate: NSMenuDelegate {
    /// 文案/勾选态的刷新点。**不放在 menuWillOpen 里**：NSMenu.h 明写
    /// "Do not modify the structure of the menu or the menu items from within
    /// these callbacks"，而这里要改标题（定时防睡的剩余时间）。menuNeedsUpdate
    /// 就是为此设计的，且在 menuWillOpen 之前调用，菜单几何按新文案算
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        // 每次打开都刷一次剩余时间，省得只靠 60s 心跳
        updateSleepGuardMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // 子菜单也会走 delegate 转发链，只认主菜单
        guard menu === statusMenu else { return }
        // 分屏 tap 让路：它的窗口枚举按 pid 过滤掉了 Bento 自己的菜单窗口，
        // 只看得见菜单「底下」那个别家窗口的标题栏带，会把落在菜单上的点击
        // 当成标题栏操作吞掉并吸附无关窗口
        tiling.setMenuTracking(true)
        // 图标管理（拖拽模式）也让路：合成 ⌘ 拖拽在菜单窗口开着时会打架
        iconMgr.setStatusMenuOpen(true)
    }

    /// 鼠标在菜单里移动就给让路续期：否则让路是个绝对超时，菜单被晾着开久了会自行失效
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === statusMenu else { return }
        tiling.setMenuTracking(true)
        iconMgr.setStatusMenuOpen(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        tiling.setMenuTracking(false)
        iconMgr.setStatusMenuOpen(false)
    }
}

#if BENTO_TESTS
// 仅测试构建暴露驱动入口，测试不安装菜单、event tap 或修改真实显示器。
extension AppDelegate {
    func testConnect(_ source: String = "Screen Sharing") { applyConnected(source) }
    func testDisconnect(rustdesk: ConnectionProbe = .unknown, screenSharing: ConnectionProbe = .disconnected) {
        applyNotConnected(rustdesk: rustdesk, screenSharing: screenSharing)
    }
    func testSetMonitoring(_ enabled: Bool) { remoteMonitorEnabled = enabled }
    func testDisableMonitoring() { if remoteMonitorEnabled { toggleRemoteMonitor() } }
    func testRehearse(duration: TimeInterval) -> Bool { beginRehearsal(duration: duration) }
    var testSessionPrepared: Bool { sessionPrepared }
    var testHasLockWarning: Bool { lockWarning != nil }
}
#endif
