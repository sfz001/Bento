import AppKit
import CoreGraphics
import Foundation
import IOKit

// MARK: - Scroll Reverser

private let prefReverseMouse = "ReverseMouseScroll"
private let prefReverseTrackpad = "ReverseTrackpadScroll"
private let gestureEventType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue))!
private let recentTouchWindowNs: UInt64 = 222_000_000
private let staleTouchWindowNs: UInt64 = 333_000_000
private let ioHIDEventFieldScrollX: UInt32 = 6 << 16
private let ioHIDEventFieldScrollY: UInt32 = (6 << 16) + 1

@_silgen_name("CGEventCopyIOHIDEvent")
private func CGEventCopyIOHIDEvent(_ event: CGEvent) -> UnsafeMutableRawPointer?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: UnsafeMutableRawPointer, _ field: UInt32) -> Double

@_silgen_name("IOHIDEventSetFloatValue")
private func IOHIDEventSetFloatValue(_ event: UnsafeMutableRawPointer, _ field: UInt32, _ value: Double)

private enum ScrollInputSource {
    case mouse
    case trackpad
}

private func nowNs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func reverseScrollDeltas(_ event: CGEvent) {
    let d1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    let d2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
    let d3 = event.getIntegerValueField(.scrollWheelEventDeltaAxis3)
    let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
    let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    let p3 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3)
    let f1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    let f2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
    let f3 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3)
    let hidEvent = CGEventCopyIOHIDEvent(event)
    let hidX = hidEvent.map { IOHIDEventGetFloatValue($0, ioHIDEventFieldScrollX) } ?? 0
    let hidY = hidEvent.map { IOHIDEventGetFloatValue($0, ioHIDEventFieldScrollY) } ?? 0

    // 0 &- x 而非 -x：这是 session tap，任何本地进程都能投递 delta = Int64.min
    // 的合成滚轮事件，一元取负直接溢出 trap；&- 对 .min 取负仍是 .min，滚动怪但不崩
    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0 &- d1)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0 &- d2)
    event.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: 0 &- d3)

    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -f1)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -f2)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis3, value: -f3)

    // Set point deltas last; setting line deltas can cause macOS to recalculate them.
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0 &- p1)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0 &- p2)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: 0 &- p3)

    if let hidEvent = hidEvent {
        IOHIDEventSetFloatValue(hidEvent, ioHIDEventFieldScrollX, -hidX)
        IOHIDEventSetFloatValue(hidEvent, ioHIDEventFieldScrollY, -hidY)
        Unmanaged<AnyObject>.fromOpaque(hidEvent).release()
    }
}

private func scrollEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            Unmanaged<ScrollReverser>.fromOpaque(userInfo).takeUnretainedValue().reenableTap()
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let reverser = Unmanaged<ScrollReverser>.fromOpaque(userInfo).takeUnretainedValue()

    if type == gestureEventType {
        reverser.noteGesture(event)
        return Unmanaged.passUnretained(event)
    }

    guard type == .scrollWheel else {
        return Unmanaged.passUnretained(event)
    }

    let source = reverser.source(forScroll: event)
    let shouldReverse = source == .trackpad ? reverser.reverseTrackpad : reverser.reverseMouse

    if shouldReverse {
        reverseScrollDeltas(event)
    }

    return Unmanaged.passUnretained(event)
}

class ScrollReverser {
    private var activeTap: CFMachPort?
    private var activeRunLoopSource: CFRunLoopSource?
    private var touching = 0
    private var lastTouchTime: UInt64 = 0
    private var lastSource: ScrollInputSource = .mouse

    // Cached so the per-scroll-event tap callback never touches UserDefaults.
    private var cachedReverseMouse = UserDefaults.standard.object(forKey: prefReverseMouse) as? Bool ?? true
    private var cachedReverseTrackpad = UserDefaults.standard.object(forKey: prefReverseTrackpad) as? Bool ?? false

    var reverseMouse: Bool {
        get { cachedReverseMouse }
        set {
            cachedReverseMouse = newValue
            UserDefaults.standard.set(newValue, forKey: prefReverseMouse)
        }
    }

    private var selfHealingInstalled = false
    private var watchdog: Timer?

    /// 唤醒后自愈重建失败时回调（主线程）。start() 开头会先 stop() 拆掉旧 tap，
    /// 重建再失败就等于滚动反转彻底停摆 —— 不上报的话菜单还显示一切正常，
    /// 用户只会觉得"某次睡醒后滚动方向莫名其妙变回去了"
    var onTapRebuildFailed: (() -> Void)?

    var reverseTrackpad: Bool {
        get { cachedReverseTrackpad }
        set {
            cachedReverseTrackpad = newValue
            UserDefaults.standard.set(newValue, forKey: prefReverseTrackpad)
        }
    }

    /// Returns true if the event taps were created. Returns false when the user
    /// still needs to grant Accessibility/Input Monitoring permission and relaunch.
    func start() -> Bool {
        stop()
        touching = 0
        lastTouchTime = 0
        lastSource = .mouse

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

        let scrollMask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        let gestureMask: CGEventMask = 1 << gestureEventType.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let active = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: scrollMask | gestureMask,
            callback: scrollEventCallback,
            userInfo: userInfo
        ) else {
            NSLog("ScrollReverser: event tap creation failed (trusted=\(trusted))")
            return false
        }

        let activeSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, active, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), activeSrc, .commonModes)
        CGEvent.tapEnable(tap: active, enable: true)

        activeTap = active
        activeRunLoopSource = activeSrc
        installSelfHealing()
        NSLog("ScrollReverser: taps installed (mouseRev=\(reverseMouse), trackpadRev=\(reverseTrackpad))")
        return true
    }

    /// 睡醒/会话切回后 tap 可能被系统拆掉或禁用且不再来事件——加观察者重建 + 看门狗兜底。
    /// TilingController 有同款防护；此前 ScrollReverser 失效只能靠用户手动“重新检测”。
    private func installSelfHealing() {
        guard !selfHealingInstalled else { return }
        selfHealingInstalled = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.activeTap != nil else { return }
                NSLog("ScrollReverser: rebuilding tap after wake/session-active")
                if !self.start() {
                    ErrorLog.log("滚动反转: 唤醒后重建 event tap 失败，功能已停用")
                    self.onTapRebuildFailed?()
                }
            }
        }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.activeTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("ScrollReverser: watchdog found tap disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    func stop() {
        if let tap = activeTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = activeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        activeTap = nil
        activeRunLoopSource = nil
    }

    func reenableTap() {
        if let tap = activeTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        NSLog("ScrollReverser: tap re-enabled after disable")
    }

    func noteGesture(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let currentTouching = nsEvent.touches(matching: .touching, in: nil).count
        guard currentTouching >= 2 else { return }
        touching = max(touching, currentTouching)
        lastTouchTime = nowNs()
    }

    fileprivate func source(forScroll event: CGEvent) -> ScrollInputSource {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let detectedTouching = touching
        let elapsed = lastTouchTime == 0 ? UInt64.max : nowNs() &- lastTouchTime
        touching = 0

        if !continuous {
            lastSource = .mouse
            return .mouse
        }

        if detectedTouching >= 2 && elapsed < recentTouchWindowNs {
            lastSource = .trackpad
            return .trackpad
        }

        if let nsEvent = NSEvent(cgEvent: event), nsEvent.momentumPhase.isEmpty, elapsed > staleTouchWindowNs {
            lastSource = .mouse
            return .mouse
        }

        return lastSource
    }
}
