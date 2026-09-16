---
name: project-mise-runtimes-shipped
description: mise owns node/Go/uv/LSP on Linux (#153, 2026-09-16) and Windows (#154, 2026-09-16); the three interop/PowerShell gotchas that bit the Windows execution gate and are NOT in the repo docs
metadata:
  type: project
---

Both halves of the mise consolidation are merged: PR #153 (Linux `mise-runtimes`, `lib/mise.sh`, generated conf.d) and PR #154 (Windows portable mise + `Invoke-MiseRuntimes`). Spec: `docs/superpowers/specs/2026-09-13-mise-runtimes-design.md`. Nothing is pending. Three things learned on the Windows execution gate that the docs don't carry:

- **Windows `mise` commands run through interop must `Set-Location` to a Windows dir first.** The interop process inherits the WSL cwd as a `\\wsl.localhost\...` UNC path; mise walks UP from cwd looking for `.config/mise/conf.d/*.toml` and finds the LINUX home's files over the share, then fails to parse them — `mise ls` prints nothing, `mise where` returns empty, `mise doctor` shows "failed to load config". Shims/versions still work, so the failure looks partial and confusing.
- **`winget uninstall` of a portable package (e.g. `OpenJS.NodeJS.LTS`) fails with "directory is not empty" even with `--purge` when a nested `node_modules` path exceeds 260 chars.** Nothing holds the files; winget's deleter can't reach them. Fix: `pwsh` (long-path aware) `Remove-Item -LiteralPath <pkg dir> -Recurse -Force`, then `winget uninstall` again to clear the record + PATH entry.
- **`Sort-Object` on names that differ only by a hyphen orders them differently in Windows PowerShell 5.1 (NLS) and pwsh 7 (ICU).** Any hash/stamp built from a sorted file list must use an explicit order (bit `Get-MiseRuntimesStamp`: doctor under 5.1 disagreed with the pwsh-written stamp). Also: mise's `activate pwsh` warns on every 5.1 start about the missing chpwd hook — `MISE_PWSH_CHPWD_WARNING=0` silences it; activation itself works on 5.1.

**How to apply:** for any future Windows-side probe of mise (or another cwd-walking tool) via `powershell.exe`, prefix `Set-Location $env:USERPROFILE;`. The PSReadLine prediction errors the pwsh profile prints when output is redirected are pre-existing and unrelated to mise.
