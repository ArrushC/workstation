#!/usr/bin/env bash
# sync-tool-memory.sh — Claude Code PostToolUse hook (Edit|Write|MultiEdit).
#
# Repo-specific. When Claude edits a tool-source makefile, regenerate the
# auto-inventory block in the machine-level Claude memory (chezmoi source
# chezmoi/private_dot_claude/CLAUDE.md) so it never drifts from what the repo
# installs. Pure: fails OPEN (does nothing) on unparseable input or a generator
# error, always exits 0. Reports back so Claude commits it + runs `cza`.
#
# Honors MEMFILE in the environment (passed through to the generator) so the
# hook test can target a throwaway file. See CLAUDE.md + docs/claude/.
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
norm="${f//\\//}"

case "$norm" in
*/makefile/versions.mk | */makefile/tools.mk | */makefile/packages.mk | */makefile/Makefile) ;;
*) exit 0 ;;
esac

# Resolve the generator: prefer CLAUDE_PROJECT_DIR, else walk up from the file.
gen=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh" ]; then
  gen="$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh"
else
  d="$(dirname "$norm")"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -x "$d/scripts/gen-tool-memory.sh" ]; then
      gen="$d/scripts/gen-tool-memory.sh"
      break
    fi
    d="$(dirname "$d")"
  done
fi
[ -n "$gen" ] || exit 0

"$gen" >/dev/null 2>&1 || exit 0

msg="Tool inventory regenerated in chezmoi/private_dot_claude/CLAUDE.md (TOOLS block) from your makefile edit — commit it with this change and run \`cza\` to deploy the refreshed memory to ~/.claude/CLAUDE.md."

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c},suppressOutput:true}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"},"suppressOutput":true}\n' "$msg"
fi
exit 0
