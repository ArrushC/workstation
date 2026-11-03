---
name: project-windows-ps1-shadows-cmd
description: PowerShell runs name.ps1 ahead of name.cmd in the same PATH dir, so npm's leftover .ps1 shims shadow tool-env's .cmd launchers in node's install dir.
metadata:
  type: project
---

In one PATH directory PowerShell (5.1 and 7) picks `name.ps1` over `name.cmd`; cmd.exe, Nushell
and mise's `.exe` shims go by PATHEXT and take the `.cmd`. Verified 2026-11-02 with a scratch
dir holding both.

**Why it matters:** node's old postinstall (`npm install -g`) left `name`, `name.cmd` and
`name.ps1` shims in `%LOCALAPPDATA%\mise\installs\node\26.11.1`. `scripts/tool-env.py`
rewrites only `name.cmd`, so a leftover `.ps1` keeps PowerShell on the old global install.

**How to apply:** this is a per-host leftover, not repo logic ([[feedback-no-migration-code]]).
The Windows host's 20 stale `.ps1`/bare shims were deleted by hand on 2026-11-02 (copies in
`%LOCALAPPDATA%\workstation\environment-backup-20261102T085730Z`). A host whose node still
carries npm-global server shims needs the same one-off. A new node version starts clean.
See also [[project-tool-env-rollout]].
