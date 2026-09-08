import AppKit
import Foundation

// MARK: - Main

// 单实例运行：已有同 Bundle ID 的实例在跑则退出——但必须留痕（同步写，马上 exit）。
// 静默退出的后果：重建后启动新包，旧实例还在，新实例悄悄消失，看起来就像
// 「修好了却没生效」。换新构建请先退出旧实例，或用 ./build_app.sh --relaunch
let bundleID = Bundle.main.bundleIdentifier ?? "com.sz.bento"
let duplicateInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if let existing = duplicateInstances.first {
    ErrorLog.logSync("已有 Bento 实例在运行（pid \(existing.processIdentifier)），本实例退出；换新构建请先退出旧实例，或用 ./build_app.sh --relaunch")
    exit(0)
}

CrashLogging.install()
let buildCommit = Bundle.main.object(forInfoDictionaryKey: "BentoBuildCommit") as? String ?? "unknown"
let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
let buildTime = Bundle.main.object(forInfoDictionaryKey: "BentoBuildTime") as? String ?? "unknown"
ErrorLog.logSync("Bento 启动：版本 \(buildVersion)，提交 \(buildCommit)，构建时间 \(buildTime)")

// 未处理异常写日志，便于事后排查
NSSetUncaughtExceptionHandler { exception in
    // 必须同步写：处理器返回后进程就 abort，异步队列块来不及落盘
    ErrorLog.logSync("未处理异常 \(exception.name.rawValue): \(exception.reason ?? "")\n"
        + exception.callStackSymbols.joined(separator: "\n"))
}

// SIGTERM 走正常退出：pkill / launchctl 发的是 TERM，AppKit 对它的默认处理是直接死，
// applicationWillTerminate 里的 Dock/分辨率/镜像收尾全部跳过。先忽略默认动作，再用
// dispatch source 在主线程转成 terminate(nil)。source 是全局常量，与进程同寿
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { NSApplication.shared.terminate(nil) }
sigtermSource.resume()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
