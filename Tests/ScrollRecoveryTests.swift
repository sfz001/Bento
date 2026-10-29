import AppKit
import Foundation
import IOKit

@main
struct ScrollRecoveryTests {
    static func pump(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "Timed out waiting for silent scroll recovery")
    }

    static func main() {
        let granted = ScrollAccessSnapshot(accessibility: true, postEvent: true,
                                           listenEvent: kIOHIDAccessTypeDenied)
        let denied = ScrollAccessSnapshot(accessibility: false, postEvent: false,
                                          listenEvent: kIOHIDAccessTypeDenied)
        precondition(granted.failure(tapEnabled: false) == .eventTap,
                     "Tap failure with Accessibility/PostEvent must not say missing permission")
        precondition(denied.failure(tapEnabled: false) == .authorization)
        precondition(granted.failure(tapEnabled: true) == nil,
                     "A working modifying tap must clear failure even without ListenEvent")
        precondition(denied.failure(tapEnabled: true) == nil,
                     "Actual tap success takes precedence over a stale permission snapshot")

        var attempts = 0, prompts = 0, notifications = 0
        let reverser = ScrollReverser(readAccess: { granted }, requestAccess: { prompts += 1 },
            makeTap: { _, _, _ in attempts += 1; return nil }, retryInterval: 0.02)
        reverser.onStateChange = { notifications += 1 }
        precondition(!reverser.start(promptForPermissions: false))
        precondition(attempts == 1 && notifications == 1 && reverser.startupFailure == .eventTap)
        let firstTimer = reverser.testWatchdog
        precondition(firstTimer != nil && firstTimer!.isValid,
                     "An initial tap failure must still install the watchdog")
        precondition(!reverser.start(promptForPermissions: false))
        precondition(reverser.testWatchdog === firstTimer,
                     "Retrying must reuse the single watchdog")
        pump { attempts >= 3 }
        precondition(prompts == 0, "Automatic recovery must not request system permission")
        reverser.stop()
        let stoppedAttempts = attempts
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(attempts == stoppedAttempts && reverser.testWatchdog == nil)

        var access = denied
        var changedAttempts = 0
        let changed = ScrollReverser(readAccess: { access }, requestAccess: { prompts += 1 },
            makeTap: { _, _, _ in changedAttempts += 1; return nil }, retryInterval: 0.02)
        precondition(!changed.start(promptForPermissions: false))
        precondition(changed.startupFailure == .authorization && changedAttempts == 0)
        changed.refreshPermissions()
        precondition(changedAttempts == 0 && prompts == 0,
                     "Rechecking denied authorization must not request permission or create a tap")
        access = granted
        changed.refreshPermissions()
        precondition(changedAttempts == 1,
                     "Returning from settings must retry immediately, without waiting for the watchdog")
        precondition(changed.startupFailure == .eventTap && prompts == 0,
                     "New authorization must silently retry and replace the stale authorization error")
        changed.stop()
        changed.refreshPermissions()
        precondition(changedAttempts == 1,
                     "A settings notification after stop must not restart scroll handling")

        // Keep the unattended path covered as well as the immediate settings-return path.
        access = denied
        precondition(!changed.start(promptForPermissions: false))
        access = granted
        pump { changedAttempts > 1 }
        precondition(changed.startupFailure == .eventTap && prompts == 0,
                     "Authorization changes must recover through the watchdog without user interaction")
        changed.stop()

        precondition(!reverser.start())
        precondition(prompts == 1)
        let manualAttempts = attempts
        pump { attempts > manualAttempts }
        precondition(prompts == 1, "Only the explicit start may prompt")
        reverser.stop()
        print("PASS: scroll failure classification, initial-failure recovery, authorization changes, single watchdog and silent retries")
    }
}
