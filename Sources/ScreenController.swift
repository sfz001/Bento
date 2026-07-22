import AppKit
import CoreGraphics
import Foundation
import IOKit

// MARK: - Screen Control

class ScreenController {
    private var isBlack = false
    private let mirrorSnapshotDefaultsKey = "BentoMirrorSnapshot"
    private var savedMirrorTargets: [CGDirectDisplayID: CGDirectDisplayID]?

    private struct MirrorSnapshot: Codable {
        let entries: [MirrorSnapshotEntry]
    }

    private struct MirrorSnapshotEntry: Codable {
        let displayID: UInt32
        let mirrorsDisplayID: UInt32
    }

    func enableMirroring() {
        let displays = onlineDisplays()
        let main = CGMainDisplayID()
        guard displays.count > 1 else { return }

        let hadSnapshot = hasMirrorSnapshot()
        if !hadSnapshot {
            let snapshot = currentMirrorTargets(for: displays, main: main)
            saveMirrorSnapshot(snapshot)
            NSLog("Mirroring: saved pre-remote snapshot for \(snapshot.count) display(s)")
        }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)

        var mirrored: [CGDirectDisplayID] = []
        for d in displays where d != main {
            if CGDisplayMirrorsDisplay(d) != main {
                CGConfigureDisplayMirrorOfDisplay(config, d, main)
                mirrored.append(d)
            }
        }

