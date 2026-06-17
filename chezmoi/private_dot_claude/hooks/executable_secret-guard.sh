#!/usr/bin/env bash
# secret-guard.sh — Claude Code PreToolUse hook (Edit|Write|MultiEdit|Read|Bash).
#
# GLOBAL (deployed to ~/.claude/hooks/ by chezmoi; active in every repo). Keeps
# secrets out of Claude's reach:
#   - DENY editing OR reading the age identity, SSH private keys, and certs
#   - ASK before any Bash command that names one of those secrets
# The age identity (~/.config/chezmoi/key.txt) is the crown jewel: it is never
# committed and decrypts every encrypted_*.age source file in the dotfiles repo.
#
# Contract: hook JSON on stdin -> PreToolUse JSON on stdout. Fails OPEN if it
# cannot parse the input (so it never wedges the session).
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
emit() { # emit <allow|deny|ask> <reason>
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg d "$1" --arg r "$2" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  fi
  exit 0
}

is_secret_path() { # 0 if $1 looks like a private key / age identity / cert
  case "${1//\\//}" in
  */chezmoi/key.txt) return 0 ;;
  */id_rsa | */id_ed25519 | */id_ecdsa | */id_dsa) return 0 ;;
  *.pem | *.key) return 0 ;;
  esac
  return 1
}

tool="$(hookfield '.tool_name')"
case "$tool" in
Edit | Write | MultiEdit | Read)
  f="$(hookfield '.tool_input.file_path')"
  [ -n "$f" ] || exit 0
  if is_secret_path "$f"; then
    verb="modify"
    [ "$tool" = "Read" ] && verb="read"
    emit deny "Refusing to $verb $f — it looks like a private key, the chezmoi age identity, or a cert. Claude must not load or change secrets. If this is intentional, the user can do it manually or temporarily disable the secret-guard hook."
  fi
  ;;
Bash)
  c="$(hookfield '.tool_input.command')"
  [ -n "$c" ] || exit 0
  if printf '%s' "$c" | grep -Eq '\bkey\.txt\b|\bid_(rsa|ed25519|ecdsa|dsa)\b'; then
    emit ask "This command references what looks like the age identity or an SSH private key. Confirm it will not read, copy, or commit the secret before allowing."
  fi
  ;;
esac
exit 0
