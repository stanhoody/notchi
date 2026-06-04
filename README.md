# Notchi

A pixel-art companion that lives in your MacBook notch and shows what Claude Code is doing — at a glance, without tab-switching to the terminal.

When a Claude Code session is running, a little creature appears beside the camera. It types at a keyboard while Claude writes code, lights up a lightbulb when it's planning, shows a magnifier while reading files, waves when Claude needs you, and goes quiet when there's nothing to do. Spin up several sessions and you get several creatures. Spawn sub-agents and they appear as small companions. It has a bit of an attitude, too — try an `rm -rf` and see.

Fully local. No network, no telemetry, no accounts.

## What it shows

| Claude Code is… | Notchi |
|---|---|
| writing code (Edit/Write) | typing, keyboard icon |
| running a shell command (Bash) | terminal-window icon |
| reading files (Read/Grep/Glob) | magnifier icon |
| browsing the web (WebFetch/WebSearch) | globe icon |
| planning (TodoWrite / plan mode) | lightbulb |
| thinking between tools | `...` |
| working 30s+ on one thing | tired, with a coffee |
| done with a turn | a happy hop + star |
| a tool errored | confused `?` + a quip |
| waiting on you (permission / input) | waves, the island expands |
| idle for a while | sits still, then sleeps (`Zzz`) |
| nothing running | hidden |

The notch itself expands into a black "island" (Dynamic-Island style) to host the creatures and, when Claude needs you, a small panel with an **Open in Claude Code** button.

## Requirements

- A MacBook with a notch (M1 Pro/Max 2021+, or any M2/M3/M4 Pro/Max/Air), macOS 13+
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed
- Swift toolchain (Xcode or Command Line Tools) to build

## Build & run

```bash
cd src
swift build -c release
./scripts/package.sh        # builds Notchi.app into ~/Applications
open ~/Applications/Notchi.app
```

Then click the Notchi icon in the menu bar → **Install Claude Code hooks**. Open a new `claude` session and the creature comes alive. (Hooks are read when a session starts, so existing sessions won't pick them up — open a new one.)

## How it works

- Notchi installs hooks into `~/.claude/settings.json` (merging with any hooks you already have — e.g. it won't clobber existing `SessionStart` scripts).
- The hooks forward Claude Code's events (`SessionStart`, `Stop`, `PreToolUse`, `PostToolUse`, `Notification`, `SubagentStop`, `SessionEnd`) over a local Unix socket to the app.
- **Observational by default:** Notchi only interrupts when Claude actually pings you (its `Notification`). It does not gate your tools. An optional "Confirm every non-allowlisted tool" toggle turns on true in-notch Approve/Deny for power users.
- Uninstall any time from the menu bar, or `notchi --uninstall-hooks`.

## Settings (menu bar)

Character skin (Blob / Kitty / Bot), accent color, animation speed, opacity, hide-in-fullscreen, hide-on-video-calls, optional sound, launch-at-login, and the permission-gate toggle.

## Privacy

No network calls. No telemetry. No analytics. No update check. Token/usage figures, when shown, are read from Claude Code's own local transcript files; nothing leaves your machine.

## CLI

```bash
notchi --install-hooks      # install Claude Code hooks
notchi --uninstall-hooks    # remove them
notchi --export-assets DIR  # dump all sprite GIFs/PNGs for review
notchi --selftest           # run the headless logic checks
```

## Credits & notes

- Sub-agent visualization, optional sound, speech bubbles and selectable characters are inspired by [pixel-agents](https://github.com/pablodelucca/pixel-agents) by Pablo De Lucca.
- An unrelated project named [sk-ruban/notchi](https://github.com/sk-ruban/notchi) also exists in this space; this is a separate, independent implementation.

## License

MIT — see [LICENSE](LICENSE).