        if mirrored.isEmpty {
            CGCancelDisplayConfiguration(config)
            return
        }

        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err == .success {
            NSLog("Mirroring enabled for \(mirrored.count) display(s)")
        } else {
            if !hadSnapshot {
                clearMirrorSnapshot()
            }
            NSLog("Mirroring enable failed with error \(err.rawValue)")
        }
    }

    func disableMirroring(forceFallback: Bool = false) {
        guard let snapshot = loadMirrorSnapshot() else {
            if forceFallback {
                restoreExtendedDisplays()
            }
            return
        }

        restoreMirrorTargets(snapshot)
    }

    func restoreExtendedDisplays() {
        let displays = onlineDisplays()
        guard displays.count > 1 else {
            clearMirrorSnapshot()
            return
        }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)

        var restored: [CGDirectDisplayID] = []
        for d in displays where CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay {
            CGConfigureDisplayMirrorOfDisplay(config, d, kCGNullDirectDisplay)
            restored.append(d)
        }

        guard !restored.isEmpty else {
            CGCancelDisplayConfiguration(config)
            clearMirrorSnapshot()
            NSLog("Mirroring already disabled")
            return
        }

        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err == .success {
            clearMirrorSnapshot()
            NSLog("Mirroring force-disabled for \(restored.count) display(s)")
        } else {
            NSLog("Mirroring force-disable failed with error \(err.rawValue)")
        }
    }

    private func restoreMirrorTargets(_ targets: [CGDirectDisplayID: CGDirectDisplayID]) {
        let displays = onlineDisplays()
        guard displays.count > 1 else {
            clearMirrorSnapshot()
            return
        }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)

        var restored: [CGDirectDisplayID] = []
        let onlineSet = Set(displays)
        for d in displays where d != CGMainDisplayID() {
            var desired = targets[d] ?? kCGNullDirectDisplay
            if desired != kCGNullDirectDisplay && !onlineSet.contains(desired) {
                desired = kCGNullDirectDisplay
            }
            guard CGDisplayMirrorsDisplay(d) != desired else { continue }

            CGConfigureDisplayMirrorOfDisplay(config, d, desired)
            restored.append(d)
        }

        guard !restored.isEmpty else {
            CGCancelDisplayConfiguration(config)
            clearMirrorSnapshot()
            NSLog("Mirroring restored from snapshot; no changes needed")
            return
        }

        let err = CGCompleteDisplayConfiguration(config, .forSession)
        if err == .success {
            clearMirrorSnapshot()
            NSLog("Mirroring restored from snapshot for \(restored.count) display(s)")
        } else {
            NSLog("Mirroring restore failed with error \(err.rawValue)")
        }
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let err = CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count)
        guard err == .success else {
            NSLog("Display list read failed with error \(err.rawValue)")
            return []
        }
        return Array(displays.prefix(Int(count)))
    }

    private func currentMirrorTargets(
        for displays: [CGDirectDisplayID],
        main: CGDirectDisplayID
    ) -> [CGDirectDisplayID: CGDirectDisplayID] {
        var targets: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for d in displays where d != main {
            targets[d] = CGDisplayMirrorsDisplay(d)
        }
        return targets
    }

    private func hasMirrorSnapshot() -> Bool {
        savedMirrorTargets != nil || UserDefaults.standard.data(forKey: mirrorSnapshotDefaultsKey) != nil
    }

    private func saveMirrorSnapshot(_ targets: [CGDirectDisplayID: CGDirectDisplayID]) {
        let entries = targets.map {
            MirrorSnapshotEntry(displayID: $0.key, mirrorsDisplayID: $0.value)
        }
        let snapshot = MirrorSnapshot(entries: entries)
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: mirrorSnapshotDefaultsKey)
        }
        savedMirrorTargets = targets
    }

    private func loadMirrorSnapshot() -> [CGDirectDisplayID: CGDirectDisplayID]? {
        if let savedMirrorTargets {
            return savedMirrorTargets
        }
        guard let data = UserDefaults.standard.data(forKey: mirrorSnapshotDefaultsKey),
              let snapshot = try? JSONDecoder().decode(MirrorSnapshot.self, from: data) else {
            return nil
        }

        var targets: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for entry in snapshot.entries {
            targets[entry.displayID] = entry.mirrorsDisplayID
        }
        savedMirrorTargets = targets
        return targets
    }

    private func clearMirrorSnapshot() {
        savedMirrorTargets = nil
        UserDefaults.standard.removeObject(forKey: mirrorSnapshotDefaultsKey)
    }

    // MARK: Resolution

    private var savedMode: CGDisplayMode?
    private let targetWidth = 1512
    private let targetHeight = 982

    func switchResolution() {
        let main = CGMainDisplayID()
        let currentMode = CGDisplayCopyDisplayMode(main)

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(main, options) as? [CGDisplayMode] else { return }

        let target = modes.first {
            $0.width == targetWidth && $0.height == targetHeight && $0.pixelWidth > $0.width
        }
        guard let mode = target else {
            NSLog("Resolution mode \(targetWidth)x\(targetHeight) HiDPI not found, skipping")
            return
        }

        let err = CGDisplaySetDisplayMode(main, mode, nil)
        if err == .success {
            savedMode = currentMode
            NSLog("Resolution switched to \(targetWidth)x\(targetHeight) HiDPI")
        } else {
            NSLog("Resolution switch failed with error \(err.rawValue)")
        }
    }

    func restoreResolution() {
        guard let mode = savedMode else { return }
        let main = CGMainDisplayID()
        let err = CGDisplaySetDisplayMode(main, mode, nil)
        if err == .success {
            NSLog("Resolution restored to \(mode.width)x\(mode.height)")
        }
        savedMode = nil
    }

    // MARK: Dock

    private var savedDockOrientation: String?
    private var savedDockAutohide: Bool?

    func saveDockAndSetLeft() {
        let orientation = runProcess("/usr/bin/defaults", ["read", "com.apple.dock", "orientation"], captureOutput: true).output
        savedDockOrientation = orientation.isEmpty ? "bottom" : orientation
        let autohide = runProcess("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"], captureOutput: true).output
        savedDockAutohide = (autohide == "1")

        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "orientation", "-string", "left"])
        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"])
        restartDock()
        NSLog("Dock set to left, autohide off (was: \(savedDockOrientation ?? "?"), autohide: \(savedDockAutohide == true))")
    }

    func restoreDock() {
        guard let orientation = savedDockOrientation, let autohide = savedDockAutohide else { return }
        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "orientation", "-string", orientation])
        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", autohide ? "true" : "false"])
        restartDock()
        NSLog("Dock restored to \(orientation), autohide: \(autohide)")
        savedDockOrientation = nil
        savedDockAutohide = nil
    }

    private func restartDock() {
        runProcess("/usr/bin/killall", ["Dock"])
    }

    // MARK: Gamma Black

    func setBlack() {
        guard !isBlack else { return }
        for d in onlineDisplays() {
            CGSetDisplayTransferByFormula(d, 0, 0, 1, 0, 0, 1, 0, 0, 1)
        }
        isBlack = true
    }

    func restore() {
        guard isBlack else { return }
        CGDisplayRestoreColorSyncSettings()
        isBlack = false
    }

    func lockScreen() {
        runProcess("/usr/bin/open", ["-a", "ScreenSaverEngine"])
    }

    var isScreenBlack: Bool { isBlack }
}
