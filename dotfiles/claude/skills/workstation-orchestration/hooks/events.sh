#!/usr/bin/env bash
# workstation-orchestration UserPromptSubmit hook: print the [orchestration] lines about jobs
# this session hasn't heard of yet (ws-agent events reads the hook JSON on stdin: session_id,
# cwd). Read-only, files only, and it never fails a prompt: without ws-agent, on an error or a
# slow answer it prints nothing. Run through bash by hooks.json, so the file needs no exec bit.
input=$(cat)
cwd=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$cwd" ] && [ -d "$cwd" ] && { cd "$cwd" 2>/dev/null || true; }
command -v ws-agent >/dev/null 2>&1 || exit 0
out=$(printf '%s' "$input" | timeout "${WS_AGENT_HOOK_TIMEOUT:-3}" ws-agent events 2>/dev/null) || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
