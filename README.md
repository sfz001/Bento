# Bento

> 个人 macOS 菜单栏工具箱 / Personal macOS menu bar toolkit

一个 app 装一堆个人需要的小功能。当前包含：远程连接自动熄屏、鼠标/触控板独立滚动方向控制、分屏（窗口吸附）、防止睡眠。菜单栏图标管理代码保留，但当前停用。

A single app for a grab-bag of small personal utilities. Currently: remote-connection auto screen-off, Mos-style independent scroll-direction control, MaxTo-style window tiling, and a Caffeine-style sleep guard. The menu bar icon manager is retained in source but currently disabled.

---

## 中文

### 功能

#### 1. 远程连接自动熄屏

- RustDesk 连接通过真实可执行文件路径与连接管理参数识别；macOS 屏幕共享（VNC）还需本次守护进程的认证成功记录。确认连接后本地先压黑，再调整显示器，防止旁人看到远程操作内容
- 多显示器自动镜像：连接时自动将多个屏幕合并为一个，远程端只看到一个屏幕
- 连接前保存多显示器镜像状态，断开后按快照恢复；菜单提供手动恢复扩展显示器
- 仅内置主屏尝试切换到 1512×982 HiDPI，并保持当前刷新率；无匹配模式则跳过。镜像前保存原始模式，断开后先拆镜像再恢复分辨率
- Dock 自动移到左侧并关闭自动隐藏，断开后恢复原始位置
- 远程断开连续确认两轮后先请求锁屏，确认锁定后恢复显示与 Dock；6 秒未确认锁定也会恢复，同时在菜单提示警告
- 远程端画面不受影响，正常显示桌面
- 菜单栏显示监控、熄屏、停用及探测异常状态；认证日志不可读或长期缺失会显式告警
- 菜单「远程连接自动熄屏」可整体开关此监控；停用时若正黑屏会立即恢复（不锁屏），选择自动持久化
- 菜单「熄屏流程演练…」确认后执行 10 秒演练，再自动锁屏恢复；真实连接会接管演练。需先开启监控且当前没有会话
- 支持 FileVault AuthRestart：在终端确认管理员身份后，下一次重启跳过 FileVault 开机解锁

#### 2. 滚动方向独立控制（Mos 风格）

- 鼠标和触控板独立反转滚动方向，互不影响
- 默认：鼠标反转（传统方向）、触控板保持系统设置（自然方向）
- 菜单栏可即时切换两个开关，状态自动持久化
- 需要授予「辅助功能」和「输入监控」权限

#### 3. 分屏（窗口吸附，类似 MaxTo/Moom）

- **双击窗口标题栏**：把窗口放大到它所在的布局格子（点击点所在的格子）；再次双击还原到吸附前位置
- **Shift + 拖动标题栏**：显示半透明网格浮层并高亮光标所在格，松手把窗口吸进该格
- **Shift + 双击标题栏**：铺满当前屏幕可用区域
- **快速上甩或来回甩动标题栏**：窗口实际随光标移动时最大化；拖出浏览器标签页不会最大化源窗口
- 多显示器：每屏独立布局，格子基于 `NSScreen.visibleFrame`（自动排除菜单栏和 Dock）
- 布局 = 递归二叉分割树；菜单「编辑分屏布局…」在每块真实屏幕盖一层半透明编辑面：点选格子、拖分隔线调比例、右键分割/合并，浮动工具条支持重置此屏/复制到所有屏/保存/取消；编辑窗口拥有焦点时 Esc 取消、回车保存。休眠、分辨率变化和热插拔保留未保存草稿
- 配置按显示器 UUID 持久化到 `~/Library/Application Support/Bento/config.json`，重启/插拔显示器不丢布局
- 需要授予「辅助功能」权限（未授权时菜单栏图标变为警告标志）

#### 4. 菜单栏图标管理（当前停用）

`MenuBarIconManager.featureEnabled = false`，因此当前没有菜单入口、后台纠偏或退出时图标恢复操作。代码保留供以后使用，未因本轮修复重新启用。

若未来启用：面向 macOS 27，按系统版本使用位置偏好字典或合成拖拽，支持选择性隐藏和排序。macOS 27 没有强制隐藏原语，宽松菜单栏中的隐藏项仍可能重新出现。系统模块名称会去掉动态状态；无溢出条与展开、收起、不可读状态分别处理；点击不发送全局 Esc。

