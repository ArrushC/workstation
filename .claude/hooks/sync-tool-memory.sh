#!/usr/bin/env bash
# sync-tool-memory.sh — Claude Code PostToolUse hook (Edit|Write|MultiEdit).
#
# Repo-specific. When Claude edits a mise config*.toml (tool pins, host pins
# in [vars], or bootstrap.packages), regenerate the auto-inventory block in
# the machine-level Claude memory (chezmoi source chezmoi/private_dot_claude/
# CLAUDE.md) so it never drifts from what the repo installs. Pure: fails OPEN
# (does nothing) on unparseable input or a generator error, always exits 0.
# Reports back so Claude commits it (and refreshes mise.lock on a pin change).
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
# A chezmoi-managed dotfile's OWN config.toml (helix/herdr/tealdeer/…) is not
# mise's config*.toml — exclude it before the glob below, which would
# otherwise also match "*/dot_config/helix/config.toml" etc. (both end in
# "/config.toml").
*/chezmoi/dot_config/*) exit 0 ;;
*/config.toml | */config.*.toml) ;;
*) exit 0 ;;
esac

# Resolve the generators from the EDITED FILE's checkout (walk up from the
# file), so an edit inside a git worktree regenerates THAT worktree's files.
# CLAUDE_PROJECT_DIR is only a fallback: it points at the main checkout, and
# preferring it used to silently regenerate the WRONG copy (a content no-op)
# while claiming success for the worktree edit.
scripts=""
d="$(dirname "$norm")"
while [ "$d" != "/" ] && [ -n "$d" ]; do
  if [ -x "$d/scripts/gen-tool-memory.sh" ]; then
    scripts="$d/scripts"
    break
  fi
  d="$(dirname "$d")"
done
if [ -z "$scripts" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "$CLAUDE_PROJECT_DIR/scripts/gen-tool-memory.sh" ]; then
  scripts="$CLAUDE_PROJECT_DIR/scripts"
fi
[ -n "$scripts" ] || exit 0

"$scripts/gen-tool-memory.sh" >/dev/null 2>&1 || exit 0

msg="Regenerated the TOOLS block in chezmoi/private_dot_claude/CLAUDE.md from your config*.toml edit — commit it with this change and run \`cza\`. If you changed a pin: \`mise lock --global\` refreshes mise.lock (commit it too)."

if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$msg" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c},suppressOutput:true}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"},"suppressOutput":true}\n' "$msg"
fi
exit 0
