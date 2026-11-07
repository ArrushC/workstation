#!/usr/bin/env bash
# workstation-orchestration SessionStart hook: print the one-line [orchestration] context of
# the session's directory (ws-agent context) for Claude to route by. Read-only, and it never
# fails a session start: without ws-agent (Windows, a host without it), on an error or a slow
# answer it prints nothing. Run through bash by hooks.json, so the file needs no exec bit.
cwd=$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$cwd" ] && [ -d "$cwd" ] && { cd "$cwd" 2>/dev/null || true; }
command -v ws-agent >/dev/null 2>&1 || exit 0
out=$(timeout "${WS_AGENT_HOOK_TIMEOUT:-3}" ws-agent context 2>/dev/null) || exit 0
line=${out%%$'\n'*}
[ -n "$line" ] && printf '%s\n' "$line"
exit 0
