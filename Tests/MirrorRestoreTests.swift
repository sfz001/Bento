import AppKit
import CoreGraphics
import Foundation

// Compile with ScreenController.swift only. These module-local substitutes keep
// tests from changing real displays, launching processes, or writing Bento logs.
private enum Displays {
    static var asleep = false
    static var mirrored = true
    static var configError = CGError.success
    static var completeError = CGError.success
    static var applyChanges = true
    static var failReadAfterCommit = false
    static var configured: [CGDirectDisplayID] = []
    static var commits = 0
    static let snapshotKey = "BentoMirrorSnapshot"

    static func reset(preMirrored: Bool = false) {
        asleep = false
        mirrored = true
        configError = .success
        completeError = .success
        applyChanges = true
        failReadAfterCommit = false
        configured = []
        commits = 0
        let snapshot = "{\"entries\":[{\"displayID\":2,\"mirrorsDisplayID\":0}],\"preMirrored\":\(preMirrored ? "[2]" : "[]")}"
        UserDefaults.standard.set(Data(snapshot.utf8), forKey: snapshotKey)
    }
}

func CGGetOnlineDisplayList(_ max: UInt32, _ displays: inout [CGDirectDisplayID], _ count: inout UInt32) -> CGError {
    if Displays.failReadAfterCommit && Displays.commits > 0 { return .failure }
    displays[0] = 1
    displays[1] = 2
    count = 2
    return .success
}
func CGMainDisplayID() -> CGDirectDisplayID { 1 }
func CGDisplayIsActive(_ display: CGDirectDisplayID) -> boolean_t {
    // Hardware mirror follower is awake but inactive: the reported regression.
    Displays.asleep || (display == 2 && Displays.mirrored) ? 0 : 1
}
func CGDisplayIsAsleep(_ display: CGDirectDisplayID) -> boolean_t { Displays.asleep ? 1 : 0 }
func CGDisplayIsInMirrorSet(_ display: CGDirectDisplayID) -> boolean_t { Displays.mirrored ? 1 : 0 }
func CGDisplayMirrorsDisplay(_ display: CGDirectDisplayID) -> CGDirectDisplayID { 0 }
func CGBeginDisplayConfiguration(_ config: inout CGDisplayConfigRef?) -> CGError {
    config = OpaquePointer(bitPattern: 1)
    return .success
}
func CGConfigureDisplayMirrorOfDisplay(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ target: CGDirectDisplayID) -> CGError {
    precondition(target == kCGNullDirectDisplay)
    Displays.configured.append(display)
    return Displays.configError
}
@discardableResult
func CGCancelDisplayConfiguration(_ config: CGDisplayConfigRef?) -> CGError { .success }
func CGCompleteDisplayConfiguration(_ config: CGDisplayConfigRef?, _ option: CGConfigureOption) -> CGError {
    Displays.commits += 1
    if Displays.completeError == .success && Displays.applyChanges { Displays.mirrored = false }
    return Displays.completeError
}
enum ErrorLog { static func log(_ message: String) {} }
enum DisplayKeys { static func uuid(for display: CGDirectDisplayID) -> String { "test-\(display)" } }
@discardableResult
func runProcess(_ path: String, _ args: [String], captureOutput: Bool = false, timeout: TimeInterval = 10) -> (status: Int32, output: String) {
    fatalError("Unexpected process launch in mirror test")
}

private final class RestoreOrderSpy: ScreenController {
    var operations: [String] = []
    override func disableMirroring(forceFallback: Bool = false) { operations.append("mirror") }
    override func restoreResolution() { operations.append("resolution") }
}

@main
struct MirrorRestoreTests {
    static func main() {
        defer { UserDefaults.standard.removeObject(forKey: Displays.snapshotKey) }

        Displays.reset()
        let manual = ScreenController()
        precondition(manual.restoreExtendedDisplays() == nil, "Awake inactive mirror must be restorable")
        precondition(Displays.configured == [2] && Displays.commits == 1)
        precondition(!manual.hasPendingMirrorRestore)

        Displays.reset()
        let automatic = ScreenController()
        automatic.disableMirroring()
        precondition(!Displays.mirrored && !automatic.hasPendingMirrorRestore)

        Displays.reset()
        Displays.asleep = true
        let sleeping = ScreenController()
        precondition(sleeping.restoreExtendedDisplays() != nil)
        sleeping.disableMirroring()
        precondition(Displays.configured.isEmpty && sleeping.hasPendingMirrorRestore)
        Displays.asleep = false
        sleeping.disableMirroring()
        precondition(!Displays.mirrored && !sleeping.hasPendingMirrorRestore)

        Displays.reset()
        Displays.configError = .failure
        let configureFailure = ScreenController()
        precondition(configureFailure.restoreExtendedDisplays() != nil)
        precondition(Displays.commits == 0 && configureFailure.hasPendingMirrorRestore)

        Displays.reset()
        Displays.completeError = .failure
        let commitFailure = ScreenController()
        precondition(commitFailure.restoreExtendedDisplays() != nil)
        precondition(Displays.mirrored && commitFailure.hasPendingMirrorRestore)

        Displays.reset()
        Displays.applyChanges = false
        let unapplied = ScreenController()
        precondition(unapplied.restoreExtendedDisplays() != nil)
        precondition(unapplied.hasPendingMirrorRestore)

        Displays.reset()
        Displays.failReadAfterCommit = true
        let readFailure = ScreenController()
        precondition(readFailure.restoreExtendedDisplays() != nil)
        precondition(readFailure.hasPendingMirrorRestore)

        Displays.reset(preMirrored: true)
        let preexisting = ScreenController()
        preexisting.disableMirroring()
        precondition(Displays.mirrored && Displays.configured.isEmpty)
        precondition(preexisting.restoreExtendedDisplays() == nil)
        precondition(!Displays.mirrored)

        precondition(preexisting.restoreExtendedDisplays() == nil)
        precondition(Displays.commits == 1, "Already extended must be a no-op")
        let order = RestoreOrderSpy()
        order.restoreDisplaySettings()
        precondition(order.operations == ["mirror", "resolution"])

        Displays.reset()
        let resolutionKey = "BentoDisplayModeSnapshot"
        let resolution = Data("{\"width\":1704,\"height\":959,\"pixelWidth\":3408,\"pixelHeight\":1918,\"refreshRate\":60,\"displayUUID\":\"test-1\"}".utf8)
        UserDefaults.standard.set(resolution, forKey: resolutionKey)
        ScreenController().restoreResolution()
        precondition(UserDefaults.standard.data(forKey: resolutionKey) == resolution,
                     "Mirrored display must retain original resolution snapshot")
        UserDefaults.standard.removeObject(forKey: resolutionKey)
        print("PASS: 11 mirror/display restore regression scenarios")
    }
}
