import AppKit
import CoreGraphics
import Foundation

// MARK: - Screen Control

class ScreenController {
    private var isBlack = false
    private let mirrorSnapshotDefaultsKey = "BentoMirrorSnapshot"
    private var savedMirrorState: MirrorState?

    /// 快照下来的镜像状态：每块非主屏的镜像目标，外加「快照时它本来就在镜像组里」的标记。
    /// 后者不可省——硬件镜像组里 CGDisplayMirrorsDisplay 对每块屏都返回 0，光看目标值
    /// 区分不出「用户自己开着镜像」和「本来是扩展」，恢复时把前者拆掉就是毁掉用户的设置
    private struct MirrorState {
        var targets: [CGDirectDisplayID: CGDirectDisplayID]
        var preMirrored: Set<CGDirectDisplayID>
    }

    private struct MirrorSnapshot: Codable {
        let entries: [MirrorSnapshotEntry]
        /// 旧快照没有这个字段：解出 nil 视为「当时没有任何屏预先处于镜像组」
        let preMirrored: [UInt32]?
    }

    private struct MirrorSnapshotEntry: Codable {
        let displayID: UInt32
        let mirrorsDisplayID: UInt32
    }

    /// 「这块屏此刻是否处在镜像中」的**唯一**可靠判据。
    ///
    /// CGDisplayMirrorsDisplay 只在**软件**镜像里返回主屏 ID；一旦系统走**硬件**镜像组，
    /// 它对组内每一块屏（含从屏）都返回 kCGNullDirectDisplay。2026-09-08 实测：本机两块
    /// Studio Display 被 CGConfigureDisplayMirrorOfDisplay 合并后走的正是硬件镜像 ——
    /// 于是所有以「!= kCGNullDirectDisplay」为条件的解除分支一条都不执行，restored 为空
    /// → 取消配置 + 清快照 + 日志写「已解除」，镜像永久留在系统里，连菜单的
    /// 「恢复扩展显示器」都救不回来（那次远程会话结束后两块屏就这样一直镜像着）。
    /// 判断「是否需要拆」一律用这个函数，别再用 CGDisplayMirrorsDisplay
    private func isMirrored(_ d: CGDirectDisplayID) -> Bool {
        CGDisplayIsInMirrorSet(d) != 0
    }

    /// 睡眠中的显示器无法重新配置：2026-09-08 实测，两块屏 CGDisplayIsActive=false 时
    /// CGConfigureDisplayMirrorOfDisplay 逐个返回成功，CGCompleteDisplayConfiguration
    /// 却整体失败（错误 1014）。此时必须保留快照等唤醒后重试，绝不能当成「已恢复」清掉
    private func anyDisplayAsleep(_ displays: [CGDirectDisplayID]) -> Bool {
        displays.contains { CGDisplayIsAsleep($0) != 0 || CGDisplayIsActive($0) == 0 }
    }

    /// 还有未完成的镜像恢复（快照仍在）。轮询的空闲支路据此重试——空闲清理本身是
    /// 边沿触发的，一次失败（如断开时屏幕已睡）之后就再没有第二次机会，
    /// 桌面会一直停在镜像态
    var hasPendingMirrorRestore: Bool { hasMirrorSnapshot() }

