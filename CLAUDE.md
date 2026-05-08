# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Bento** — personal macOS menu bar toolkit (Swift + AppKit, single-file). A grab-bag of small utilities the owner uses daily. Current modules:
1. **Remote screen-off** — when a RustDesk or macOS Screen Sharing (VNC) connection is detected, the local screen goes black for privacy; on disconnect, the screen restores and locks.
2. **Scroll direction control** — Mos-style independent scroll-direction reversal for mouse vs trackpad.

Repo directory is still named `RustDeskScreenOff` for historical reasons (predates the rename); the app/binary/bundle is `Bento`.

## Build & Run

```bash
./build_app.sh       # Compile universal binary (arm64 + x86_64), package .app bundle
open Bento.app       # Run
```

Build requires macOS 14.0+ SDK. Uses `swiftc` directly (no Xcode project/SPM). Frameworks: AppKit, CoreGraphics, IOKit.

## Architecture

Everything lives in `Bento.swift` (~640 lines), structured as three classes + main entry:

- **`ScreenController`** — Screen blackout via `CGSetDisplayTransferByFormula` (gamma to zero), restore via `CGDisplayRestoreColorSyncSettings`, lock via `open -a ScreenSaverEngine`. Multi-monitor mirroring via `CGConfigureDisplayMirrorOfDisplay` (merge on connect, restore on disconnect). Resolution switching to 1512x982 HiDPI on connect (saves/restores original mode). Dock repositioning (moves to left on connect, restores original position/autohide on disconnect). Gamma is invisible to ScreenCaptureKit so remote viewers see normal desktop.

- **`ScrollReverser`** — Independent scroll-direction control (Mos-style). Installs one session event tap for both two-finger gesture detection and scroll-wheel delta rewriting. Trackpad vs mouse follows Scroll Reverser’s approach: non-continuous scrolls are mouse, recent 2+ finger gesture scrolls are trackpad, momentum continues with the previous source. Reverses line/fixed-point/point delta axes when enabled, setting point deltas last to preserve smooth scrolling, and also rewrites the underlying IOHID scroll fields for apps that read those. Defaults: mouse reversed (ON), trackpad untouched (OFF). Persists toggles in `UserDefaults` (`ReverseMouseScroll`, `ReverseTrackpadScroll`). Self-heals on `.tapDisabledByTimeout`. Requires Accessibility and Input Monitoring permissions; if denied, Bento shows a warning alert, exposes menu actions to open the relevant System Settings panes, disables scroll toggles with "(Grant Permissions)", and allows retrying without relaunch.

- **`AppDelegate`** — Orchestrates everything. Every 1 second polls for active connections: `pgrep -fi "rustdesk.*--cm"` for RustDesk, `netstat` checking port 5900 ESTABLISHED for macOS Screen Sharing (VNC). On connect: enable mirroring → switch resolution → dock to left → black screen. On disconnect: restore screen → restore resolution → restore dock → disable mirroring → lock. Manages NSStatusItem menu bar UI with FileVault AuthRestart and scroll-reverse toggles. Installs LaunchAgent plist for login auto-start.

- **Main entry** — Creates `NSApplication`, sets delegate, calls `app.run()` (no storyboard/NIB).

## Key Technical Details

- `LSUIElement=true` in Info.plist hides Dock icon (menu bar only)
- Gamma stays black as long as the process runs; killing the app restores normal display
- Bundle ID: `com.sz.bento`
- LaunchAgent plist written to `~/Library/LaunchAgents/com.sz.bento.plist`
- `migrateLegacyLaunchAgent()` runs once at startup to unload + delete the old `com.rustdesk.screen-off.plist` from the pre-rename name. Safe to remove that function after a few launches confirm the migration succeeded for everyone.
