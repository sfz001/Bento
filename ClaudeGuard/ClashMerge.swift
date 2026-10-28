import Darwin
import Foundation

let clashMergeBeginMarker = "# BEGIN BENTO CLAUDE PROXY GUARD"
let clashMergeEndMarker = "# END BENTO CLAUDE PROXY GUARD"
let clashScriptBeginMarker = "// BEGIN BENTO CLAUDE PROXY GUARD"
let clashScriptEndMarker = "// END BENTO CLAUDE PROXY GUARD"
let claudeProxyRuleDomains = ["claude.ai", "claude.com", "claudeusercontent.com", "claudemcpcontent.com", "anthropic.com"]

enum ClashMergeError: LocalizedError {
    case noConfiguration, malformedManagedBlock, unsupportedScript, unsafeFile, fileChanged
    var errorDescription: String? {
        switch self {
        case .noConfiguration: return "未找到 Clash Verge 的全局 profiles/Script.js"
        case .malformedManagedBlock: return "Clash 配置中的 Bento 标记不完整或重复，请手动修复"
        case .unsupportedScript: return "全局 Script.js 不是可安全包装的顶层 function main 模板（暂不支持 const/箭头、模板字面量、正则或除法）；已保留 hosts 阻断"
        case .unsafeFile: return "拒绝修改非普通文件、链接或不安全路径中的 Clash 配置"
        case .fileChanged: return "Clash 配置在保存前已变化，请重试"
        }
    }
}

// Match whole marker lines. The script's extra leading LF belongs to Bento too,
// so even an original without an EOF newline round-trips byte for byte.
private func removingManagedBlock(_ contents: String, begin: String, end: String,
                                  includesLeadingNewline: Bool) throws -> String {
    var bytes = Array(contents.utf8)
    func lines(_ marker: String) -> [Range<Int>] {
        let expected = Array(marker.utf8)
        return bytes.split(separator: 10, omittingEmptySubsequences: false).compactMap { line in
            let text = line.last == 13 ? line.dropLast() : line
            guard text.elementsEqual(expected) else { return nil }
            return line.startIndex..<min(line.endIndex + 1, bytes.count)
        }
    }
    let begins = lines(begin), ends = lines(end)
    if begins.isEmpty && ends.isEmpty { return contents }
    guard begins.count == 1, ends.count == 1, let first = begins.first, let last = ends.first,
          first.upperBound <= last.lowerBound else { throw ClashMergeError.malformedManagedBlock }
    var lower = first.lowerBound
    if includesLeadingNewline {
        guard lower > 0, bytes[lower - 1] == 10 else { throw ClashMergeError.malformedManagedBlock }
        lower -= 1
    }
    bytes.removeSubrange(lower..<last.upperBound)
    return String(decoding: bytes, as: UTF8.self)
}

// Verge 1.7+ no longer implements Merge prepend-rules. Only remove our legacy
// block; never replace the subscription's rules or any other user Merge keys.
func removingLegacyClashMergeBlock(_ contents: String) throws -> String {
    try removingManagedBlock(contents, begin: clashMergeBeginMarker, end: clashMergeEndMarker,
                             includesLeadingNewline: false)
}

private struct ClashScriptToken { let text: String; let depth: Int }

