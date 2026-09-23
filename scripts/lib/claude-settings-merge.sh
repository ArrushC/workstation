#!/usr/bin/env bash
# claude-settings-merge.sh — the three-layer ~/.claude/settings.json merge
# `modify_private_settings.json` (chezmoi) used to do, now in jq (ruling 5,
# docs/superpowers/plans/2026-09-19-mise-dotfiles.md: mise has no
# modify_-template equivalent, so ~/.claude/settings.json is not a
# [dotfiles] entry at all).
#
# Layers, lowest to highest precedence:
#   1. dotfiles/claude/settings.seed.json — personal defaults, set only when
#      the corresponding top-level key is ABSENT from the live file (model,
#      effortLevel, theme, editorMode, tui, verbose).
#   2. ~/.claude/settings.json (if present) — whatever is already there,
#      keys and all, wins over the seed.
#   3. dotfiles/claude/settings.enforced.json — infra keys that ALWAYS win,
#      overwriting the live file's own values for the same key (statusLine,
#      hooks, enabledPlugins, skipAutoPermissionPrompt,
#      skipWorkflowUsageWarning, remoteControlAtStartup,
#      agentPushNotifEnabled, inputNeededNotifEnabled).
#
# The merge is a recursive object merge (jq `.[0] * .[1] * .[2]`), matching
# chezmoi's mergeOverwrite (Sprig -> mergo's recursive merge): a later
# operand overwrites a matching LEAF, but siblings the later operand doesn't
# mention survive untouched. Fix round 1: `+` (plain top-level union) was
# wrong here — it replaces a whole key's value wholesale, so a live
# `hooks.Stop` (a real Claude Code hook type the user added by hand, not one
# of the enforced sub-keys) was silently wiped every run because
# `enforced.hooks` replaced `live.hooks` in full. `*` merges objects
# key-by-key recursively and, for two non-object values (including arrays),
# lets the later operand win wholesale — so `enforced.hooks.PreToolUse`
# still fully REPLACES (never concatenates with) a live PreToolUse array,
# while a live-only `hooks.Stop` is preserved as a sibling.
#
# Invoked from tasks/bootstrap, dev only. Soft-failing by design: every
# expected failure mode (no jq, missing dotfiles source, invalid existing
# JSON, a write failure) prints a warning to stderr and exits 0 — the caller
# additionally wraps the call in `||` as belt-and-braces, but this script
# must never be the reason `mise run bootstrap` aborts.
#
# Writes atomically: renders into a temp file in the same directory as the
# destination (so `mv` is an atomic rename, never a partial write visible to
# a concurrently-running `claude`), mode 0600 (settings.json can carry
# machine-specific paths/tokens — same posture as ~/.ssh/config).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SEED="$REPO_ROOT/dotfiles/claude/settings.seed.json"
ENFORCED="$REPO_ROOT/dotfiles/claude/settings.enforced.json"
DEST="${CLAUDE_SETTINGS_MERGE_DEST:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'claude-settings-merge.sh: jq not found on PATH — skipping settings merge\n' >&2
  exit 0
fi

for f in "$SEED" "$ENFORCED"; do
  if [ ! -f "$f" ]; then
    printf 'claude-settings-merge.sh: missing %s — skipping settings merge\n' "$f" >&2
    exit 0
  fi
done

current='{}'
if [ -f "$DEST" ]; then
  if ! current="$(jq -c '.' "$DEST" 2>/dev/null)"; then
    printf 'claude-settings-merge.sh: %s is not valid JSON — leaving it untouched\n' "$DEST" >&2
    exit 0
  fi
fi

dest_dir="$(dirname "$DEST")"
if ! mkdir -p "$dest_dir" 2>/dev/null; then
  printf 'claude-settings-merge.sh: could not create %s — skipping settings merge\n' "$dest_dir" >&2
  exit 0
fi

tmp="$(mktemp "$dest_dir/.settings.json.XXXXXX" 2>/dev/null)" || {
  printf 'claude-settings-merge.sh: mktemp in %s failed — skipping settings merge\n' "$dest_dir" >&2
  exit 0
}
trap 'rm -f "$tmp"' EXIT

if ! jq -s '.[0] * .[1] * .[2]' "$SEED" <(printf '%s' "$current") "$ENFORCED" >"$tmp" 2>/dev/null; then
  printf 'claude-settings-merge.sh: jq merge failed — leaving %s untouched\n' "$DEST" >&2
  exit 0
fi

if ! chmod 0600 "$tmp" 2>/dev/null; then
  printf 'claude-settings-merge.sh: chmod 0600 failed — leaving %s untouched\n' "$DEST" >&2
  exit 0
fi

if ! mv -f "$tmp" "$DEST" 2>/dev/null; then
  printf 'claude-settings-merge.sh: could not write %s — leaving it untouched\n' "$DEST" >&2
  exit 0
fi

trap - EXIT
printf 'claude-settings-merge.sh: merged seed + live + enforced -> %s\n' "$DEST"