    func enableMirroring() {
        let displays = onlineDisplays()
        let main = CGMainDisplayID()
        guard displays.count > 1 else { return }

        let hadSnapshot = hasMirrorSnapshot()
        if !hadSnapshot {
            let state = currentMirrorState(for: displays, main: main)
            saveMirrorSnapshot(state)
            NSLog("Mirroring: saved pre-remote snapshot for \(state.targets.count) display(s), "
                + "\(state.preMirrored.count) already mirrored")
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, config != nil else {
            if !hadSnapshot { clearMirrorSnapshot() }
            NSLog("Mirroring begin failed with error \(begin.rawValue)")
            return
        }

        var mirrored: [CGDirectDisplayID] = []
        for d in displays where d != main {
            // 已在镜像组里就不必再配一遍（硬件镜像下 CGDisplayMirrorsDisplay 恒为 0，
            // 只比它会对已经镜像好的屏重复下发配置）
            guard !isMirrored(d) else { continue }
            let e = CGConfigureDisplayMirrorOfDisplay(config, d, main)
            if e == .success {
                mirrored.append(d)
            } else {
                NSLog("Mirroring config failed for display \(d): \(e.rawValue)")
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

        restoreMirrorState(snapshot)
    }

    func restoreExtendedDisplays() {
        let displays = onlineDisplays()
        guard displays.count > 1 else {
            clearMirrorSnapshot()
            return
        }

        guard !anyDisplayAsleep(displays) else {
            ErrorLog.log("镜像: 显示器处于睡眠，无法重新配置，本次跳过（唤醒后可再试）")
            return
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, config != nil else {
            NSLog("Mirroring begin failed with error \(begin.rawValue)")
            return
        }

        // 判据用 isMirrored 而不是 CGDisplayMirrorsDisplay：见 isMirrored 的说明。
        // 这是用户手动的「强制拆回扩展」入口，不理会 preMirrored——他点了就是要扩展
        var restored: [CGDirectDisplayID] = []
        let main = CGMainDisplayID()
        for d in displays where d != main && isMirrored(d) {
            if CGConfigureDisplayMirrorOfDisplay(config, d, kCGNullDirectDisplay) == .success {
                restored.append(d)
            }
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

    private func restoreMirrorState(_ state: MirrorState) {
        let displays = onlineDisplays()
        guard displays.count > 1 else {
            clearMirrorSnapshot()
            return
        }

        // 屏幕睡着时重配置必失败：保留快照，等轮询在唤醒后重试
        guard !anyDisplayAsleep(displays) else {
            NSLog("Mirroring restore deferred: display asleep")
            return
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, config != nil else {
            NSLog("Mirroring begin failed with error \(begin.rawValue)")
            return // 快照留着，下次再试
        }

        var restored: [CGDirectDisplayID] = []
        let onlineSet = Set(displays)
        let main = CGMainDisplayID()
        for d in displays where d != main {
            // 快照时用户自己就开着镜像的屏：原样不动，别替他拆掉
            guard !state.preMirrored.contains(d) else { continue }
            var desired = state.targets[d] ?? kCGNullDirectDisplay
            if desired != kCGNullDirectDisplay && !onlineSet.contains(desired) {
                desired = kCGNullDirectDisplay
            }
            // 要拆镜像时必须用 isMirrored 判断当前状态：硬件镜像下 CGDisplayMirrorsDisplay
            // 恒为 0，只比它会把「该拆的」当成「已经拆好了」而跳过
            if desired == kCGNullDirectDisplay {
                guard isMirrored(d) else { continue }
            } else {
                guard CGDisplayMirrorsDisplay(d) != desired else { continue }
            }

            if CGConfigureDisplayMirrorOfDisplay(config, d, desired) == .success {
                restored.append(d)
            }
        }

        guard !restored.isEmpty else {
            CGCancelDisplayConfiguration(config)
            // 清快照前先确认真的没有遗留：快照一清就再没有依据去拆镜像。
            // 这正是那次会话的教训——判据看错 → 认定无事可做 → 清快照 → 镜像永久留下
            let stillMirrored = displays.filter {
                $0 != main && isMirrored($0) && !state.preMirrored.contains($0)
            }
            if stillMirrored.isEmpty {
                clearMirrorSnapshot()
                NSLog("Mirroring restored from snapshot; no changes needed")
            } else {
                ErrorLog.log("镜像: 判定无需恢复，但 \(stillMirrored) 仍在镜像组，保留快照待下次重试")
            }
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

    private func currentMirrorState(
        for displays: [CGDirectDisplayID],
        main: CGDirectDisplayID
    ) -> MirrorState {
        var targets: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        var pre: Set<CGDirectDisplayID> = []
        for d in displays where d != main {
            targets[d] = CGDisplayMirrorsDisplay(d)
            if isMirrored(d) { pre.insert(d) }
        }
        return MirrorState(targets: targets, preMirrored: pre)
    }

    private func hasMirrorSnapshot() -> Bool {
        savedMirrorState != nil || UserDefaults.standard.data(forKey: mirrorSnapshotDefaultsKey) != nil
    }

    private func saveMirrorSnapshot(_ state: MirrorState) {
        let entries = state.targets.map {
            MirrorSnapshotEntry(displayID: $0.key, mirrorsDisplayID: $0.value)
        }
        let snapshot = MirrorSnapshot(entries: entries, preMirrored: Array(state.preMirrored))
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: mirrorSnapshotDefaultsKey)
        }
        savedMirrorState = state
    }

    private func loadMirrorSnapshot() -> MirrorState? {
        if let savedMirrorState {
            return savedMirrorState
        }
        guard let data = UserDefaults.standard.data(forKey: mirrorSnapshotDefaultsKey) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(MirrorSnapshot.self, from: data) else {
            // 同分辨率/Dock 快照：坏键永远挡住新快照的保存，必须清 + 记日志
            ErrorLog.log("镜像快照损坏，已清除")
            UserDefaults.standard.removeObject(forKey: mirrorSnapshotDefaultsKey)
            return nil
        }

        var targets: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for entry in snapshot.entries {
            targets[entry.displayID] = entry.mirrorsDisplayID
        }
        let state = MirrorState(targets: targets, preMirrored: Set(snapshot.preMirrored ?? []))
        savedMirrorState = state
        return state
    }

    private func clearMirrorSnapshot() {
        savedMirrorState = nil
        UserDefaults.standard.removeObject(forKey: mirrorSnapshotDefaultsKey)
    }

    // MARK: 崩溃/被杀后的收尾
    //
    // gamma 随进程死亡自动复原，镜像有 BentoMirrorSnapshot 兜底，但分辨率和 Dock
    // 原来只活在内存里：远程连接期间 Bento 被 SIGKILL/崩溃，重启后 isScreenBlack
    // 是 false，恢复分支永远不触发 —— 分辨率永远停在 1512×982、Dock 永远停在左侧。
    // 更糟的是下一次连接会把「已经是目标值的当前状态」当成原始状态存下来，把错误固化。
    // 所以两者都按镜像快照的同一套路落盘：已有快照就不覆盖，恢复成功才清除。

    /// 启动时调用：上次是非正常退出（有残留快照）就把分辨率和 Dock 收回去。
    /// 直接看盘上的键而不是 hasDockSnapshot()——它还会读 savedDock*，
    /// 那组是 dockQueue 独占的，主线程不该碰
    func recoverFromUncleanExit() {
        let staleResolution = UserDefaults.standard.data(forKey: resolutionSnapshotDefaultsKey) != nil
        let staleDock = UserDefaults.standard.data(forKey: dockSnapshotDefaultsKey) != nil
        guard staleResolution || staleDock else { return }
        NSLog("Recovering display/dock state left behind by an unclean exit")
        if staleResolution { restoreResolution() }
        if staleDock { restoreDock() }
    }

    // MARK: Resolution

    private let resolutionSnapshotDefaultsKey = "BentoDisplayModeSnapshot"
    private let targetWidth = 1512
    private let targetHeight = 982

    /// CGDisplayMode 不可序列化，落盘存足以唯一定位它的几何 + 刷新率，恢复时回查。
    /// displayUUID 标记快照属于哪块屏（复用分屏模块的 DisplayKeys）：恢复时按 UUID
    /// 找回目标显示器，而不是无条件套用到「当前主屏」——崩溃重启之间主屏可能已经
    /// 换了（合盖外接等），套错屏比不恢复更糟。Optional 是为了还能解开旧版快照
    private struct DisplayModeSnapshot: Codable {
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double
        let displayUUID: String?
    }

    private var displayModeOptions: CFDictionary {
        [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    }

    func switchResolution() {
        let main = CGMainDisplayID()
        // 1512×982 HiDPI 是 14" MacBook Pro 内置屏的模式，只对内置屏执行。外接屏的模式表里
        // 往往也有这一档（2026-09-08 实测两块 Studio Display 都有），不加门槛就会把外接主屏
        // 切糊、还多一次显示重配置；没有内置屏的 Mac 上这一步因此是真正的 no-op。
        // restoreResolution 不受影响：盘上若有旧快照（任何显示器的）照常恢复
        guard CGDisplayIsBuiltin(main) != 0 else {
            NSLog("Resolution switch skipped: main display \(main) is not built-in")
            return
        }
        let currentMode = CGDisplayCopyDisplayMode(main)

        guard let modes = CGDisplayCopyAllDisplayModes(main, displayModeOptions) as? [CGDisplayMode] else { return }

        let target = modes.first {
            $0.width == targetWidth && $0.height == targetHeight && $0.pixelWidth > $0.width
        }
        guard let mode = target else {
            NSLog("Resolution mode \(targetWidth)x\(targetHeight) HiDPI not found, skipping")
            return
        }

        // 已有快照 = 上次没干净收尾，当前模式很可能就是目标模式；再存一次会把
        // 真正的原始分辨率永久丢掉
        let hadSnapshot = hasResolutionSnapshot()
        // 先落盘再切换（与镜像/Dock 同序）：反过来的话，切换成功到 cfprefsd 落盘
        // 之间被 SIGKILL，分辨率就永久固化且盘上无任何可恢复依据——快照要防的
        // 正是这种场景，自己不能留同款窗口
        if !hadSnapshot, let currentMode {
            saveResolutionSnapshot(currentMode, display: main)
        }

        let err = CGDisplaySetDisplayMode(main, mode, nil)
        if err == .success {
            NSLog("Resolution switched to \(targetWidth)x\(targetHeight) HiDPI")
        } else {
            if !hadSnapshot { clearResolutionSnapshot() } // 没切成，别留下假快照
            NSLog("Resolution switch failed with error \(err.rawValue)")
        }
    }

    /// 恢复以盘上快照为唯一事实来源（切换成功时必然已落盘，进程内不再另存一份）
    func restoreResolution() {
        guard let data = UserDefaults.standard.data(forKey: resolutionSnapshotDefaultsKey) else { return }
        guard let snapshot = try? JSONDecoder().decode(DisplayModeSnapshot.self, from: data) else {
            // 坏快照必须清 + 记日志：has*Snapshot 只看键存在，坏键会永远挡住新快照
            // 的保存（「不覆盖」规则），恢复又永远读不出——一条坏数据毒死整个恢复子系统
            ErrorLog.log("分辨率快照损坏，已清除")
            clearResolutionSnapshot()
            return
        }
        // 按 UUID 找回快照对应的显示器；旧版快照没有 UUID，退回主屏（原行为）
        let display: CGDirectDisplayID
        if let uuid = snapshot.displayUUID {
            guard let match = onlineDisplays().first(where: { DisplayKeys.uuid(for: $0) == uuid }) else {
                // 目标显示器不在线（外接屏暂时拔了）：保留快照等它回来，
                // 千万别套用到别的屏上
                NSLog("Resolution restore deferred: snapshot display \(uuid) not online")
                return
            }
            display = match
        } else {
            display = CGMainDisplayID()
        }
        guard let modes = CGDisplayCopyAllDisplayModes(display, displayModeOptions) as? [CGDisplayMode],
              let mode = modes.first(where: {
                  $0.width == snapshot.width && $0.height == snapshot.height
                      && $0.pixelWidth == snapshot.pixelWidth && $0.pixelHeight == snapshot.pixelHeight
                      && abs($0.refreshRate - snapshot.refreshRate) < 0.5
              })
        else {
            // 显示器还在但模式列表里找不到了：快照永远用不上，别留着挡下一次保存
            NSLog("Resolution snapshot \(snapshot.width)x\(snapshot.height) no longer available, dropping")
            clearResolutionSnapshot()
            return
        }
        let err = CGDisplaySetDisplayMode(display, mode, nil)
        if err == .success {
            NSLog("Resolution restored to \(mode.width)x\(mode.height)")
            clearResolutionSnapshot()
        } else {
            // 没恢复成功就留着快照，下次启动/断开还有机会
            NSLog("Resolution restore failed with error \(err.rawValue)")
        }
    }

    private func hasResolutionSnapshot() -> Bool {
        UserDefaults.standard.data(forKey: resolutionSnapshotDefaultsKey) != nil
    }

    private func saveResolutionSnapshot(_ mode: CGDisplayMode, display: CGDirectDisplayID) {
        let snapshot = DisplayModeSnapshot(width: mode.width, height: mode.height,
                                           pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                                           refreshRate: mode.refreshRate,
                                           displayUUID: DisplayKeys.uuid(for: display))
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: resolutionSnapshotDefaultsKey)
        }
    }

    private func clearResolutionSnapshot() {
        UserDefaults.standard.removeObject(forKey: resolutionSnapshotDefaultsKey)
    }

    // MARK: Dock
    //
    // Dock 这一档是全模块最贵的：2 次 `defaults read` + 2 次 `defaults write` +
    // 一次 `killall Dock`，五个进程创建。连接切换是在主线程判定的，同步跑就是
    // 肉眼可见的卡顿 —— 所以整档挪到自己的串行队列上（串行 = 保住"连接时存并设左、
    // 断开时还原"的先后顺序）。savedDock* 与快照读写也一并只在这个队列上进行。
    // 退出路径必须 waitForPendingDockWork()：否则进程先死，Dock 永远停在左边。

    private let dockQueue = DispatchQueue(label: "com.sz.bento.dock")
    private var savedDockOrientation: String?
    private var savedDockAutohide: Bool?
    private let dockSnapshotDefaultsKey = "BentoDockSnapshot"

    private struct DockSnapshot: Codable {
        let orientation: String
        let autohide: Bool
    }

    func saveDockAndSetLeft() {
        dockQueue.async { self.saveDockAndSetLeftSync() }
    }

    func restoreDock() {
        dockQueue.async { self.restoreDockSync() }
    }

    /// 排空队列。退出/终止路径调用，等 Dock 真的还原完再走
    func waitForPendingDockWork() {
        dockQueue.sync {}
    }

    private func saveDockAndSetLeftSync() {
        // 同分辨率：上次没干净收尾时当前 Dock 已经在左侧，再存一次就把原始方向丢了
        if !hasDockSnapshot() {
            let orientation = runProcess("/usr/bin/defaults", ["read", "com.apple.dock", "orientation"], captureOutput: true)
            let autohide = runProcess("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"], captureOutput: true)
            // defaults read 的可信退出码只有 0（读到值）和 1（键不存在 = 系统默认）。
            // 其他（spawn 失败 -1、看门狗超时杀 15）读到的是垃圾——快照有「不覆盖」规则，
            // 垃圾一旦入快照就永远修不掉。读不可信就整个跳过 Dock 调整：
            // 挪走却还原不回，比不挪更糟
            guard orientation.status == 0 || orientation.status == 1,
                  autohide.status == 0 || autohide.status == 1 else {
                ErrorLog.log("Dock: 读取当前配置失败（status \(orientation.status)/\(autohide.status)），本次跳过 Dock 调整")
                return
            }
            let snapshot = DockSnapshot(orientation: orientation.output.isEmpty ? "bottom" : orientation.output,
                                        autohide: autohide.output == "1")
            savedDockOrientation = snapshot.orientation
            savedDockAutohide = snapshot.autohide
            saveDockSnapshot(snapshot)
        }

        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "orientation", "-string", "left"])
        runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"])
        restartDock()
        let described = savedDockOrientation ?? loadDockSnapshot()?.orientation ?? "?"
        NSLog("Dock set to left, autohide off (original: \(described))")
    }

    private func restoreDockSync() {
        let snapshot: DockSnapshot
        if let orientation = savedDockOrientation, let autohide = savedDockAutohide {
            snapshot = DockSnapshot(orientation: orientation, autohide: autohide)
        } else if let disk = loadDockSnapshot() {
            snapshot = disk
        } else {
            return
        }
        let w1 = runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "orientation", "-string", snapshot.orientation])
        let w2 = runProcess("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", snapshot.autohide ? "true" : "false"])
        // 「成功才清快照」对恢复路径同样成立：写失败还无条件清快照的话，
        // Dock 永远停在左边且再无自愈依据。分辨率路径一直是对的，这里对齐
        guard w1.status == 0, w2.status == 0 else {
            ErrorLog.log("Dock: 恢复写入失败（status \(w1.status)/\(w2.status)），保留快照待下次重试")
            return
        }
        restartDock()
        NSLog("Dock restored to \(snapshot.orientation), autohide: \(snapshot.autohide)")
        savedDockOrientation = nil
        savedDockAutohide = nil
        clearDockSnapshot()
    }

