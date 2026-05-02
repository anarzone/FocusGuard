# FocusGuard

[![CI](https://github.com/anarzone/FocusGuard/actions/workflows/ci.yml/badge.svg)](https://github.com/anarzone/FocusGuard/actions/workflows/ci.yml)

Native macOS menu bar app that detects distractions during focus sessions and escalates from silent logging → motivational notification → full-screen block. Generates per-session and per-day reports so you can see where time leaks.

Privacy-first: all data lives on your Mac. No network calls.

## Features

- **Always-on activity tracking** — frontmost app, window title, and active browser tab URL captured every second; coalesced into a SwiftData store
- **Rule-based classification** — every event tagged Focus / Neutral / Distraction via a user-editable rule store (bundle id / URL host / window-title regex)
- **Sessions with auto-stop** — pick 25/50/90 min or custom; pause/resume; auto-stop at planned duration
- **Escalation engine** — silence threshold → motivational notification → full-screen block overlay (with a 5s countdown override). Strict mode blocks immediately on any distraction
- **Live reports** — per-minute timeline (Apple Charts), top distractions grouped by host, weekly bar chart
- **Calendar autostart** — auto-start a focus session when a calendar event matching a keyword begins
- **Privacy controls** — per-app window-title opt-out, configurable retention (30 days → keep all), JSON / CSV export, one-click delete-all
- **Distribution-ready** — hardened runtime on, signed with Apple Development cert, Apple Events entitlement declared

## Install

```sh
brew install --cask anarzone/focusguard/focusguard
```

That's it. Click 🛡 FG in the menu bar to start. Upgrade with `brew upgrade --cask anarzone/focusguard/focusguard`. Remove with all data via `brew uninstall --cask --zap focusguard`.

## Build from source

Requires macOS 14+, Xcode 16+, and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
open FocusGuard.xcodeproj   # then ⌘R
```

Or build & install in one shot:

```sh
./scripts/install.sh
```

Run the 22 unit tests:

```sh
xcodebuild -project FocusGuard.xcodeproj -scheme FocusGuard \
           -destination 'platform=macOS' test
```

Cut a new release (builds, tags, pushes, updates the Homebrew tap):

```sh
./scripts/release.sh 0.2.0
```

## Architecture

```
AppDelegate
  └── AppState (single owner)
       ├── SwiftData ModelContainer
       │     ├── Session, ActivityEvent, AppRule, TitleOptOut
       ├── ActivityTracker (1Hz polling + NSWorkspace observer)
       │     ├── WindowInspector  (CGWindowList → window titles)
       │     └── BrowserTabReader (NSAppleScript → tab URLs)
       ├── Classifier (rule cache, 30s TTL)
       ├── SessionManager (start/stop/pause/resume, planned-duration auto-stop)
       ├── EscalationEngine (silence → notify → block state machine)
       │     ├── NotificationPresenter (DistractionNotifier protocol)
       │     └── BlockOverlayController (BlockOverlayPresenting protocol)
       ├── CalendarAutostartCoordinator (EKEventStore polling)
       ├── ReportBuilder (per-minute timeline, top distractions, breakdowns)
       └── RetentionPolicy (daily prune of old data)
```

UI surfaces:
- **Menu bar popover** — Glanceable variant: hero focus minutes, week strip, now-card, tight start row
- **Standalone window** — Reports (Hero Numeric variant) + Settings (sub-sidebar with General / Sessions / Escalation / Rules / Privacy / About)
- **Block overlay** — borderless `NSWindow` at `.screenSaver` level on every monitor, with motivational message and countdown override

## Status

Feature-complete vs the original plan, including:

- ✅ Phases 1–7 (skeleton, tracking, browser URLs, classification, escalation, reports, polish)
- ✅ Calendar autostart, pause/resume, custom duration, JSON+CSV export
- ✅ Hardened runtime, signed with Personal Team, app icon

Deferred:
- Sparkle auto-update
- Sentry / crash reporting
- Localization beyond English
