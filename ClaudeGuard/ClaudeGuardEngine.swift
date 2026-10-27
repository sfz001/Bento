import Foundation

final class ClaudeGuardEngine {
    private(set) var enabled: Bool
    private(set) var ready = false
    private(set) var configurationError: String?
    private let hosts: ClaudeGuardHostsManaging
    private let flushDNS: () throws -> Void
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
            if try hosts.setBlocked(!clashReady) { try flushDNS() }
            ready = clashReady; configurationError = nil
        } catch { ready = false; configurationError = error.localizedDescription }
    }
    func cleanup() throws {
        try clearBlock(); enabled = false; ready = false; configurationError = nil
    }
    private func clearBlock() throws { if try hosts.setBlocked(false) { try flushDNS() } }
    var status: NSDictionary { ["enabled": enabled, "ready": ready, "error": configurationError as Any] }
}
