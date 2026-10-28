import Darwin
import Foundation
import JavaScriptCore

// Only these repository fixtures are evaluated. No live Clash script/config is
// read or executed, and no controller connection or network request is made.
@main struct ClashScriptTests {
    static let template = "// Clash Verge global script\nfunction main(config, profileName) { return config; }"
    static func main() throws {
        try testWrapper()
        try testSourcePreservation()
        try testUnsupportedScripts()
        try testManagedFiles()
        try testUnsafeFiles()
        print("Clash script tests passed")
    }
    static func evaluate(_ script: String, expression: String) -> JSValue {
        let context = JSContext()!
        let result = context.evaluateScript("(function () {\n" + script + "\n; return (" + expression + ");\n})()")!
        precondition(context.exception == nil, "Fixture JavaScript failed: \(context.exception?.toString() ?? "")")
        return result
    }
    static func testWrapper() throws {
        let original = """
        let calls = 0;
        function main(config, profileName) {
          calls += 1;
          config.calls = calls;
          config.profile = profileName;
          config.receiver = this.tag;
          config.dns = { enable: true };
          config.rules.unshift("PROCESS-NAME,fixture,DIRECT");
          return config;
        }
        """
        let enabled = try clashScriptContents(original, proxyGroup: "PROXY")
        let result = evaluate(enabled, expression: "main.call({tag:'receiver'}, {rules:['DOMAIN-SUFFIX,claude.ai,PROXY','MATCH,ORIGINAL']}, 'profile')").toDictionary()!
        let guarded = claudeProxyRuleDomains.map { "DOMAIN-SUFFIX,\($0),PROXY" }
        precondition(result["rules"] as? [String] == guarded + ["PROCESS-NAME,fixture,DIRECT", "MATCH,ORIGINAL"])
        precondition((result["calls"] as? NSNumber)?.intValue == 1)
        precondition(result["profile"] as? String == "profile" && result["receiver"] as? String == "receiver")
        precondition((result["dns"] as? [String: Bool])?["enable"] == true)
        let repeated = evaluate(try clashScriptContents(template, proxyGroup: "PROXY"), expression: "main(main({rules:['MATCH,ORIGINAL']})).rules").toArray() as! [String]
        precondition(repeated == guarded + ["MATCH,ORIGINAL"])
        let group = "代理\"'); globalThis.injected=true; //\\\n\u{2028}\u{2029}"
        let safe = try clashScriptContents(template, proxyGroup: group)
        let escaped = evaluate(safe, expression: "({rules: main({}).rules, injected: globalThis.injected === true})").toDictionary()!
        precondition(escaped["rules"] as? [String] == claudeProxyRuleDomains.map { "DOMAIN-SUFFIX,\($0),\(group)" })
        precondition(escaped["injected"] as? Bool == false)
    }
    static func testSourcePreservation() throws {
        for original in [template, template + "\n", template + "\r", template + "\n\n", template.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n",
                         "/* function main(fake) {} */\n" + template + " // trailing comment"] {
            let enabled = try clashScriptContents(original, proxyGroup: "PROXY")
            let repeated = try clashScriptContents(enabled, proxyGroup: "PROXY")
            let removed = try clashScriptContents(enabled, proxyGroup: nil)
            precondition(repeated == enabled)
            precondition(Data(removed.utf8) == Data(original.utf8))
            let changed = try clashScriptContents(enabled, proxyGroup: "NEXT")
            precondition(!changed.contains("anthropic.com,PROXY") && changed.contains("anthropic.com,NEXT"))
        }
        let literalMarker = template + "\nconst note = '" + clashScriptBeginMarker + "';"
        let literalRemoved = try clashScriptContents(literalMarker, proxyGroup: nil)
        precondition(literalRemoved == literalMarker)
        for malformed in [template + "\n" + clashScriptBeginMarker + "\n",
                          template + "\n" + clashScriptEndMarker + "\n",
                          try clashScriptContents(template, proxyGroup: "PROXY") + clashScriptEndMarker + "\n"] {
            do { _ = try clashScriptContents(malformed, proxyGroup: nil); preconditionFailure("Malformed block accepted") }
            catch ClashMergeError.malformedManagedBlock {}
        }
    }
    static func testUnsupportedScripts() throws {
        for original in ["const main = config => config;", "let main = function(config) { return config; };",
                         "const alias = function main(config) { return config; };",
                         "async function main(config) { return config; }", "function* main(config) { return config; }",
                         "function other() { function main(config) { return config; } }",
                         "// function main(config) {}\nconst x = 'function main() {}';",
                         template + "\n" + template, "if (true) function main(config) { return config; }",
                         "function main(config) { config.x = `template`; return config; }",
                         "function main(config) { config.x = /regexp/; return config; }",
                         "function main(config) { config.x = 2 / 1; return config; }"] {
            do { _ = try clashScriptContents(original, proxyGroup: "PROXY"); preconditionFailure("Unsupported script accepted") }
            catch ClashMergeError.unsupportedScript {}
        }
    }
    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("bento-clash-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func testManagedFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("Script.js"), merge = directory.appendingPathComponent("Merge.yaml")
        let userMerge = "# User merge\nipv6: false\nprepend-rules:\n  - DOMAIN,example.com,DIRECT\n"
        let legacy = userMerge + clashMergeBeginMarker + "\nprepend-rules:\n  - DOMAIN-SUFFIX,claude.ai,PROXY\n" + clashMergeEndMarker + "\n"
        try template.write(to: script, atomically: false, encoding: .utf8)
        try legacy.write(to: merge, atomically: false, encoding: .utf8)
        precondition(chmod(script.path, 0o640) == 0)
        var before = stat(); precondition(lstat(script.path, &before) == 0)
        let manager = ClashMergeManager(profileDirectories: { [directory.path] })
        try manager.install(proxyGroup: "PROXY")
        let installed = try String(contentsOf: script, encoding: .utf8)
        let migrated = try String(contentsOf: merge, encoding: .utf8)
        precondition(installed.contains(clashScriptBeginMarker) && migrated == userMerge)
        var after = stat(); precondition(lstat(script.path, &after) == 0)
        precondition(before.st_mode == after.st_mode && before.st_uid == after.st_uid && before.st_gid == after.st_gid)
        try manager.install(proxyGroup: "PROXY")
        var repeated = stat(); precondition(lstat(script.path, &repeated) == 0)
        precondition(after.st_ino == repeated.st_ino, "An unchanged file should not be rewritten")
        // A fresh manager must reconcile persistent state without a saved in-memory copy.
        try ClashMergeManager(profileDirectories: { [directory.path] }).remove()
        let restored = try Data(contentsOf: script)
        precondition(restored == Data(template.utf8))
        try manager.remove()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        precondition(remaining == ["Merge.yaml", "Script.js"])
        // Old versions may leave only Merge.yaml; off must still clean it.
        try FileManager.default.removeItem(at: script)
        try legacy.write(to: merge, atomically: false, encoding: .utf8)
        try manager.remove()
        let legacyCleaned = try String(contentsOf: merge, encoding: .utf8)
        precondition(legacyCleaned == userMerge)
    }
    static func testUnsafeFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("Script.js"), target = directory.appendingPathComponent("target")
        try template.write(to: target, atomically: false, encoding: .utf8)
        let manager = ClashMergeManager(profileDirectories: { [directory.path] })
        try FileManager.default.createSymbolicLink(at: script, withDestinationURL: target)
        do { try manager.install(proxyGroup: "PROXY"); preconditionFailure("Symlink accepted") }
        catch ClashMergeError.unsafeFile {}
        let unchanged = try String(contentsOf: target, encoding: .utf8)
        precondition(unchanged == template)
        try FileManager.default.removeItem(at: script)
        precondition(mkfifo(script.path, 0o600) == 0)
        do { try manager.install(proxyGroup: "PROXY"); preconditionFailure("FIFO accepted") }
        catch ClashMergeError.unsafeFile {}
        try FileManager.default.removeItem(at: script)
        try template.write(to: script, atomically: false, encoding: .utf8)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        do { try ClashMergeManager(profileDirectories: { [alias.path] }).install(proxyGroup: "PROXY"); preconditionFailure("Parent symlink accepted") }
        catch ClashMergeError.unsafeFile {}
        try Data(repeating: 32, count: 1_048_577).write(to: script)
        do { try manager.install(proxyGroup: "PROXY"); preconditionFailure("Oversized file accepted") }
        catch ClashMergeError.unsafeFile {}
        try template.write(to: script, atomically: false, encoding: .utf8)
        let changed = template + "\n// concurrent user edit\n"
        let racing = ClashMergeManager(readFile: { path in
            let original = try String(contentsOfFile: path, encoding: .utf8)
            try changed.write(toFile: path, atomically: false, encoding: .utf8)
            return original
        }, profileDirectories: { [directory.path] })
        do { try racing.install(proxyGroup: "PROXY"); preconditionFailure("Concurrent edit overwritten") }
        catch ClashMergeError.fileChanged {}
        let preserved = try String(contentsOf: script, encoding: .utf8)
        precondition(preserved == changed)
    }
}
