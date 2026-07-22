import AppKit
import CoreGraphics
import Foundation
import IOKit

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
    private var restoreDisplaysItem: NSMenuItem!
    // 分屏
    private let tiling = TilingController()
    // 远程熄屏监控开关（默认开）
    private var remoteMonitorItem: NSMenuItem!
    private var tilingMasterItem: NSMenuItem!
    private var tilingDoubleClickItem: NSMenuItem!
    private var tilingDragItem: NSMenuItem!
    private var tilingPermissionItem: NSMenuItem!
    private var tilingModifierCommandItem: NSMenuItem!
    private var tilingModifierControlItem: NSMenuItem!
    private var tilingPermissionMissing = false
    private var autoLaunchItem: NSMenuItem!
    // 菜单栏图标管理
    private let iconMgr = MenuBarIconManager()
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.sz.bento.connection-poll")
    private var hasShownScrollPermissionAlert = false

    private let launchAgentLabel = "com.sz.bento"
    private let legacyLaunchAgentLabel = "com.rustdesk.screen-off"
    private var launchAgentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateLegacyLaunchAgent()
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

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Bento")
        statusItem.button?.setAccessibilityLabel("Bento")
        // 显式 autosaveName：图标管理靠它构造 MenuBarAgent 字典里自己的条目键（status:…::BentoMain）
        statusItem.autosaveName = "BentoMain"

        statusMenu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Monitoring", action: nil, keyEquivalent: "")
        statusMenu.addItem(statusMenuItem)

        remoteMonitorItem = NSMenuItem(title: "远程连接自动熄屏", action: #selector(toggleRemoteMonitor), keyEquivalent: "")
        remoteMonitorItem.target = self
        remoteMonitorItem.state = remoteMonitorEnabled ? .on : .off
        statusMenu.addItem(remoteMonitorItem)

        scrollPermissionItem = NSMenuItem(title: "Scroll Permissions Needed", action: nil, keyEquivalent: "")
        scrollPermissionItem.isEnabled = false
        scrollPermissionItem.isHidden = true
        statusMenu.addItem(scrollPermissionItem)

        autoLaunchItem = NSMenuItem(title: "开机自启 (Launch at Login)", action: #selector(toggleAutoLaunch), keyEquivalent: "")
        autoLaunchItem.target = self
        autoLaunchItem.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        statusMenu.addItem(autoLaunchItem)

        statusMenu.addItem(.separator())

        reverseMouseItem = NSMenuItem(title: "Reverse Mouse Scroll", action: #selector(toggleReverseMouse), keyEquivalent: "")
        reverseMouseItem.target = self
        reverseMouseItem.state = scrollReverser.reverseMouse ? .on : .off
        statusMenu.addItem(reverseMouseItem)

        reverseTrackpadItem = NSMenuItem(title: "Reverse Trackpad Scroll", action: #selector(toggleReverseTrackpad), keyEquivalent: "")
        reverseTrackpadItem.target = self
        reverseTrackpadItem.state = scrollReverser.reverseTrackpad ? .on : .off
        statusMenu.addItem(reverseTrackpadItem)

        openAccessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        openAccessibilityItem.target = self
        openAccessibilityItem.isHidden = true
        statusMenu.addItem(openAccessibilityItem)

        openInputMonitoringItem = NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        openInputMonitoringItem.target = self
        openInputMonitoringItem.isHidden = true
        statusMenu.addItem(openInputMonitoringItem)

        retryScrollPermissionsItem = NSMenuItem(title: "Retry Scroll Permissions", action: #selector(retryScrollPermissions), keyEquivalent: "")
        retryScrollPermissionsItem.target = self
        retryScrollPermissionsItem.isHidden = true
        statusMenu.addItem(retryScrollPermissionsItem)

        statusMenu.addItem(.separator())

        // —— 分屏 ——
        let tilingHeader = NSMenuItem(title: "分屏（窗口吸附）", action: nil, keyEquivalent: "")
        tilingHeader.isEnabled = false
        statusMenu.addItem(tilingHeader)

        tilingPermissionItem = NSMenuItem(title: "分屏需要辅助功能权限（点击打开设置）", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        tilingPermissionItem.target = self
        tilingPermissionItem.isHidden = true
        statusMenu.addItem(tilingPermissionItem)

        tilingMasterItem = NSMenuItem(title: "启用分屏", action: #selector(toggleTilingMaster), keyEquivalent: "")
        tilingMasterItem.target = self
        statusMenu.addItem(tilingMasterItem)

        tilingDoubleClickItem = NSMenuItem(title: "双击标题栏吸附到格子", action: #selector(toggleTilingDoubleClick), keyEquivalent: "")
        tilingDoubleClickItem.target = self
        statusMenu.addItem(tilingDoubleClickItem)

        tilingDragItem = NSMenuItem(title: "修饰键拖动标题栏吸附", action: #selector(toggleTilingDrag), keyEquivalent: "")
        tilingDragItem.target = self
        statusMenu.addItem(tilingDragItem)

        let modifierMenu = NSMenu()
        tilingModifierCommandItem = NSMenuItem(title: "⌘ Command", action: #selector(setTilingModifier(_:)), keyEquivalent: "")
        tilingModifierCommandItem.target = self
        tilingModifierCommandItem.representedObject = TilingConfig.DragModifier.command.rawValue
        modifierMenu.addItem(tilingModifierCommandItem)
        tilingModifierControlItem = NSMenuItem(title: "⌃ Control", action: #selector(setTilingModifier(_:)), keyEquivalent: "")
        tilingModifierControlItem.target = self
        tilingModifierControlItem.representedObject = TilingConfig.DragModifier.control.rawValue
        modifierMenu.addItem(tilingModifierControlItem)
        let modifierItem = NSMenuItem(title: "拖动吸附修饰键", action: nil, keyEquivalent: "")
        modifierItem.submenu = modifierMenu
        statusMenu.addItem(modifierItem)

        let editLayoutsItem = NSMenuItem(title: "编辑分屏布局…", action: #selector(editTilingLayouts), keyEquivalent: "")
        editLayoutsItem.target = self
        statusMenu.addItem(editLayoutsItem)

        statusMenu.addItem(.separator())

        let manageIconsItem = NSMenuItem(title: "管理菜单栏图标…", action: #selector(openIconManager), keyEquivalent: "")
        manageIconsItem.target = self
        statusMenu.addItem(manageIconsItem)

        updateTilingMenuStates()

        restoreDisplaysItem = NSMenuItem(title: "Restore Extended Displays", action: #selector(restoreExtendedDisplays), keyEquivalent: "")
        restoreDisplaysItem.target = self
        statusMenu.addItem(restoreDisplaysItem)

        statusMenu.addItem(.separator())

        let authRestartItem = NSMenuItem(title: "FileVault AuthRestart", action: #selector(authRestart), keyEquivalent: "")
        authRestartItem.target = self
        statusMenu.addItem(authRestartItem)

        statusMenu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "Remote/Screen Sharing auto screen-off", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        statusMenu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = statusMenu
    }

    // MARK: - Connection Detection (1s process poll)

    private func startPollTimer() {
        stopPollTimer()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(200))
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
        // Match only the *local* address column ($4) so an outbound VNC
        // connection from this Mac to another host's 5900 doesn't trigger.
        let script = "/usr/sbin/netstat -an -p tcp | /usr/bin/awk '$4 ~ /\\.5900$/ && $6 == \"ESTABLISHED\" {found=1; exit} END {exit !found}'"
        return runProcess("/bin/sh", ["-c", script]).status == 0
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
        } else if !connected {
            screenCtl.disableMirroring()
        }
    }

    // MARK: - UI Updates

    private func updateStatus() {
        if tilingPermissionMissing {
            // 未授予辅助功能权限时，菜单栏图标给出明确状态
            statusMenuItem.title = "需要辅助功能权限"
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Bento 需要辅助功能权限")
            statusItem.button?.title = ""
            return
        }
        if !remoteMonitorEnabled {
            statusMenuItem.title = "远程熄屏监控已停用"
            statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            statusItem.button?.title = ""
            return
        }
        if screenCtl.isScreenBlack {
            statusMenuItem.title = "Remote Connected · Screen Off"
            statusItem.button?.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
            statusItem.button?.title = " Screen Off"
        } else {
            statusMenuItem.title = "Monitoring"
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
        tilingDoubleClickItem.state = tiling.config.doubleClickSnapEnabled ? .on : .off
        tilingDragItem.state = tiling.config.dragSnapEnabled ? .on : .off
        tilingModifierCommandItem.state = tiling.config.dragModifier == .command ? .on : .off
        tilingModifierControlItem.state = tiling.config.dragModifier == .control ? .on : .off
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

        reverseMouseItem.title = missing ? "Reverse Mouse Scroll (Grant Permissions)" : "Reverse Mouse Scroll"
        reverseTrackpadItem.title = missing ? "Reverse Trackpad Scroll (Grant Permissions)" : "Reverse Trackpad Scroll"
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

    @objc private func toggleTilingDoubleClick() {
        tiling.setDoubleClickSnap(!tiling.config.doubleClickSnapEnabled)
        updateTilingMenuStates()
    }

    @objc private func toggleTilingDrag() {
        tiling.setDragSnap(!tiling.config.dragSnapEnabled)
        updateTilingMenuStates()
    }

    @objc private func setTilingModifier(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let modifier = TilingConfig.DragModifier(rawValue: raw) else { return }
        tiling.setDragModifier(modifier)
        updateTilingMenuStates()
    }

    @objc private func editTilingLayouts() {
        tiling.openLayoutEditor()
    }

    @objc private func openIconManager() {
        iconMgr.openManagerWindow()
    }

    @objc private func toggleAutoLaunch() {
        if FileManager.default.fileExists(atPath: launchAgentPath) {
            runProcess("/bin/launchctl", ["unload", launchAgentPath])
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            installAutoLaunch()
        }
        autoLaunchItem.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
    }

    // MARK: - Auto Launch

    /// 首次启动默认开启自启；之后完全由菜单开关决定，不覆盖用户选择
    private func installAutoLaunchIfFirstRun() {
        let key = "LaunchAtLoginConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        installAutoLaunch()
    }

    private func installAutoLaunch() {
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        let url = URL(fileURLWithPath: launchAgentPath)
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? data.write(to: url)
    }

    /// One-time cleanup: remove the LaunchAgent from the previous app name
    /// (`com.rustdesk.screen-off`) so reboots don't auto-launch the old binary
    /// alongside Bento. No-op if the legacy plist is already gone.
    private func migrateLegacyLaunchAgent() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let oldPath = "\(home)/Library/LaunchAgents/\(legacyLaunchAgentLabel).plist"
        guard FileManager.default.fileExists(atPath: oldPath) else { return }

        runProcess("/bin/launchctl", ["unload", oldPath])
        try? FileManager.default.removeItem(atPath: oldPath)
        NSLog("Migration: removed legacy LaunchAgent \(legacyLaunchAgentLabel)")
    }
}
