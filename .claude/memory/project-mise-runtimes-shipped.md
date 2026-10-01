---
name: project-mise-runtimes-shipped
description: "Windows mise-via-interop gotchas: Set-Location before mise, winget long-path uninstall, Sort-Object order differs 5.1 vs 7"
metadata:
  type: project
---

Three Windows gotchas the repo docs don't carry. They date from the old `Invoke-MiseRuntimes` step, which is gone: since PR 4 `bootstrap.ps1` installs only mise, and `mise bootstrap --only dotfiles,tools` installs every CLI tool. The gotchas still apply.

- **Windows `mise` commands run through interop must `Set-Location` to a Windows dir first.** The interop process inherits the WSL cwd as a `\\wsl.localhost\...` UNC path; mise walks UP from cwd looking for `.config/mise/conf.d/*.toml` and finds the LINUX home's files over the share, then fails to parse them — `mise ls` prints nothing, `mise where` returns empty, `mise doctor` shows "failed to load config". Shims/versions still work, so the failure looks partial and confusing. (`bootstrap.ps1` pins its mise calls with `-C $env:USERPROFILE` for the same reason; `mise activate nu` is the one unpinned call.)
- **`winget uninstall` of a portable package (e.g. `OpenJS.NodeJS.LTS`) fails with "directory is not empty" even with `--purge` when a nested `node_modules` path exceeds 260 chars.** Nothing holds the files; winget's deleter can't reach them. Fix: `pwsh` (long-path aware) `Remove-Item -LiteralPath <pkg dir> -Recurse -Force`, then `winget uninstall` again to clear the record + PATH entry.
- **`Sort-Object` on names that differ only by a hyphen orders them differently in Windows PowerShell 5.1 (NLS) and pwsh 7 (ICU).** Any hash/stamp built from a sorted file list must use an explicit order (it bit the since-deleted `Get-MiseRuntimesStamp`: the old `-Doctor` under 5.1 disagreed with the pwsh-written stamp). Also: mise's `activate pwsh` warns on every 5.1 start about the missing chpwd hook — `MISE_PWSH_CHPWD_WARNING=0` silences it; activation itself works on 5.1.

**How to apply:** for any future Windows-side probe of mise (or another cwd-walking tool) via `powershell.exe`, prefix `Set-Location $env:USERPROFILE;`. The PSReadLine prediction errors the pwsh profile prints when output is redirected are pre-existing and unrelated to mise.
