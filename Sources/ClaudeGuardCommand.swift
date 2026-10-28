import Foundation
import ServiceManagement

enum ClaudeGuardCommand {
    private enum Outcome {
        case success(String)
        case failure(String)
    }

    // An XPC reply and a connection error can arrive on different queues. Only
    // the first completion determines the command's output and exit status.
    private final class Reply {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var outcome: Outcome?

        func complete(_ value: Outcome) {
            lock.lock()
            guard outcome == nil else { lock.unlock(); return }
            outcome = value
            lock.unlock()
            semaphore.signal()
        }

        func wait() -> Outcome? {
            guard semaphore.wait(timeout: .now() + 15) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return outcome
        }
    }

    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count > 1, arguments[1] == "--claude-guard" else { return false }
        let action = arguments.count > 2 ? arguments[2] : ""
        let keepRegistered = action == "off" && arguments.count == 4 && arguments[3] == "--keep-registered"
        guard ["on", "off", "status", "restart", "unregister"].contains(action),
              arguments.count == 3 || keepRegistered else {
            FileHandle.standardError.write(Data("用法：Bento --claude-guard on|off [--keep-registered]|status|restart|unregister\n".utf8))
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
            if action == "on", service.status != .enabled { try service.register() }
            if service.status != .enabled {
                if service.status == .requiresApproval {
                    FileHandle.standardError.write(Data("需要在系统设置中允许 Bento 后台守护进程\n".utf8))
                    exit(2)
                }
                if action == "off" {
                    FileHandle.standardError.write(Data("Claude 防护守护未注册，未执行清理\n".utf8))
                    exit(1)
                }
                if action == "restart" {
                    FileHandle.standardError.write(Data("Claude 防护守护未注册，无法重启\n".utf8))
                    exit(1)
                }
                print("Claude 防护已关闭")
                exit(action == "status" ? 0 : 1)
            }
            let connection = NSXPCConnection(machServiceName: claudeGuardDaemonLabel, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: ClaudeGuardXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            let reply = Reply()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                reply.complete(.failure("守护进程调用失败：\(error.localizedDescription)"))
            }) as? ClaudeGuardXPCProtocol else {
                FileHandle.standardError.write(Data("无法连接 Claude 防护守护进程\n".utf8))
                exit(1)
            }
            if action == "status" {
                proxy.getStatus { status in
                    let snapshot = ClaudeGuardSnapshot(status)
                    var message = !snapshot.enabled ? "Claude 防护已关闭" : snapshot.ready ? "Clash/TUN 已就绪，Claude 通过代理访问" : "Clash/TUN 未就绪，Claude 已阻断"
                    if let detail = snapshot.detectionDetail, !detail.isEmpty { message += "；\(detail)" }
                    if let error = snapshot.configurationError, !error.isEmpty {
                        reply.complete(.failure("\(message)；\(error)"))
                    } else {
                        reply.complete(.success(message))
                    }
                }
            } else if action == "restart" {
                proxy.restart { error in
                    if let error { reply.complete(.failure(error as String)) }
                    else { reply.complete(.success("已请求重启 Claude 防护守护；请通过 status 确认恢复")) }
                }
            } else {
                proxy.setEnabled(action == "on") { error in
                    if let error {
                        reply.complete(.failure(error as String))
                    } else {
                        reply.complete(.success(action == "on" ? "Claude 防护已开启" : "Claude 防护已关闭并清理"))
                    }
                }
            }
            guard let outcome = reply.wait() else {
                FileHandle.standardError.write(Data("Claude 防护操作超时\n".utf8)); exit(1)
            }
            switch outcome {
            case .failure(let message):
                let prefix = action == "off" ? "清理失败，守护保持注册：" : ""
                FileHandle.standardError.write(Data("\(prefix)\(message)\n".utf8))
                exit(1)
            case .success(let message):
                if action == "off", !keepRegistered { try service.unregister() }
                print(message + (keepRegistered ? "；守护保持注册" : ""))
                exit(0)
            }
        } catch {
            FileHandle.standardError.write(Data("Claude 防护操作失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
