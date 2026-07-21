# Bento

> 个人 macOS 菜单栏工具箱 / Personal macOS menu bar toolkit

一个 app 装一堆个人需要的小功能。当前包含：远程连接自动熄屏、鼠标/触控板独立滚动方向控制。

A single app for a grab-bag of small personal utilities. Currently: remote-connection auto screen-off, and Mos-style independent scroll-direction control for mouse vs trackpad.

---

## 中文

### 功能

#### 1. 远程连接自动熄屏

- 当有人通过 RustDesk 或 macOS 屏幕共享（VNC）远程连接到你的 Mac 时，本地屏幕自动变黑，防止旁人看到远程操作内容
- 多显示器自动镜像：连接时自动将多个屏幕合并为一个，远程端只看到一个屏幕
- 连接前保存多显示器镜像状态，断开后按快照恢复；菜单提供手动恢复扩展显示器
- 自动切换分辨率：连接时切换到 1512×982 HiDPI，断开后恢复
- Dock 自动移到左侧并关闭自动隐藏，断开后恢复原始位置
- 远程连接断开后，屏幕自动恢复并锁屏
- 远程端画面不受影响，正常显示桌面
- 菜单栏显示当前状态（监控中 / 已熄屏 / 已停用）
- 菜单「远程连接自动熄屏」可整体开关此监控；停用时若正黑屏会立即恢复（不锁屏），选择自动持久化
- 支持 FileVault AuthRestart（免密重启）

#### 2. 滚动方向独立控制（Mos 风格）

- 鼠标和触控板独立反转滚动方向，互不影响
- 默认：鼠标反转（传统方向）、触控板保持系统设置（自然方向）
- 菜单栏可即时切换两个开关，状态自动持久化
- 需要授予「辅助功能」和「输入监控」权限

#### 3. 分屏（窗口吸附，类似 MaxTo/Moom）

- **双击窗口标题栏**：把窗口放大到它所在的布局格子（与窗口重叠面积最大的格子）；再次双击还原到吸附前位置
- **修饰键 + 拖动标题栏**（⌘ 或 ⌃ 可选）：显示半透明网格浮层并高亮光标所在格，松手把窗口吸进该格
- 多显示器：每屏独立布局，格子基于 `NSScreen.visibleFrame`（自动排除菜单栏和 Dock）
- 布局 = 递归二叉分割树；菜单「编辑分屏布局…」在每块真实屏幕盖一层半透明编辑面：点选格子、拖分隔线调比例、右键分割/合并，浮动工具条支持重置此屏/复制到所有屏/保存/取消，Esc 随时取消
- 配置按显示器 UUID 持久化到 `~/Library/Application Support/Bento/config.json`，重启/插拔显示器不丢布局
- 需要授予「辅助功能」权限（未授权时菜单栏图标变为警告标志）

#### 4. 菜单栏图标管理（类似 Bartender/Ice）

- 菜单栏图标太多被刘海/系统挤掉时，可以**选择哪些显示、哪些隐藏**
- 菜单「管理菜单栏图标…」弹出清单：勾选 = 显示，取消勾选 = 隐藏，即时生效并记住选择
- Bento 自己的图标始终钉在第三方图标最右边，不会被挤掉
- 退出 Bento 后所有被隐藏的图标自动恢复，不会遗留状态
- 系统图标（时钟/电池/Wi-Fi 等）请在 系统设置 → 控制中心 中管理
- 需要授予「辅助功能」权限

### 使用方法

```bash
./build_app.sh
open Bento.app
```

1. 启动后菜单栏出现眼睛图标
2. 首次启动会请求权限（用于滚动方向控制）。在「系统设置 → 隐私与安全性」里确认 Bento 已允许「辅助功能」和「输入监控」，**然后退出 app 重开**
3. 开机自启已自动配置，无需操作
4. 点击菜单栏图标可看状态、切换滚动反转开关、退出

### 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- 远程熄屏功能需要 RustDesk 或开启 macOS 屏幕共享

---

## English

### Features

#### 1. Auto screen-off on remote connection

- Automatically blacks out the local screen when someone connects to your Mac via RustDesk or macOS Screen Sharing (VNC)
- Auto display mirroring: merges multiple monitors into one when connected
- Saves the pre-connection display mirroring state and restores it on disconnect; includes a manual restore action for extended displays
- Auto resolution switching: switches to 1512×982 HiDPI on connect, restores on disconnect
- Dock repositioning: moves Dock to the left and disables auto-hide on connect, restores on disconnect
- Restores the screen, multi-monitor layout, resolution, and Dock when the remote connection ends, then locks the screen
- The remote viewer's display is unaffected
- Menu bar icon shows current status (monitoring / screen off / disabled)
- "远程连接自动熄屏" menu toggle enables/disables the whole monitor; if the screen is black when you disable it, everything restores immediately (no lock); choice persists
- FileVault AuthRestart support (password-free reboot)

#### 2. Independent scroll-direction control (Mos-style)

- Mouse and trackpad scroll directions can be reversed independently
- Defaults: mouse reversed (traditional direction), trackpad untouched (natural direction)
- Toggle either from the menu bar — changes apply instantly and persist
- Requires Accessibility and Input Monitoring permissions

#### 3. Window tiling (MaxTo/Moom-style)

- **Double-click a window titlebar**: snaps the window into its layout cell (the cell with the largest overlap); double-click again to restore its previous position
- **Modifier + drag titlebar** (⌘ or ⌃, selectable): shows a translucent grid overlay with the hovered cell highlighted; release to snap into it
- Multi-monitor: each display has its own layout based on `NSScreen.visibleFrame` (menu bar and Dock excluded)
- Layout = recursive binary-split tree; "编辑分屏布局…" opens a WYSIWYG full-screen editor overlay on every real display: click to select cells, drag dividers, right-click to split/merge, floating toolbar with reset/copy-to-all/save/cancel, Esc cancels anytime
- Config persists per display UUID in `~/Library/Application Support/Bento/config.json` — survives reboots and display replugging
- Requires Accessibility permission (the menu bar icon shows a warning badge while missing)

#### 4. Menu bar icon manager (Bartender/Ice-style)

- When menu bar icons overflow (notch), **choose which icons stay visible and which get hidden**
- "管理菜单栏图标…" opens a checklist: checked = show, unchecked = hide — applies instantly and persists
- Bento's own icon is always pinned rightmost among third-party icons and never gets pushed out
- Quitting Bento restores all hidden icons — nothing is left behind
- System icons (clock/battery/Wi-Fi) are managed in System Settings → Control Center
- Requires Accessibility permission

### Usage

```bash
./build_app.sh
open Bento.app
```

1. An eye icon appears in the menu bar
2. On first launch you'll be prompted for permissions used by the scroll reverser. Confirm Bento is allowed under System Settings → Privacy & Security → Accessibility and Input Monitoring, **then quit and relaunch the app**
3. Launch-at-login is configured automatically
4. Click the menu bar icon to see status, toggle scroll reversal, or quit

### Requirements

- macOS 14.0 (Sonoma) or later
- Remote screen-off feature requires RustDesk or macOS Screen Sharing
