# RustDeskScreenOff

## 中文

RustDesk / macOS 屏幕共享 远程连接自动熄屏工具，保护你的隐私。

### 功能

- 当有人通过 RustDesk 或 macOS 屏幕共享（VNC）远程连接到你的 Mac 时，本地屏幕自动变黑，防止旁人看到远程操作内容
- 多显示器自动镜像：连接时自动将多个屏幕合并为一个，远程端只看到一个屏幕，避免窗口分散混乱
- 自动切换分辨率：连接时切换到 1512×982 HiDPI，断开后恢复原始分辨率
- Dock 自动移到左侧：连接时将 Dock 移至屏幕左侧并关闭自动隐藏，断开后恢复原始位置和设置
- 远程连接断开后，屏幕自动恢复（包括恢复多屏布局、分辨率、Dock 位置）并锁屏
- 远程端画面不受影响，正常显示桌面
- 菜单栏显示当前状态（监控中 / 已熄屏）
- 支持 FileVault AuthRestart（免密重启）
- 开机自动启动，无需手动操作

### 使用方法

1. 编译并运行：
   ```bash
   ./build_app.sh
   open RustDeskScreenOff.app
   ```
2. 启动后菜单栏出现眼睛图标，App 在后台自动工作
3. 无需任何配置，开箱即用
4. 点击菜单栏图标可查看状态或退出

### 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- 已安装 RustDesk

---

## English

Auto screen-off tool for RustDesk and macOS Screen Sharing (VNC) remote connections. Protects your privacy.

### Features

- Automatically blacks out the local screen when someone connects to your Mac via RustDesk or macOS Screen Sharing (VNC), preventing bystanders from seeing remote activity
- Auto display mirroring: merges multiple monitors into one when connected, so the remote viewer sees a single clean screen instead of a scattered multi-monitor layout
- Auto resolution switching: switches to 1512×982 HiDPI on connect, restores original resolution on disconnect
- Dock repositioning: moves Dock to the left side and disables auto-hide on connect, restores original position and settings on disconnect
- Restores the screen, multi-monitor layout, resolution, and Dock when the remote connection ends, then locks the screen
- The remote viewer's display is unaffected — they see the desktop normally
- Menu bar icon shows current status (monitoring / screen off)
- FileVault AuthRestart support (password-free reboot)
- Launches automatically at login, no manual action needed

### Usage

1. Build and run:
   ```bash
   ./build_app.sh
   open RustDeskScreenOff.app
   ```
2. An eye icon appears in the menu bar — the app works automatically in the background
3. No configuration needed, works out of the box
4. Click the menu bar icon to check status or quit

### Requirements

- macOS 14.0 (Sonoma) or later
- RustDesk installed
