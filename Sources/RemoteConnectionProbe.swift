import AppKit
import Darwin
import Foundation

enum ConnectionProbe {
    case connected(String)
    case disconnected
    case unknown
}

/// pid 可复用，必须同时校验启动时间和内核返回的可执行文件路径。
struct RemoteProcessIdentity: Equatable {
    let pid: Int32
    let executable: String
    let startedAt: Date

    static func read(_ pid: Int32) -> RemoteProcessIdentity? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        // 启动时间走 sysctl KERN_PROC_PID（ps -o lstart 同源）。不能用
        // proc_pidinfo(PROC_PIDTBSDINFO)：普通用户进程对 root 守护进程调用返回 EPERM
        // （screensharingd、launchd 均如此，2026-10-22 实测），身份读取为 nil 后探测每轮
        // unknown，屏幕共享会话从未被认定为已连接。proc_pidpath 对同一进程是可用的。
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return RemoteProcessIdentity(pid: pid, executable: String(cString: path),
            startedAt: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000))
    }
}

/// 仅由 pollQueue 使用；认证成功只缓存到同一进程退出，空闲时不查询统一日志。
final class RemoteConnectionDetector {
    typealias Runner = (String, [String], Bool, TimeInterval) -> (status: Int32, output: String)
    static let screenSharingPath = "/System/Library/CoreServices/RemoteManagement/screensharingd.bundle/Contents/MacOS/screensharingd"
    private let run: Runner
    private let identity: (Int32) -> RemoteProcessIdentity?
    private let rustDeskPaths: Set<String>
    private var authenticatedProcess: RemoteProcessIdentity?

    init(run: @escaping Runner = { runProcess($0, $1, captureOutput: $2, timeout: $3) },
         identity: @escaping (Int32) -> RemoteProcessIdentity? = RemoteProcessIdentity.read,
         rustDeskPaths: Set<String>? = nil) {
        self.run = run
        self.identity = identity
        var paths = Set(["/Applications/RustDesk.app/Contents/MacOS/RustDesk",
                         NSHomeDirectory() + "/Applications/RustDesk.app/Contents/MacOS/RustDesk"])
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.carriez.RustDesk") {
            paths.insert(app.appendingPathComponent("Contents/MacOS/RustDesk").resolvingSymlinksInPath().path)
        }
        self.rustDeskPaths = rustDeskPaths ?? paths
    }

    func rustDesk() -> ConnectionProbe {
        let result = run("/usr/bin/pgrep", ["-fi", "rustdesk.*[[:space:]]--cm([[:space:]]|$)"], true, 3)
        if result.status == 1 { return .disconnected }
        guard result.status == 0, let pids = Self.pids(result.output) else { return .unknown }
        var unreadable = false
        for pid in pids {
            guard let process = identity(pid) else { unreadable = true; continue }
            if rustDeskPaths.contains(process.executable) { return .connected("RustDesk") }
        }
        return unreadable ? .unknown : .disconnected
    }

    func screenSharing(now: Date = Date()) -> ConnectionProbe {
        let result = run("/usr/bin/pgrep", ["-x", "screensharingd"], true, 3)
        if result.status == 1 { authenticatedProcess = nil; return .disconnected }
        guard result.status == 0, let pids = Self.pids(result.output) else { return .unknown }
        var processes: [RemoteProcessIdentity] = []
        for pid in pids {
            guard let process = identity(pid) else { return .unknown }
            if process.executable == Self.screenSharingPath { processes.append(process) }
        }
        guard let process = processes.first else { authenticatedProcess = nil; return .disconnected }
        if authenticatedProcess == process { return .connected("Screen Sharing") }
        authenticatedProcess = nil

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        // 默认级别的认证成功记录已经在本机真实会话取证；不保存姓名/IP 等日志内容。
        let predicate = "processIdentifier == \(process.pid) AND processImagePath == '\(Self.screenSharingPath)' AND eventMessage BEGINSWITH 'Authentication: SUCCEEDED'"
        let logs = run("/usr/bin/log", ["show", "--style", "json", "--start", formatter.string(from: process.startedAt),
                                     "--predicate", predicate], true, 3)
        guard logs.status == 0, let data = logs.output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              identity(process.pid) == process else { return .unknown }
        if entries.contains(where: {
            ($0["processID"] as? Int) == Int(process.pid)
                && ($0["processImagePath"] as? String) == process.executable
                && ($0["eventMessage"] as? String)?.hasPrefix("Authentication: SUCCEEDED") == true
        }) {
            authenticatedProcess = process
            return .connected("Screen Sharing")
        }
        // 扫描/认证未完成时不熄屏。若长时间无法确认认证，进入现有探测健康告警，
        // 防止未来系统改变日志格式后静默失效；已激活会话的 unknown 仍维持黑屏。
        return now.timeIntervalSince(process.startedAt) > 30 ? .unknown : .disconnected
    }

    private static func pids(_ output: String) -> [Int32]? {
        let lines = output.split(whereSeparator: \.isWhitespace)
        let ids = lines.compactMap { Int32($0) }.filter { $0 > 0 }
        return !ids.isEmpty && ids.count == lines.count ? ids : nil
    }
}