// Conservative recognizer, not a JS evaluator. The root daemon never executes
// user scripts. Unknown syntax fails closed; profile scripts run after this
// global script, so the running core's first-five-rules check is still required.
private func hasWrappableMain(_ source: String) -> Bool {
    let bytes = Array(source.utf8)
    var tokens: [ClashScriptToken] = [], brackets: [UInt8] = [], i = 0
    func identifier(_ byte: UInt8) -> Bool {
        byte >= 128 || (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 36
    }
    while i < bytes.count {
        let byte = bytes[i]
        if byte == 32 || (9...13).contains(byte) { i += 1; continue }
        if byte == 47 {
            guard i + 1 < bytes.count else { return false }
            if bytes[i + 1] == 47 {
                i += 2
                while i < bytes.count && bytes[i] != 10 && bytes[i] != 13 { i += 1 }
                continue
            }
            if bytes[i + 1] == 42 {
                i += 2
                while i + 1 < bytes.count && !(bytes[i] == 42 && bytes[i + 1] == 47) { i += 1 }
                guard i + 1 < bytes.count else { return false }
                i += 2; continue
            }
            return false // Regex/division needs a full parser; do not guess.
        }
        if byte == 96 || byte == 92 { return false } // Templates / escaped identifiers.
        if byte == 34 || byte == 39 {
            let quote = byte
            i += 1
            while i < bytes.count && bytes[i] != quote {
                if bytes[i] == 92 {
                    i += 1
                    guard i < bytes.count else { return false }
                    if bytes[i] == 13 && i + 1 < bytes.count && bytes[i + 1] == 10 { i += 1 }
                } else if bytes[i] == 10 || bytes[i] == 13 { return false }
                i += 1
            }
            guard i < bytes.count else { return false }
            tokens.append(ClashScriptToken(text: "<string>", depth: brackets.count))
            i += 1; continue
        }
        if identifier(byte) {
            let start = i
            i += 1
            while i < bytes.count && (identifier(bytes[i]) || (48...57).contains(bytes[i])) { i += 1 }
            tokens.append(ClashScriptToken(text: String(decoding: bytes[start..<i], as: UTF8.self), depth: brackets.count))
            continue
        }
        if byte == 41 || byte == 93 || byte == 125 {
            let expected: UInt8 = byte == 41 ? 40 : (byte == 93 ? 91 : 123)
            guard brackets.popLast() == expected else { return false }
        }
        tokens.append(ClashScriptToken(text: String(UnicodeScalar(byte)), depth: brackets.count))
        if byte == 40 || byte == 91 || byte == 123 { brackets.append(byte) }
        i += 1
    }
    guard brackets.isEmpty else { return false }
    let top = tokens.filter { $0.depth == 0 }.map(\.text)
    let mainIndices = top.indices.filter { top[$0] == "main" }
    guard mainIndices.count == 1, let index = mainIndices.first, index >= 1,
          top[index - 1] == "function", index + 4 < top.count,
          Array(top[(index + 1)...(index + 4)]) == ["(", ")", "{", "}"] else { return false }
    // Excludes named function expressions, async/conditional declarations.
    return index == 1 || top[index - 2] == ";" || top[index - 2] == "}"
}

func clashScriptContents(_ contents: String, proxyGroup: String?) throws -> String {
    let original = try removingManagedBlock(contents, begin: clashScriptBeginMarker, end: clashScriptEndMarker,
                                            includesLeadingNewline: true)
    guard let proxyGroup else { return original }
    guard hasWrappableMain(original) else { throw ClashMergeError.unsupportedScript }
    let rules = claudeProxyRuleDomains.map { "DOMAIN-SUFFIX,\($0),\(proxyGroup)" }
    let data = try JSONSerialization.data(withJSONObject: rules)
    let json = String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    return original + "\n" + """
    \(clashScriptBeginMarker)
    ;(function () {
      const originalMain = main;
      const guardedRules = \(json);
      main = function () {
        const config = originalMain.apply(this, arguments);
        if (!config || typeof config !== "object" || Array.isArray(config)) {
          throw new Error("Bento Claude Guard: main must return a configuration object");
        }
        if (config.rules !== undefined && !Array.isArray(config.rules)) {
          throw new Error("Bento Claude Guard: rules must be an array");
        }
        config.rules = guardedRules.concat((config.rules || []).filter(function (rule) {
          return guardedRules.indexOf(rule) === -1;
        }));
        return config;
      };
    })();
    \(clashScriptEndMarker)

    """
}

final class ClashMergeManager {
    private let readFile: (String) throws -> String
    private let writeFile: (String, String, String) throws -> Void
    private let fileExists: (String) -> Bool
    private let profileDirectories: () -> [String]
    init(readFile: @escaping (String) throws -> String = ClashMergeManager.readRegularFile,
         writeFile: @escaping (String, String, String) throws -> Void = ClashMergeManager.atomicWrite,
         fileExists: @escaping (String) -> Bool = ClashMergeManager.pathExists,
         profileDirectories: @escaping () -> [String] = ClashMergeManager.userProfileDirectories) {
        self.readFile = readFile; self.writeFile = writeFile; self.fileExists = fileExists
        self.profileDirectories = profileDirectories
    }
    func install(proxyGroup: String) throws {
        let directories = profileDirectories().filter { fileExists($0 + "/Script.js") }.sorted()
        guard !directories.isEmpty else { throw ClashMergeError.noConfiguration }
        // Validate all content before writing anything; migrate only our old block.
        var edits: [(String, String, String)] = []
        for directory in directories {
            let script = directory + "/Script.js", original = try readFile(script)
            edits.append((script, original, try clashScriptContents(original, proxyGroup: proxyGroup)))
            let merge = directory + "/Merge.yaml"
            if fileExists(merge) {
                let original = try readFile(merge)
                edits.append((merge, original, try removingLegacyClashMergeBlock(original)))
            }
        }
        for (file, original, updated) in edits where updated != original { try writeFile(file, original, updated) }
    }
    func remove() throws {
        var edits: [(String, String, String)] = []
        for directory in profileDirectories().sorted() {
            for name in ["Script.js", "Merge.yaml"] {
                let file = directory + "/" + name
                guard fileExists(file) else { continue }
                let original = try readFile(file)
                let updated = try name == "Script.js" ? clashScriptContents(original, proxyGroup: nil) : removingLegacyClashMergeBlock(original)
                edits.append((file, original, updated))
            }
        }
        for (file, original, updated) in edits where updated != original { try writeFile(file, original, updated) }
    }
    private static func userProfileDirectories() -> [String] {
        let users = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
        let relative = "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles"
        return users.map { "/Users/\($0)/\(relative)" }
    }
    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 // Include dangling symlinks so reads reject them.
    }
    // Walk with no-follow directory descriptors, then use openat/renameat so a
    // swapped parent cannot redirect root writes outside the opened directory.
    private static func withParent<T>(_ path: String, _ body: (Int32, String) throws -> T) throws -> T {
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !parts.contains(".."), !parts.contains("."),
              let name = parts.last, ["Script.js", "Merge.yaml"].contains(name) else { throw ClashMergeError.unsafeFile }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ClashMergeError.unsafeFile }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ClashMergeError.unsafeFile }
            close(directory); directory = next
        }
        return try body(directory, name)
    }
    private static func readDescriptor(_ fd: Int32) throws -> (String, stat) {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= 1_048_576 else { throw ClashMergeError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while data.count <= 1_048_576 {
            guard let chunk = try handle.read(upToCount: 1_048_577 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= 1_048_576, let contents = String(data: data, encoding: .utf8) else { throw ClashMergeError.unsafeFile }
        return (contents, info)
    }
    private static func readRegularFile(_ path: String) throws -> String {
        try withParent(path) { directory, name in
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw ClashMergeError.unsafeFile }
            defer { close(fd) }
            return try readDescriptor(fd).0
        }
    }
    private static func atomicWrite(path: String, expected: String, contents: String) throws {
        try withParent(path) { directory, name in
            let originalFD = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard originalFD >= 0 else { throw ClashMergeError.unsafeFile }
            defer { close(originalFD) }
            let (original, info) = try readDescriptor(originalFD)
            guard original == expected else { throw ClashMergeError.fileChanged }
            let temporary = ".bento-claude-guard." + UUID().uuidString
            let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ClashMergeError.unsafeFile }
            var renamed = false
            defer { close(fd); if !renamed { unlinkat(directory, temporary, 0) } }
            guard fchown(fd, info.st_uid, info.st_gid) == 0, fchmod(fd, info.st_mode & 0o7777) == 0 else { throw ClashMergeError.unsafeFile }
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: Data(contents.utf8))
            guard fsync(fd) == 0 else { throw ClashMergeError.unsafeFile }
            var current = stat()
            guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                  current.st_size == info.st_size, current.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw ClashMergeError.fileChanged }
            guard renameat(directory, temporary, directory, name) == 0 else { throw ClashMergeError.unsafeFile }
            renamed = true
        }
    }
}
