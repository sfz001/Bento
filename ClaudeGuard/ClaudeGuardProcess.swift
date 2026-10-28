import Darwin
import Foundation

@discardableResult
func claudeGuardRunProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 2,
                          captureStandardError: Bool = false) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    let output = Pipe(); process.standardOutput = output
    process.standardError = captureStandardError ? output : FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    let watchdog = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); watchdog.cancel()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func claudeGuardFlushDNS() throws {
    guard claudeGuardRunProcess("/usr/bin/dscacheutil", ["-flushcache"]).status == 0 else {
        throw ClaudeGuardHostsError.writeFailed("后刷新 DNS 缓存")
    }
    guard claudeGuardRunProcess("/usr/bin/killall", ["-HUP", "mDNSResponder"]).status == 0 else {
        throw ClaudeGuardHostsError.writeFailed("后通知 mDNSResponder")
    }
}
