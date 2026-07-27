import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Sleep Guard (防止睡眠)
//
// 全部在 macOS 27.0 实测过的要点：
// - 必须 `import IOKit.pwr_mgt`，裸 `import IOKit` 拿不到任何 IOPMAssertion* 符号。
// - 断言类型/属性键在 Swift 里是 String（不是 CFString），进 [String: Any] 可直接用。
// - 只建一条断言：单独建 PreventUserIdleDisplaySleep 时系统 idle sleep 也一并被挡住，
//   再叠一条 PreventUserIdleSystemSleep 纯属浪费。
// - 绝不用 kIOPMAssertionTypePreventSystemSleep：SDK 头文件标注 "not supported"，实测无效。
// - 硬期限交给 powerd（TimeoutSeconds + TimeoutActionRelease），进程卡死/被 SIGKILL 也会到点释放。
//   TimeoutAction 必须是 Release：TurnOff/Log 到期后 CopyProperties 仍谎报 AssertLevel=255，程序测不出来。
// - 定时器一律 wallDeadline：DispatchTime/Timer 走 mach 单调钟，睡眠期间冻结（本机实测两钟差 ~44 小时）。
// - AssertName 必须 ASCII，否则 `pmset -g assertions` 渲染成 named: ""。
// - 进程退出（含 abort/SIGKILL）时 powerd 自动回收断言，不会泄漏 —— 所以没有 prepareForQuit。
//
// 线程约定：SleepGuard 内部无锁，所有可变入口（start/stop/reconcile/设置项 setter）
// 只允许在主线程调用。现有调用方全是菜单动作、.main 队列定时器、.main 队列通知观察者。

private let prefMode = "SleepGuardMode"
private let prefCustomMinutes = "SleepGuardCustomMinutes"
private let prefBatteryStop = "SleepGuardBatteryStopPercent"

/// 防睡模式
enum SleepGuardMode: String {
    /// 屏幕也不许睡（≈ caffeinate -d）
    case displayAndSystem
    /// 只防系统闲置睡眠，屏幕可自行熄灭（≈ caffeinate -i）
    case systemOnly

    var assertionType: String {
        switch self {
        case .displayAndSystem: return kIOPMAssertionTypePreventUserIdleDisplaySleep
        case .systemOnly: return kIOPMAssertionTypePreventUserIdleSystemSleep
        }
    }
}

