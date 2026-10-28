import Foundation
import Security

/// Diagnostic only: reproduce the old KVC assumption and identify the exact
/// failed stage. Production authentication uses Foundation's public API.
private final class AuditTokenDiagnostic: NSObject, NSXPCListenerDelegate {
    let delegate: ClaudeGuardListener
    init(delegate: ClaudeGuardListener) { self.delegate = delegate }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let raw = connection.value(forKey: "auditToken")
        var token: Data
        if let data = raw as? Data {
            token = data
        } else if let value = raw as? NSValue {
            var size = 0
            NSGetSizeAndAlignment(value.objCType, &size, nil)
            precondition(size == MemoryLayout<audit_token_t>.size, "Unexpected audit token length")
            token = Data(count: size)
            token.withUnsafeMutableBytes { value.getValue($0.baseAddress!, size: size) }
        } else {
            preconditionFailure("Missing audit token")
        }
        precondition(token.count == MemoryLayout<audit_token_t>.size)
        var guest: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &guest)
        precondition(copyStatus == errSecSuccess && guest != nil, "Audit token must resolve to kernel-authenticated code")
        let validityStatus = SecCodeCheckValidity(guest!, [], nil)
        precondition(validityStatus == errSecSuccess)
        var requirement: SecRequirement?
        let parseStatus = SecRequirementCreateWithString(#"identifier "com.sz.bento.authorization-tests""# as CFString, [], &requirement)
        precondition(parseStatus == errSecSuccess && requirement != nil)
        let matchStatus = SecCodeCheckValidity(guest!, [], requirement)
        precondition(matchStatus == errSecSuccess)
        print("AUDIT: class=\(type(of: raw!)) asData=\(raw is Data) bytes=\(token.count) copy=\(copyStatus) validity=\(validityStatus) parse=\(parseStatus) match=\(matchStatus)")
        return delegate.listener(listener, shouldAcceptNewConnection: connection)
    }
}

@main
struct ClaudeGuardAuthorizationTests {
    static func main() {
        let daemon = #"identifier "com.sz.bento.claudeguard" and anchor apple generic and certificate leaf[subject.OU] = RV3FMJ29RW"#
        let expected = #"identifier "com.sz.bento" and anchor apple generic and certificate leaf[subject.OU] = RV3FMJ29RW"#
        precondition(ClaudeGuardClientAuthorizer.clientRequirement(fromDaemonRequirement: daemon) == expected)
        precondition(ClaudeGuardClientAuthorizer.clientRequirement(fromDaemonRequirement: #"identifier "other""#) == nil)
        precondition(ClaudeGuardClientAuthorizer.clientRequirement(fromDaemonRequirement: daemon + " and " + daemon) == nil)
        exchange(requirement: #"identifier "com.sz.bento.authorization-tests""#, shouldReply: true, diagnoseToken: true)
        exchange(requirement: #"identifier "different.app""#, shouldReply: false)
        // The identifier alone matches; a different signing identity must still fail.
        exchange(requirement: #"identifier "com.sz.bento.authorization-tests" and anchor apple generic and certificate leaf[subject.OU] = RV3FMJ29RW"#, shouldReply: false)
        exchange(requirement: "this is not a code signing requirement", shouldReply: false)
        exchange(requirement: nil, shouldReply: false)
        print("PASS: real XPC accepts matching identity, rejects different ID/certificate and invalid/missing requirements")
    }

    private static func exchange(requirement: String?, shouldReply: Bool, diagnoseToken: Bool = false) {
        let listener = NSXPCListener.anonymous()
        let engine = ClaudeGuardEngine(enabled: false, hosts: ClaudeGuardHostsFile(path: "/unused-test-hosts"), flushDNS: {})
        let service = ClaudeGuardService(engine: engine, probe: ClashProbe(), merge: ClashMergeManager(),
                                        stateURL: URL(fileURLWithPath: "/unused-test-state"))
        let delegate = ClaudeGuardListener(service: service, authorizer: ClaudeGuardClientAuthorizer(requirement: requirement))
        let diagnostic = AuditTokenDiagnostic(delegate: delegate)
        listener.delegate = diagnoseToken ? diagnostic : delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ClaudeGuardXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        let completed = DispatchSemaphore(value: 0)
        var didReply = false
        var error: NSError?
        let proxy = connection.remoteObjectProxyWithErrorHandler {
            error = $0 as NSError
            completed.signal()
        } as! ClaudeGuardXPCProtocol
        proxy.getStatus { status in
            precondition(status["enabled"] as? Bool == false)
            didReply = true
            completed.signal()
        }
        withExtendedLifetime((delegate, diagnostic)) {
            precondition(completed.wait(timeout: .now() + 10) == .success, "XPC test timed out")
        }
        precondition(didReply == shouldReply, "Unexpected XPC admission result: \(String(describing: error))")
        if !shouldReply { precondition(error != nil, "Rejection must produce an XPC error") }
    }
}
