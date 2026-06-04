# Notchi

A pixel-art companion that lives at the MacBook notch and reflects Claude Code session state.
Swift (SPM), zero dependencies, fully local (no network, no telemetry). macOS 13+, notch Macs.

## Install as an app (daily use + autostart)

```bash
cd src
./scripts/package.sh            # release build → ~/Applications/Notchi.app (ad-hoc signed, LSUIElement)
open ~/Applications/Notchi.app
```

Click the menu-bar face icon → **Install hooks**, toggle **Launch at login**.
Open a *new* terminal `claude` session (hooks load at session start) — the creature reacts.

## Dev

```bash
cd src
swift build
./.build/debug/notchi                    # run (menu-bar agent + creature at the notch)
./.build/debug/notchi --selftest         # headless logic check (no Xcode/XCTest on CLT-only machines)
./.build/debug/notchi --dumpsprite bash  # ASCII-dump an animation (idle|waiting|edit|bash|read|other|attention)
./.build/debug/notchi --install-hooks    # install/uninstall hooks from CLI
./.build/debug/notchi --tokentest <cwd> <sessionID>   # verify transcript token parsing
```

`NOTCHI_GATE=1` launches in gate mode; `NOTCHI_SOCK=/path` runs on a custom socket (isolated testing).

## How it works

- Hooks (`SessionStart`/`Stop`/`SessionEnd`/`PreToolUse`/`PostToolUse`/`Notification`) are merged
  into `~/.claude/settings.json` (existing hooks preserved) and forward Claude's hook JSON over a
  Unix socket (`/tmp/notchi.sock`).
- `HookBridge` decodes → `StateEngine` (actor) → `SpriteView` (Canvas + TimelineView) animates the
  creature: idle breathing/blink, per-tool working poses (pencil/terminal/book/gear), wave on attention.
- Parallel sessions → clones with per-project letter badges, "+N" overflow.
- Click a clone → session details popup (project, model, duration, tool count, best-effort tokens).
- Permissions: default **observational** (watch only; popup button focuses the terminal). Settings →
  **Intercept permissions** turns on real Approve/Deny gating in the notch.

## Honest limitations (v1)

- **Tokens best-effort.** Parsed from the transcript's `usage` when present; "—" otherwise. Cost is
  windowed (last ~1MB), so it under-counts long sessions — directional, not exact.
- Gate mode blocks every tool until you click; opt-in, default off.
- Unsigned/ad-hoc build; no DMG/notarization. macOS 13+, Apple-silicon notch Macs.
- `swift test` needs full Xcode (XCTest). Tests live in `Tests/NotchiTests/`; `--selftest` covers the
  same logic without Xcode.

## Layout

```
Sources/Notchi/
├── App/          main, AppDelegate (wiring), SelfTest
├── Window/       NotchWindow, NotchGeometry, ScreenWatcher, NotchHostView
├── State/        SessionState, ToolKind, Events, StateEngine actor, TokenStats
├── Bridge/       HookProtocol, HookBridge (unix socket), HookInstaller, HookScripts, JSONLWatcher
├── Render/       SpriteCompositor (frames), SpriteView (Canvas)
├── Permission/   PopupController + PermissionPopupView, ClickPopupController + ClickPopupView
└── Settings/     SettingsStore, SettingsView
```

See `../docs/architecture.md` and `../docs/design.md` for full design.

## Uninstall

```bash
# In the app: Settings → Uninstall hooks, then quit. Or:
./.build/debug/notchi --uninstall-hooks
rm -rf ~/Applications/Notchi.app /tmp/notchi.sock
```
