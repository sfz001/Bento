import Darwin
import Foundation

let claudeGuardDomains = [
    "claude.ai", "www.claude.ai", "downloads.claude.ai",
    "claude.com", "www.claude.com", "code.claude.com", "platform.claude.com", "sso.claude.com",
    "claudeusercontent.com", "www.claudeusercontent.com", "bridge.claudeusercontent.com", "frame.claudeusercontent.com",
    "claudemcpcontent.com", "www.claudemcpcontent.com",
    "api.anthropic.com", "console.anthropic.com", "auth.anthropic.com", "login.anthropic.com",
    "mcp-proxy.anthropic.com", "assets-proxy.anthropic.com", "statsig.anthropic.com", "sentry.anthropic.com",
]
let claudeGuardBeginMarker = "# BEGIN CLAUDE PROXY GUARD"
let claudeGuardEndMarker = "# END CLAUDE PROXY GUARD"
let claudeGuardBlock = ([claudeGuardBeginMarker] + claudeGuardDomains.flatMap {
    ["127.0.0.1 \($0)", "::1 \($0)"]
} + [claudeGuardEndMarker]).joined(separator: "\n")

enum ClaudeGuardHostsError: LocalizedError {
    case invalidFile, malformedManagedBlock, writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidFile: return "hosts 不是可安全修改的普通文件"
        case .malformedManagedBlock: return "hosts 中的 Claude 防护标记不完整，请手动修复后重试"
        case .writeFailed(let operation): return "hosts \(operation)失败"
        }
    }
}

func removingClaudeGuardBlock(from contents: String) throws -> String {
    let begin = contents.range(of: claudeGuardBeginMarker)
    let end = contents.range(of: claudeGuardEndMarker)
    guard begin == nil && end == nil else {
        guard let begin, let end, begin.lowerBound < end.lowerBound,
              !contents[end.upperBound...].contains(claudeGuardBeginMarker) else {
            throw ClaudeGuardHostsError.malformedManagedBlock
        }
        var result = contents
        var removal = begin.lowerBound..<end.upperBound
        if removal.upperBound < result.endIndex, result[removal.upperBound] == "\n" {
            removal = removal.lowerBound..<result.index(after: removal.upperBound)
        } else if removal.lowerBound > result.startIndex {
            let previous = result.index(before: removal.lowerBound)
            if result[previous] == "\n" { removal = previous..<removal.upperBound }
        }
        result.removeSubrange(removal)
        return result
    }
    return contents
}

func claudeGuardHostsContents(_ contents: String, blocked: Bool) throws -> String {
    let original = try removingClaudeGuardBlock(from: contents)
    guard blocked else { return original }
    var result = original
    if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
    result += claudeGuardBlock + "\n"
    return result
}

protocol ClaudeGuardHostsManaging: AnyObject {
    @discardableResult func setBlocked(_ blocked: Bool) throws -> Bool
}

final class ClaudeGuardHostsFile: ClaudeGuardHostsManaging {
    private let path: String
    private let renameFile: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    init(path: String = "/etc/hosts",
         renameFile: @escaping (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32 = { Darwin.rename($0, $1) }) {
        self.path = path
        self.renameFile = renameFile
    }

    @discardableResult
    func setBlocked(_ blocked: Bool) throws -> Bool {
        let fd = path.withCString { Darwin.open($0, O_RDWR | O_NOFOLLOW) }
        guard fd >= 0 else { throw ClaudeGuardHostsError.invalidFile }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ClaudeGuardHostsError.writeFailed("锁定") }
        defer { flock(fd, LOCK_UN) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ClaudeGuardHostsError.invalidFile }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        guard let contents = String(data: data, encoding: .utf8) else { throw ClaudeGuardHostsError.writeFailed("解码") }
        let updated = try claudeGuardHostsContents(contents, blocked: blocked)
        guard updated != contents else { return false }
        guard let bytes = updated.data(using: .utf8) else { throw ClaudeGuardHostsError.writeFailed("编码") }
        let template = (path as NSString).deletingLastPathComponent + "/.bento-claude-hosts.XXXXXX"
        guard let temp = strdup(template) else { throw ClaudeGuardHostsError.writeFailed("创建临时文件") }
        defer { free(temp) }
        let tempFD = mkstemp(temp)
        guard tempFD >= 0 else { throw ClaudeGuardHostsError.writeFailed("创建临时文件") }
        let tempPath = String(cString: temp)
        var renamed = false
        defer { Darwin.close(tempFD); if !renamed { Darwin.unlink(tempPath) } }
        do {
            guard fchmod(tempFD, info.st_mode & 0o7777) == 0,
                  fchown(tempFD, info.st_uid, info.st_gid) == 0 else { throw ClaudeGuardHostsError.writeFailed("保留权限") }
            try FileHandle(fileDescriptor: tempFD, closeOnDealloc: false).write(contentsOf: bytes)
            guard fsync(tempFD) == 0 else { throw ClaudeGuardHostsError.writeFailed("同步") }
            guard tempPath.withCString({ tempCString in path.withCString { renameFile(tempCString, $0) } }) == 0 else {
                throw ClaudeGuardHostsError.writeFailed("原子替换")
            }
            renamed = true
            let directoryFD = Darwin.open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY)
            if directoryFD >= 0 { _ = fsync(directoryFD); Darwin.close(directoryFD) }
            return true
        } catch let error as ClaudeGuardHostsError { throw error } catch {
            throw ClaudeGuardHostsError.writeFailed("写入")
        }
    }
}