final class SleepGuard {
    /// 「定时防睡」子菜单的预设
    static let timedPresets: [(title: String, minutes: Int)] = [
        ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240),
    ]
    static let batteryStopChoices = [0, 10, 20, 30]

    private(set) var isActive = false
    /// nil = 永久防睡
    private(set) var deadline: Date?
    /// 当前会话的时长，0 = 永久。菜单靠它给对应的预设打勾
    private(set) var sessionMinutes = 0
    /// 最近一次失败/自动停止的原因，成功开始时清空。设置窗口显示它——
    /// 主动操作没反应却查不到原因是最糟的体验
    private(set) var lastError: String?

    /// 状态变化回调（主线程）：刷新菜单/tooltip
    var onStateChange: (() -> Void)?

    private var assertionID = IOPMAssertionID(0)
    private var expiryTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?
    private var observersInstalled = false

    /// 永久防睡进行中
    var isPermanent: Bool { isActive && deadline == nil }

    // MARK: 设置项（UserDefaults 缓存模式，沿用 ScrollReverser 风格）
    //
    // 故意没有 SleepGuardEnabled：防睡状态不跨进程持久化。它是高显著性的临时状态
    // （你知道自己在开会/在渲染），重启后自动恢复「永久防睡」是个静默的电池杀手；
    // 而且断言在进程退出时被 powerd 回收，没有「恢复」的语义基础。

    private var cachedMode = SleepGuardMode(
        rawValue: UserDefaults.standard.string(forKey: prefMode) ?? "") ?? .displayAndSystem
    private var cachedCustomMinutes = SleepGuard.clampMinutes(
        UserDefaults.standard.object(forKey: prefCustomMinutes) as? Int ?? 90)
    private var cachedBatteryStop = SleepGuard.clampPercent(
        UserDefaults.standard.object(forKey: prefBatteryStop) as? Int ?? 0)

    private static func clampMinutes(_ v: Int) -> Int { max(1, min(24 * 60, v)) }
    private static func clampPercent(_ v: Int) -> Int { max(0, min(90, v)) }

    var mode: SleepGuardMode {
        get { cachedMode }
        set {
            guard newValue != cachedMode else { return }
            cachedMode = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: prefMode)
            // 断言类型不能原地改：正在防睡就按剩余时间重建
            if isActive { restart() }
        }
    }

    /// 「自定义…」用的分钟数，1…1440
    var customMinutes: Int {
        get { cachedCustomMinutes }
        set {
            let v = Self.clampMinutes(newValue)
            guard v != cachedCustomMinutes else { return }
            cachedCustomMinutes = v
            UserDefaults.standard.set(v, forKey: prefCustomMinutes)
            notifyChanged()
        }
    }

    var batteryStopPercent: Int {
        get { cachedBatteryStop }
        set {
            let v = Self.clampPercent(newValue)
            guard v != cachedBatteryStop else { return }
            cachedBatteryStop = v
            UserDefaults.standard.set(v, forKey: prefBatteryStop)
            // 立即生效：否则永久会话里最长要等 60s 才按新阈值判断
            if isActive {
                checkBattery()
                if isActive { scheduleTimers() }
            }
            notifyChanged()
        }
    }

    // MARK: 开 / 关（菜单两个入口）

    /// 「永久防睡」行：勾上 = 无限期，再点 = 停
    func togglePermanent() {
        if isPermanent { stop() } else { start(minutes: 0) }
    }

    /// 「定时防睡 ▸ N」：点已勾选的那项 = 停，否则按新时长重开
    func toggleTimed(minutes: Int) {
        if isActive, deadline != nil, sessionMinutes == minutes { stop() } else { start(minutes: minutes) }
    }

    /// minutes <= 0 表示永久
    func start(minutes: Int) {
        let m = minutes > 0 ? Self.clampMinutes(minutes) : 0
        startInternal(minutes: m, deadline: m > 0 ? Date().addingTimeInterval(TimeInterval(m) * 60) : nil)
    }

    func stop() { stopInternal(notify: true) }

    /// 换模式时保留剩余时间重建断言
    private func restart() {
        let keepDeadline = deadline
        let keepMinutes = sessionMinutes
        // 已过期就直接收工，否则会造出一个 1 秒断言、随即冒出「到期自动停止」日志。
        // 走 handleExpiry 而非 stop()：deadline 已过 = powerd 的超时释放多半已经
        // 发生，必须判活后再决定是否本地 Release（同 reconcile / 到期定时器路径）
        if let keepDeadline, keepDeadline <= Date() {
            handleExpiry()
            return
        }
        stopInternal(notify: false)
        startInternal(minutes: keepMinutes, deadline: keepDeadline)
    }

    private func startInternal(minutes: Int, deadline newDeadline: Date?) {
        stopInternal(notify: false)
        let remaining = newDeadline.map { max(1, $0.timeIntervalSinceNow) }

        var props: [String: Any] = [
            kIOPMAssertionTypeKey: cachedMode.assertionType,
            kIOPMAssertionNameKey: "Bento KeepAwake",
            kIOPMAssertionDetailsKey: "Bento keep-awake (menu bar)",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
        ]
        if let remaining {
            props[kIOPMAssertionTimeoutKey] = remaining
            props[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
        }

        var id = IOPMAssertionID(0)
        let rc = IOPMAssertionCreateWithProperties(props as CFDictionary, &id)
        guard rc == kIOReturnSuccess else {
            lastError = "创建断言失败（rc=\(rc)）"
            ErrorLog.log("防睡: 创建断言失败 rc=\(rc) mode=\(cachedMode.rawValue)")
            notifyChanged()
            return
        }
        lastError = nil
        assertionID = id
        isActive = true
        deadline = newDeadline
        sessionMinutes = minutes
        installObservers()
        scheduleTimers()
        checkBattery()
        notifyChanged()
    }

    /// - Parameter release: false = 只丢弃本地状态，不碰 IOPMAssertionRelease。
    ///   powerd 已经超时释放过这个 ID 时必须传 false —— IOPMAssertionID 是会被复用的句柄，
    ///   对着死 ID 再 Release 一次可能误杀别人（或本模块下一次）的断言。
    private func stopInternal(notify: Bool, release: Bool = true) {
        expiryTimer?.cancel(); expiryTimer = nil
        tickTimer?.cancel(); tickTimer = nil
        if isActive, release {
            let rc = IOPMAssertionRelease(assertionID)
            // kIOReturnBadArgument = powerd 已超时释放，属正常
            if rc != kIOReturnSuccess && rc != kIOReturnBadArgument {
                ErrorLog.log("防睡: 释放断言失败 rc=\(rc)")
            }
        }
        assertionID = IOPMAssertionID(0)
        isActive = false
        deadline = nil
        sessionMinutes = 0
        if notify { notifyChanged() }
    }

    /// 到期收工。powerd 那侧的 TimeoutActionRelease 和这个墙钟定时器指向同一时刻，
    /// 谁先落地不确定 —— 所以先问一次断言还在不在：已被 powerd 释放就绝不能再
    /// Release 一次（IOPMAssertionID 是会被复用的句柄，对着死 ID 释放可能误杀
    /// 别人的断言）。与 reconcile 用的是同一套判活方式
    private func handleExpiry() {
        guard isActive else { return }
        let stillAlive = IOPMAssertionCopyProperties(assertionID)?.takeRetainedValue() != nil
        stopInternal(notify: true, release: stillAlive)
    }

    deinit { if isActive { IOPMAssertionRelease(assertionID) } }

    // MARK: 定时器（一律墙钟）

    private func scheduleTimers() {
        expiryTimer?.cancel(); expiryTimer = nil
        tickTimer?.cancel(); tickTimer = nil

        if let deadline {
            let t = DispatchSource.makeTimerSource(queue: .main)
            // wallDeadline 而非 deadline：睡眠期间照常流逝，唤醒后若已过期立刻触发
            t.schedule(wallDeadline: .now() + max(0, deadline.timeIntervalSinceNow), leeway: .seconds(1))
            t.setEventHandler { [weak self] in
                ErrorLog.log("防睡: 到期自动停止")
                self?.handleExpiry()
            }
            t.activate() // 必须 activate，否则静默不跑
            expiryTimer = t
        }

        // 每分钟一跳只为两件事：刷新剩余时间文案、查电量。
        // 永久 + 低电停关闭时两件事都不存在 —— 不建这个定时器，空闲时零唤醒。
        guard deadline != nil || cachedBatteryStop > 0 else { return }
        let u = DispatchSource.makeTimerSource(queue: .main)
        let toNextMinute = 60.0 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60.0)
        u.schedule(wallDeadline: .now() + toNextMinute, repeating: .seconds(60), leeway: .seconds(10))
        u.setEventHandler { [weak self] in
            guard let self else { return }
            self.checkBattery()
            self.notifyChanged()
        }
        u.activate()
        tickTimer = u
    }

    // MARK: 自愈

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let ws = NSWorkspace.shared.notificationCenter
        // 解锁必然在唤醒之后，reconcile 又是幂等的 —— 不再额外挂 screenIsUnlocked 跨进程通知
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reconcile()
            }
        }
    }

    /// 唤醒后对表：墙钟过期就收工；powerd 已释放就同步为关闭；否则重建定时器
    func reconcile() {
        guard isActive else { return }
        if let deadline, Date() >= deadline {
            ErrorLog.log("防睡: 唤醒后发现已过期，停止")
            // 走 handleExpiry 而非 stop()：deadline 已过意味着 powerd 的
            // TimeoutActionRelease 几乎必然已经释放过了，这里恰是全文件
            // 最容易撞上「对死 ID 再 Release」的路径，必须先判活
            handleExpiry()
            return
        }
        if IOPMAssertionCopyProperties(assertionID)?.takeRetainedValue() == nil {
            ErrorLog.log("防睡: 断言已被系统释放，同步为关闭")
            stopInternal(notify: true, release: false) // ID 已死，不能再 Release
            return
        }
        scheduleTimers()
        checkBattery()
        notifyChanged()
    }

    private func notifyChanged() {
        if Thread.isMainThread {
            onStateChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
        }
    }

    // MARK: 低电量自动停

    private func checkBattery() {
        guard isActive, cachedBatteryStop > 0, let s = Self.batterySnapshot(), !s.onAC else { return }
        guard s.percent < cachedBatteryStop else { return }
        ErrorLog.log("防睡: 电量 \(s.percent)% 低于阈值 \(cachedBatteryStop)%，自动停止")
        stop()
        // 必须写在 stop() 之后（stopInternal 不清 lastError，下次成功 start 会自动清掉）。
        // 否则用户点了没反应，现象和「断言创建失败」完全无法区分
        lastError = "电量 \(s.percent)% 低于 \(cachedBatteryStop)%，已自动停止"
        notifyChanged()
    }

    /// 无内置电池（台式机）返回 nil → 设置窗口整行隐藏
    static func batterySnapshot() -> (percent: Int, onAC: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  (d[kIOPSIsPresentKey] as? Bool) ?? false,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let mx = d[kIOPSMaxCapacityKey] as? Int, mx > 0
            else { continue }
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            // 先在 Double 域钳制再转 Int：IOKit 报出离谱容量时 Int(超界 Double) 会 trap
            let pct = (Double(cur) / Double(mx) * 100).rounded()
            return (Int(min(100, max(0, pct))), onAC)
        }
        return nil
    }

    // MARK: 文案

    static func durationLabel(_ minutes: Int) -> String {
        if minutes <= 0 { return "永久" }
        if minutes < 60 { return "\(minutes) 分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    /// 剩余时间，仅定时会话有
    var remainingLabel: String? {
        guard isActive, let deadline else { return nil }
        let mins = max(1, Int((max(0, deadline.timeIntervalSinceNow) / 60).rounded(.up)))
        return Self.durationLabel(mins)
    }

    /// 结束时刻，跟随系统 12/24 小时制
    private var deadlineClock: String? {
        guard let deadline else { return nil }
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: deadline)
    }

    /// 「定时防睡」菜单行标题：进行中带上剩余时间。
    /// 刻意不带结束时刻——菜单宽度是所有项一起算的，这一行变长会把整个菜单撑宽
    var timedMenuTitle: String {
        guard let remainingLabel else { return "定时防睡" }
        return "定时防睡 · 剩余 \(remainingLabel)"
    }

    /// 设置窗口状态卡的副标题。标题已经由 isActive / isPermanent 说明状态，
    /// 这里只补充细节，不重复
    var statusText: String {
        guard isActive else { return "系统按「节能」设置正常休眠" }
        guard let remainingLabel, let deadlineClock else { return "直到你手动关闭" }
        return "剩余 \(remainingLabel) · 到 \(deadlineClock) 自动停止"
    }

    /// 状态栏 tooltip 用的短形式；未激活返回 nil
    var shortStatus: String? {
        guard isActive else { return nil }
        guard let remainingLabel else { return "防睡中 · 永久" }
        return "防睡中 · 剩余 \(remainingLabel)"
    }
}

