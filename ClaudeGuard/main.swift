import Darwin
import Foundation

let stateURL = URL(fileURLWithPath: "/Library/Application Support/Bento/ClaudeGuard/enabled")
let savedEnabled = (try? String(contentsOf: stateURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
let engine = ClaudeGuardEngine(enabled: savedEnabled, hosts: ClaudeGuardHostsFile(), flushDNS: claudeGuardFlushDNS)
let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let requirementURL = executableURL.deletingLastPathComponent().appendingPathComponent("ClaudeGuardClient.requirement")
let packagedRequirement = (try? String(contentsOf: requirementURL, encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines)
let requirement = ClaudeGuardClientAuthorizer.trustedClientRequirement()
// This resource remains a build diagnostic; it cannot widen the root daemon's trust.
if packagedRequirement != requirement {
    FileHandle.standardError.write(Data("ClaudeGuard: packaged client requirement differs from daemon signing identity; using signed identity\n".utf8))
}
let service = ClaudeGuardService(engine: engine, probe: ClashProbe(), merge: ClashMergeManager(), stateURL: stateURL)
let listener = NSXPCListener(machServiceName: claudeGuardDaemonLabel)
let delegate = ClaudeGuardListener(service: service, authorizer: ClaudeGuardClientAuthorizer(requirement: requirement))
listener.delegate = delegate
listener.resume()
service.start()
withExtendedLifetime(delegate) { RunLoop.current.run() }
