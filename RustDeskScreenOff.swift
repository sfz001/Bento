import AppKit
import CoreGraphics
import Foundation

// MARK: - Screen Control

class ScreenController {
    private var isBlack = false
    private var mirroredDisplays: [CGDirectDisplayID] = []

    func enableMirroring() {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &displays, &count)

        let main = CGMainDisplayID()
        guard count > 1 else { return }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)

        var mirrored: [CGDirectDisplayID] = []
        for i in 0..<Int(count) {
            let d = displays[i]
            if d != main && CGDisplayMirrorsDisplay(d) == kCGNullDirectDisplay {
                CGConfigureDisplayMirrorOfDisplay(config, d, main)
                mirrored.append(d)
            }
        }

        if mirrored.isEmpty {
            CGCancelDisplayConfiguration(config)
            return
        }

        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err == .success {
            mirroredDisplays = mirrored
            NSLog("Mirroring enabled for \(mirrored.count) display(s)")
        }
    }

    func disableMirroring() {
        guard !mirroredDisplays.isEmpty else { return }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        for d in mirroredDisplays {
            CGConfigureDisplayMirrorOfDisplay(config, d, kCGNullDirectDisplay)
        }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err == .success {
            NSLog("Mirroring disabled, restored \(mirroredDisplays.count) display(s)")
            mirroredDisplays = []
        }
    }

    // MARK: Resolution

    private var savedMode: CGDisplayMode?
    private let targetWidth = 1512
    private let targetHeight = 982

    func switchResolution() {
        let main = CGMainDisplayID()
        savedMode = CGDisplayCopyDisplayMode(main)

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(main, options) as? [CGDisplayMode] else { return }

        let target = modes.first {
            $0.width == targetWidth && $0.height == targetHeight && $0.pixelWidth > $0.width
        }
        guard let mode = target else {
            NSLog("Resolution mode \(targetWidth)x\(targetHeight) HiDPI not found, skipping")
            return
        }

        let err = CGDisplaySetDisplayMode(main, mode, nil)
        if err == .success {
            NSLog("Resolution switched to \(targetWidth)x\(targetHeight) HiDPI")
        }
    }

    func restoreResolution() {
        guard let mode = savedMode else { return }
        let main = CGMainDisplayID()
        let err = CGDisplaySetDisplayMode(main, mode, nil)
        if err == .success {
            NSLog("Resolution restored to \(mode.width)x\(mode.height)")
        }
        savedMode = nil
    }

    // MARK: Dock

    private var savedDockOrientation: String?
    private var savedDockAutohide: Bool?

    func saveDockAndSetLeft() {
        // Save current orientation
        let orientTask = Process()
        orientTask.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        orientTask.arguments = ["read", "com.apple.dock", "orientation"]
        let orientPipe = Pipe()
        orientTask.standardOutput = orientPipe
        orientTask.standardError = FileHandle.nullDevice
        try? orientTask.run()
        orientTask.waitUntilExit()
        let orientData = orientPipe.fileHandleForReading.readDataToEndOfFile()
        savedDockOrientation = String(data: orientData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if savedDockOrientation?.isEmpty ?? true { savedDockOrientation = "bottom" }

        // Save current autohide
        let hideTask = Process()
        hideTask.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        hideTask.arguments = ["read", "com.apple.dock", "autohide"]
        let hidePipe = Pipe()
        hideTask.standardOutput = hidePipe
        hideTask.standardError = FileHandle.nullDevice
        try? hideTask.run()
        hideTask.waitUntilExit()
        let hideData = hidePipe.fileHandleForReading.readDataToEndOfFile()
        let hideStr = String(data: hideData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        savedDockAutohide = (hideStr == "1")

        // Set dock to left, no autohide
        runDefaults(["write", "com.apple.dock", "orientation", "-string", "left"])
        runDefaults(["write", "com.apple.dock", "autohide", "-bool", "false"])
        restartDock()
        NSLog("Dock set to left, autohide off (was: \(savedDockOrientation ?? "?"), autohide: \(savedDockAutohide == true))")
    }

    func restoreDock() {
        guard let orientation = savedDockOrientation, let autohide = savedDockAutohide else { return }
        runDefaults(["write", "com.apple.dock", "orientation", "-string", orientation])
        runDefaults(["write", "com.apple.dock", "autohide", "-bool", autohide ? "true" : "false"])
        restartDock()
        NSLog("Dock restored to \(orientation), autohide: \(autohide)")
        savedDockOrientation = nil
        savedDockAutohide = nil
    }

    private func runDefaults(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: Gamma Black

    func setBlack() {
        guard !isBlack else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &displays, &count)
        for i in 0..<Int(count) {
            CGSetDisplayTransferByFormula(displays[i], 0, 0, 1, 0, 0, 1, 0, 0, 1)
        }
        isBlack = true
    }

    func restore() {
        guard isBlack else { return }
        CGDisplayRestoreColorSyncSettings()
        isBlack = false
    }

    func lockScreen() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "ScreenSaverEngine"]
        try? task.run()
    }

    var isScreenBlack: Bool { isBlack }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusMenuItem: NSMenuItem!

    private let screenCtl = ScreenController()
    private var pollTimer: DispatchSourceTimer?

    private let launchAgentLabel = "com.rustdesk.screen-off"
    private var launchAgentPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        installAutoLaunch()
        pollConnectionState()
        startPollTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPollTimer()
        screenCtl.restore()
        screenCtl.restoreResolution()
        screenCtl.restoreDock()
        screenCtl.disableMirroring()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "RustDesk Screen Off")

        statusMenu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Monitoring", action: nil, keyEquivalent: "")
        statusMenu.addItem(statusMenuItem)

        let autoLaunchItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
        autoLaunchItem.state = .on
        autoLaunchItem.isEnabled = false
        statusMenu.addItem(autoLaunchItem)

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
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-fi", "rustdesk.*--cm"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func isScreenSharingConnected() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "netstat -an | grep '\\.5900 ' | grep -q ESTABLISHED"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private func pollConnectionState() {
        let rustdesk = isRustDeskConnected()
        let screenSharing = isScreenSharingConnected()
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
            screenCtl.disableMirroring()
            screenCtl.lockScreen()
            updateStatus()
        }
    }

    // MARK: - UI Updates

    private func updateStatus() {
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

    // MARK: - Actions

    @objc private func authRestart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"Terminal\" to do script \"sudo fdesetup authrestart\"", "-e", "tell application \"Terminal\" to activate"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Auto Launch

    private func installAutoLaunch() {
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? data?.write(to: URL(fileURLWithPath: launchAgentPath))
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
