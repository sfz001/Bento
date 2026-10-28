import Foundation

/// Compile with ClaudeGuardProtocol.swift, then sign ad-hoc with identifier
/// com.sz.bento. A live daemon must refuse even this matching claimed identifier.
/// This client only requests status; it never changes guard or network state.
@main
struct ClaudeGuardUnauthorizedClient {
    static func main() {
        let connection = NSXPCConnection(machServiceName: claudeGuardDaemonLabel, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ClaudeGuardXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let completed = DispatchSemaphore(value: 0)
        var receivedReply = false
        var failure: NSError?
        let proxy = connection.remoteObjectProxyWithErrorHandler {
            failure = $0 as NSError
            completed.signal()
        } as! ClaudeGuardXPCProtocol
        proxy.getStatus { _ in receivedReply = true; completed.signal() }
        guard completed.wait(timeout: .now() + 10) == .success else {
            print("INCONCLUSIVE: XPC timed out"); exit(2)
        }
        guard !receivedReply, let failure else {
            print("FAIL: unauthorized client received a service reply"); exit(1)
        }
        print("REFUSED: domain=\(failure.domain) code=\(failure.code)")
        // A live authorized status request must succeed alongside this refusal;
        // otherwise service unavailability could produce the same transport error.
    }
}
