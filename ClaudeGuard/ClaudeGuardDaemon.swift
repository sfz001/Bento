import Darwin
import Foundation
import Security

final class ClaudeGuardClientAuthorizer {
    private let requirement: String
    init(requirement: String) { self.requirement = requirement }
    func authorize(_ connection: NSXPCConnection) -> Bool {
        guard let token = connection.value(forKey: "auditToken") as? Data,
              token.count == MemoryLayout<audit_token_t>.size else { return false }
        return authorize(token: token)
    }
    func authorize(token: Data) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

final class ClaudeGuardService: NSObject, ClaudeGuardXPCProtocol {
    private let queue = DispatchQueue(label: "com.sz.bento.claudeguard.work")
    private let engine: ClaudeGuardEngine, probe: ClashProbe, merge: ClashMergeManager
    private let stateURL: URL, authorizer: ClaudeGuardClientAuthorizer
    private var maintenanceError: String?, detectionDetail: String?
    init(engine: ClaudeGuardEngine, probe: ClashProbe, merge: ClashMergeManager, stateURL: URL, authorizer: ClaudeGuardClientAuthorizer) {
        self.engine = engine; self.probe = probe; self.merge = merge; self.stateURL = stateURL; self.authorizer = authorizer; super.init()
    }
    func start() {
        queue.async {
            if self.engine.enabled { self.engine.refresh(clashReady: false); self.installRules() }
            self.tick()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1); timer.setEventHandler { self.tick() }; timer.resume()
        }
    }
    func setEnabled(_ enabled: Bool, withReply reply: @escaping (NSString?) -> Void) {
        perform(reply: reply) {
            if enabled {
                try self.saveEnabled(true); try self.engine.setEnabled(true); self.engine.refresh(clashReady: false)
                self.installRules(); self.tick()
            } else { try self.disableAndCleanup(); try self.saveEnabled(false) }
        }
    }
    func getStatus(withReply reply: @escaping (NSDictionary) -> Void) {
        let authorized = authorizeCurrentConnection()
        queue.async {
            guard authorized else { reply(["enabled": false, "ready": false, "error": "调用者签名未通过验证"]); return }
            var status = self.engine.status as! [String: Any]
            if self.maintenanceError == nil { self.maintenanceError = self.engine.configurationError }
            status["error"] = self.maintenanceError as Any; status["detail"] = self.detectionDetail as Any
            reply(status as NSDictionary)
        }
    }
    func cleanup(withReply reply: @escaping (NSString?) -> Void) {
        perform(reply: reply) { try self.disableAndCleanup(); try self.saveEnabled(false) }
    }
    private func perform(reply: @escaping (NSString?) -> Void, operation: @escaping () throws -> Void) {
        let authorized = authorizeCurrentConnection()
        queue.async {
            guard authorized else { reply("调用者签名未通过验证" as NSString); return }
            do { try operation(); reply(nil) } catch { reply(error.localizedDescription as NSString) }
        }
    }
    private func authorizeCurrentConnection() -> Bool {
        guard let connection = NSXPCConnection.current() else { return false }
        return authorizer.authorize(connection)
    }
    private func tick() {
        guard engine.enabled else { return }
        do {
            try probe.check(); try merge.install(proxyGroup: probe.preferredProxyGroup())
            maintenanceError = nil; detectionDetail = nil; engine.refresh(clashReady: true)
        } catch { detectionDetail = error.localizedDescription; engine.refresh(clashReady: false) }
        if let error = engine.configurationError { maintenanceError = error }
    }
    private func installRules() {
        do { try merge.install(proxyGroup: (try? probe.preferredProxyGroup()) ?? "PROXY"); maintenanceError = nil }
        catch { maintenanceError = error.localizedDescription }
    }
    private func disableAndCleanup() throws {
        var firstError: Error?
        do { try merge.remove() } catch { firstError = error }
        do { try engine.cleanup() } catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
        maintenanceError = nil; detectionDetail = nil
    }
    private func saveEnabled(_ enabled: Bool) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data((enabled ? "1\n" : "0\n").utf8).write(to: stateURL, options: .atomic)
        chmod(stateURL.path, 0o600); chown(stateURL.path, 0, 0)
    }
}

final class ClaudeGuardListener: NSObject, NSXPCListenerDelegate {
    private let service: ClaudeGuardService
    init(service: ClaudeGuardService) { self.service = service }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ClaudeGuardXPCProtocol.self)
        newConnection.exportedObject = service; newConnection.invalidationHandler = {}; newConnection.interruptionHandler = {}
        newConnection.resume(); return true
    }
}