#### 5. 防止睡眠（类似 Caffeine/Amphetamine）

- **永久防睡**：勾选后一直保持唤醒，再点一次关闭
- **定时防睡 ▸**：30 分钟 / 1 小时 / 2 小时 / 4 小时预设，点已勾选的那项即停止；菜单项会显示剩余时间
- 「防睡设置…」可设自定义分钟数（1–1440）、选择是否允许屏幕自行熄灭（只防系统睡眠）、设置低电量自动停止阈值
- 到期由系统 powerd 兜底释放，Bento 被强杀也不会把机器永久钉醒
- 状态**不跨启动保存**：重启后不会自动恢复防睡，避免静默耗电
- 无法阻止合盖睡眠（Apple Silicon 上没有不装内核扩展的做法），设置窗口里有说明
- 不需要任何额外权限

### 使用方法

```bash
./build_app.sh
open Bento.app
# 已在运行时用这个：退出旧实例再启动新包（直接 open 只会激活旧实例）
# Already running? Use this: quits the old instance, then opens the new bundle
./build_app.sh --relaunch
```

1. 启动后菜单栏出现眼睛图标
2. 首次启动会请求权限（用于滚动方向控制）。在「系统设置 → 隐私与安全性」里确认 Bento 已允许「辅助功能」和「输入监控」，**然后点击 Bento 菜单中的「重新检测滚动权限」，无需退出重开**
3. 首次启动登记开机自启，后续由菜单开关控制；若系统要求批准，菜单会引导到登录项设置
4. 点击菜单栏图标可看状态、切换各功能开关、编辑分屏布局、启动熄屏演练、退出

### 系统要求

- macOS 14.0 (Sonoma) 或更高版本；停用中的菜单栏图标管理模块面向 macOS 27+
- 远程熄屏功能需要 RustDesk 或开启 macOS 屏幕共享

---

## English

### Features

#### 1. Auto screen-off on remote connection

- Detects RustDesk by its executable path and connection-manager argument. macOS Screen Sharing also requires an authentication-success event for the current Apple daemon instance; a port scan alone does not trigger blackout
- Auto display mirroring: merges multiple monitors into one when connected
- Saves the pre-connection display mirroring state and restores it on disconnect; includes a manual restore action for extended displays
- Only a built-in main display is eligible for 1512×982 HiDPI, at the current refresh rate; skip if no matching mode exists. Capture the original mode before mirroring, and remove mirroring before restoring it
- Dock repositioning: moves Dock to the left and disables auto-hide on connect, restores on disconnect
- After two definite disconnect polls, request a lock first, then restore displays and Dock after lock confirmation. A six-second lock timeout also restores the desktop and leaves a warning in the menu
- The remote viewer's display is unaffected
- Menu bar status includes monitoring, blackout, disabled, and probe-health warnings. Missing or unreadable authentication evidence is surfaced rather than silently treated as a successful probe
- "远程连接自动熄屏" menu toggle enables/disables the whole monitor; if the screen is black when you disable it, everything restores immediately (no lock); choice persists
- “熄屏流程演练…” runs the same workflow for 10 seconds, then locks and restores; requires confirmation, monitoring enabled, and no current session. A real remote connection takes over the rehearsal
- FileVault AuthRestart opens an administrator-authenticated Terminal command to bypass FileVault preboot unlock for the next restart

#### 2. Independent scroll-direction control (Mos-style)

- Mouse and trackpad scroll directions can be reversed independently
- Defaults: mouse reversed (traditional direction), trackpad untouched (natural direction)
- Toggle either from the menu bar — changes apply instantly and persist
- Requires Accessibility and Input Monitoring permissions

#### 3. Window tiling (MaxTo/Moom-style)

