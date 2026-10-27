import Darwin
import Foundation

final class MockHosts: ClaudeGuardHostsManaging {
    var contents = "127.0.0.1 localhost\n# keep this entry\n192.168.1.10 printer\n"
    var writes = 0
    func setBlocked(_ blocked: Bool) throws -> Bool {
        let updated = try claudeGuardHostsContents(contents, blocked: blocked)
        guard updated != contents else { return false }
        contents = updated
        writes += 1
        return true
    }
}

@main
struct ClaudeGuardTests {
    static func main() throws {
        try testStateTransitionsAndRestart()
        try testAtomicHostsAndFailure()
        try testMerge()
        testClashProbe()
        testClientRejection()
        print("PASS: Claude guard state, hosts atomicity, Clash probe, Merge and client rejection")
    }

    static func testStateTransitionsAndRestart() throws {
        let hosts = MockHosts()
        var flushes = 0
        let engine = ClaudeGuardEngine(enabled: false, hosts: hosts) { flushes += 1 }
        try engine.setEnabled(true)
        engine.refresh(clashReady: false)
        precondition(hosts.contents.contains(claudeGuardBeginMarker))
        precondition(hosts.contents.contains("127.0.0.1 api.anthropic.com"))
        precondition(hosts.contents.contains("::1 platform.claude.com"))
        precondition(hosts.contents.contains("192.168.1.10 printer"))
        precondition(hosts.writes == 1 && flushes == 1)
        try engine.setEnabled(true)
        engine.refresh(clashReady: false)
        precondition(hosts.writes == 1 && flushes == 1, "Repeated enable must be idempotent")
        precondition(hosts.contents.components(separatedBy: claudeGuardBeginMarker).count == 2)

        engine.refresh(clashReady: true)
        precondition(!hosts.contents.contains(claudeGuardBeginMarker))
        precondition(hosts.contents.contains("192.168.1.10 printer"))
        precondition(hosts.writes == 2 && flushes == 2)
        engine.refresh(clashReady: false)
        let restarted = ClaudeGuardEngine(enabled: true, hosts: hosts) { flushes += 1 }
        restarted.refresh(clashReady: false)
        precondition(hosts.writes == 3 && flushes == 3, "Daemon restart must not rewrite an unchanged block")
        restarted.refresh(clashReady: true)
        try restarted.setEnabled(false)
        precondition(!hosts.contents.contains(claudeGuardBeginMarker))
        precondition(hosts.contents == "127.0.0.1 localhost\n# keep this entry\n192.168.1.10 printer\n")
        precondition(flushes == 4, "Already-clean hosts must not trigger a DNS flush")
    }

    static func testAtomicHostsAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hosts")
        let original = "127.0.0.1 localhost\n10.0.0.8 untouched\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o640)
        let store = ClaudeGuardHostsFile(path: file.path)
        let firstWrite = try store.setBlocked(true)
        let repeatedWrite = try store.setBlocked(true)
        precondition(firstWrite)
        precondition(!repeatedWrite)
        var info = stat()
        precondition(stat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o640)
        let cleanupWrite = try store.setBlocked(false)
        precondition(cleanupWrite)
        let restored = try String(contentsOf: file, encoding: .utf8)
        precondition(restored == original)

        let failing = ClaudeGuardHostsFile(path: file.path, renameFile: { _, _ in -1 })
        do {
            _ = try failing.setBlocked(true)
            preconditionFailure("Injected rename failure must throw")
        } catch {}
        let afterFailure = try String(contentsOf: file, encoding: .utf8)
        precondition(afterFailure == original)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(temporaryFiles == ["hosts"], "Failed atomic write must remove its temporary file")
    }

    static func testMerge() throws {
        let original = "# user merge\nipv6: false\n"
        let enabled = try clashMergeContents(original, proxyGroup: "PROXY")
        precondition(enabled.contains("DOMAIN-SUFFIX,anthropic.com,PROXY"))
        let repeated = try clashMergeContents(enabled, proxyGroup: "PROXY")
        let removed = try clashMergeContents(enabled, proxyGroup: nil)
        precondition(repeated == enabled)
        precondition(removed == original)
        do {
            _ = try clashMergeContents("prepend-rules:\n  - DOMAIN,example.com,DIRECT\n", proxyGroup: "PROXY")
            preconditionFailure("Existing prepend-rules must not be overwritten")
        } catch ClashMergeError.existingPrependRules {}
    }

    static func testClashProbe() {
        let yaml = """
        external-controller-unix: /tmp/clash.sock
        tun:
          enable: true
          auto-route: true
          device: utun1024
        proxy-groups:
          - name: PROXY
            type: select
        """
        let rules = #"{"rules":[{"type":"DomainSuffix","payload":"claude.ai","proxy":"PROXY"},{"type":"DomainSuffix","payload":"claude.com","proxy":"PROXY"},{"type":"DomainSuffix","payload":"claudeusercontent.com","proxy":"PROXY"},{"type":"DomainSuffix","payload":"claudemcpcontent.com","proxy":"PROXY"},{"type":"DomainSuffix","payload":"anthropic.com","proxy":"PROXY"}]}"#
        precondition(ClashConfiguration.parse(yaml).proxyGroups == ["PROXY"])
        precondition(ClashProbe.rulesRouteToProxy(rules, groups: ["PROXY"]))
        var routeInterface = "utun1024"
        let probe = ClashProbe(run: { path, _, _ in
            if path == "/bin/ps" { return (0, "1710 /cores/verge-mihomo-alpha -d /tmp -f /tmp/config.yaml -ext-ctl-unix /tmp/clash.sock\n") }
            return (0, "  interface: \(routeInterface)\n")
        }, executablePath: { _ in "/Library/service/cores/verge-mihomo-alpha" },
           readFile: { _ in yaml }, activeInterface: { $0 == "utun1024" },
           request: { _, _, path in path == "/version" ? #"{"meta":true,"version":"test"}"# : rules })
        do { try probe.check() } catch { preconditionFailure("Expected ready probe: \(error)") }
        precondition((try? probe.preferredProxyGroup()) == "PROXY")
        routeInterface = "en0"
        do {
            try probe.check()
            preconditionFailure("A physical default route must not count as Clash TUN")
        } catch ClashProbeError.routeUnavailable {} catch {
            preconditionFailure("Unexpected probe error: \(error)")
        }
        precondition(!ClashProbe.rulesRouteToProxy(#"{"rules":[]}"#, groups: ["PROXY"]))
    }

    static func testClientRejection() {
        let authorizer = ClaudeGuardClientAuthorizer(requirement: #"identifier "com.sz.bento""#)
        precondition(!authorizer.authorize(token: Data()))
        precondition(!authorizer.authorize(token: Data(repeating: 0, count: MemoryLayout<audit_token_t>.size)))
    }
}
