# claude-settings-merge.jq: the one filter behind scripts/lib/claude-settings-merge.sh and
# scripts/claude-settings-merge.ps1. Input (jq -s): [seed, live, enforced].
#
# A recursive object merge, seed * live * enforced: a later layer overwrites a matching
# leaf and leaves the siblings it doesn't mention. Arrays are leaves, so on their own the
# enforced `hooks.PreToolUse` would replace the live one, deleting any hook another tool
# put there (trail's two PreToolUse hooks went that way on every update).
#
# So for each hook event the enforced file defines, the result is the enforced groups
# first, then the live groups that are someone else's. A live group isn't kept when it
# equals an enforced one, and a hook in it isn't kept when its command runs a file of ours
# (~/.claude/hooks/*, ~/.claude/notify.sh): that is an entry an older enforced file put
# there, which would otherwise outlive its removal or rewording. A group left with no
# hooks goes. Every hook of an event runs, and one deny is enough, so a kept live hook can
# add to the guards but never switch one off. Events the enforced file doesn't define are
# the live file's alone, as before.
def ours: test("[/\\\\]\\.claude[/\\\\](hooks[/\\\\]|notify\\.sh)");

def theirs($enforced):
  if type != "array" then []
  else
    map(
      . as $group
      | select(type == "object")
      | select(any($enforced[]; . == $group) | not)
      | if (.hooks | type) == "array"
        then .hooks |= map(select(((.command? // "") | tostring | ours) | not))
        else . end
      | select((.hooks | type) != "array" or (.hooks | length) > 0)
    )
  end;

(.[1].hooks // {}) as $live
| (.[2].hooks // {}) as $enforced
| (.[0] * .[1] * .[2])
| if ($live | type) == "object" and ($enforced | type) == "object" then
    reduce ($enforced | to_entries[] | select(.value | type == "array")) as $e
      (.; .hooks[$e.key] = $e.value + ($live[$e.key] | theirs($e.value)))
  else . end