- **Double-click a window titlebar**: snaps the window into its layout cell (the cell under the click); double-click again to restore its previous position
- **Shift + drag titlebar**: shows a translucent grid overlay with the hovered cell highlighted; release to snap into it
- Multi-monitor: each display has its own layout based on `NSScreen.visibleFrame` (menu bar and Dock excluded)
- Layout = recursive binary-split tree; "编辑分屏布局…" opens a WYSIWYG full-screen editor overlay on every real display: click to select cells, drag dividers, right-click to split/merge, floating toolbar with reset/copy-to-all/save/cancel; Esc cancels and Enter saves while an editor window is key
- Config persists per display UUID in `~/Library/Application Support/Bento/config.json` — survives reboots and display replugging
- Requires Accessibility permission (the menu bar icon shows a warning badge while missing)
- **Shift + double-click** maximizes to the usable screen area. **Flick upward or wiggle** maximizes only when the window itself actually moved.
- Draft layouts survive sleep, display changes, and hot-plugging; Esc/Enter apply only while an editor window is key.

#### 4. Menu bar icon manager (currently disabled)

`MenuBarIconManager.featureEnabled = false`: no menu entry, background correction, or icon restore on exit. The source is retained for possible future use and stays disabled after this audit.

If enabled later, it targets macOS 27 and chooses preference-dictionary updates or synthetic drags according to the OS version. It cannot force icons to remain hidden on a roomy menu bar. Module names exclude volatile status text, overflow has four explicit states, and synthetic clicks do not send a global Escape key.

#### 5. Sleep guard (Caffeine/Amphetamine-style)

- **永久防睡** (keep awake indefinitely): check to hold the Mac awake, click again to stop
- **定时防睡 ▸** (timed): 30 min / 1 h / 2 h / 4 h presets; clicking the checked one stops it, and the menu row shows the time remaining
- "防睡设置…" sets a custom duration (1–1440 min), whether the display may still sleep (system-sleep only), and a low-battery auto-stop threshold
- The hard deadline is enforced by powerd, so even a killed Bento can't pin the machine awake forever
- State is **not persisted across launches** — a relaunch never silently restores keep-awake and drains the battery
- Cannot prevent clamshell sleep (no kext-free mechanism exists on Apple Silicon); the settings window says so
- Requires no extra permissions

### Usage

```bash
./build_app.sh
open Bento.app
# 已在运行时用这个：退出旧实例再启动新包（直接 open 只会激活旧实例）
# Already running? Use this: quits the old instance, then opens the new bundle
./build_app.sh --relaunch
```

1. An eye icon appears in the menu bar
2. On first launch you'll be prompted for permissions used by the scroll reverser. Confirm Bento is allowed under System Settings → Privacy & Security → Accessibility and Input Monitoring, **then click “重新检测滚动权限” in Bento’s menu; no relaunch is needed**
3. Launch-at-login is registered on first launch and controlled by the menu toggle afterward; pending system approval links to Login Items settings
4. Click the menu bar icon to see status, toggle features, edit tiling layouts, start a screen-off rehearsal, or quit

### Requirements

- macOS 14.0 (Sonoma) or later; the disabled menu bar icon manager targets macOS 27+
- Remote screen-off feature requires RustDesk or macOS Screen Sharing

## 验证 / Validation

```bash
./build_app.sh --check   # Swift 类型检查 / type-check
./build_app.sh --test    # 8 组自动回归 / 8 regression suites
./build_app.sh --relaunch
```

自动测试不改真实显示器、Dock 或权限；具体覆盖范围见 [Tests/README.md](Tests/README.md)。实际远程连接、真实硬件镜像切换和编辑器交互仍需在本机验证；新增菜单演练入口供主动检查。

Tests use substitute display/process interfaces and do not change physical displays, Dock, or permissions. See [Tests/README.md](Tests/README.md). Real remote sessions and hardware/UI behavior still require local validation; the rehearsal menu provides an explicit way to exercise the screen-off workflow.

构建的 Info.plist 记录数字版本、短提交号、dirty 标志和构建时间；启动时写入 `~/Library/Application Support/Bento/error.log`。普通重复日志按 60 秒汇总；致命信号直接追加标记，系统崩溃报告仍保留。Dock 退出恢复最多等待 2 秒，超时快照留给下次启动。

Build metadata records a numeric version, commit hash, dirty state, and UTC build time, also logged at startup. Repeated errors are summarized every 60 seconds; fatal-signal markers preserve system crash reports. Exit waits at most two seconds for Dock work, retaining snapshots for startup recovery.
