---
name: project-trail-claude-wiring
description: How trail 0.30.5 (the renamed graft) wires Claude Code, measured in a scratch repo and home on 2026-11-27, and where it collides with the settings merge.
metadata:
  type: project
---

Measured on `npm:@trailhq/trail-code` 0.30.5 (scratch repo + scratch `HOME`, 2026-11-27):

- The package ships one bin, `trail`. No `graft` command.
- `trail mcp` is a server named `trail` (tools `trail_find_code` ...), but `trail init` registers none for
  Claude Code (its code: "trail gives Claude Code no repo-tools server"). A real run wrote no `.mcp.json`
  and no `~/.claude.json`, and removed a graft server from an existing `.mcp.json`. Only `trail login` adds
  a `trail` entry, a workspace connector.
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

- The hook shim finds trail by `~/.trail/install.json` (`claudeDist`), then a PATH `trail` linking into the
  package (mise's shim doesn't), then `npm root -g`. `scripts/lib/trail-install-record.sh` (from
  `tasks/claude`) keeps the record on the pinned install.
- `DO_NOT_TRACK=1 trail telemetry disable` writes nothing; the postinstall unsets the variable for that run.
- The user wants the session look-back left on (2026-11-27): don't set `TRAIL_NO_LOOK_BACK`.

**Why:** the migration brief said the MCP server and CLI keep the graft name; both were wrong.
**How to apply:** check the tarball or a scratch `trail init` before trusting a claim about its names.
