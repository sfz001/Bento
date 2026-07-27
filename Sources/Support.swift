import AppKit
import Foundation

// MARK: - Process Helper

/// 同步跑一个子进程。**永远会返回**：卡死的子进程由看门狗按 timeout 终止，
/// 否则 readDataToEndOfFile / waitUntilExit 会把调用线程永久钉住 —— 远程熄屏的
/// 轮询队列就此静默死亡，而定时器事件还在往上堆。
@discardableResult
func runProcess(_ path: String, _ args: [String], captureOutput: Bool = false,
                timeout: TimeInterval = 10) -> (status: Int32, output: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = captureOutput ? Pipe() : nil
    task.standardOutput = pipe ?? FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return (-1, "")
    }

    // 先 SIGTERM，1s 后还活着就 SIGKILL（SIGTERM 被忽略/阻塞的进程照样得走）
    let watchdog = DispatchWorkItem {
        guard task.isRunning else { return }
        ErrorLog.log("子进程超时 \(Int(timeout))s，强制终止: \(path) \(args.joined(separator: " "))")
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

    // Drain the pipe before waiting so large output can't deadlock the child.
    let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    task.waitUntilExit()
    watchdog.cancel()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (task.terminationStatus, output)
}

// MARK: - 错误日志（全模块共用）

/// 未处理异常与关键错误写入 ~/Library/Application Support/Bento/error.log
enum ErrorLog {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Bento", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 写入串行化：多线程（含未处理异常回调）同时 log 不会交错损坏行
    private static let queueKey = DispatchSpecificKey<Bool>()
    private static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "com.sz.bento.errorlog")
        q.setSpecific(key: queueKey, value: true)
        return q
    }()
    private static let formatter = ISO8601DateFormatter()
    private static let maxSize = 256 * 1024

    /// 崩溃路径专用：同步写盘。异常处理器 log 完进程就死，异步队列块会来不及执行
    static func logSync(_ message: String) {
        NSLog("%@", message)
        // 崩溃发生在本队列内部时（write() 里的 FileHandle.write 在磁盘满等情况下
        // 会抛 NSException → 未捕获异常处理器 → 这里），queue.sync 就是自己等自己：
        // 死锁，进程既不 abort 日志也落不了盘。已经在队列上就直接写，串行队列上
        // 本来也不存在并发者
        if DispatchQueue.getSpecific(key: queueKey) == true {
            write(message)
        } else {
            queue.sync { write(message) }
        }
    }

    static func log(_ message: String) {
        NSLog("%@", message)
        queue.async { write(message) }
    }

    private static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        let url = directory.appendingPathComponent("error.log")
        // 超上限就滚动到 .1（覆盖旧的），防止反复异常把日志写爆
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
            let rolled = directory.appendingPathComponent("error.log.1")
            try? fm.removeItem(at: rolled)
            try? fm.moveItem(at: url, to: rolled)
        }
        if fm.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
