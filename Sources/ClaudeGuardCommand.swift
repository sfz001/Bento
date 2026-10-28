import Foundation
import ServiceManagement

enum ClaudeGuardCommand {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "--claude-guard" else { return false }
        let action = arguments[2]
        guard ["on", "off", "status", "unregister"].contains(action) else {
            FileHandle.standardError.write(Data("用法：Bento --claude-guard on|off|status|unregister\n".utf8))
            exit(2)
        }
        let service = SMAppService.daemon(plistName: claudeGuardDaemonPlist)
        if action == "on", let signingError = claudeGuardSigningError {
            FileHandle.standardError.write(Data("\(signingError)\n".utf8))
            exit(1)
        }
        do {
            if action == "unregister" {
                try service.unregister()
                print("已注销 Claude 防护守护；此应急命令不清理 hosts，常规清理请使用 off")
                exit(0)
            }
            if action != "status", service.status != .enabled { try service.register() }
            if service.status != .enabled {
                print(service.status == .requiresApproval ? "需要在系统设置中允许 Bento 后台守护进程" : "Claude 防护已关闭")
                exit(service.status == .requiresApproval ? 2 : 0)
            }
            let connection = NSXPCConnection(machServiceName: claudeGuardDaemonLabel, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: ClaudeGuardXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            let semaphore = DispatchSemaphore(value: 0)
            var message = "守护进程未响应"
            let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in semaphore.signal() }) as? ClaudeGuardXPCProtocol
            if action == "status" {
                proxy?.getStatus { status in
                    let snapshot = ClaudeGuardSnapshot(status)
                    message = !snapshot.enabled ? "Claude 防护已关闭" : snapshot.ready ? "Clash/TUN 已就绪，Claude 通过代理访问" : "Clash/TUN 未就绪，Claude 已阻断"
                    if let error = snapshot.configurationError { message += "；\(error)" }
                    semaphore.signal()
                }
            } else {
                proxy?.setEnabled(action == "on") { error in
                    message = error.map(String.init) ?? (action == "on" ? "Claude 防护已开启" : "Claude 防护已关闭并清理")
                    semaphore.signal()
                }
            }
            guard semaphore.wait(timeout: .now() + 15) == .success else {
                FileHandle.standardError.write(Data("Claude 防护操作超时\n".utf8)); exit(1)
            }
            if action == "off", message != "Claude 防护已关闭并清理" {
                FileHandle.standardError.write(Data("清理失败，守护保持注册：\(message)\n".utf8)); exit(1)
            }
            if action == "off" { try service.unregister() }
            print(message)
            exit(message.contains("未通过验证") || message.contains("未响应") ? 1 : 0)
        } catch {
            FileHandle.standardError.write(Data("Claude 防护操作失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
