import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusMenuItem: NSMenuItem!

    private let screenCtl = ScreenController()
    private let scrollReverser = ScrollReverser()
    private var remoteMonitorEnabled = UserDefaults.standard.object(forKey: "RemoteMonitorEnabled") as? Bool ?? true
    private var scrollPermissionItem: NSMenuItem!
    private var openAccessibilityItem: NSMenuItem!
    private var openInputMonitoringItem: NSMenuItem!
    private var retryScrollPermissionsItem: NSMenuItem!
    private var reverseMouseItem: NSMenuItem!
    private var reverseTrackpadItem: NSMenuItem!
    // 分屏
    private let tiling = TilingController()
    // 远程熄屏监控开关（默认开）
    private var remoteMonitorItem: NSMenuItem!
    private var tilingMasterItem: NSMenuItem!
    private var tilingPermissionItem: NSMenuItem!
    private var tilingPermissionMissing = false
    private var autoLaunchItem: NSMenuItem!
    // 菜单栏图标管理
    private let iconMgr = MenuBarIconManager()
    // 防止睡眠
    private let sleepGuard = SleepGuard()
    private var permanentSleepItem: NSMenuItem!
    private var timedSleepItem: NSMenuItem!
    private var timedSleepSubmenu: NSMenu?
    private var pollTimer: DispatchSourceTimer?
    /// 上一轮轮询的连接状态（nil = 尚未轮询过），用于边沿触发
    private var lastPolledConnected: Bool?
    private let pollQueue = DispatchQueue(label: "com.sz.bento.connection-poll")
    private var hasShownScrollPermissionAlert = false

    private let launchAgentLabel = "com.sz.bento"
    private var launchAgentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先收拾上次非正常退出留下的分辨率/Dock 残留，再启动轮询：
        // 首轮轮询若真的检测到连接，它会在恢复后的干净状态上重新取快照
        screenCtl.recoverFromUncleanExit()
        setupStatusBar()
        installAutoLaunchIfFirstRun()
        startScrollReverser(showAlert: true)
        startTiling()
        iconMgr.start()
        sleepGuard.onStateChange = { [weak self] in self?.refreshSleepGuardState() }
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
        if remoteMonitorEnabled { startPollTimer() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPollTimer()
        iconMgr.stop()
        tiling.stop()
        scrollReverser.stop()
        screenCtl.restore()
        screenCtl.restoreResolution()
        screenCtl.restoreDock()
        screenCtl.disableMirroring()
        // Dock 还原是异步的，等它落地再让进程走，否则 Dock 会永远停在左边
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

        // 远程场景配件：认证重启，跳过 FileVault 开机解锁界面，重启后远程还能连回来
        statusMenu.addItem(makeItem("FileVault 免密重启", symbol: "lock.rotation", action: #selector(authRestart)))

        statusMenu.addItem(.sectionHeader(title: "滚动方向"))

        reverseMouseItem = makeItem("反转鼠标滚动", symbol: "computermouse", action: #selector(toggleReverseMouse))
        reverseMouseItem.state = scrollReverser.reverseMouse ? .on : .off
        statusMenu.addItem(reverseMouseItem)

        reverseTrackpadItem = makeItem("反转触控板滚动", symbol: "hand.point.up.left", action: #selector(toggleReverseTrackpad))
        reverseTrackpadItem.state = scrollReverser.reverseTrackpad ? .on : .off
        statusMenu.addItem(reverseTrackpadItem)

        scrollPermissionItem = NSMenuItem(title: "滚动功能缺少权限", action: nil, keyEquivalent: "")
        scrollPermissionItem.isEnabled = false
        scrollPermissionItem.isHidden = true
        statusMenu.addItem(scrollPermissionItem)

        openAccessibilityItem = makeItem("打开「辅助功能」设置", symbol: "accessibility", action: #selector(openAccessibilitySettings))
        openAccessibilityItem.isHidden = true
        statusMenu.addItem(openAccessibilityItem)

        openInputMonitoringItem = makeItem("打开「输入监控」设置", symbol: "keyboard", action: #selector(openInputMonitoringSettings))
        openInputMonitoringItem.isHidden = true
        statusMenu.addItem(openInputMonitoringItem)

        retryScrollPermissionsItem = makeItem("重新检测滚动权限", symbol: "arrow.clockwise", action: #selector(retryScrollPermissions))
        retryScrollPermissionsItem.isHidden = true
        statusMenu.addItem(retryScrollPermissionsItem)

        statusMenu.addItem(.sectionHeader(title: "分屏（窗口吸附）"))

        tilingPermissionItem = makeItem("分屏需要辅助功能权限（点击打开设置）", symbol: "exclamationmark.triangle", action: #selector(openAccessibilitySettings))
        tilingPermissionItem.isHidden = true
        statusMenu.addItem(tilingPermissionItem)

        // 单一总开关：开 = 双击标题栏吸附 + ⌘ 拖动标题栏吸附都可用
        tilingMasterItem = makeItem("启用分屏", symbol: "uiwindow.split.2x1", action: #selector(toggleTilingMaster))
        statusMenu.addItem(tilingMasterItem)

        statusMenu.addItem(makeItem("编辑分屏布局…", symbol: "squareshape.split.2x2.dotted", action: #selector(editTilingLayouts)))

        statusMenu.addItem(.sectionHeader(title: "防止睡眠"))

        installSleepGuardItems()

        statusMenu.addItem(.sectionHeader(title: "菜单栏图标"))

        statusMenu.addItem(makeItem("管理菜单栏图标…", symbol: "menubar.rectangle", action: #selector(openIconManager)))

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

    /// 探测三态：进程 spawn 失败 / 看门狗超时杀 / netstat 输出异常都不是「没有连接」。
    /// 原实现把一切失败折叠成 false——远程会话中一次瞬时故障就恢复亮屏 + 锁定，
    /// 本地桌面直接暴露一个轮询周期，还把对面正在操作的会话打断
    private enum ConnectionProbe {
        case connected(String)
        case disconnected
        case unknown
    }

    private func probeRustDesk() -> ConnectionProbe {
        switch runProcess("/usr/bin/pgrep", ["-fi", "rustdesk.*--cm"]).status {
        case 0: return .connected("RustDesk")
        case 1: return .disconnected // pgrep 语义：1 = 确定无匹配进程
        default: return .unknown     // -1 spawn 失败 / 15 看门狗超时杀 / 其他
        }
    }

    private func probeScreenSharing() -> ConnectionProbe {
        // 只匹配本地地址列（第 4 列）：本机主动连别人 5900 不算。
        // 直接跑 netstat 在 Swift 里解析，省掉 sh+awk 两个进程
        let r = runProcess("/usr/sbin/netstat", ["-an", "-p", "tcp"], captureOutput: true)
        // netstat 正常运行绝不会输出空——空输出/非零退出都是探测手段故障
        guard r.status == 0, !r.output.isEmpty else { return .unknown }
        for line in r.output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 6, cols[3].hasSuffix(".5900"), cols[5] == "ESTABLISHED" {
                return .connected("Screen Sharing")
            }
        }
        return .disconnected
    }

    /// Runs on pollQueue: process/netstat checks block, so they stay off the
    /// main thread; state changes are applied back on main.
    private func pollConnectionState() {
        let rustdesk = probeRustDesk()
        if case .connected(let source) = rustdesk {
            DispatchQueue.main.async { [weak self] in self?.applyConnected(source) }
            return // 已确定连接就不用再跑 netstat
        }
        let screenSharing = probeScreenSharing()
        if case .connected(let source) = screenSharing {
            DispatchQueue.main.async { [weak self] in self?.applyConnected(source) }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyNotConnected(rustdesk: rustdesk, screenSharing: screenSharing)
        }
    }

    /// 远程会话中热插显示器 / 睡眠唤醒：重新镜像 + 重压 gamma（都幂等）
    private func reassertScreenOffState() {
        guard screenCtl.isScreenBlack else { return }
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

    // 两个 apply 共用的闸门语义：pollConnectionState 是异步交回主线程的，用户在
    // 这中间关掉远程熄屏时 stopPollTimer 只停了后续轮次，拦不住已经算完的这一份。
    // 放行的话它会重新镜像 + 改 Dock + 黑屏，而定时器已停——没有路径再恢复回来

    private func applyConnected(_ source: String) {
        guard remoteMonitorEnabled else { return }
        disconnectStreak = 0
        loggedUnknownProbe = false
        activeSource = source
        restoreGeneration += 1 // 作废一切在途的延迟撤黑任务
        pendingRestore?.cancel()
        pendingRestore = nil
        if !screenCtl.isScreenBlack {
            NSLog("[POLL] \(source) connection active — activating screen off")
            if !sessionPrepared {
                sessionPrepared = true
                screenCtl.enableMirroring()
                screenCtl.switchResolution()
                screenCtl.saveDockAndSetLeft()
            }
            screenCtl.setBlack()
            updateStatus()
        }
        lastPolledConnected = true
    }

    /// 两路探测都不是「确定连接」时的处理。关键规则：黑屏会话的断开确认
    /// **只看激活这次会话的那一路探测**——另一路可能在本机永远不可用
    /// （实测 netstat 在子进程里可能整张 TCP 表不可见，永远 unknown），
    /// 要求它也「确定断开」等于 RustDesk 会话结束后黑屏永不恢复。
    /// 它既然从来探不到连接，也不可能是这次会话的激活来源
    private func applyNotConnected(rustdesk: ConnectionProbe, screenSharing: ConnectionProbe) {
        guard remoteMonitorEnabled else { return }
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
            // ——netstat 永久 unknown 的机器上，启动首轮的镜像恢复不能被卡住
            if lastPolledConnected != false { screenCtl.disableMirroring() }
            lastPolledConnected = false
            if case .unknown = screenSharing, !loggedUnknownProbe {
                loggedUnknownProbe = true
                ErrorLog.log("远程检测: netstat 探测不可用（输出为空/失败），屏幕共享检测失效；RustDesk 检测不受影响")
            }
        }
    }

    /// 确认断开：先锁再撤黑。原顺序（恢复 → 锁）在屏保接管前有一段真实桌面
    /// 直接可见；现在 gamma 黑幕多留 1.2s 垫底，锁屏就位后才撤，全程无裸露窗口。
    /// 期间若重新连上，pendingRestore 会被取消，黑幕原样保留
    private func confirmedDisconnect() {
        disconnectStreak = 0
        sessionPrepared = false
        activeSource = nil
        NSLog("[POLL] No active connection — locking, then restoring screen")
        screenCtl.lockScreen()
        restoreGeneration += 1
        let gen = restoreGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.restoreGeneration else { return }
            self.pendingRestore = nil
            self.screenCtl.restore()
            self.screenCtl.restoreResolution()
            self.screenCtl.restoreDock()
            self.screenCtl.disableMirroring(forceFallback: true)
            self.updateStatus()
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
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
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        statusItem.button?.title = ""
    }

    private func updateStatus() {
        if tilingPermissionMissing {
            // 未授予辅助功能权限时，菜单栏图标给出明确状态
            statusMenuItem.title = "需要辅助功能权限"
            statusMenuItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            setStatusSymbol("exclamationmark.triangle", description: "Bento 需要辅助功能权限")
            statusItem.button?.toolTip = "Bento 需要辅助功能权限"
            return
        }
        if !remoteMonitorEnabled {
            statusMenuItem.title = "远程熄屏监控已停用"
            statusMenuItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
            setStatusSymbol("eye", description: "Bento")
            statusItem.button?.toolTip = tooltip("远程熄屏监控已停用")
            return
        }
        if screenCtl.isScreenBlack {
            statusMenuItem.title = "远程已连接 · 已熄屏"
            statusMenuItem.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
            // 熄屏态只换图标不加文字：菜单栏空间是稀缺资源（尤其拥挤栏），语义放 tooltip
            setStatusSymbol("eye.slash.fill", description: "Bento 已熄屏")
            statusItem.button?.toolTip = "远程已连接 · 已熄屏"
        } else {
            statusMenuItem.title = "监控中"
            statusMenuItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            setStatusSymbol("eye", description: "Bento")
            statusItem.button?.toolTip = tooltip("Bento")
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
        updateStatus()
    }

    private func updateTilingMenuStates() {
        tilingMasterItem.state = tiling.config.masterEnabled ? .on : .off
    }

    private func startScrollReverser(showAlert: Bool) {
        // 自愈重建失败 = 功能已停摆，菜单得跟着变成"需授权 / 可重试"的样子
        scrollReverser.onTapRebuildFailed = { [weak self] in
            self?.setScrollPermissionMissing(true)
        }
        if scrollReverser.start() {
            setScrollPermissionMissing(false)
            return
        }

        setScrollPermissionMissing(true)
        if showAlert {
            DispatchQueue.main.async { [weak self] in
                self?.showScrollPermissionAlert()
            }
        }
    }

    private func setScrollPermissionMissing(_ missing: Bool) {
        scrollPermissionItem.isHidden = !missing
        openAccessibilityItem.isHidden = !missing
        openInputMonitoringItem.isHidden = !missing
        retryScrollPermissionsItem.isHidden = !missing

        reverseMouseItem.title = missing ? "反转鼠标滚动（需授权）" : "反转鼠标滚动"
        reverseTrackpadItem.title = missing ? "反转触控板滚动（需授权）" : "反转触控板滚动"
        reverseMouseItem.isEnabled = !missing
        reverseTrackpadItem.isEnabled = !missing
        reverseMouseItem.state = scrollReverser.reverseMouse ? .on : .off
        reverseTrackpadItem.state = scrollReverser.reverseTrackpad ? .on : .off
    }

    private func showScrollPermissionAlert() {
        guard !hasShownScrollPermissionAlert else { return }
        hasShownScrollPermissionAlert = true

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Bento Needs Scroll Permissions"
        alert.informativeText = "Scroll direction control needs Accessibility and Input Monitoring. Enable Bento in System Settings, then click Retry Scroll Permissions or relaunch Bento."
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilitySettings()
        case .alertSecondButtonReturn:
            openInputMonitoringSettings()
        default:
            break
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
        remoteMonitorItem.state = remoteMonitorEnabled ? .on : .off
        if remoteMonitorEnabled {
            startPollTimer()
        } else {
            stopPollTimer()
            restoreGeneration += 1
            pendingRestore?.cancel()
            pendingRestore = nil
            disconnectStreak = 0
            let hadSession = screenCtl.isScreenBlack || sessionPrepared
            sessionPrepared = false
            activeSource = nil
            if hadSession {
                screenCtl.restore()
                screenCtl.restoreResolution()
                screenCtl.restoreDock()
                screenCtl.disableMirroring(forceFallback: true)
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

    @objc private func openInputMonitoringSettings() {
        openPrivacySettingsPane("Privacy_ListenEvent")
    }

    @objc private func retryScrollPermissions() {
        startScrollReverser(showAlert: false)
    }

    @objc private func restoreExtendedDisplays() {
        screenCtl.restoreExtendedDisplays()
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
    }

    /// 鼠标在菜单里移动就给让路续期：否则让路是个绝对超时，菜单被晾着开久了会自行失效
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === statusMenu else { return }
        tiling.setMenuTracking(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        tiling.setMenuTracking(false)
    }
}
