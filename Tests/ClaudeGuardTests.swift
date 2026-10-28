import Darwin
import Foundation

final class MockHosts: ClaudeGuardHostsManaging {
    var contents = "127.0.0.1 localhost\n# keep this entry\n192.168.1.10 printer\n"
    var writes = 0
    var failure: Error?
    func setBlocked(_ blocked: Bool) throws -> Bool {
        if let failure { throw failure }
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
        testDNSFlushRetry()
        try testEnableFailures()
        testServiceRestart()
        try testAtomicHostsAndFailure()
        try testMerge()
        testClashProbe()
        testKernelArguments()
        testProxySelection()
        testProcessDiagnostics()
        testDaemonTimer()
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
        let proxies = #"{"proxies":{"PROXY":{"type":"Selector","now":"node"},"node":{"type":"Shadowsocks"}}}"#
        precondition(ClashConfiguration.parse(yaml).proxyGroups == ["PROXY"])
        precondition(ClashProbe.rulesRouteToProxy(rules, groups: ["PROXY"]))
        var routeInterface = "utun1024"
        var ipv6Route: (status: Int32, output: String) = (0, "interface: utun1024\n")
        var runningConfigs = #"{"mode":"rule"}"#
        let probe = ClashProbe(run: { path, arguments, _ in
            if path == "/bin/ps" { return (0, "1710\n") }
            if arguments.contains("-inet6") { return ipv6Route }
            return (0, "  interface: \(routeInterface)\n")
        }, executablePath: { _ in "/Library/service/cores/verge-mihomo-alpha" },
           processArguments: { _ in ["/cores/verge-mihomo-alpha", "-f", "/Users/test/Library/Application Support/Clash/config.yaml", "-ext-ctl-unix", "/tmp/clash.sock"] },
           readFile: { path in
               precondition(path == "/Users/test/Library/Application Support/Clash/config.yaml", "Real argv must preserve spaces in config paths")
               return yaml
           }, activeInterface: { $0 == "utun1024" },
           request: { _, _, path in
               switch path {
               case "/version": return #"{"meta":true,"version":"test"}"#
               case "/configs": return runningConfigs
               case "/rules": return rules
               case "/proxies": return proxies
               default: preconditionFailure("Unexpected controller endpoint")
               }
           })
        do { try probe.check() } catch { preconditionFailure("Expected ready probe: \(error)") }
        precondition((try? probe.preferredProxyGroup()) == "PROXY")
        routeInterface = "en0"
        do {
            try probe.check()
            preconditionFailure("A physical default route must not count as Clash TUN")
        } catch ClashProbeError.routeUnavailable {} catch {
            preconditionFailure("Unexpected probe error: \(error)")
        }
        routeInterface = "utun1024"
        ipv6Route = (0, "interface: en0\n")
        do { try probe.check(); preconditionFailure("An IPv6 physical route must not count as protected") }
        catch ClashProbeError.routeUnavailable {} catch { preconditionFailure("Unexpected IPv6 probe error: \(error)") }
        ipv6Route = (71, "route: socket: Operation not permitted\n")
        do { try probe.check(); preconditionFailure("Unknown IPv6 route must stay blocked") }
        catch ClashProbeError.routeUnavailable {} catch { preconditionFailure("Unexpected IPv6 probe error: \(error)") }
        ipv6Route = (0, "route: writing to routing socket: not in table\n")
        do { try probe.check() } catch { preconditionFailure("Explicit absent IPv6 route has no bypass: \(error)") }
        ipv6Route.status = 1
        do { try probe.check() } catch { preconditionFailure("An absent IPv6 route may return exit 1: \(error)") }
        ipv6Route.status = 9
        do { try probe.check(); preconditionFailure("A killed route probe cannot establish absent IPv6 routing") }
        catch ClashProbeError.routeUnavailable {} catch { preconditionFailure("Unexpected route timeout error: \(error)") }
        ipv6Route.status = 1
        for configs in [#"{"mode":"direct"}"#, #"{"mode":"global"}"#, #"{"mode":"unknown"}"#, #"{"mode":true}"#, "{}", "invalid JSON"] {
            runningConfigs = configs
            do { try probe.check(); preconditionFailure("Only live rule mode may use the verified Claude rules") }
            catch ClashProbeError.ruleModeRequired {} catch { preconditionFailure("Unexpected mode error: \(error)") }
        }
        runningConfigs = #"{"mode":"rule"}"#
        do { try probe.check() } catch { preconditionFailure("Returning to live rule mode must recover: \(error)") }
        precondition(!ClashProbe.rulesRouteToProxy(#"{"rules":[]}"#, groups: ["PROXY"]))
        let shadowedRules = rules.replacingOccurrences(of: "[{", with: "[{\"type\":\"Match\",\"payload\":\"\",\"proxy\":\"DIRECT\"},{")
        precondition(!ClashProbe.rulesRouteToProxy(shadowedRules, groups: ["PROXY"]), "Presence after an earlier MATCH is not protection")
    }

    static func testKernelArguments() {
        let arguments = ["/Library/core/mihomo", "-f", "/Users/test/Library/Application Support/Clash/config.yaml", "", "-ext-ctl-unix", "/tmp/clash socket"]
        var count = Int32(arguments.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(Data("/Library/core/mihomo\0\0\0".utf8))
        data.append(Data((arguments.joined(separator: "\0") + "\0SECRET_ENV=not-an-argument\0").utf8))
        precondition(ClashProbe.parseKernelArguments(data) == arguments)
        precondition(ClashProbe.parseKernelArguments(Data()) == nil)
        precondition(ClashProbe.parseKernelArguments(data.prefix(10)) == nil)
        precondition(ClashProbe.kernelArguments(getpid()) == CommandLine.arguments, "Read genuine process argv without ps word splitting")
    }

    static func testProxySelection() {
        let safe = #"{"proxies":{"PROXY":{"type":"Selector","now":"auto"},"auto":{"type":"URLTest","now":"node"},"node":{"type":"Shadowsocks"},"DIRECT":{"type":"Direct"}}}"#
        precondition(ClashProbe.selectedProxyIsSafe(safe, group: "PROXY"))
        precondition(!ClashProbe.selectedProxyIsSafe(safe.replacingOccurrences(of: "\"now\":\"node\"", with: "\"now\":\"DIRECT\""), group: "PROXY"))
        precondition(!ClashProbe.selectedProxyIsSafe(safe.replacingOccurrences(of: "\"now\":\"node\"", with: "\"now\":\"PROXY\""), group: "PROXY"))
        precondition(!ClashProbe.selectedProxyIsSafe(safe.replacingOccurrences(of: "Shadowsocks", with: "unknown"), group: "PROXY"))
        precondition(!ClashProbe.selectedProxyIsSafe(#"{"proxies":{"PROXY":{"type":"LoadBalance","all":[]}}}"#, group: "PROXY"))
        precondition(!ClashProbe.selectedProxyIsSafe("{}", group: "PROXY"))
    }

    static func testDaemonTimer() {
        let polls = DispatchSemaphore(value: 0)
        let probe = ClashProbe(run: { _, _, _ in polls.signal(); return (0, "") })
        let service = ClaudeGuardService(engine: ClaudeGuardEngine(enabled: true, hosts: MockHosts(), flushDNS: {}),
            probe: probe, merge: ClashMergeManager(fileExists: { _ in false }),
            stateURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        service.start()
        let started = DispatchSemaphore(value: 0)
        service.getStatus { _ in started.signal() }
        precondition(started.wait(timeout: .now() + 2) == .success)
        // The status reply is a queue barrier after all startup work. Drain those
        // polls so this assertion cannot pass just because startup probes twice.
        while polls.wait(timeout: .now()) == .success {}
        precondition(polls.wait(timeout: .now() + 2) == .success, "Daemon must keep polling after start returns")
        withExtendedLifetime(service) {}
    }

    static func testProcessDiagnostics() {
        let arguments = ["-c", "printf 'route: writing to routing socket: not in table\\n' >&2; exit 1"]
        let defaultResult = claudeGuardRunProcess("/bin/sh", arguments)
        precondition(defaultResult.status == 1 && defaultResult.output.isEmpty)
        let captured = claudeGuardRunProcess("/bin/sh", arguments, captureStandardError: true)
        precondition(captured.status == 1 && captured.output == "route: writing to routing socket: not in table\n",
                     "Route diagnostics must be captured from stderr to distinguish absent IPv6 routes from probe failure")
    }

    static func testDNSFlushRetry() {
        let hosts = MockHosts()
        var attempts = 0, shouldFail = true
        let engine = ClaudeGuardEngine(enabled: true, hosts: hosts) {
            attempts += 1
            if shouldFail { throw NSError(domain: "test", code: 1) }
        }
        engine.refresh(clashReady: false)
        precondition(engine.configurationError != nil && hosts.writes == 1 && attempts == 1)
        shouldFail = false
        engine.refresh(clashReady: false)
        precondition(engine.configurationError == nil && hosts.writes == 1 && attempts == 2,
                     "A failed DNS flush must retry even when hosts already contains the block")
        shouldFail = true
        engine.refresh(clashReady: true)
        precondition(!engine.ready && engine.configurationError != nil && hosts.writes == 2)
        shouldFail = false
        engine.refresh(clashReady: true)
        precondition(engine.ready && attempts == 4 && hosts.writes == 2,
                     "Recovery cannot claim ready until its pending DNS flush succeeds")
    }

    static func operationReply(_ operation: (@escaping (NSString?) -> Void) -> Void) -> NSString? {
        let completed = DispatchSemaphore(value: 0)
        var error: NSString?
        operation { error = $0; completed.signal() }
        precondition(completed.wait(timeout: .now() + 2) == .success, "Service callback must complete")
        return error
    }

    static func testEnableFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hosts = MockHosts()
        let service = ClaudeGuardService(engine: ClaudeGuardEngine(enabled: false, hosts: hosts, flushDNS: {}),
            probe: ClashProbe(run: { _, _, _ in (0, "") }), merge: ClashMergeManager(fileExists: { _ in false }),
            stateURL: directory.appendingPathComponent("enabled"))
        precondition(operationReply { service.setEnabled(true, withReply: $0) } != nil,
                     "Failure to maintain Merge must be returned by on, not only in later status")
        precondition(hosts.contents.contains(claudeGuardBeginMarker), "Configuration failure keeps hosts blocked")
        let hostsError = NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "injected hosts failure"])
        hosts.failure = hostsError
        let error = operationReply { service.setEnabled(true, withReply: $0) }
        precondition(error == hostsError.localizedDescription as NSString,
                     "A hosts failure must be returned even when the requested enabled state is already true")
    }

    static func testServiceRestart() {
        let hosts = MockHosts()
        let engine = ClaudeGuardEngine(enabled: true, hosts: hosts, flushDNS: {})
        engine.refresh(clashReady: true)
        let terminated = DispatchSemaphore(value: 0), polled = DispatchSemaphore(value: 0)
        let service = ClaudeGuardService(engine: engine,
            probe: ClashProbe(run: { _, _, _ in polled.signal(); return (0, "") }),
            merge: ClashMergeManager(fileExists: { _ in false }),
            stateURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            terminateForRestart: { terminated.signal() })
        precondition(operationReply { service.restart(withReply: $0) } == nil)
        precondition(!engine.ready && hosts.contents.contains(claudeGuardBeginMarker),
                     "An enabled daemon must block hosts before acknowledging restart")
        precondition(operationReply { service.restart(withReply: $0) } == nil)
        precondition(operationReply { service.cleanup(withReply: $0) } != nil)
        precondition(operationReply { service.setEnabled(false, withReply: $0) } != nil)
        precondition(operationReply { service.setEnabled(true, withReply: $0) } != nil)
        service.start()
        let statusRead = DispatchSemaphore(value: 0)
        service.getStatus { status in
            precondition(status["restarting"] as? Bool == true)
            statusRead.signal()
        }
        precondition(statusRead.wait(timeout: .now() + 2) == .success)
        precondition(polled.wait(timeout: .now()) == .timedOut, "A pending restart cannot resume maintenance")
        precondition(terminated.wait(timeout: .now() + 2) == .success)
        precondition(terminated.wait(timeout: .now() + 0.3) == .timedOut, "Repeated restart must schedule exactly one exit")
        precondition(hosts.contents.contains(claudeGuardBeginMarker))

        let failingHosts = MockHosts(), failedTermination = DispatchSemaphore(value: 0)
        failingHosts.failure = NSError(domain: "test", code: 3)
        let failingService = ClaudeGuardService(
            engine: ClaudeGuardEngine(enabled: true, hosts: failingHosts, flushDNS: {}),
            probe: ClashProbe(run: { _, _, _ in (0, "") }), merge: ClashMergeManager(fileExists: { _ in false }),
            stateURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            terminateForRestart: { failedTermination.signal() })
        precondition(operationReply { failingService.restart(withReply: $0) } != nil)
        precondition(failedTermination.wait(timeout: .now() + 0.3) == .timedOut,
                     "A failed pre-restart block must keep the current daemon alive")
        failingHosts.failure = nil
        precondition(operationReply { failingService.restart(withReply: $0) } == nil)
        precondition(failedTermination.wait(timeout: .now() + 2) == .success)
    }

    static func testClientRejection() {
        let connection = NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
        precondition(!ClaudeGuardClientAuthorizer(requirement: "invalid requirement ???").configure(connection))
        precondition(!ClaudeGuardClientAuthorizer(requirement: nil).configure(connection))
    }
}
