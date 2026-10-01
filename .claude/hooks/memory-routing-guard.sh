#!/usr/bin/env bash
# memory-routing-guard.sh — Claude Code PreToolUse hook (Write|Edit|MultiEdit).
#
# Repo-specific. This repo deliberately routes project memories to
# <repo>/.claude/memory/ (committed, code-reviewable, reproducible after a fresh
# clone) and does NOT use the home-dir path the base system prompt suggests
# (~/.claude/projects/<slug>/memory/), which would land outside source control.
# The system prompt actively pushes Claude toward that home path, so this hook
# makes the CLAUDE.md override mechanical: it DENIES writes there and points
# Claude at the in-repo location.
set -u

# shellcheck source=.claude/hooks/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" 2>/dev/null || exit 0

f="$(hook_field '.tool_input.file_path')"
[ -n "$f" ] || exit 0
norm="${f//\\//}"

case "$norm" in
*/.claude/projects/*/memory/*)
  reason="Blocked by memory-routing-guard: this repo routes project memories to <repo>/.claude/memory/ (committed + code-reviewed), NOT the home-dir path ($norm). Per CLAUDE.md 'Claude memory routing': write the file to .claude/memory/<slug>.md and add a one-line pointer to .claude/memory/MEMORY.md. Only use a home/host-global path if the user EXPLICITLY asked for cross-project scope (and say so)."
  hook_deny "$reason"
  exit 0
  ;;
esac
exit 0
