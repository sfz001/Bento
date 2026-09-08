import AppKit
import Foundation

private final class FakeScreenController: ScreenController {
    var events: [String] = []
    var black = false
    var blackSucceeds = true
    override var isScreenBlack: Bool { black }
    override func setBlack() { events.append("black"); black = blackSucceeds }
    override func prepareResolutionSnapshot() { events.append("snapshot") }
    override func enableMirroring() { events.append("mirror-on") }
    override func switchResolution() { events.append("resolution") }
    override func saveDockAndSetLeft() { events.append("dock-left") }
    override func reassertBlackIfNeeded() { events.append("reassert") }
    override func lockScreen() { events.append("lock") }
    override func restoreDock() { events.append("dock-restore") }
    override func disableMirroring(forceFallback: Bool = false) { events.append("mirror-off") }
    override func restoreResolution() { events.append("resolution-restore") }
    override func restore() { events.append("gamma-restore"); black = false }
    override var hasPendingDisplayRestore: Bool { false }
}

@main
struct AppDelegateStateTests {
    static func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func main() {
        defer { UserDefaults.standard.removeObject(forKey: "RemoteMonitorEnabled") }
        let screen = FakeScreenController()
        let app = AppDelegate(screenController: screen, lockCheck: { true })
        app.testSetMonitoring(true)
        app.testConnect()
        precondition(screen.events == ["black", "snapshot", "mirror-on", "resolution", "dock-left", "reassert"])
        let setupCount = screen.events.count
        app.testConnect()
        precondition(screen.events.count == setupCount, "Connected poll must not repeat setup")
        app.testDisconnect(screenSharing: .unknown)
        precondition(screen.events.count == setupCount, "Unknown source must preserve black")
        app.testDisconnect()
        precondition(!screen.events.contains("lock"))
        app.testDisconnect()
        precondition(screen.events.last == "lock", "Two definite source disconnects required")
        app.testConnect()
        pump(0.4)
        precondition(!screen.events.contains("gamma-restore"), "Reconnect must cancel pending restore")
        precondition(app.testSessionPrepared, "Reconnect during lock wait must retain wake/hot-plug protection")
        app.testDisconnect()
        app.testDisconnect()
        app.testDisconnect()
        app.testDisconnect()
        precondition(screen.events.filter { $0 == "lock" }.count == 2, "Pending lock chain must not restart")
        pump(0.4)
        precondition(Array(screen.events.suffix(4)) == ["dock-restore", "mirror-off", "resolution-restore", "gamma-restore"])

        screen.events = []
        precondition(app.testRehearse(duration: 0.02))
        precondition(!app.testRehearse(duration: 0.02), "Cannot overlap rehearsals")
        app.testDisconnect()
        app.testDisconnect()
        precondition(!screen.events.contains("lock"), "Idle polls must not end rehearsal early")
        pump(0.45)
        precondition(screen.events.contains("lock") && screen.events.last == "gamma-restore")

        screen.events = []
        precondition(app.testRehearse(duration: 0.02))
        app.testConnect("RustDesk")
        pump(0.4)
        precondition(!screen.events.contains("gamma-restore"), "Real connection must take over rehearsal")
        app.testDisableMonitoring()
        let afterDisable = screen.events.count
        app.testConnect()
        precondition(screen.events.count == afterDisable && !screen.black, "Late connected result after disable must do nothing")

        let partial = FakeScreenController()
        partial.blackSucceeds = false
        let fallback = AppDelegate(screenController: partial, lockCheck: { false }, lockWaitBudget: 0)
        fallback.testSetMonitoring(true)
        fallback.testConnect()
        fallback.testConnect()
        precondition(partial.events.filter { $0 == "mirror-on" }.count == 1, "Partial gamma failure must not repeat heavy setup")
        fallback.testDisconnect()
        fallback.testDisconnect()
        pump(0.05)
        precondition(fallback.testHasLockWarning && partial.events.last == "gamma-restore")
        print("PASS: actual AppDelegate setup, unknown probes, source-only disconnect, reconnect cancellation, rehearsal, takeover, monitor disable and lock timeout")
    }
}
