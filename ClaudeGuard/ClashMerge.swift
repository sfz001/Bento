import Darwin
import Foundation

let clashMergeBeginMarker = "# BEGIN BENTO CLAUDE PROXY GUARD"
let clashMergeEndMarker = "# END BENTO CLAUDE PROXY GUARD"
let claudeProxyRuleDomains = ["claude.ai", "claude.com", "claudeusercontent.com", "claudemcpcontent.com", "anthropic.com"]

enum ClashMergeError: LocalizedError {
    case noConfiguration, existingPrependRules, malformedManagedBlock, unsafeFile
    var errorDescription: String? {
        switch self {
        case .noConfiguration: return "未找到 Clash Verge 的持久 Merge 配置"
        case .existingPrependRules: return "Merge 已有 prepend-rules，请手动将五条 Claude 规则合并到该列表"
        case .malformedManagedBlock: return "Clash Merge 中的 Bento 标记不完整，请手动修复"
        case .unsafeFile: return "拒绝修改非普通 Merge 文件"
        }
    }
}

func clashMergeContents(_ contents: String, proxyGroup: String?) throws -> String {
    let begin = contents.range(of: clashMergeBeginMarker), end = contents.range(of: clashMergeEndMarker)
    var original = contents
    if begin != nil || end != nil {
        guard let begin, let end, begin.lowerBound < end.lowerBound,
              !contents[end.upperBound...].contains(clashMergeBeginMarker) else { throw ClashMergeError.malformedManagedBlock }
        var range = begin.lowerBound..<end.upperBound
        if range.upperBound < original.endIndex, original[range.upperBound] == "\n" {
            range = range.lowerBound..<original.index(after: range.upperBound)
        }
        original.removeSubrange(range)
    }
    guard let proxyGroup else { return original }
    if original.range(of: #"(?m)^prepend-rules\s*:"#, options: .regularExpression) != nil { throw ClashMergeError.existingPrependRules }
    var result = original
    if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
    result += clashMergeBeginMarker + "\nprepend-rules:\n"
    result += claudeProxyRuleDomains.map { "  - DOMAIN-SUFFIX,\($0),\(proxyGroup)" }.joined(separator: "\n")
    return result + "\n" + clashMergeEndMarker + "\n"
}

final class ClashMergeManager {
    private let readFile: (String) throws -> String
    private let writeFile: (String, String) throws -> Void
    private let fileExists: (String) -> Bool
    init(readFile: @escaping (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
         writeFile: @escaping (String, String) throws -> Void = ClashMergeManager.atomicWrite,
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.readFile = readFile; self.writeFile = writeFile; self.fileExists = fileExists
    }
    func install(proxyGroup: String) throws {
        let files = mergeFiles(); guard !files.isEmpty else { throw ClashMergeError.noConfiguration }
        for file in files {
            let original = try readFile(file), updated = try clashMergeContents(original, proxyGroup: proxyGroup)
            if updated != original { try writeFile(file, updated) }
        }
    }
    func remove() throws {
        for file in mergeFiles() {
            let original = try readFile(file), updated = try clashMergeContents(original, proxyGroup: nil)
            if updated != original { try writeFile(file, updated) }
        }
    }
    private func mergeFiles() -> [String] {
        let users = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
        let relative = "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Merge.yaml"
        return users.map { "/Users/\($0)/\(relative)" }.filter { fileExists($0) }.sorted()
    }
    private static func atomicWrite(path: String, contents: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ClashMergeError.unsafeFile }
        let template = (path as NSString).deletingLastPathComponent + "/.bento-claude-merge.XXXXXX"
        guard let temp = strdup(template) else { throw ClashMergeError.unsafeFile }
        defer { free(temp) }
        let fd = mkstemp(temp); guard fd >= 0 else { throw ClashMergeError.unsafeFile }
        let tempPath = String(cString: temp); var renamed = false
        defer { close(fd); if !renamed { unlink(tempPath) } }
        guard fchmod(fd, info.st_mode & 0o7777) == 0, fchown(fd, info.st_uid, info.st_gid) == 0 else { throw ClashMergeError.unsafeFile }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(contents.utf8))
        guard fsync(fd) == 0, rename(tempPath, path) == 0 else { throw ClashMergeError.unsafeFile }
        renamed = true
    }
}
