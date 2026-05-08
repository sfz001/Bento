import AppKit
import CoreGraphics
import Foundation
import IOKit

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

// MARK: - Scroll Reverser

private let prefReverseMouse = "ReverseMouseScroll"
private let prefReverseTrackpad = "ReverseTrackpadScroll"
private let gestureEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!
private let recentTouchWindowNs: UInt64 = 222_000_000
private let staleTouchWindowNs: UInt64 = 333_000_000
private let ioHIDEventFieldScrollX: UInt32 = 6 << 16
private let ioHIDEventFieldScrollY: UInt32 = (6 << 16) + 1

@_silgen_name("CGEventCopyIOHIDEvent")
private func CGEventCopyIOHIDEvent(_ event: CGEvent) -> UnsafeMutableRawPointer?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: UnsafeMutableRawPointer, _ field: UInt32) -> Double

@_silgen_name("IOHIDEventSetFloatValue")
private func IOHIDEventSetFloatValue(_ event: UnsafeMutableRawPointer, _ field: UInt32, _ value: Double)

private enum ScrollInputSource {
    case mouse
    case trackpad
}

private func nowNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func reverseScrollDeltas(_ event: CGEvent) {
    let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    let d3 = event.getIntegerValueField(.scrollWheelEventDeltaAxis3)
    let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    let p3 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3)
    let f1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let f2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
    let f3 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3)
    let hidEvent = CGEventCopyIOHIDEvent(event)
    let hidX = hidEvent.map { IOHIDEventGetFloatValue($0, ioHIDEventFieldScrollX) } ?? 0
    let hidY = hidEvent.map { IOHIDEventGetFloatValue($0, ioHIDEventFieldScrollY) } ?? 0

    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -d1)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -d2)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: -d3)

    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -f1)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -f2)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3, value: -f3)

    // Set point deltas last; setting line deltas can cause macOS to recalculate them.
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -p1)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -p2)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: -p3)

    if let hidEvent = hidEvent {
        IOHIDEventSetFloatValue(hidEvent, ioHIDEventFieldScrollX, -hidX)
        IOHIDEventSetFloatValue(hidEvent, ioHIDEventFieldScrollY, -hidY)
        Unmanaged<AnyObject>.fromOpaque(hidEvent).release()
    }
}

private func scrollEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            Unmanaged<ScrollReverser>.fromOpaque(userInfo).takeUnretainedValue().reenableTap()
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let reverser = Unmanaged<ScrollReverser>.fromOpaque(userInfo).takeUnretainedValue()

    if type == gestureEventType {
        reverser.noteGesture(event)
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    let source = reverser.source(forScroll: event)
    let shouldReverse = source == .trackpad ? reverser.reverseTrackpad : reverser.reverseMouse

    if shouldReverse {
        reverseScrollDeltas(event)
    }

    return Unmanaged.passUnretained(event)
}

class ScrollReverser {
    private var activeTap: CFMachPort?
    private var activeRunLoopSource: CFRunLoopSource?
    private var touching = 0
    private var lastTouchTime: UInt64 = 0
    private var lastSource: ScrollInputSource = .mouse

    var reverseMouse: Bool {
        get { UserDefaults.standard.object(forKey: prefReverseMouse) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: prefReverseMouse) }
    }

    var reverseTrackpad: Bool {
        get { UserDefaults.standard.object(forKey: prefReverseTrackpad) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: prefReverseTrackpad) }
    }

    /// Returns true if the event taps were created. Returns false when the user
    /// still needs to grant Accessibility/Input Monitoring permission and relaunch.
    func start() -> Bool {
        stop()
        touching = 0
        lastTouchTime = 0
        lastSource = .mouse

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        let scrollMask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        let gestureMask: CGEventMask = 1 << gestureEventType.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let active = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: scrollMask | gestureMask,
            callback: scrollEventCallback,
            userInfo: userInfo
        ) else {
            NSLog("ScrollReverser: event tap creation failed (trusted=\(trusted))")
            return false
        }

        let activeSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, active, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), activeSrc, .commonModes)
        CGEvent.tapEnable(tap: active, enable: true)

        activeTap = active
        activeRunLoopSource = activeSrc
        NSLog("ScrollReverser: taps installed (mouseRev=\(reverseMouse), trackpadRev=\(reverseTrackpad))")
        return true
    }

    func stop() {
        if let tap = activeTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = activeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        activeTap = nil
        activeRunLoopSource = nil
    }

    func reenableTap() {
        if let tap = activeTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        NSLog("ScrollReverser: tap re-enabled after disable")
    }

    func noteGesture(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let currentTouching = nsEvent.touches(matching: .touching, in: nil).count
        guard currentTouching >= 2 else { return }
        touching = max(touching, currentTouching)
        lastTouchTime = nowNs()
    }

    fileprivate func source(forScroll event: CGEvent) -> ScrollInputSource {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let detectedTouching = touching
        let elapsed = lastTouchTime == 0 ? UInt64.max : nowNs() &- lastTouchTime
        touching = 0

        if !continuous {
            lastSource = .mouse
            return .mouse
        }

        if detectedTouching >= 2 && elapsed < recentTouchWindowNs {
            lastSource = .trackpad
            return .trackpad
        }

        if let nsEvent = NSEvent(cgEvent: event), nsEvent.momentumPhase.isEmpty, elapsed > staleTouchWindowNs {
            lastSource = .mouse
            return .mouse
        }

        return lastSource
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusMenuItem: NSMenuItem!

    private let screenCtl = ScreenController()
    private let scrollReverser = ScrollReverser()
    private var scrollPermissionItem: NSMenuItem!
    private var openAccessibilityItem: NSMenuItem!
    private var openInputMonitoringItem: NSMenuItem!
    private var retryScrollPermissionsItem: NSMenuItem!
    private var reverseMouseItem: NSMenuItem!
    private var reverseTrackpadItem: NSMenuItem!
    private var pollTimer: DispatchSourceTimer?
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
        installAutoLaunch()
        startScrollReverser(showAlert: true)
        pollConnectionState()
        startPollTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPollTimer()
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

        statusMenu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Monitoring", action: nil, keyEquivalent: "")
        statusMenu.addItem(statusMenuItem)

        scrollPermissionItem = NSMenuItem(title: "Scroll Permissions Needed", action: nil, keyEquivalent: "")
        scrollPermissionItem.isEnabled = false
        scrollPermissionItem.isHidden = true
        statusMenu.addItem(scrollPermissionItem)

        let autoLaunchItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
        autoLaunchItem.state = .on
        autoLaunchItem.isEnabled = false
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

    @objc private func toggleReverseMouse() {
        scrollReverser.reverseMouse.toggle()
        reverseMouseItem.state = scrollReverser.reverseMouse ? .on : .off
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

    /// One-time cleanup: remove the LaunchAgent from the previous app name
    /// (`com.rustdesk.screen-off`) so reboots don't auto-launch the old binary
    /// alongside Bento. No-op if the legacy plist is already gone.
    private func migrateLegacyLaunchAgent() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let oldPath = "\(home)/Library/LaunchAgents/\(legacyLaunchAgentLabel).plist"
        guard FileManager.default.fileExists(atPath: oldPath) else { return }

        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", oldPath]
        unload.standardOutput = FileHandle.nullDevice
        unload.standardError = FileHandle.nullDevice
        try? unload.run()
        unload.waitUntilExit()

        try? FileManager.default.removeItem(atPath: oldPath)
        NSLog("Migration: removed legacy LaunchAgent \(legacyLaunchAgentLabel)")
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
