# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

macOS menu bar app (Swift + AppKit, single-file). When a RustDesk or macOS Screen Sharing (VNC) remote connection is detected, the local screen goes black for privacy; on disconnect, the screen restores and locks.

## Build & Run

```bash
./build_app.sh              # Compile universal binary (arm64 + x86_64), package .app bundle
open RustDeskScreenOff.app  # Run
```

Build requires macOS 14.0+ SDK. Uses `swiftc` directly (no Xcode project/SPM). Frameworks: AppKit, CoreGraphics.

## Architecture

Everything lives in `RustDeskScreenOff.swift` (~370 lines), structured as two classes + main entry:

- **`ScreenController`** — Screen blackout via `CGSetDisplayTransferByFormula` (gamma to zero), restore via `CGDisplayRestoreColorSyncSettings`, lock via `open -a ScreenSaverEngine`. Multi-monitor mirroring via `CGConfigureDisplayMirrorOfDisplay` (merge on connect, restore on disconnect). Resolution switching to 1512x982 HiDPI on connect (saves/restores original mode). Dock repositioning (moves to left on connect, restores original position/autohide on disconnect). Gamma is invisible to ScreenCaptureKit so remote viewers see normal desktop.

- **`AppDelegate`** — Orchestrates everything. Every 1 second polls for active connections: `pgrep -fi "rustdesk.*--cm"` for RustDesk, `netstat` checking port 5900 ESTABLISHED for macOS Screen Sharing (VNC). On connect: enable mirroring → switch resolution → dock to left → black screen. On disconnect: restore screen → restore resolution → restore dock → disable mirroring → lock. Manages NSStatusItem menu bar UI with FileVault AuthRestart option. Installs LaunchAgent plist for login auto-start.

- **Main entry** — Creates `NSApplication`, sets delegate, calls `app.run()` (no storyboard/NIB).

## Key Technical Details

- `LSUIElement=true` in Info.plist hides Dock icon (menu bar only)
- Gamma stays black as long as the process runs; killing the app restores normal display
- Bundle ID: `com.rustdesk.screen-off`
- LaunchAgent plist written to `~/Library/LaunchAgents/com.rustdesk.screen-off.plist`