    private func hasDockSnapshot() -> Bool {
        savedDockOrientation != nil || UserDefaults.standard.data(forKey: dockSnapshotDefaultsKey) != nil
    }

    private func saveDockSnapshot(_ snapshot: DockSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: dockSnapshotDefaultsKey)
        }
    }

    private func loadDockSnapshot() -> DockSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: dockSnapshotDefaultsKey) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(DockSnapshot.self, from: data) else {
            // 同分辨率快照：坏键会永远挡住新快照的保存，必须清 + 记日志
            ErrorLog.log("Dock 快照损坏，已清除")
            UserDefaults.standard.removeObject(forKey: dockSnapshotDefaultsKey)
            return nil
        }
        return snapshot
    }

    private func clearDockSnapshot() {
        UserDefaults.standard.removeObject(forKey: dockSnapshotDefaultsKey)
    }

    private func restartDock() {
        runProcess("/usr/bin/killall", ["Dock"])
    }

    // MARK: Gamma Black

    /// 熄屏失败只记一次日志（3s 轮询会反复重试，逐轮记会刷爆 error.log），成功后复位
    private var loggedBlackFailure = false
    /// 至少有一块屏被写过 gamma。restore 的门槛是它而不是 isBlack：
    /// 部分置黑失败时 isBlack 是 false，但已压黑的屏真实存在——按 isBlack
    /// 早退会让它们一直黑到进程退出（且菜单/断开路径全都救不了）
    private var gammaTouched = false

    /// isBlack 只在**每一块**显示器都置黑成功后才为 true。
    /// 原实现无条件置 true：显示器枚举为空或部分失败时，菜单显示「已熄屏」、
    /// 本地屏幕却亮着，而且 `connected && !isScreenBlack` 从此为假——永不重试。
    /// 对隐私工具这是最糟的方向：失败必须保持 false，让轮询下一轮再压一次
    /// （已黑的屏重复置黑是幂等的，无副作用）。
    func setBlack() {
        guard !isBlack else { return }
        let displays = onlineDisplays()
        guard !displays.isEmpty else {
            if !loggedBlackFailure {
                loggedBlackFailure = true
                ErrorLog.log("熄屏: 显示器枚举为空，gamma 未生效，保持未熄屏状态待重试")
            }
            return
        }
        var failed: [CGDirectDisplayID] = []
        for d in displays where CGSetDisplayTransferByFormula(d, 0, 0, 1, 0, 0, 1, 0, 0, 1) != .success {
            failed.append(d)
        }
        if failed.count < displays.count { gammaTouched = true }
        if failed.isEmpty {
            isBlack = true
            loggedBlackFailure = false
        } else if !loggedBlackFailure {
            loggedBlackFailure = true
            ErrorLog.log("熄屏: \(failed.count)/\(displays.count) 台显示器置黑失败 \(failed)，保持未熄屏状态待重试")
        }
    }

    /// 显示器拓扑变化（远程会话中热插新屏、睡眠唤醒）时重压 gamma：
    /// 新接入的显示器是正常 gamma、不在镜像组，直接亮出真实桌面——隐私缺口。
    /// 对全部在线屏重设一遍，已黑的屏幂等无感。
    /// 重压失败不能装成功：isBlack 退回 false，轮询的 setBlack 下一轮整体重试
    ///（原实现忽略一切错误还保持 isBlack=true，失败的新屏亮着且永不重试）
    func reassertBlackIfNeeded() {
        guard isBlack else { return }
        let displays = onlineDisplays()
        var allOK = !displays.isEmpty
        for d in displays where CGSetDisplayTransferByFormula(d, 0, 0, 1, 0, 0, 1, 0, 0, 1) != .success {
            allOK = false
        }
        if !allOK {
            isBlack = false
            ErrorLog.log("熄屏: 唤醒/热插后重压 gamma 未全部成功，转入轮询重试")
        }
    }

    func restore() {
        guard gammaTouched else { return } // 见 gammaTouched 声明处：不能用 isBlack 当门槛
        CGDisplayRestoreColorSyncSettings()
        isBlack = false
        gammaTouched = false
        loggedBlackFailure = false
    }

    /// 会话是否已锁定（屏保已上锁）。CGSSessionScreenIsLocked 不在公开头文件里，但从
    /// 10.x 到 26 一直在会话字典里：锁定时为 true，未锁定时键不存在——键缺失即未锁。
    /// 撤黑前的确认用它（AppDelegate.pollLockThenRestore），另有分布式通知作第二路
    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    func lockScreen() {
        let r = runProcess("/usr/bin/open", ["-a", "ScreenSaverEngine"])
        if r.status != 0 {
            // 锁不上 = 撤黑后桌面直接裸露，必须留痕
            ErrorLog.log("锁屏: 启动屏保失败 status=\(r.status)")
        }
    }

    var isScreenBlack: Bool { isBlack }
}
