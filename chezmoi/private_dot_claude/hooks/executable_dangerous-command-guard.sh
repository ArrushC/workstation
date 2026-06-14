#!/usr/bin/env bash
# dangerous-command-guard.sh — Claude Code PreToolUse hook (Bash).
#
# GLOBAL (deployed to ~/.claude/hooks/ by chezmoi; active in every repo). A
# safety net over Bash commands:
#   - DENY catastrophic, never-legitimate-from-an-agent commands
#   - ASK before risky-but-sometimes-legitimate ones (the user confirms)
# It is a tripwire, not airtight security: exotic obfuscation can slip past. Keep
# the patterns conservative to avoid false positives on normal work.
#
# Contract: hook JSON on stdin -> PreToolUse JSON on stdout. Fails OPEN.
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
emit() {  # emit <deny|ask> <reason>
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg d "$1" --arg r "$2" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  fi
  exit 0
}
match() { printf '%s' "$c" | grep -Eq "$1"; }

c="$(hookfield '.tool_input.command')"
[ -n "$c" ] || exit 0

# ---------- HARD DENY: catastrophic ----------
# rm with combined -r and -f flags ...
if match 'rm[[:space:]]+-([a-zA-Z]*[rR][a-zA-Z]*[fF]|[a-zA-Z]*[fF][a-zA-Z]*[rR])[a-zA-Z]*([[:space:]]|$)'; then
  # ... targeting / , /* , ~ , $HOME , or with --no-preserve-root
  if match '(--no-preserve-root|[[:space:]]/([[:space:]]|\*|$)|[[:space:]]~([[:space:]]|$)|[[:space:]]\$HOME([[:space:]]|$))'; then
    emit deny "Refusing 'rm -rf' targeting / , ~ , or \$HOME (irreversible, wipes the system or home). Narrow the path, or run it yourself if you really mean it."
  fi
fi
# fork bomb
if match ':[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:'; then
  emit deny "Refusing a fork bomb. This would hang the machine."
fi
# writing a filesystem / raw block device
if match 'dd[[:space:]].*of=/dev/(sd|nvme|vd|hd|mmcblk|disk)'; then
  emit deny "Refusing 'dd' writing directly to a raw disk device (of=/dev/...). This destroys the drive's contents."
fi
if match '(^|[[:space:]])mkfs(\.|[[:space:]])'; then
  emit deny "Refusing 'mkfs' — formatting a filesystem is destructive and almost never what an agent should do."
fi
if match '>[[:space:]]*/dev/(sd|nvme|vd|hd|mmcblk|disk)'; then
  emit deny "Refusing a redirect into a raw block device (> /dev/...). This corrupts the disk."
fi
if match 'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-?R[a-zA-Z]*[[:space:]]+0?777[[:space:]]+/([[:space:]]|$)'; then
  emit deny "Refusing 'chmod -R 777 /' — recursively world-writable from root breaks the system."
fi

# ---------- ASK: risky but sometimes legitimate ----------
if match '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh([[:space:]]|$)'; then
  emit ask "This pipes a network download straight into a shell (curl|bash). Confirm the source is trusted. (The repo's own bootstrap does this intentionally; ad-hoc ones deserve a look.)"
fi
if match 'git[[:space:]]+push[[:space:]].*(--force([[:space:]=]|$)|[[:space:]]-f([[:space:]]|$))'; then
  emit ask "This is a force push — it can overwrite remote history (and clobber others' commits). Confirm the branch and that this is intended."
fi
if match 'chmod[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-?R[a-zA-Z]*[[:space:]]+0?777([[:space:]]|$)'; then
  emit ask "Recursive 'chmod 777' makes files world-writable. Confirm you really want that scope."
fi
exit 0