// MARK: - 设置窗口

extension SleepGuard {
    func openSettingsWindow() { SleepGuardSettingsWindow.shared.show(guard: self) }
}


/// 状态卡左侧的圆形图标徽标：浅色圆底 + 着色 symbol，比裸图标更能传达状态层级。
/// 圆底色存在 layer 里（CGColor 不随系统外观自动更新），外观切换时按当前 tint 重算
private final class IconBadgeView: NSView {
    private let symbolView = NSImageView()
    private var tint: NSColor = .secondaryLabelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, tint: NSColor) {
        self.tint = tint
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        symbolView.contentTintColor = tint
        applyTint()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    private func applyTint() {
        layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
    }
}

/// 单例设置窗口。两张卡片：顶部状态卡（当前状态 + 主操作），下方设置卡（三项高级选项）。
/// 只放菜单里放不下的东西——时长预设在「定时防睡」子菜单里。
/// 布局要点：标签用 NSGridView 右对齐成一列（控件才有统一的对齐轴），
/// 窗口高度按内容算（台式机隐藏电池行后会自动收缩，不留空白）。
final class SleepGuardSettingsWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SleepGuardSettingsWindow()

    private static let windowWidth: CGFloat = 460

    private var window: NSWindow?
    private weak var guardRef: SleepGuard?

    // 状态卡
    private var stateBadge: IconBadgeView!
    private var stateTitle: NSTextField!
    private var stateDetail: NSTextField!
    private var actionButton: NSButton!
    // 设置卡
    private var settingsGrid: NSGridView!
    private var minutesField: NSTextField!
    private var minutesStepper: NSStepper!
    private var modeCheck: NSButton!
    private var batteryPopup: NSPopUpButton!
    private var batteryRowIndex = 0

    func show(guard sg: SleepGuard) {
        guardRef = sg
        if window == nil { buildWindow() }
        syncFromModel()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 构建

    private func buildWindow() {
        let cards = [buildStateCard(), buildSettingsCard(), buildFootnote()]
        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            content.widthAnchor.constraint(equalToConstant: Self.windowWidth),
            // 顶部留白要盖住透明标题栏的高度（fullSizeContentView 下内容顶到窗口上缘）
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ]
        // 竖向 NSStackView 不会自动拉伸子视图宽度，卡片得自己贴满
        for card in cards {
            constraints.append(card.leadingAnchor.constraint(equalTo: stack.leadingAnchor))
            constraints.append(card.trailingAnchor.constraint(equalTo: stack.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        // 走 contentViewController 而不是 contentView：窗口高度由 Auto Layout 自己定，
        // 隐藏电池行时也会自动收缩。手算 fittingSize 再 setContentSize 会算少、把卡片顶部裁掉
        let controller = NSViewController()
        controller.view = content
        let w = NSWindow(contentViewController: controller)
        // fullSizeContentView + 透明标题栏：卡片直接延伸进标题栏区域，去掉标题栏与内容之间的断层
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.title = "防睡设置"
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w
    }

    /// 圆角卡片：控件背景色 + 分隔线描边，明暗两种外观下都成立
    private func card(_ inner: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.contentView = inner
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private func buildStateCard() -> NSView {
        let icon = IconBadgeView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        stateBadge = icon

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stateTitle = title

        let detail = NSTextField(labelWithString: "")
        // 等宽数字：剩余时间每分钟刷新时文案不左右跳
        detail.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        stateDetail = detail

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "开始", target: self, action: #selector(actionPressed))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        actionButton = button

        // 用显式约束而不是 NSStackView：横向 stack 默认按 gravity 排布，
        // 不会把按钮推到最右，中间会留一段莫名其妙的空隙
        let inner = NSView()
        for sub in [icon, text, button] as [NSView] { inner.addSubview(sub) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: inner.centerYAnchor),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.topAnchor.constraint(equalTo: inner.topAnchor),
            text.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),

            button.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: inner.centerYAnchor),

            // 图标或按钮比文字高时，卡片跟着长高
            inner.heightAnchor.constraint(greaterThanOrEqualTo: icon.heightAnchor),
            inner.heightAnchor.constraint(greaterThanOrEqualTo: button.heightAnchor),
        ])
        return card(inner)
    }

    private func buildSettingsCard() -> NSView {
        let field = NSTextField()
        field.alignment = .right
        field.placeholderString = "分钟"
        field.target = self
        field.action = #selector(customChanged)
        field.delegate = self // 失焦也提交，否则输完直接关窗会丢
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        minutesField = field

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 24 * 60
        stepper.increment = 5
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged)
        minutesStepper = stepper

        let unit = NSTextField(labelWithString: "分钟")
        unit.textColor = .secondaryLabelColor

        let durationRow = NSStackView(views: [field, stepper, unit])
        durationRow.orientation = .horizontal
        durationRow.alignment = .centerY
        durationRow.spacing = 6

        // 标题里不再重复「显示器」——左边那一列的标签已经说了
        let mode = NSButton(checkboxWithTitle: "允许自行熄灭", target: self, action: #selector(modeChanged))
        modeCheck = mode

        let modeHint = NSTextField(labelWithString: "只阻止系统休眠，屏幕仍按系统设置熄灭")
        modeHint.font = .systemFont(ofSize: 11)
        modeHint.textColor = .secondaryLabelColor

        let popup = NSPopUpButton()
        popup.addItem(withTitle: "不自动停止")
        for percent in SleepGuard.batteryStopChoices.dropFirst() {
            popup.addItem(withTitle: "低于 \(percent)% 自动停止")
        }
        popup.target = self
        popup.action = #selector(batteryChanged)
        batteryPopup = popup

        let grid = NSGridView(views: [
            [fieldLabel("自定义时长"), durationRow],
            [fieldLabel("显示器"), mode],
            [NSGridCell.emptyContentView, modeHint],
            [fieldLabel("电池供电时"), popup],
        ])
        grid.columnSpacing = 12
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for index in 0 ..< grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        // 提示行紧贴复选框，另外两行之间留出呼吸
        grid.row(at: 1).topPadding = 10
        grid.row(at: 3).topPadding = 10
        batteryRowIndex = 3
        settingsGrid = grid

        // 网格不能被卡片拉满宽：右对齐的标签列会把多余宽度全吃掉，
        // 结果标签跑到窗口中间，左边空出一大片
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return card(container)
    }

    private func buildFootnote() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSTextField(wrappingLabelWithString:
            "合盖后系统仍会睡眠——macOS 未开放阻止合盖睡眠。\n模式与低电量改动会立即套用到进行中的会话，时长改动只影响下次开始。")
        text.font = .systemFont(ofSize: 11)
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = Self.windowWidth - 40 - 20

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        return row
    }

    // MARK: 同步

    private func syncFromModel() {
        guard let sg = guardRef else { return }
        minutesField.stringValue = "\(sg.customMinutes)"
        minutesStepper.integerValue = sg.customMinutes
        modeCheck.state = sg.mode == .systemOnly ? .on : .off

        // 台式机没有电池：整行折叠（只藏 popup 会留一条孤零零的标签）
        settingsGrid.row(at: batteryRowIndex).isHidden = SleepGuard.batterySnapshot() == nil
        let choices = SleepGuard.batteryStopChoices
        batteryPopup.selectItem(at: choices.firstIndex(of: sg.batteryStopPercent) ?? 0)

        refreshStatus()
    }

    /// 守卫用 window != nil 而不是 isVisible：首次 show() 里 syncFromModel 跑在
    /// makeKeyAndOrderFront 之前，用 isVisible 会把首次的状态与错误信息整个吞掉
    func refreshStatus() {
        guard window != nil, let sg = guardRef else { return }

        if let error = sg.lastError {
            stateBadge.configure(symbol: "exclamationmark.triangle", tint: .systemOrange)
            stateTitle.stringValue = "未能开启"
            stateDetail.stringValue = error
        } else if sg.isActive {
            stateBadge.configure(symbol: "cup.and.saucer.fill", tint: .controlAccentColor)
            stateTitle.stringValue = sg.isPermanent ? "永久防睡中" : "定时防睡中"
            stateDetail.stringValue = sg.statusText
        } else {
            stateBadge.configure(symbol: "cup.and.saucer", tint: .secondaryLabelColor)
            stateTitle.stringValue = "已停用"
            stateDetail.stringValue = sg.statusText
        }

        actionButton.title = sg.isActive ? "停止" : "开始"
        // 主操作才染强调色；停止是收敛动作，用普通按钮
        actionButton.bezelColor = sg.isActive ? nil : .controlAccentColor
    }

    // MARK: 动作（即时生效，没有确定按钮）

    private func applyMinutes(_ value: Int) {
        guard let sg = guardRef else { return }
        sg.customMinutes = value
        minutesField.stringValue = "\(sg.customMinutes)"
        minutesStepper.integerValue = sg.customMinutes
        refreshStatus()
    }

    @objc private func customChanged() {
        guard let sg = guardRef, let field = minutesField else { return }
        // 空串/非法输入回滚到模型现值，不能 clamp 成 1 ——
        // 「清空输入框直接关窗」不该把时长静默改成 1 分钟
        guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), value >= 1 else {
            field.stringValue = "\(sg.customMinutes)"
            return
        }
        applyMinutes(value)
    }

    @objc private func stepperChanged() {
        applyMinutes(minutesStepper.integerValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) { customChanged() }

    @objc private func modeChanged() {
        guardRef?.mode = modeCheck.state == .on ? .systemOnly : .displayAndSystem
        refreshStatus()
    }

    @objc private func batteryChanged() {
        let choices = SleepGuard.batteryStopChoices
        // indexOfSelectedItem 无选中时是 -1，两头都要钳
        let index = max(0, min(batteryPopup.indexOfSelectedItem, choices.count - 1))
        guardRef?.batteryStopPercent = choices[index]
    }

    @objc private func actionPressed() {
        guard let sg = guardRef else { return }
        // 先逼编辑结束：输了分钟数没按回车就点按钮的话，读到的还是旧值
        window?.makeFirstResponder(nil)
        if sg.isActive { sg.stop() } else { sg.start(minutes: sg.customMinutes) }
        refreshStatus()
    }

    func windowWillClose(_ notification: Notification) {
        // 先强制结束编辑，把没按回车的分钟数提交掉，再拆引用
        window?.makeFirstResponder(nil)
        window = nil
        settingsGrid = nil
        minutesField = nil
        minutesStepper = nil
        modeCheck = nil
        batteryPopup = nil
        stateBadge = nil
        stateTitle = nil
        stateDetail = nil
        actionButton = nil
    }
}
