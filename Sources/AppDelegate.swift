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
        setupStatusBar()
        installAutoLaunchIfFirstRun()
        startScrollReverser(showAlert: true)
        startTiling()
        iconMgr.start()
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

        statusMenu.addItem(.separator())
        statusMenu.addItem(.sectionHeader(title: "远程熄屏"))

        remoteMonitorItem = makeItem("远程连接自动熄屏", symbol: "eye.slash", action: #selector(toggleRemoteMonitor))
        remoteMonitorItem.state = remoteMonitorEnabled ? .on : .off
        statusMenu.addItem(remoteMonitorItem)

        // 熄屏模块的手动兜底：把镜像强制拆回扩展桌面（自动恢复失灵时用）
        statusMenu.addItem(makeItem("恢复扩展显示器", symbol: "display.2", action: #selector(restoreExtendedDisplays)))

        // 远程场景配件：认证重启，跳过 FileVault 开机解锁界面，重启后远程还能连回来
        statusMenu.addItem(makeItem("FileVault 免密重启", symbol: "lock.rotation", action: #selector(authRestart)))

        statusMenu.addItem(.separator())
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

        statusMenu.addItem(.separator())
        statusMenu.addItem(.sectionHeader(title: "分屏（窗口吸附）"))

        tilingPermissionItem = makeItem("分屏需要辅助功能权限（点击打开设置）", symbol: "exclamationmark.triangle", action: #selector(openAccessibilitySettings))
        tilingPermissionItem.isHidden = true
        statusMenu.addItem(tilingPermissionItem)

        // 单一总开关：开 = 双击标题栏吸附 + ⌘ 拖动标题栏吸附都可用
        tilingMasterItem = makeItem("启用分屏", symbol: "uiwindow.split.2x1", action: #selector(toggleTilingMaster))
        statusMenu.addItem(tilingMasterItem)

        statusMenu.addItem(makeItem("编辑分屏布局…", symbol: "squareshape.split.2x2.dotted", action: #selector(editTilingLayouts)))

        statusMenu.addItem(.separator())
        statusMenu.addItem(.sectionHeader(title: "菜单栏图标"))

        statusMenu.addItem(makeItem("管理菜单栏图标…", symbol: "menubar.rectangle", action: #selector(openIconManager)))

        updateTilingMenuStates()

        statusMenu.addItem(.separator())

        autoLaunchItem = makeItem("开机自启", symbol: "power", action: #selector(toggleAutoLaunch))
        autoLaunchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusMenu.addItem(autoLaunchItem)

        statusMenu.addItem(makeItem("退出 Bento", symbol: nil, action: #selector(quitApp), key: "q"))

        statusItem.menu = statusMenu
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

    private func isRustDeskConnected() -> Bool {
        runProcess("/usr/bin/pgrep", ["-fi", "rustdesk.*--cm"]).status == 0
    }

    private func isScreenSharingConnected() -> Bool {
        // 只匹配本地地址列（第 4 列）：本机主动连别人 5900 不算。
        // 直接跑 netstat 在 Swift 里解析，省掉 sh+awk 两个进程
        let out = runProcess("/usr/sbin/netstat", ["-an", "-p", "tcp"], captureOutput: true).output
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 6, cols[3].hasSuffix(".5900"), cols[5] == "ESTABLISHED" {
                return true
            }
        }
        return false
    }

    /// Runs on pollQueue: process/netstat checks block, so they stay off the
    /// main thread; state changes are applied back on main.
    private func pollConnectionState() {
        let rustdesk = isRustDeskConnected()
        let screenSharing = isScreenSharingConnected()
        DispatchQueue.main.async { [weak self] in
            self?.applyConnectionState(rustdesk: rustdesk, screenSharing: screenSharing)
        }
    }

    private func applyConnectionState(rustdesk: Bool, screenSharing: Bool) {
        let connected = rustdesk || screenSharing

        if connected && !screenCtl.isScreenBlack {
            let source = rustdesk ? "RustDesk" : "Screen Sharing"
            NSLog("[POLL] \(source) connection active — activating screen off")
            screenCtl.enableMirroring()
            screenCtl.switchResolution()
            screenCtl.saveDockAndSetLeft()
            screenCtl.setBlack()
            updateStatus()
        } else if !connected && screenCtl.isScreenBlack {
            NSLog("[POLL] No active connection — restoring screen")
            screenCtl.restore()
            screenCtl.restoreResolution()
            screenCtl.restoreDock()
            screenCtl.disableMirroring(forceFallback: true)
            screenCtl.lockScreen()
            updateStatus()
        } else if !connected, lastPolledConnected != false {
            // 只在启动首轮和连接边沿做一次镜像清理，空闲时不再每跳空转
            screenCtl.disableMirroring()
        }
        lastPolledConnected = connected
    }

    // MARK: - UI Updates

    private func updateStatus() {
        if tilingPermissionMissing {
            // 未授予辅助功能权限时，菜单栏图标给出明确状态
            statusMenuItem.title = "需要辅助功能权限"
            statusMenuItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Bento 需要辅助功能权限")
            statusItem.button?.title = ""
            return
        }
        if !remoteMonitorEnabled {
            statusMenuItem.title = "远程熄屏监控已停用"
            statusMenuItem.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
            statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            statusItem.button?.title = ""
            return
        }
        if screenCtl.isScreenBlack {
            statusMenuItem.title = "远程已连接 · 已熄屏"
            statusMenuItem.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
            statusItem.button?.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
            statusItem.button?.title = " 已熄屏"
        } else {
            statusMenuItem.title = "监控中"
            statusMenuItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            statusItem.button?.title = ""
        }
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

    @objc private func authRestart() {
        runProcess("/usr/bin/osascript", [
            "-e", "tell application \"Terminal\" to do script \"sudo fdesetup authrestart\"",
            "-e", "tell application \"Terminal\" to activate",
        ])
    }

    @objc private func quitApp() {
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
            if screenCtl.isScreenBlack {
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

    @objc private func toggleAutoLaunch() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            ErrorLog.log("开机自启切换失败: \(error.localizedDescription)")
        }
        autoLaunchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
            UserDefaults.standard.set(true, forKey: key)
            register(reason: "首次启动")
        }
        autoLaunchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
