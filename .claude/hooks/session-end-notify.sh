#!/usr/bin/env bash
# session-end-notify.sh — Claude Code SessionEnd hook (repo-scoped).
#
# When a session in the workstation repo ends with uncommitted changes and/or a
# pending `chezmoi apply`, fire a desktop toast so the work isn't forgotten.
# Reuses the global notify.sh (WSL toast / notify-send / bell). SessionEnd can't
# inject context, so the only output is the toast side-effect. Fail-open; always
# exit 0. Skips reason=clear/resume (neither is a real departure). The toast is
# fired DETACHED (setsid) so the hook returns instantly: SessionEnd runs during
# shutdown, and a synchronous ~1s powershell.exe toast on WSL gets cancelled
# ("Hook cancelled") before it finishes.
#
# Honors WORKSTATION_NOTIFY (override the notifier) so the hook test can target a
# recording stub. See CLAUDE.md + docs/claude/.
set -u

INPUT="$(cat)"
hookfield() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$INPUT" | HF="$1" python3 -c 'import os,sys,json
p=os.environ["HF"].lstrip(".").split(".")
try:
    v=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in p:
    v=v.get(k) if isinstance(v,dict) else None
print(v if isinstance(v,str) else "")' 2>/dev/null
  fi
}

reason="$(hookfield '.reason')"
# clear (/clear) and resume (suspend-for-resume) are not real departures — no nag.
case "$reason" in clear | resume) exit 0 ;; esac

cwd="$(hookfield '.cwd')"
root=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  root="$CLAUDE_PROJECT_DIR"
elif [ -n "$cwd" ] && [ -d "$cwd" ]; then
  root="$cwd"
fi
[ -n "$root" ] || exit 0
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$top" ] && root="$top"

# uncommitted changes
nd=0
dirty="$(git -C "$root" status --porcelain 2>/dev/null)"
[ -n "$dirty" ] && nd="$(printf '%s\n' "$dirty" | grep -c .)"

# pending chezmoi apply
np=0
if command -v chezmoi >/dev/null 2>&1; then
  pend="$(timeout 4s chezmoi status 2>/dev/null)" || pend=""
  [ -n "$pend" ] && np="$(printf '%s\n' "$pend" | grep -c .)"
fi

[ "$nd" -eq 0 ] && [ "$np" -eq 0 ] && exit 0

msg="workstation: $nd uncommitted change(s)"
[ "$np" -gt 0 ] && msg="$msg; chezmoi apply pending ($np)"

# Fire the toast DETACHED so this hook returns immediately and the toast still
# completes after SessionEnd tears the hook down. setsid reparents it into its
# own session (survives a process-group kill); fall back to a backgrounded
# subshell where setsid is absent (e.g. macOS).
notify="${WORKSTATION_NOTIFY:-$HOME/.claude/notify.sh}"
if [ -x "$notify" ]; then
  if command -v setsid >/dev/null 2>&1; then
    setsid "$notify" 'Workstation repo' "$msg" </dev/null >/dev/null 2>&1 &
  else
    ("$notify" 'Workstation repo' "$msg" </dev/null >/dev/null 2>&1 &)
  fi
fi
exit 0
