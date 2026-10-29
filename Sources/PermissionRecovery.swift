import AppKit
import Foundation
import Security

enum PermissionRecoveryCondition: Equatable {
    case ready
    case authorization
    case eventTap
}

struct PermissionRecoveryPresentation: Equatable {
    let title: String
    let message: String
    let appPath: String
    let signer: String?
}

/// Only inspect this process's public signing information. TCC remains owned by macOS.
private enum PermissionSigningIdentity {
    static func requirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    static func signer() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
}

final class PermissionRecoveryModel {
    private static let authorizedRequirementKey = "PermissionRecoveryLastAuthorizedRequirement"
    private let defaults: UserDefaults
    private let appURL: URL
    private let signingRequirement: String?
    private let signer: String?

    init(defaults: UserDefaults = .standard,
         appURL: URL = Bundle.main.bundleURL,
         signingRequirement: String? = PermissionSigningIdentity.requirement(),
         signer: String? = PermissionSigningIdentity.signer()) {
        self.defaults = defaults
        self.appURL = appURL
        self.signingRequirement = Self.nonempty(signingRequirement)
        self.signer = Self.nonempty(signer)
    }

    /// Call only after observing effective authorization, not merely an open Settings pane.
    func recordAuthorizationGranted() {
        guard let signingRequirement,
              defaults.string(forKey: Self.authorizedRequirementKey) != signingRequirement else { return }
        defaults.set(signingRequirement, forKey: Self.authorizedRequirementKey)
    }

    func presentation(for condition: PermissionRecoveryCondition) -> PermissionRecoveryPresentation {
        let title: String
        let message: String
        switch condition {
        case .ready:
            title = "Bento 权限已生效"
            message = "当前版本的设备控制授权已生效，滚动监听已启用，可以关闭此窗口。Bento 会继续自动检测运行状态。"
        case .eventTap:
            title = "权限已生效，输入监听暂不可用"
            message = "Bento 已读取到有效授权，但系统暂未启用输入事件监听。Bento 会自动重试，也可以点击「重新检测」。若仍未恢复，请点击「重启 Bento」。"
        case .authorization:
            let previous = Self.nonempty(defaults.string(forKey: Self.authorizedRequirementKey))
            let changed = previous != nil && signingRequirement != nil && previous != signingRequirement
            title = changed ? "Bento 签名已改变，授权尚未生效" : "Bento 当前版本的授权尚未生效"
            let reason = changed
                ? "检测到当前签名与上次授权成功的版本不同。系统里原先开启的 Bento 项目可能仍对应旧签名。"
                : "如果系统里的 Bento 开关已打开，可能仍关联旧版本或旧签名，也可能需要重启后才生效。"
            message = """
            \(reason)

            1. 打开「系统设置 → 隐私与安全 → 设备控制和数据访问」（较早版本名为「辅助功能」），允许 Bento。
            2. 点击「重新检测」；若已开启但仍无效，先尝试「重启 Bento」。
            3. 如果重启后仍未恢复，请在该设置页手动移除 Bento，再用「+」添加下方路径的 App 并开启。可点击「在访达中显示」找到当前版本。

            Bento 会自动重新检测并更新此窗口。系统授权与身份验证需要你在 macOS 中完成。
            """
        }
        return PermissionRecoveryPresentation(title: title, message: message,
                                              appPath: appURL.standardizedFileURL.path, signer: signer)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// A single, modeless window that can reflect recovery while the user is in Settings.
final class PermissionRecoveryWindow: NSWindowController {
    private let titleLabel = NSTextField(wrappingLabelWithString: "Bento 权限恢复")
    private let details = NSTextView(frame: .zero)
    private var lastPresentation: PermissionRecoveryPresentation?
    private let onOpenSettings: () -> Void
    private let onRevealApp: () -> Void
    private let onRetry: () -> Void
    private let onRestart: () -> Void

    init(onOpenSettings: @escaping () -> Void,
         onRevealApp: @escaping () -> Void,
         onRetry: @escaping () -> Void,
         onRestart: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        self.onRevealApp = onRevealApp
        self.onRetry = onRetry
        self.onRestart = onRestart
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Bento 权限恢复"
        window.minSize = NSSize(width: 620, height: 380)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        let content = NSView()
        window.contentView = content
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.isSelectable = true

        details.isEditable = false
        details.isSelectable = true
        details.isRichText = false
        details.drawsBackground = false
        details.font = .systemFont(ofSize: 13)
        details.textColor = .labelColor
        details.textContainerInset = NSSize(width: 0, height: 4)
        details.isVerticallyResizable = true
        details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let buttons = NSStackView(views: [
            button("打开权限设置", #selector(openSettings)),
            button("在访达中显示", #selector(revealApp)),
            button("重新检测", #selector(retry)),
            button("重启 Bento", #selector(restart))
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        for view in [titleLabel, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -18),
            buttons.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ presentation: PermissionRecoveryPresentation) {
        // Polling must not reset a selected path or the user's scroll position.
        guard presentation != lastPresentation else { return }
        lastPresentation = presentation
        titleLabel.stringValue = presentation.title
        details.string = "\(presentation.message)\n\n当前 App\n\(presentation.appPath)\n\n签名\n\(presentation.signer ?? "无法读取签名信息")"
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    @objc private func openSettings() { onOpenSettings() }
    @objc private func revealApp() { onRevealApp() }
    @objc private func retry() { onRetry() }
    @objc private func restart() { onRestart() }
}
