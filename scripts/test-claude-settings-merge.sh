#!/usr/bin/env bash
# test-claude-settings-merge.sh: scripts/lib/claude-settings-merge.sh (and so
# scripts/lib/claude-settings-merge.jq, the filter Windows' merge runs too) against this
# checkout's settings.seed.json and settings.enforced.json, writing a throwaway
# CLAUDE_SETTINGS_MERGE_DEST. Never the real ~/.claude/settings.json.
#   Hook events the enforced file defines: its hooks come first and all of them stay, a
#   live hook another tool added follows them, a live copy of an enforced group isn't
#   doubled, a live hook that runs a file of ours (an entry an older enforced file left)
#   goes, and a second run changes nothing. Other events and keys: the live file's.
#   A live file that isn't JSON is left as it was, exit 0.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
merge="$root/scripts/lib/claude-settings-merge.sh"
enforced="$root/dotfiles/claude/settings.enforced.json"
if ! command -v jq >/dev/null 2>&1; then
  echo "test-claude-settings-merge: jq missing, skipped"
  exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dest="$tmp/.claude/settings.json"
mkdir -p "$tmp/.claude"
fails=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1" >&2
  fails=$((fails + 1))
}
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
run() { CLAUDE_SETTINGS_MERGE_DEST="$dest" bash "$merge" >"$tmp/out" 2>&1; }
# is <jq filter>: true for the merged file. The enforced file is $e[0].
is() { jq -e --slurpfile e "$enforced" "$1" "$dest" >/dev/null 2>&1; }

# A live file as another tool leaves it: its own hooks on an enforced event (PreToolUse)
# and on events of its own, beside copies of ours from an earlier merge and from an older
# enforced file (other wording, a guard since removed, a Windows path).
jq -n --slurpfile e "$enforced" '{
  mine: 1,
  hooks: {
    PreToolUse: ($e[0].hooks.PreToolUse + [
      {matcher: "Write|Edit", hooks: [{type: "command", command: "node \"/h/.claude/helpers/tool.cjs\" pre-edit || exit 0", timeout: 5}]},
      {matcher: "Bash", hooks: [{type: "command", command: "\"$HOME/.claude/hooks/old-guard.sh\""}]},
      {matcher: "Bash", hooks: [
        {type: "command", command: "C:\\Users\\x\\.claude\\hooks\\gone.cmd"},
        {type: "command", command: "node tool.cjs pre-bash"}]}
    ]),
    Notification: [
      {matcher: "idle_prompt", hooks: [{type: "command", command: "\"$HOME/.claude/notify.sh\" old wording"}]}
    ],
    Stop: [{hooks: [{type: "command", command: "echo stop"}]}]
  }
}' >"$dest"

check "the merge runs" run
check "every enforced PreToolUse group stays, first and in order" \
  is '($e[0].hooks.PreToolUse | length) as $n | .hooks.PreToolUse[:$n] == $e[0].hooks.PreToolUse'
check "another tool's PreToolUse hook follows them" \
  is '[.hooks.PreToolUse[].hooks[].command] | index("node \"/h/.claude/helpers/tool.cjs\" pre-edit || exit 0") != null'
check "a live copy of an enforced group isn't doubled" \
  is '[.hooks.PreToolUse[].hooks[].command | select(test("secret-guard"))] | length == 1'
check "a hook an older enforced file left is gone" \
  is '[.hooks.PreToolUse[].hooks[].command | select(test("old-guard|gone\\.cmd"))] | length == 0'
check "the other tool's hook in that group stays" \
  is '[.hooks.PreToolUse[].hooks[].command] | index("node tool.cjs pre-bash") != null'
check "PreToolUse is the enforced groups plus the two kept ones" \
  is '(.hooks.PreToolUse | length) == ($e[0].hooks.PreToolUse | length) + 2'
check "an old wording of our notification is replaced, not kept beside the new one" \
  is '.hooks.Notification == $e[0].hooks.Notification'
check "an event the enforced file doesn't define is the live file's" \
  is '.hooks.Stop == [{hooks: [{type: "command", command: "echo stop"}]}]'
check "a live-only key stays and an enforced key wins" \
  is '.mine == 1 and .theme == $e[0].theme'

cp "$dest" "$tmp/first"
check "a second run" run
check "a second run changes nothing" cmp -s "$dest" "$tmp/first"

rm -f "$dest"
check "no live file" run
check "no live file: exactly the enforced hooks" is '.hooks == $e[0].hooks'

printf '{"theme": "auto",' >"$dest"
cp "$dest" "$tmp/broken"
check "a live file that isn't JSON: exit 0" run
check "a live file that isn't JSON: left as it was" cmp -s "$dest" "$tmp/broken"

if [ "$fails" -gt 0 ]; then
  echo "test-claude-settings-merge: $fails failed" >&2
  exit 1
fi
echo "test-claude-settings-merge: all passed"
