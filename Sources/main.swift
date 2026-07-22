import AppKit
import Foundation

// MARK: - Main

// 单实例运行：已有同 Bundle ID 的实例在跑则直接退出
let bundleID = Bundle.main.bundleIdentifier ?? "com.sz.bento"
let duplicateInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
guard duplicateInstances.isEmpty else { exit(0) }

// 未处理异常写日志，便于事后排查
NSSetUncaughtExceptionHandler { exception in
    ErrorLog.log("未处理异常 \(exception.name.rawValue): \(exception.reason ?? "")\n"
        + exception.callStackSymbols.joined(separator: "\n"))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
