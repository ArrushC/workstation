#!/usr/bin/env bash
# lib.sh — sourced by the repo's Claude Code hooks (.claude/hooks/*.sh); not a hook itself.
# Reads the hook input with jq, else python3, else not at all (callers then fail
# open), and writes hook JSON that stays valid on the no-jq path. The global
# hooks in dotfiles/claude/hooks/ keep their own copies: they deploy alone.
# HOOK_LIB_NO_JQ=1 / HOOK_LIB_NO_PY=1 force the fallbacks (test-hooks.sh).

HOOK_INPUT="$(cat)"

_hook_jq() { [ -z "${HOOK_LIB_NO_JQ:-}" ] && command -v jq >/dev/null 2>&1; }
_hook_py() { [ -z "${HOOK_LIB_NO_PY:-}" ] && command -v python3 >/dev/null 2>&1; }

# hook_field <.dotted.path> — the string at that path, else nothing.
hook_field() {
  if _hook_jq; then
    printf '%s' "$HOOK_INPUT" | jq -r "($1 // empty) | strings" 2>/dev/null
  elif _hook_py; then
    printf '%s' "$HOOK_INPUT" | HF="$1" python3 -c 'import os,sys,json
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

# _hook_str <s> — <s> as a JSON string literal, for the no-jq path.
_hook_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# hook_context <EventName> <message> [visible] — additionalContext for the model.
# With "visible" the message is also a systemMessage shown to the user, and the
# output is not suppressed.
hook_context() {
  if _hook_jq; then
    jq -nc --arg e "$1" --arg c "$2" --arg v "${3:-}" \
      'if $v == "visible"
       then {hookSpecificOutput:{hookEventName:$e,additionalContext:$c},systemMessage:$c}
       else {hookSpecificOutput:{hookEventName:$e,additionalContext:$c},suppressOutput:true} end'
  elif [ "${3:-}" = visible ]; then
    printf '{"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s},"systemMessage":%s}\n' \
      "$(_hook_str "$1")" "$(_hook_str "$2")" "$(_hook_str "$2")"
  else
    printf '{"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s},"suppressOutput":true}\n' \
      "$(_hook_str "$1")" "$(_hook_str "$2")"
  fi
}

# hook_deny <reason> — PreToolUse deny.
hook_deny() {
  if _hook_jq; then
    jq -nc --arg r "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
      "$(_hook_str "$1")"
  fi
}
