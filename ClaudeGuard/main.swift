import Darwin
import Foundation

let stateURL = URL(fileURLWithPath: "/Library/Application Support/Bento/ClaudeGuard/enabled")
let savedEnabled = (try? String(contentsOf: stateURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
let engine = ClaudeGuardEngine(enabled: savedEnabled, hosts: ClaudeGuardHostsFile(), flushDNS: claudeGuardFlushDNS)
let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let requirementURL = executableURL.deletingLastPathComponent().appendingPathComponent("ClaudeGuardClient.requirement")
let requirement = (try? String(contentsOf: requirementURL, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "identifier \"invalid.missing.bento.requirement\""
let service = ClaudeGuardService(engine: engine, probe: ClashProbe(), merge: ClashMergeManager(), stateURL: stateURL,
                                 authorizer: ClaudeGuardClientAuthorizer(requirement: requirement))
let listener = NSXPCListener(machServiceName: claudeGuardDaemonLabel)
let delegate = ClaudeGuardListener(service: service)
listener.delegate = delegate
listener.resume()
service.start()
withExtendedLifetime(delegate) { RunLoop.current.run() }
