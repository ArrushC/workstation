#!/usr/bin/env bash
# post-edit-guard.sh — Claude Code PostToolUse hook (Edit|Write|MultiEdit).
#
# Repo-specific. The repo's load-bearing file invariants (LF endings, 0755 git
# mode, UTF-8 BOM on three .ps1 files) are enforced at COMMIT time by
# scripts/check-invariants.sh (pre-commit hook + CI + `make lint`). This hook
# pulls that feedback forward to EDIT time and AUTO-REPAIRS the cheap cases, so
# a regression Claude just introduced cannot survive the turn:
#   - strip CRLF from "run-directly" shell scripts
#   - restore the on-disk +x bit and the 100755 git index mode
#   - restore the EF BB BF BOM on manage-hosts.ps1 / bootstrap.ps1 /
#     install-nerd-fonts.ps1
# It reports what it changed back to Claude (additionalContext) so the model
# re-reads the file. Silent + exit 0 when there is nothing to fix.
#
# Contract: hook JSON on stdin -> PostToolUse JSON on stdout. Fails OPEN (does
# nothing) if it cannot parse the input. See docs/claude/ + CLAUDE.md.
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

f="$(hookfield '.tool_input.file_path')"
[ -n "$f" ] || exit 0
[ -e "$f" ] || exit 0

norm="${f//\\//}" # normalise Windows backslashes for matching only

is_lf_exec=0
case "$norm" in
*/makefile/lib/*.sh | */scripts/*.sh | */.claude/hooks/*.sh | */.githooks/* | */chezmoi/dot_local/bin/executable_batpipe)
  is_lf_exec=1
  ;;
esac
is_ps1_bom=0
case "$norm" in
*/scripts/manage-hosts.ps1 | */bootstrap.ps1 | */scripts/install-nerd-fonts.ps1)
  is_ps1_bom=1
  ;;
esac
[ "$is_lf_exec" = 1 ] || [ "$is_ps1_bom" = 1 ] || exit 0

actions=""
gitdir="$(dirname "$f")"

if [ "$is_lf_exec" = 1 ]; then
  if LC_ALL=C grep -q $'\r' "$f" 2>/dev/null; then
    tmp="$(mktemp)" && tr -d '\r' <"$f" >"$tmp" && cat "$tmp" >"$f" && rm -f "$tmp"
    actions="${actions}stripped CRLF; "
  fi
  if [ ! -x "$f" ]; then
    chmod +x "$f" 2>/dev/null && actions="${actions}set +x; "
  fi
  if git -C "$gitdir" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    mode="$(git -C "$gitdir" ls-files --stage -- "$f" 2>/dev/null | awk '{print $1}')"
    if [ -n "$mode" ] && [ "$mode" != "100755" ]; then
      git -C "$gitdir" update-index --chmod=+x -- "$f" 2>/dev/null &&
        actions="${actions}staged git mode 100755; "
    fi
  fi
fi

if [ "$is_ps1_bom" = 1 ]; then
  b="$(head -c3 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  if [ "$b" != "efbbbf" ]; then
    tmp="$(mktemp)" && {
      printf '\xef\xbb\xbf'
      cat "$f"
    } >"$tmp" && cat "$tmp" >"$f" && rm -f "$tmp"
    actions="${actions}restored UTF-8 BOM; "
  fi
fi

[ -n "$actions" ] || exit 0
actions="${actions%; }"
ctx="post-edit-guard auto-repaired ${norm##*/}: ${actions}. The file changed on disk — re-read it before your next edit (this keeps fresh clones working; see CLAUDE.md file-care)."

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$ctx" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c},systemMessage:$c}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"},"systemMessage":"%s"}\n' "$ctx" "$ctx"
fi
exit 0
