import Foundation

let claudeGuardDaemonLabel = "com.sz.bento.claudeguard"
let claudeGuardDaemonPlist = "com.sz.bento.claudeguard.plist"

@objc(ClaudeGuardXPCProtocol)
protocol ClaudeGuardXPCProtocol {
    func setEnabled(_ enabled: Bool, withReply reply: @escaping (NSString?) -> Void)
    func getStatus(withReply reply: @escaping (NSDictionary) -> Void)
    func cleanup(withReply reply: @escaping (NSString?) -> Void)
}

struct ClaudeGuardSnapshot {
    let enabled: Bool
    let ready: Bool
    let configurationError: String?

    init(_ dictionary: NSDictionary) {
        enabled = dictionary["enabled"] as? Bool ?? false
        ready = dictionary["ready"] as? Bool ?? false
        configurationError = dictionary["error"] as? String
    }
}
