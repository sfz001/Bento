# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Bento** — personal macOS menu bar toolkit (Swift + AppKit, single-file). A grab-bag of small utilities the owner uses daily. Current modules:
1. **Remote screen-off** — when a RustDesk or macOS Screen Sharing (VNC) connection is detected, the local screen goes black for privacy; on disconnect, the screen restores and locks.
2. **Scroll direction control** — Mos-style independent scroll-direction reversal for mouse vs trackpad.
3. **Window tiling (分屏)** — MaxTo/Moom-style per-monitor split layouts: double-click a titlebar to snap the window into its layout cell (double-click again to restore), or hold a modifier (⌘/⌃) while dragging a titlebar to snap into the cell highlighted on a grid overlay. Layouts are recursive binary-split trees, edited via a WYSIWYG full-screen overlay editor on each real display, persisted per-display (keyed by CGDisplay UUID) in `~/Library/Application Support/Bento/config.json`.
4. **Menu bar icon manager (菜单栏图标管理)** — Bartender/Ice-style selective hide/show of menu bar icons: menu opens a checklist window (NSTableView) listing every third-party icon by owning app **plus movable system modules** (Battery/Wi-Fi/User Switching; Clock and Control Center are pinned by the system and excluded) **plus Bento's own icon** (sortable, not hideable); unchecking hides an icon into the system "«" overflow section, checking shows it again; rows are **drag-reorderable** and the row order is applied to the real menu bar (persisted as `MenuBarIconOrder`). All moves are done by rewriting `com.apple.MenuBarAgent`'s `TrailingItemPreferredPositions` plist (macOS 27 mechanism — no synthetic drags); a 10000pt "hider" status item blocks hidden items from ever re-fitting. Hidden keys persist in UserDefaults (`HiddenMenuBarItemKeys`); manual user ⌘-drags are adopted back into that state rather than fought.

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

- **Menu bar icon manager** (`MARK: - Menu Bar Icon Manager` section) — targets the macOS 27 menu bar architecture (the macOS 26 ControlCenter-hosted / synthetic-⌘-drag "scromble" implementation was removed; see git history if ever needed). Key facts, all verified on 27.0:
  - macOS 27 hosts the whole menu bar in a dedicated `MenuBarAgent` process: no more per-icon layer-25 CG windows, so CG-window enumeration finds nothing. Item layout lives in `com.apple.MenuBarAgent`'s `TrailingItemPreferredPositions` dict: key `status:<signing-id>::<autosaveName>` (bundleID for properly signed apps, executable name for ad-hoc — Bento writes both candidate keys for its own items, `BentoMain`/`BentoHider`) or `module:<Name>` for system modules; value = preferred distance from the right edge (bigger = further left). External writes apply live within ~0.5s (cfprefsd) — no agent restart, no synthetic events.
  - System modules are managed through the same `module:` entries (AX id ↔ dict key via `moduleKeyMap`; instance suffixes like `module:BentoBox-0` handled). Verified movable/hideable: Battery, WiFi, UserSwitcher. Verified PINNED (writes silently ignored, frame never moves): Clock and Control Center (`module:BentoBox` — Apple's internal name for it, coincidentally) — these are in `pinnedModules` and never shown as rows. All managed items (third-party + modules + `bento:main`) share one unified position grid (base 100, step 8); order adoption runs every pass — the actual bar layout is the source of truth for ordering, never the persisted list (enforcing a stale persisted order silently rearranges the user's bar).
  - System layout rule: items are packed right-to-left in ascending position order; the first item that doesn't fit AND everything left of it collapse into the "«" overflow chevron (click to expand). New items with no dict entry start in overflow on a crowded bar.
  - Hiding exploits that rule: the 10000pt hider never fits, so it sits in overflow itself (occupying no visible space) while permanently blocking every higher-positioned (hidden) item, independent of free space. Layout bands are computed from `module:` max: visible = base+8·i, hider = base+800, hidden = base+1000+8·j, hidden-threshold = base+900. Caveat: chevron expansion may not work while the hider exists; quitting Bento removes the hider and hidden icons return to the normal system overflow.
  - Identity still comes from each app's `AXExtrasMenuBar` (title/desc); persistence keys are `bundleID|index`, never titles (WeChat badge titles are volatile). Dict entries are matched per app by prefix; when entry count equals item count they pair in sorted order (covers custom autosave names like `systemuiserver::Siri`, `campo::Item-1`).
  - Enforcer runs every 3s on a serial queue, gated by a (positions-dict + running-apps) signature. The agent dict is the source of truth: manual user ⌘-drags are *adopted* back into `hiddenKeys`/`iconOrder` (position past the hidden threshold = hidden); Bento only rewrites the dict on semantic mismatch (should-be-hidden visible, wrong visible order, missing entries), never over numeric drift — this avoids write-fights with the agent. UI-triggered rounds set `suppressAdoptionOnce` so fresh user intent isn't immediately overwritten by stale positions.

- **Main entry** — Creates `NSApplication`, sets delegate, calls `app.run()` (no storyboard/NIB).

## Key Technical Details

- `LSUIElement=true` in Info.plist hides Dock icon (menu bar only)
- Gamma stays black as long as the process runs; killing the app restores normal display
- Bundle ID: `com.sz.bento`
- LaunchAgent plist written to `~/Library/LaunchAgents/com.sz.bento.plist`
- `migrateLegacyLaunchAgent()` runs once at startup to unload + delete the old `com.rustdesk.screen-off.plist` from the pre-rename name. Safe to remove that function after a few launches confirm the migration succeeded for everyone.
