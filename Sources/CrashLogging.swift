import Foundation

@_silgen_name("bento_install_crash_logger")
private func installCrashLogger(_ path: UnsafePointer<CChar>) -> Int32

enum CrashLogging {
    static func install() {
        let path = ErrorLog.directory.appendingPathComponent("error.log").path
        if path.withCString({ installCrashLogger($0) }) != 0 {
            ErrorLog.logSync("崩溃标记处理器安装失败，系统崩溃报告仍可用")
        }
    }
}
