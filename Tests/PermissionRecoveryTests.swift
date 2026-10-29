import Foundation

@main
struct PermissionRecoveryTests {
    static func main() {
        let suite = "Bento.PermissionRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appURL = URL(fileURLWithPath: "/Applications/My Apps/Bento.app")
        let old = PermissionRecoveryModel(defaults: defaults, appURL: appURL,
                                          signingRequirement: "old certificate", signer: "Local signer")
        precondition(!old.presentation(for: .authorization).title.contains("签名已改变"),
                     "No previous success means no evidence of a signing change")
        old.recordAuthorizationGranted()

        let current = PermissionRecoveryModel(defaults: defaults, appURL: appURL,
                                              signingRequirement: "new certificate", signer: "Apple Development")
        let denied = current.presentation(for: .authorization)
        precondition(denied.title.contains("签名已改变"))
        precondition(denied.message.contains("可能仍对应旧签名"),
                     "Signing history cannot prove what is enabled in System Settings")
        precondition(denied.appPath == "/Applications/My Apps/Bento.app" && denied.signer == "Apple Development")
        precondition(denied.message.contains("手动移除") && denied.message.contains("设备控制和数据访问") && denied.message.contains("辅助功能"))

        // A failed launch and subsequent polling must never replace the last authorized identity.
        for _ in 0..<3 { _ = current.presentation(for: .authorization) }
        let afterFailedRelaunch = PermissionRecoveryModel(defaults: defaults, appURL: appURL,
                                                         signingRequirement: "new certificate", signer: nil)
        precondition(afterFailedRelaunch.presentation(for: .authorization).title.contains("签名已改变"))

        let unknown = PermissionRecoveryModel(defaults: defaults, appURL: appURL,
                                              signingRequirement: nil, signer: nil)
        precondition(!unknown.presentation(for: .authorization).title.contains("签名已改变"),
                     "Unavailable current signing information must stay conservative")
        unknown.recordAuthorizationGranted()
        precondition(current.presentation(for: .authorization).title.contains("签名已改变"),
                     "Unknown signing information must not erase the last valid baseline")

        let listeningFailure = current.presentation(for: .eventTap)
        precondition(listeningFailure.title.contains("权限已生效") && !listeningFailure.message.contains("手动移除"),
                     "An event-tap failure after effective authorization should not request reauthorization")
        let recovered = current.presentation(for: .ready)
        precondition(recovered.title == "Bento 权限已生效" && !recovered.message.contains("旧签名"))
        current.recordAuthorizationGranted()
        precondition(!current.presentation(for: .authorization).title.contains("签名已改变"),
                     "A later revocation under the same successful signature is not a signing change")
        let nextLaunch = PermissionRecoveryModel(defaults: defaults, appURL: appURL,
                                                signingRequirement: "new certificate", signer: "Apple Development")
        precondition(!nextLaunch.presentation(for: .authorization).title.contains("签名已改变"))
        print("PASS: permission signing history, failed-launch retention, conservative unknown identity and live recovery presentation")
    }
}
