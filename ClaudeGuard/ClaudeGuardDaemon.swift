import Darwin
import Foundation
import OSLog
import Security

final class ClaudeGuardClientAuthorizer {
    private static let logger = Logger(subsystem: "com.sz.bento.claudeguard", category: "authorization")
    private let requirement: String?

    /// Derive trust from the running daemon's signed identity, never a writable
    /// sidecar file. Preserve its certificate/Team constraints for the App.
    static func trustedClientRequirement() -> String? {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            logger.error("XPC authorization stage=self-code status=\(status, privacy: .public)")
            return nil
        }
        status = SecCodeCheckValidity(code, [], nil)
        guard status == errSecSuccess else {
            logger.error("XPC authorization stage=self-validity status=\(status, privacy: .public)")
            return nil
        }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            logger.error("XPC authorization stage=self-static-code status=\(status, privacy: .public)")
            return nil
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(staticCode, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            logger.error("XPC authorization stage=self-requirement status=\(status, privacy: .public)")
            return nil
        }
        var text: CFString?
        status = SecRequirementCopyString(requirement, [], &text)
        guard status == errSecSuccess, let text,
              let clientRequirement = clientRequirement(fromDaemonRequirement: text as String) else {
            logger.error("XPC authorization stage=client-requirement status=\(status, privacy: .public)")
            return nil
        }
        return clientRequirement
    }

    static func clientRequirement(fromDaemonRequirement requirement: String) -> String? {
        let identity = "identifier \"\(claudeGuardDaemonLabel)\""
        let parts = requirement.components(separatedBy: identity)
        guard parts.count == 2, parts[0].isEmpty,
              parts[1].isEmpty || parts[1].hasPrefix(" and ") else { return nil }
        return "identifier \"com.sz.bento\"" + parts[1]
    }

    init(requirement: String?) {
        guard let requirement else {
            Self.logger.error("XPC authorization stage=requirement-load: missing requirement")
            self.requirement = nil
            return
        }
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &parsed)
        guard status == errSecSuccess, parsed != nil else {
            Self.logger.error("XPC authorization stage=requirement-parse status=\(status, privacy: .public)")
            self.requirement = nil
            return
        }
        self.requirement = requirement
    }

    /// Foundation checks the sender of every message using its audit token.
    /// Configure before resume so a bad requirement never exposes the service.
    func configure(_ connection: NSXPCConnection) -> Bool {
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        return true
    }
}

final class ClaudeGuardService: NSObject, ClaudeGuardXPCProtocol {
    private let queue = DispatchQueue(label: "com.sz.bento.claudeguard.work")
    private let engine: ClaudeGuardEngine, probe: ClashProbe, merge: ClashMergeManager
    private let stateURL: URL
    private let terminateForRestart: () -> Void
    private var maintenanceError: String?, detectionDetail: String?
    private var timer: DispatchSourceTimer?
    private var restarting = false
    init(engine: ClaudeGuardEngine, probe: ClashProbe, merge: ClashMergeManager, stateURL: URL,
         terminateForRestart: @escaping () -> Void = { exit(0) }) {
        self.engine = engine; self.probe = probe; self.merge = merge; self.stateURL = stateURL
        self.terminateForRestart = terminateForRestart; super.init()
    }
    deinit { timer?.cancel() }
    func start() {
        queue.async { [self] in
            guard self.timer == nil, !self.restarting else { return }
            if self.engine.enabled { self.engine.refresh(clashReady: false); self.installRules() }
            self.tick()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }
    func setEnabled(_ enabled: Bool, withReply reply: @escaping (NSString?) -> Void) {
        perform(reply: reply) {
            if enabled {
                if !self.engine.enabled {
                    try self.saveEnabled(true); try self.engine.setEnabled(true); self.engine.refresh(clashReady: false)
                    self.installRules()
                }
                self.tick()
                if let error = self.engine.configurationError ?? self.maintenanceError {
                    throw NSError(domain: claudeGuardDaemonLabel, code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: error])
                }
            } else { try self.disableAndCleanup(); try self.saveEnabled(false) }
        }
    }
    func getStatus(withReply reply: @escaping (NSDictionary) -> Void) {
        queue.async {
            var status = self.engine.status as! [String: Any]
            let error: String? = self.engine.configurationError ?? self.maintenanceError
            status["error"] = error
            status["detail"] = self.detectionDetail
            status["restarting"] = self.restarting
            reply(status as NSDictionary)
        }
    }
    func cleanup(withReply reply: @escaping (NSString?) -> Void) {
        perform(reply: reply) { try self.disableAndCleanup(); try self.saveEnabled(false) }
    }
    func restart(withReply reply: @escaping (NSString?) -> Void) {
        queue.async {
            guard !self.restarting else { reply(nil); return }
            // Keep protection in place during launchd's possible restart throttle.
            // Persistent enabled state and Merge rules are deliberately preserved.
            if self.engine.enabled {
                self.engine.refresh(clashReady: false)
                if let error = self.engine.configurationError {
                    self.maintenanceError = error
                    reply("重启前无法确认 Claude 阻断：\(error)" as NSString)
                    return
                }
            }
            self.restarting = true
            self.timer?.cancel(); self.timer = nil
            self.detectionDetail = "守护正在重启"
            reply(nil)
            // This acknowledges the request only. A fresh daemon status/PID is
            // needed to prove restart completion; no shell or caller arguments run.
            self.queue.asyncAfter(deadline: .now() + 0.25) { self.terminateForRestart() }
        }
    }
    private func perform(reply: @escaping (NSString?) -> Void, operation: @escaping () throws -> Void) {
        queue.async {
            guard !self.restarting else { reply("守护正在重启，请稍后重试" as NSString); return }
            do { try operation(); reply(nil) } catch { reply(error.localizedDescription as NSString) }
        }
    }
    private func tick() {
        guard engine.enabled, !restarting else { return }
        // Repair persistent rules even when their removal made the running rules fail validation.
        installRules()
        guard maintenanceError == nil else {
            detectionDetail = nil
            engine.refresh(clashReady: false)
            return
        }
        do {
            try probe.check()
            detectionDetail = nil; engine.refresh(clashReady: true)
        } catch { detectionDetail = error.localizedDescription; engine.refresh(clashReady: false) }
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
    private let authorizer: ClaudeGuardClientAuthorizer
    init(service: ClaudeGuardService, authorizer: ClaudeGuardClientAuthorizer) {
        self.service = service; self.authorizer = authorizer
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard authorizer.configure(newConnection) else { return false }
        newConnection.exportedInterface = NSXPCInterface(with: ClaudeGuardXPCProtocol.self)
        newConnection.exportedObject = service; newConnection.invalidationHandler = {}; newConnection.interruptionHandler = {}
        newConnection.resume(); return true
    }
}
