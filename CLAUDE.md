# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Bento** — personal macOS menu bar toolkit (Swift + AppKit, single-file). A grab-bag of small utilities the owner uses daily. Current modules:
1. **Remote screen-off** — when a RustDesk or macOS Screen Sharing (VNC) connection is detected, the local screen goes black for privacy; on disconnect, the screen restores and locks.
2. **Scroll direction control** — Mos-style independent scroll-direction reversal for mouse vs trackpad.
3. **Window tiling (分屏)** — MaxTo/Moom-style per-monitor split layouts: double-click a titlebar to snap the window into its layout cell (double-click again to restore), or hold a modifier (⌘/⌃) while dragging a titlebar to snap into the cell highlighted on a grid overlay. Layouts are recursive binary-split trees, edited via a WYSIWYG full-screen overlay editor on each real display, persisted per-display (keyed by CGDisplay UUID) in `~/Library/Application Support/Bento/config.json`.
4. **Menu bar icon manager (菜单栏图标管理)** — Bartender/Ice-style selective hide/show of third-party menu bar icons: menu opens a checklist window listing every third-party icon by owning app; unchecking drags it (synthetic ⌘-drag) behind a 10000pt-wide "hider" status item so macOS parks it offscreen; checking drags it back. Rows have ←/→ buttons to reorder icons in the real menu bar (order persisted as `MenuBarIconOrder` and applied by drag-walking each icon left→right; note that self-updating ticker items like stock-price icons recreate their window and reset position themselves — that part can't be pinned). Bento's own icon is pinned rightmost among third-party icons. Hidden keys persist in UserDefaults (`HiddenMenuBarItemKeys`). System modules (clock/battery/…) are left to System Settings → Control Center.

Repo directory is still named `RustDeskScreenOff` for historical reasons (predates the rename); the app/binary/bundle is `Bento`.

## Build & Run

```bash
./build_app.sh       # Compile universal binary (arm64 + x86_64), package .app bundle
open Bento.app       # Run
```

Build requires macOS 14.0+ SDK. Uses `swiftc` directly (no Xcode project/SPM). Frameworks: AppKit, CoreGraphics, IOKit.

## Architecture

Everything lives in `Bento.swift` (~2400 lines), structured as four classes + tiling module + main entry:

- **`ScreenController`** — Screen blackout via `CGSetDisplayTransferByFormula` (gamma to zero), restore via `CGDisplayRestoreColorSyncSettings`, lock via `open -a ScreenSaverEngine`. Multi-monitor mirroring via `CGConfigureDisplayMirrorOfDisplay` (merge on connect, restore on disconnect). Before mirroring, it persists a display mirror snapshot in `UserDefaults` (`BentoMirrorSnapshot`) so disconnect/relaunch can restore the pre-connection layout instead of relying only on process memory; the menu also exposes "Restore Extended Displays" as a manual fallback. Resolution switching to 1512x982 HiDPI on connect (saves/restores original mode). Dock repositioning (moves to left on connect, restores original position/autohide on disconnect). Gamma is invisible to ScreenCaptureKit so remote viewers see normal desktop.

- **`ScrollReverser`** — Independent scroll-direction control (Mos-style). Installs one session event tap for both two-finger gesture detection and scroll-wheel delta rewriting. Trackpad vs mouse follows Scroll Reverser’s approach: non-continuous scrolls are mouse, recent 2+ finger gesture scrolls are trackpad, momentum continues with the previous source. Reverses line/fixed-point/point delta axes when enabled, setting point deltas last to preserve smooth scrolling, and also rewrites the underlying IOHID scroll fields for apps that read those. Defaults: mouse reversed (ON), trackpad untouched (OFF). Persists toggles in `UserDefaults` (`ReverseMouseScroll`, `ReverseTrackpadScroll`). Self-heals on `.tapDisabledByTimeout`. Requires Accessibility and Input Monitoring permissions; if denied, Bento shows a warning alert, exposes menu actions to open the relevant System Settings panes, disables scroll toggles with "(Grant Permissions)", and allows retrying without relaunch.

- **`AppDelegate`** — Orchestrates everything. Every 1 second polls for active connections: `pgrep -fi "rustdesk.*--cm"` for RustDesk, `netstat` checking port 5900 ESTABLISHED for macOS Screen Sharing (VNC). On connect: enable mirroring → switch resolution → dock to left → black screen. On disconnect: restore screen → restore resolution → restore dock → disable mirroring → lock. Manages NSStatusItem menu bar UI with FileVault AuthRestart, scroll-reverse toggles, and the tiling section. Installs LaunchAgent plist for login auto-start (first launch only; afterwards the 开机自启 menu toggle owns it).

- **Tiling module** (`MARK: - Window Tiling` section) — key pieces:
  - `CoordConv` — the ONLY place AppKit (bottom-left origin) ↔ CG/AX (main-screen top-left origin) conversion happens. Never flip y elsewhere.
  - `LayoutNode` — recursive binary-split tree (`cell` / `split(dir:V|H, ratio, a, b)`), defensive Codable (bad ratio→0.5, missing node→cell, corrupt JSON→default + error.log).
  - `TilingConfig` — JSON persistence; display layouts keyed by CGDisplay UUID (`DisplayKeys`), never displayID/screen index.
  - `WindowManager` — CGWindowList geometry prefilter (titlebar band, 28pt) before any AX call; AX frame set with read-back + one retry; snappable = standard subrole, not fullscreen/minimized, size-settable.
  - `TilingController` — session event tap (leftMouseDown/Up/Dragged/mouseMoved) that *swallows* the 2nd click of titlebar double-clicks (plus its paired mouse-up, plus same-spot 3rd+ clicks inside the double-click window); modifier+titlebar-drag shows grid overlays (`ignoresMouseEvents`, `.screenSaver` level) and snaps on release. Snap memory stores (original, actual-snapped) frames per CGWindowID (`_AXUIElementGetWindow` private API); restore clamps to nearest screen if the original display is gone. Watchdog re-enables/rebuilds the tap; wake/unlock rebuilds it and resets all click state; `didChangeScreenParameters` closes the editor and invalidates display-key cache.
  - `LayoutEditorSession` — one borderless editor window per screen covering exactly `visibleFrame` (menu bar/Dock stay clickable), draggable floating toolbar, right-click split/merge menu, divider dragging clamped to 0.08–0.92, Esc cancels; only 保存并应用 writes config.
  - Uncaught exceptions append to `~/Library/Application Support/Bento/error.log`; single-instance enforced in main.

- **Menu bar icon manager** (`MARK: - Menu Bar Icon Manager` section) — macOS 26 hosts ALL status item windows in the ControlCenter process (same pid for every icon, `button.window == nil`, so identity can't come from window owners or window numbers). Instead: each app exposes its own items via its `AXExtrasMenuBar` (title/desc/frame), matched to CG windows by AX-frame-midX ≈ window-midX (±10); system modules come from ControlCenter's extras (`com.apple.menuextra.*` AXIdentifier). Key facts verified on 26.6:
  - Moving an item = synthetic ⌘-drag with `windowID` event field `0x33`, delivered via the "scromble" (null event → `CGEvent.tapCreateForPid` → repost to session tap → repost to pid), 5 retries with frame-change waits. Drop points clamp to visible slots — you cannot park an item offscreen by dragging.
  - Hiding = our own `NSStatusItem` with `length = 10000` pushes everything left of it offscreen (system overflow behavior); the giant window does NOT eat app-menu clicks. Hide-drops must land deep inside the hider's window (~anchor − width/2); shallow drops clamp to the visible slot right of it.
  - WeChat etc. have volatile badge titles ("2") — persistence keys are `bundleID|index`, never titles.
  - Show-drags run only on explicit user unhide (`pendingShow`); system-overflow-parked items are never fought automatically. Enforcer runs every 3s on a serial queue; hider is removed when nothing is hidden, so quitting Bento restores everything.

- **Main entry** — Creates `NSApplication`, sets delegate, calls `app.run()` (no storyboard/NIB).

## Key Technical Details

- `LSUIElement=true` in Info.plist hides Dock icon (menu bar only)
- Gamma stays black as long as the process runs; killing the app restores normal display
- Bundle ID: `com.sz.bento`
- LaunchAgent plist written to `~/Library/LaunchAgents/com.sz.bento.plist`
- `migrateLegacyLaunchAgent()` runs once at startup to unload + delete the old `com.rustdesk.screen-off.plist` from the pre-rename name. Safe to remove that function after a few launches confirm the migration succeeded for everyone.
