import Foundation

final class ClaudeGuardEngine {
    private(set) var enabled: Bool
    private(set) var ready = false
    private(set) var configurationError: String?
    private let hosts: ClaudeGuardHostsManaging
    private let flushDNS: () throws -> Void
    private var pendingDNSFlush = false
    init(enabled: Bool, hosts: ClaudeGuardHostsManaging, flushDNS: @escaping () throws -> Void) {
        self.enabled = enabled; self.hosts = hosts; self.flushDNS = flushDNS
    }
    func setEnabled(_ enabled: Bool) throws {
        if !enabled { try clearBlock() }
        self.enabled = enabled; ready = false; configurationError = nil
    }
    func refresh(clashReady: Bool) {
        guard enabled else { ready = false; configurationError = nil; return }
        do {
            try updateHosts(blocked: !clashReady)
            ready = clashReady; configurationError = nil
        } catch { ready = false; configurationError = error.localizedDescription }
    }
    func cleanup() throws {
        try clearBlock(); enabled = false; ready = false; configurationError = nil
    }
    private func clearBlock() throws { try updateHosts(blocked: false) }
    private func updateHosts(blocked: Bool) throws {
        if try hosts.setBlocked(blocked) { pendingDNSFlush = true }
        if pendingDNSFlush {
            try flushDNS()
            pendingDNSFlush = false
        }
    }
    var status: NSDictionary { ["enabled": enabled, "ready": ready, "error": configurationError as Any] }
}
