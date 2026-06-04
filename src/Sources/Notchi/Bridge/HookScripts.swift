import Foundation

/// Source text of the hook scripts Notchi installs into ~/.claude/hooks/notchi/.
///
/// Two scripts:
///   - `notchi-event.sh`     — fire-and-forget. Forwards Claude's hook JSON to the socket and
///                             exits 0. Used for SessionStart, SessionEnd, Stop, PostToolUse,
///                             Notification.
///   - `notchi-pretooluse.sh` — PreToolUse. Forwards the event, then reads one response line.
///                             If Notchi is gating, it emits Claude's `permissionDecision` JSON
///                             (allow/deny). Otherwise (empty response / socket down / not gating)
///                             it passes through (exit 0, no output) and Claude's own permission
///                             flow runs.
///
/// Both forward Claude's hook JSON VERBATIM (compacted to one line). The Swift bridge decodes
/// by `hook_event_name`, so a single forwarder works for every fire-and-forget event.
enum HookScripts {

    static let eventScript = #"""
    #!/usr/bin/env bash
    # Notchi observational hook — forward Claude's hook JSON to the socket, fire-and-forget.
    SOCK="${NOTCHI_SOCK:-/tmp/notchi.sock}"
    [[ -S "$SOCK" ]] || exit 0
    command -v nc >/dev/null 2>&1 || exit 0
    payload="$(cat)"
    if command -v jq >/dev/null 2>&1; then
      compact="$(printf '%s' "$payload" | jq -c . 2>/dev/null)"
      [[ -n "$compact" ]] && payload="$compact" || payload="$(printf '%s' "$payload" | tr '\n' ' ')"
    else
      payload="$(printf '%s' "$payload" | tr '\n' ' ')"
    fi
    printf '%s\n' "$payload" | nc -U "$SOCK" -w 1 >/dev/null 2>&1 || true
    exit 0
    """#

    static let preToolUseScript = #"""
    #!/usr/bin/env bash
    # Notchi PreToolUse hook. Forwards the event; if Notchi is gating it waits for the
    # Approve/Deny response and emits Claude's permissionDecision JSON. Otherwise passthrough.
    SOCK="${NOTCHI_SOCK:-/tmp/notchi.sock}"
    [[ -S "$SOCK" ]] || exit 0
    command -v nc >/dev/null 2>&1 || exit 0
    payload="$(cat)"
    if command -v jq >/dev/null 2>&1; then
      compact="$(printf '%s' "$payload" | jq -c . 2>/dev/null)"
      [[ -n "$compact" ]] && payload="$compact" || payload="$(printf '%s' "$payload" | tr '\n' ' ')"
    else
      payload="$(printf '%s' "$payload" | tr '\n' ' ')"
    fi
    # nc writes the request then reads the response. `-w 30` caps the wait so a hung or
    # quit Notchi (or a stale socket) can never freeze the tool forever — it falls through
    # to Claude's own permission flow after 30s. Observational mode closes instantly → passthrough.
    resp="$(printf '%s\n' "$payload" | nc -U -w 30 "$SOCK" 2>/dev/null | head -n 1)"
    [[ -z "$resp" ]] && exit 0
    if printf '%s' "$resp" | grep -q '"decision":"approve"'; then
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
      exit 0
    fi
    reason="$(printf '%s' "$resp" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')"
    [[ -z "$reason" ]] && reason="Denied in Notchi"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
    exit 0
    """#
}
