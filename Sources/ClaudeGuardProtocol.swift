import Foundation
import Security

let claudeGuardSigningError: String? = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var signingInfo: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
          let info = signingInfo as? [String: Any],
          let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
        return "当前自签名构建无法启动 root 防护守护；请使用 Developer ID 签名 App 和 daemon"
    }
    return nil
}()

let claudeGuardDaemonLabel = "com.sz.bento.claudeguard"
let claudeGuardDaemonPlist = "com.sz.bento.claudeguard.plist"

@objc(ClaudeGuardXPCProtocol)
protocol ClaudeGuardXPCProtocol {
    func setEnabled(_ enabled: Bool, withReply reply: @escaping (NSString?) -> Void)
    func getStatus(withReply reply: @escaping (NSDictionary) -> Void)
    func cleanup(withReply reply: @escaping (NSString?) -> Void)
    func restart(withReply reply: @escaping (NSString?) -> Void)
}

struct ClaudeGuardSnapshot {
    let enabled: Bool
    let ready: Bool
    let configurationError: String?
    let detectionDetail: String?

    init(_ dictionary: NSDictionary) {
        enabled = dictionary["enabled"] as? Bool ?? false
        ready = dictionary["ready"] as? Bool ?? false
        configurationError = dictionary["error"] as? String
        detectionDetail = dictionary["detail"] as? String
    }
}
