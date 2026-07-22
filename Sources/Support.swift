import AppKit
import CoreGraphics
import Foundation
import IOKit

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

    static func log(_ message: String) {
        NSLog("%@", message)
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = directory.appendingPathComponent("error.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
