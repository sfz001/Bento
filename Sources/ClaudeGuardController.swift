import AppKit
import Foundation
import ServiceManagement

final class ClaudeGuardController {
    var onUpdate: (() -> Void)?
    private(set) var snapshot = ClaudeGuardSnapshot(["enabled": false, "ready": false])
    private(set) var operationInFlight = false
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private let service = SMAppService.daemon(plistName: claudeGuardDaemonPlist)
    private var registrationStatus = SMAppService.Status.notRegistered

    var menuState: NSControl.StateValue {
        if registrationStatus == .requiresApproval { return .mixed }
        return snapshot.enabled ? .on : .off
    }

    var statusText: String {
        if operationInFlight { return "Claude 防护：正在应用设置…" }
        switch registrationStatus {
        case .requiresApproval:
            return "Claude 防护：需要在系统设置中允许后台守护进程"
        default:
            break
        }
        if let error = snapshot.configurationError, !error.isEmpty {
            return "Claude 防护：配置错误（查看说明与排错）"
        }
        if !snapshot.enabled { return "Claude 防护已关闭" }
        return snapshot.ready ? "Clash/TUN 已就绪，Claude 通过代理访问" : "Clash/TUN 未就绪，Claude 已阻断"
    }

    func start() {
        reconcileDaemonUpgrade()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        connection?.invalidate()
    }

    func setEnabled(_ enabled: Bool) {
        guard !operationInFlight else { return }
        if enabled, let signingError = claudeGuardSigningError {
            snapshot = ClaudeGuardSnapshot(["enabled": false, "ready": false, "error": signingError])
            onUpdate?()
            return
        }
        operationInFlight = true
        onUpdate?()
        DispatchQueue.main.async {
            do {
                if self.service.status != .enabled { try self.service.register() }
                guard self.service.status == .enabled else {
                    self.finish(nil)
                    SMAppService.openSystemSettingsLoginItems()
                    return
                }
                self.remote { proxy, failure in
                    proxy?.setEnabled(enabled) { error in
                        if let error { failure(error as String); return }
                        if !enabled {
                            do { try self.service.unregister() } catch { failure(error.localizedDescription); return }
                        }
                        self.finish(nil)
                    } ?? failure("无法连接 Claude 防护守护进程")
                }
            } catch {
                self.finish(error.localizedDescription)
                if self.service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        }
    }

    func cleanupAndUnregister() { setEnabled(false) }

    func refresh() {
        registrationStatus = service.status
        guard registrationStatus == .enabled else {
            snapshot = ClaudeGuardSnapshot(["enabled": false, "ready": false])
            onUpdate?()
            return
        }
        remote { proxy, failure in
            proxy?.getStatus { dictionary in
                DispatchQueue.main.async {
                    self.snapshot = ClaudeGuardSnapshot(dictionary)
                    self.onUpdate?()
                }
            } ?? failure("无法读取 Claude 防护状态")
        }
    }

    func openBackgroundSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func remote(_ operation: @escaping (ClaudeGuardXPCProtocol?, @escaping (String) -> Void) -> Void) {
        let failure: (String) -> Void = { message in
            DispatchQueue.main.async {
                self.connection?.invalidate()
                self.connection = nil
                self.snapshot = ClaudeGuardSnapshot(["enabled": self.snapshot.enabled, "ready": false, "error": message])
                self.onUpdate?()
            }
        }
        if connection == nil {
            let newConnection = NSXPCConnection(machServiceName: claudeGuardDaemonLabel, options: .privileged)
            newConnection.remoteObjectInterface = NSXPCInterface(with: ClaudeGuardXPCProtocol.self)
            newConnection.invalidationHandler = { [weak self] in self?.connection = nil }
            newConnection.interruptionHandler = { [weak self] in self?.connection = nil }
            newConnection.resume()
            connection = newConnection
        }
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in failure(error.localizedDescription) } as? ClaudeGuardXPCProtocol
        operation(proxy, failure)
    }

    private func finish(_ error: String?) {
        DispatchQueue.main.async {
            self.operationInFlight = false
            if let error { self.snapshot = ClaudeGuardSnapshot(["enabled": self.snapshot.enabled, "ready": false, "error": error]) }
            self.refresh()
            self.onUpdate?()
        }
    }

    private func reconcileDaemonUpgrade() {
        guard service.status == .enabled else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "BentoBuildCommit") as? String ?? "unknown"
        let key = "ClaudeGuardDaemonBuild"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        do {
            try service.unregister()
            try service.register()
            UserDefaults.standard.set(build, forKey: key)
        } catch {
            ErrorLog.log("Claude 防护守护升级失败: \(error.localizedDescription)")
        }
    }
}

final class ClaudeGuardHelpWindow: NSWindowController {
    static let shared = ClaudeGuardHelpWindow()

    private init() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 410))
        text.isEditable = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.string = """
Claude 的 Clash 联动防直连保护

开启后，Bento 注册一个 root LaunchDaemon。守护进程每秒核实 Clash 核心、本次 TUN 配置、TUN 地址、实际路由和控制接口。未就绪或检测失败时，将指定 Claude/Anthropic 域名指向 127.0.0.1 和 ::1；就绪后自动移除阻断。App 退出不影响守护，重启后按上次开启状态自动恢复。

首次授权
macOS 可能要求在「系统设置 → 通用 → 登录项与扩展 → 在后台允许」中允许 Bento。保护关闭会清理 hosts 和 Bento 的 Clash Merge 规则，并注销守护。「恢复 hosts 并卸载守护」执行同样的彻底清理。

排错
• 确认 Clash Verge 核心运行，TUN 与自动路由均开启。
• 五条 DOMAIN-SUFFIX 规则写入 Clash Verge 持久 Merge 的 Bento 标记段，不修改订阅。
• 默认使用 PROXY 代理组。若运行配置不存在该组且无法唯一判断其他代理组，或后续脚本覆盖规则，保护保持阻断并显示配置错误。
• 原有 Merge 已含 prepend-rules 时不会擅自合并；请按提示手动处理，避免破坏现有列表。
• 状态检测、hosts 或 DNS 刷新失败都按未就绪处理，不会为了放行而忽略错误。

限制
hosts 不支持通配符。*.frame.claudeusercontent.com、*.claudemcpcontent.com 等动态子域名无法通过 hosts 完整覆盖，本功能不保证阻断所有未知子域名。Clash 的 DOMAIN-SUFFIX 规则仍会覆盖其代理范围内的子域名，但这不等同于 hosts 的完整阻断。

切换 Clash/TUN 后，浏览器或 Claude Code 可能仍缓存旧解析；如仍异常，请重启浏览器或 Claude Code。
"""
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Claude 防护说明与排错"
        window.contentView = scroll
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
