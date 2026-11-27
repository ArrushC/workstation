---
name: project-trail-claude-wiring
description: How trail 0.30.5 (the renamed graft) wires Claude Code, measured in a scratch repo and home on 2026-11-27, and where it collides with the settings merge.
metadata:
  type: project
---

Measured on `npm:@trailhq/trail-code` 0.30.5 (scratch repo + scratch `HOME`, 2026-11-27):

- The package ships one bin, `trail`. No `graft` command.
- MCP server name is `trail` (`trail mcp`), tools `trail_find_code`, `trail_find_all`, `trail_trace_calls`,
  `trail_file_api`, `trail_repo_map`, `trail_check_freshness` (so `mcp__trail__trail_*`).
- `trail init` writes, in the repo: `.trail/` (map in git-ignored `.trail/cache/`), a SessionStart hook in
  `.claude/settings.json`, and `.claude/settings.local.json` (allow list; a statusLine + subagentStatusLine
  unless `GRAFT_NO_STATUSLINE` is set: the only name it reads, no `TRAIL_` spelling).
- Unless `--no-global`, it also writes user files: hooks in `~/.claude/settings.json` (commands run
  `~/.claude/helpers/graft-hooks.cjs`, trail's own file name) and `~/.claude/skills/trail/SKILL.md`.
- The settings merge dropped trail's two user-level `PreToolUse` hooks (`pre-edit`, `pre-bash`): the
  enforced `PreToolUse` replaced the live array. Fixed by branch `settings-merge-keep-live-hooks`
  (2026-11-27, its own PR): the merge keeps another tool's live hooks after the enforced ones.
- `trail telemetry disable` stops the usage ping only; `DO_NOT_TRACK=1` (now in `config.linux.toml`'s
  `[env]`) also stops the daily npm version check.

**Why:** the migration brief said the MCP server and CLI keep the graft name; both were wrong.
**How to apply:** check the tarball or a scratch `trail init` before trusting a claim about its names.
