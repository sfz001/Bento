import Foundation

// The detector uses these injected fixtures; it never queries real sessions.
@discardableResult
func runProcess(_ path: String, _ args: [String], captureOutput: Bool = false, timeout: TimeInterval = 10) -> (status: Int32, output: String) { fatalError("Unexpected real process") }

@main
struct RemoteConnectionTests {
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000)
        var process = RemoteProcessIdentity(pid: 42, executable: RemoteConnectionDetector.screenSharingPath, startedAt: start)
        var pgrep: (status: Int32, output: String) = (0, "42\n")
        var logs: (status: Int32, output: String) = (0, "[]")
        var logReads = 0
        let detector = RemoteConnectionDetector(run: { path, _, _, _ in
            if path == "/usr/bin/pgrep" { return pgrep }
            logReads += 1
            return logs
        }, identity: { _ in process }, rustDeskPaths: ["/Applications/RustDesk.app/Contents/MacOS/RustDesk"])
        func state(_ p: ConnectionProbe) -> String {
            switch p { case .connected: return "connected"; case .disconnected: return "disconnected"; case .unknown: return "unknown" }
        }
        precondition(state(detector.screenSharing(now: start.addingTimeInterval(5))) == "disconnected", "Port scan is not authentication")
        logs.output = "[{\"processID\":42,\"processImagePath\":\"\(process.executable)\",\"eventMessage\":\"Authentication: SUCCEEDED :: fixture\"}]"
        precondition(state(detector.screenSharing(now: start.addingTimeInterval(5))) == "connected")
        let reads = logReads
        logs.status = 1
        precondition(state(detector.screenSharing()) == "connected", "Authenticated process stays latched until exit")
        precondition(reads == logReads)
        pgrep = (1, "")
        precondition(state(detector.screenSharing()) == "disconnected")
        pgrep = (0, "42")
        process = RemoteProcessIdentity(pid: 42, executable: process.executable, startedAt: start.addingTimeInterval(20))
        precondition(state(detector.screenSharing()) == "unknown", "Log failure is not a definite disconnect")
        logs = (0, "[]")
        precondition(state(detector.screenSharing(now: process.startedAt.addingTimeInterval(5))) == "disconnected", "Reused pid needs fresh authentication")
        precondition(state(detector.screenSharing(now: process.startedAt.addingTimeInterval(40))) == "unknown", "Missing auth signal must surface health failure")
        logs.output = "invalid JSON"
        precondition(state(detector.screenSharing()) == "unknown")
        process = RemoteProcessIdentity(pid: 42, executable: "/tmp/screensharingd", startedAt: start)
        precondition(state(detector.screenSharing()) == "disconnected")
        precondition(state(detector.rustDesk()) == "disconnected")
        process = RemoteProcessIdentity(pid: 42, executable: "/Applications/RustDesk.app/Contents/MacOS/RustDesk", startedAt: start)
        precondition(state(detector.rustDesk()) == "connected")
        pgrep = (-1, "")
        precondition(state(detector.rustDesk()) == "unknown")
        print("PASS: remote probe authentication, process identity, PID reuse, malformed logs and health failure")
    }
}
