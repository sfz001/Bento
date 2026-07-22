import AppKit
import Foundation

// MARK: - Process Helper

@discardableResult
func runProcess(_ path: String, _ args: [String], captureOutput: Bool = false) -> (status: Int32, output: String) {
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
    // Drain the pipe before waiting so large output can't deadlock the child.
    let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
    task.waitUntilExit()
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
    private static let queue = DispatchQueue(label: "com.sz.bento.errorlog")
    private static let formatter = ISO8601DateFormatter()
    private static let maxSize = 256 * 1024

    /// 崩溃路径专用：同步写盘。异常处理器 log 完进程就死，异步队列块会来不及执行
    static func logSync(_ message: String) {
        NSLog("%@", message)
        queue.sync { write(message) }
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
