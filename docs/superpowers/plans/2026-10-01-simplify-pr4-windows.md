# Simplification PR 4 — Windows on mise — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Windows host gets its CLI tools, its Python and its font from mise, exactly as Linux does. Its GUI apps come from one winget table. `bootstrap.ps1` stops re-implementing what mise and the Linux tasks already do: portable-tool installer, vendor-installer resolvers, Doctor, CheckForUpdates, MiseRuntimes.

**Architecture:**
- **Pins:** jq, gh, helix and starship move to `config.toml` (loaded on both OSes). OpenCode and Oh My Pi lose `os = ["linux"]`. DevToys CLI gets a per-platform asset. Nushell, dnGrep and LogExpert become `os = ["windows"]` tools in `config.owned.toml`. Every version lives once, in `config*.toml` plus the lock files.
- **Bootstrap:** `bootstrap.ps1` keeps one pinned download (mise itself). It writes `miserc.toml`, runs `mise bootstrap --only dotfiles,tools`, puts mise's shims on PATH, then installs GUI apps through winget.
- **Clean-up:** a one-time migration removes the old `workstation\*` PATH entries and copies, which would otherwise shadow the mise shims.

**Tech Stack:** Windows PowerShell 5.1 (`bootstrap.ps1` must also run there), mise 2026.9.9 (`github:` `platforms` table, `mise where`, shims), winget 1.29, TOML.

**Spec:** `docs/superpowers/specs/2026-09-29-simplify-design.md` §5 PR 4. Research for this plan (all VERIFIED unless marked): `/tmp/claude-1000/-home-arrush-chaturvedi--config-mise/33fbdf40-9bd1-4392-97dd-c2c041ad7dae/scratchpad/pr4-research.md`. Read §1 (function map), §3 (lock table) and §4 (platforms syntax) before Task 1.

**Deviations from the spec (rulings, recorded here):**
1. **App presence check.** It uses the Uninstall-registry DisplayName glob (`Test-InstallerPresent`, kept) instead of `winget list`. Reason: `winget list` misses the installed "DevToys Preview" and would install a second DevToys next to it; the glob is also offline and fast. `winget` is used only to install. Windows Terminal is an Appx package and gets an Appx check.
2. **`scripts/install-nerd-fonts.ps1` stays, cut down** to a "register these TTFs for this user" helper that takes `-SourceDir`. Its download, sha256 pin and copy of `Invoke-CurlRequest` are deleted. The spec's goals still hold: no duplicate pin, no duplicate curl helper. Folding ~200 lines of font-registration code into `bootstrap.ps1` would work against its ≤ 1,400-line target.
3. **One-time PATH/file migration** (not in the spec): the research found the stale `workstation\{helix,nu,devtoys-cli,dngrep,logexpert}` PATH entries and the old `workstation\bin\{starship,gh,jq,omp,opencode,chezmoi}.exe` ahead of the mise shims.
4. **Nushell launches through `%LOCALAPPDATA%\mise\shims\nu.exe`.** On Windows, mise's `latest` is a plain file, so there is no stable install path.

## Global Constraints

- Branch `refactor/simplify-windows` (create it from `main` at `3f2182c`). Commit after each task and push. Never push to `main`, never force-push, never `--no-verify`.
- Every commit message ends with a blank line and then:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq
  ```
  Use these exact lines even if your own context suggests a different model name.
- **Never run `bootstrap.ps1`** (it is the user's to run, Task 7). Never run `winget install/upgrade`, never edit the Windows registry or User environment, and never touch `%LOCALAPPDATA%\workstation` or the real Windows mise data dir.
- **Allowed Windows interop:** read-only probes, and the repo's own `scripts/test-*.ps1` with `-NoProfile -ExecutionPolicy Bypass -File`, from a copied path under `$env:TEMP` when the script expects to run from a repo checkout. Always `Set-Location $env:USERPROFILE` first. The WSL checkout is the source of truth; the Windows checkout (`/mnt/c/Users/arrush.chaturvedi/.config/mise`) is read-only for you.
- **Linux side:** this checkout IS the live mise config. Never run `mise install`, `mise dot apply`, `wsa`, non-dry-run `mise bootstrap`, `mise run update` or anything with `sudo`. Lock work uses the out-of-checkout form (below) and only names the tools you change.
- **`bootstrap.ps1`:**
  - stays UTF-8 **with BOM** (`head -c3 bootstrap.ps1 | od -An -tx1` → `ef bb bf`), as does `scripts/install-nerd-fonts.ps1` while it exists
  - must parse under Windows PowerShell 5.1: no ternary, no `??`, no `&&`/`||` pipeline chains
  - `$name:` inside double-quoted strings must be braced (`${name}:`)
- **Parse check after every `bootstrap.ps1` edit:**
  ```bash
  cp bootstrap.ps1 /mnt/c/Users/arrush.chaturvedi/AppData/Local/Temp/bs-parse.ps1
  /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
    'Set-Location $env:USERPROFILE; $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$env:TEMP\bs-parse.ps1",[ref]$null,[ref]$e); if($e){$e|%{$_.ToString()}; exit 1}else{"parse OK"}' | tr -d '\r'
  ```
- **Out-of-checkout lock form** (scripts/bump-versions.sh uses the same), for a list of tools:
  ```bash
  L=$(mktemp -d); ln -s ~/.config/mise "$L/mise"
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=linux,owned,host,native mise lock --global --platform linux-x64 <tools…>)
  (cd /tmp && env -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$L" MISE_ENV=windows,owned mise lock --global --platform windows-x64 <tools…>)
  rm -rf "$L"
  ```
  If `.mise/locks/` appears in the checkout, fold it into `locks/` and repoint the paths exactly as `normalize_lock_sidecars` in `scripts/bump-versions.sh` does.
- **Size and docs:**
  - `bootstrap.ps1` ≤ 1,400 lines at the end of Task 6
  - `CLAUDE.md` ≤ 14,000 bytes; `CLAUDE.md` + `docs/claude/*` ≤ 30,000 bytes; `README.md` ≤ 600 lines
  - User-facing changes go into README in the same commit
- `mise run lint` (also the pre-commit hook) passes after every task, and `scripts/check-ps.ps1` passes in CI.

## Review Focus

1. **On the Windows host, an old `workstation\bin\*.exe` or `workstation\nu\nu.exe` still wins over the mise shim** because of PATH order. The Task 2 migration removes them. Task 7's live check runs `Get-Command starship, gh, jq, omp, opencode, hx, nu` and expects mise shim paths, except gh, which a machine-wide install may shadow; that's documented.
2. **A fresh Windows host breaks on run order.** Mise must be installed before the clone, and the shims must be on the session PATH before `jq`/`starship`/`nu` users run (Claude settings merge, the Nushell generators, python-env). Task 2's step list fixes the order, and Task 7 checks it from the bootstrap output.
3. **winget installs a second copy of an app the old code installed directly** (DevToys Preview, per-user Zed). Task 4's presence check is the registry glob. Its test (step 1) runs the presence logic read-only against this host and expects every currently installed app to be detected.
4. **Nushell from Windows Terminal/Warp fails to start** because the shim needs `mise.exe` on PATH, or the profile points at a deleted path. Task 2 updates both launch paths. Task 7 opens each.
5. **A Linux host loses or changes a tool when jq/gh/helix/starship move from `config.linux.toml` to `config.toml`.** Task 1's check compares `mise ls --json` tool/version sets before and after for all three Linux token sets, plus `verify-tools`.

---

### Task 1: Windows CLI tools become mise tools (config + locks)

**Files:**
- Modify:
  - `config.linux.toml`: move the `starship`, `gh`, `jq` and `helix` lines out, keeping their comments
  - `config.toml`: add those four lines under `[tools]` with a one-line comment ("both OSes")
- Modify `config.owned.toml`:
  - `opencode`: drop `os = ["linux"]` and its "Windows half stays in bootstrap.ps1" comment
  - `"github:can1357/oh-my-pi"`: becomes `"18.3.4"` with no `os` and no `bin`. On Windows, `bin` makes a non-`.exe` file and no shim (research §3); on Linux the auto-strip still yields `omp`.
  - `"github:DevToys-app/DevToys"`: becomes the `platforms` form from research §4:
    ```toml
    "github:DevToys-app/DevToys" = { version = "2.0.9.0", platforms = { linux-x64 = { asset_pattern = "devtoys.cli_linux_x64_portable.zip", rename_exe = { "DevToys.CLI" = "devtoys.cli" } }, windows-x64 = { asset_pattern = "devtoys.cli_win_x64_portable.zip" } } }
    ```
  - add these, each with a one-line comment:
    ```toml
    nushell = { version = "0.113.1", os = ["windows"] }   # Windows default shell (WT); launched via %LOCALAPPDATA%\mise\shims\nu.exe
    "github:dnGrep/dnGrep" = { version = "5.0.30.0", os = ["windows"], asset_pattern = "dnGrep.{{version}}.x64.zip" }   # GUI grep; Start Menu shortcut + settings seed by bootstrap.ps1
    "github:LogExperts/LogExpert" = { version = "1.41.0", os = ["windows"], asset_pattern = "LogExpert.{{version}}.zip" }   # GUI log viewer (needs the .NET 10 Desktop Runtime); Start Menu shortcut by bootstrap.ps1
    ```
- Modify: `mise.lock`, `mise.linux.lock`, `mise.owned.lock` (+ `locks/**` if sidecars move), regenerated only for the tools above
- Docs:
  - `CLAUDE.md` Layout: `config.toml` holds "uv, python, starship/gh/jq/helix (both OSes), `[vars]`…"; `config.owned.toml` adds "Windows-only nushell/dnGrep/LogExpert"
  - `README.md` "Adding a tool" if it says where both-OS tools go

Do NOT touch `bootstrap.ps1`, `check_version_pins` or `bump-versions.sh` in this task. `$PortableTools` still holds the same versions until Task 2, so the existing dual-edit checks keep passing.

- [ ] **Step 1: Write the Linux no-change check first (record the baseline)**

Save as `.superpowers/sdd/2026-10-01-simplify-pr4-windows/checks/claude-pr4-linux-tools.sh`:
```bash
#!/usr/bin/env bash
# Linux tool set must be identical before/after moving pins between config files.
# usage: claude-pr4-linux-tools.sh record|compare
set -uo pipefail
cd /tmp
d=/home/arrush.chaturvedi/.config/mise/.superpowers/sdd/2026-10-01-simplify-pr4-windows/checks
for e in linux linux,owned,host,wsl linux,owned,host,native; do
  MISE_ENV=$e mise -C "$HOME" ls --json 2>/dev/null |
    jq -r 'to_entries[] | .key as $t | .value[] | select(.requested_version != null) | "\($t)@\(.requested_version)"' | sort > "$d/tools-$1-$e.txt"
done
if [ "$1" = compare ]; then
  fail=0
  for e in linux linux,owned,host,wsl linux,owned,host,native; do
    diff "$d/tools-record-$e.txt" "$d/tools-compare-$e.txt" >/dev/null && echo "same tools: $e" || { echo "DIFF $e:"; diff "$d/tools-record-$e.txt" "$d/tools-compare-$e.txt"; fail=1; }
  done
  exit $fail
fi
```
Run `bash …/claude-pr4-linux-tools.sh record`. This writes the baseline. Then check that the three `tools-record-*.txt` files are non-empty.

- [ ] **Step 2: Edit the config files** as listed under Files.

- [ ] **Step 3: Regenerate the locks for exactly these tools**

`starship gh jq helix opencode github:can1357/oh-my-pi github:DevToys-app/DevToys nushell github:dnGrep/dnGrep github:LogExperts/LogExpert`, with the out-of-checkout form, for both platforms.

Then:
```bash
git diff --stat -- mise*.lock locks/
```
Expected:
- starship/gh/jq/helix entries move into `mise.lock`, with linux-x64 and windows-x64 blocks
- the `config.owned.toml` tools gain windows-x64 blocks; the checksums equal research §3
- no other tool's entry changes

`mise.linux.lock` may still hold stale entries for the four moved tools. If it does:
1. Copy the checkout to a scratch dir and run a full `mise lock --global --platform linux-x64` there with `MISE_ENV=linux`, using the XDG symlink pointed at the copy.
2. Diff the scratch lock against the real one.
3. If the only difference is the four entries disappearing, run the same command on the real checkout. If anything else changes (e.g. a `pypi:… latest` version), stop and report BLOCKED with the diff.

- [ ] **Step 4: Verify**

```bash
bash .superpowers/sdd/2026-10-01-simplify-pr4-windows/checks/claude-pr4-linux-tools.sh compare   # "same tools" ×3
MISE_ENV=windows,owned mise -C "$HOME" ls --json 2>/dev/null | jq -r 'keys[]' | sort   # includes starship gh jq helix opencode github:can1357/oh-my-pi github:DevToys-app/DevToys nushell github:dnGrep/dnGrep github:LogExperts/LogExpert
mise run lint      # lock coverage (linux-x64; windows-x64 where it installs on Windows), dual-edit pins still equal
```
Also run a Linux sandbox install of the DevToys entry, to prove the nested `rename_exe` still yields `devtoys.cli`:
```bash
S=$(mktemp -d); mkdir -p "$S/cfg/mise"
printf '[tools]\n"github:DevToys-app/DevToys" = { version = "2.0.9.0", platforms = { linux-x64 = { asset_pattern = "devtoys.cli_linux_x64_portable.zip", rename_exe = { "DevToys.CLI" = "devtoys.cli" } }, windows-x64 = { asset_pattern = "devtoys.cli_win_x64_portable.zip" } } }\n' > "$S/cfg/mise/config.toml"
(cd /tmp && env -u MISE_ENV -u MISE_CONFIG_DIR XDG_CONFIG_HOME="$S/cfg" MISE_DATA_DIR="$S/d" MISE_CACHE_DIR="$S/c" MISE_STATE_DIR="$S/s" MISE_YES=1 mise install && ls "$S/d/installs/github-dev-toys-app-dev-toys/2.0.9.0/" | grep -x devtoys.cli)
rm -rf "$S"
```

- [ ] **Step 5: Commit and push**

```bash
git add -A config.toml config.linux.toml config.owned.toml mise*.lock locks CLAUDE.md README.md
git commit -q -m "refactor(tools): Windows CLI tools become mise tools (starship/gh/jq/helix both-OS; opencode/omp/DevToys CLI on Windows; nushell/dnGrep/LogExpert Windows-only)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq"
git push -q -u origin refactor/simplify-windows
```

---

### Task 2: bootstrap.ps1 installs only mise; mise does the rest

**Files:**
- Modify `bootstrap.ps1`:
  - Replace `$PortableTools` and `Install-PortableTool` with constants `$MiseVersion`/`$MiseSha256`/`$MiseUrl` and an `Install-Mise` function (below). Keep `$WsMise`; delete `$WsHelix`, `$WsNu`, `$WsDevToysCli`, `$WsDnGrep` and `$WsLogExpert`.
  - Rewrite `Initialize-MiseEnv` (below).
  - `Invoke-MiseBootstrap` absorbs the post-tools steps (below). Delete `Invoke-MiseRuntimes`, `Get-MiseRuntimesStamp` and `$MiseConfigFiles`.
  - `Invoke-ToolInstall`: `foreach ($tool in $PortableTools)` becomes `Install-Mise`, and the directory-creation loop keeps only `$WsRoot`, `$WsBin` and `$WsStamps`. Leave the Warp/WT/installer/elevated calls for Task 4.
  - Add `Invoke-LegacyToolCleanup` (below), called right after `Install-Mise`.
  - `Invoke-WarpTabConfigs`: the Nushell compatibility tab runs `"$env:LOCALAPPDATA\mise\shims\nu.exe"` instead of `workstation\nu\nu.exe`.
  - `Invoke-StartMenuShortcuts`: build the dnGrep and LogExpert shortcuts from `mise where github:dnGrep/dnGrep` (`dnGREP.exe`) and `mise where github:LogExperts/LogExpert` (`LogExpert.exe`). Skip each with a warning if `mise where` fails.
  - `Invoke-DnGrepConfig`: seed `dnGrep.config.xml` beside `dnGREP.exe` in `mise where github:dnGrep/dnGrep`. The install dir is versioned, so re-seed when absent.
  - The banner at the end lists `$WsMise\bin` and `$MiseShims` only.
  - `$WsBin` stays: the python-env launchers live there.
- Modify: `dotfiles/windows/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`. The Nushell profile's `commandline` becomes `%LOCALAPPDATA%\\mise\\shims\\nu.exe`. JSON edit only: keep the file's existing formatting and the missing trailing newline.
- Modify `scripts/check-invariants.sh`:
  - `check_version_pins`: the mise three-way reads `$MiseVersion` from bootstrap.ps1 (not a `$PortableTools` entry)
  - delete the jq/gh/helix/opencode/omp/DevToys `$PortableTools` dual-edit blocks and `ps1_tool_version`
- Modify `scripts/bump-versions.sh`: delete `PS1_NAME`, `ps1_field`, `ps1_set`, `bump_ps1` and their loop branches. Keep however mise's own version is handled today, re-pointed at `$MiseVersion`/`$MiseSha256`/`$MiseUrl`; if the bumper never touched mise, leave it so. `check_bumper_exclude` must still pass.
- Modify: `.claude/hooks/parity-reminder.sh` (drop the `$PortableTools` ↔ config pins clause) + `.claude/hooks/test-hooks.sh` assertions. Run `bash .claude/hooks/test-hooks.sh`.

New code (adapt names only if a collision forces it):

```powershell
# mise is the one tool this script pins itself: everything else comes from
# config*.toml through mise. Triple-edit with MISE_VERSION in bootstrap.sh and
# min_version in config.toml (scripts/check-invariants.sh checks it).
$MiseVersion = "2026.9.9"
$MiseSha256  = "f758ee4afe061cccd4587c0108c147209a7cb2372704909a8b9d5e230203ec07"
$MiseUrl     = "https://github.com/jdx/mise/releases/download/v$MiseVersion/mise-v$MiseVersion-windows-x64.zip"
$MiseShims   = Join-Path $env:LOCALAPPDATA "mise\shims"
$MiseEnvTokens = @("windows", "owned")

function Install-Mise {
    $binDir = Join-Path $WsMise "bin"
    $stamp  = Join-Path $WsStamps "mise.$MiseVersion.stamp"
    if ((Test-Path $stamp) -and (Test-Path (Join-Path $binDir "mise.exe"))) {
        Add-ToUserPath $binDir
        Write-Ok "mise $MiseVersion already installed"
        return
    }
    Write-Log "Installing mise $MiseVersion..."
    $zip = Join-Path $env:TEMP "ws-mise-$MiseVersion.zip"
    $tmp = Join-Path $env:TEMP "ws-mise-$MiseVersion"
    try {
        Invoke-CurlRequest -Uri $MiseUrl -OutFile $zip
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower()
        if ($actual -ne $MiseSha256) { Write-Fail "mise $MiseVersion sha256 mismatch (got $actual) — refusing to install" }
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $top = @(Get-ChildItem -Path $tmp)
        $src = if (($top.Count -eq 1) -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmp }
        if (Test-Path $WsMise) { Remove-Item -Recurse -Force $WsMise }
        New-Item -ItemType Directory -Force -Path $WsMise | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $WsMise -Recurse -Force
        Add-ToUserPath $binDir
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "mise $MiseVersion installed to $WsMise"
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The token set lives in miserc.toml (git-ignored), like on Linux; nothing
# exports MISE_ENV. An exported value would override miserc, so the old User
# variable is removed here and in this session.
function Initialize-MiseEnv {
    $rc = Join-Path $RepoPath "miserc.toml"
    $envList = ($MiseEnvTokens | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $body = "# Written by bootstrap.ps1 (Windows is always owned).`nenv = [$envList]`nauto_env = false`n"
    [System.IO.File]::WriteAllText($rc, $body, [System.Text.UTF8Encoding]::new($false))
    if ([Environment]::GetEnvironmentVariable("MISE_ENV", "User")) {
        [Environment]::SetEnvironmentVariable("MISE_ENV", $null, "User")
        Write-Ok "removed the old User MISE_ENV variable (miserc.toml replaces it)"
    }
    Remove-Item Env:MISE_ENV -ErrorAction SilentlyContinue
}

# One-time cleanup of the pre-mise portable installs (remove once every
# Windows host has run it): their PATH entries sat ahead of mise's shims.
function Invoke-LegacyToolCleanup {
    $old = @("helix", "nu", "devtoys-cli", "dngrep", "logexpert") | ForEach-Object { Join-Path $WsRoot $_ }
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
        $kept = @($userPath -split ';' | Where-Object { $_ -and ($old -notcontains $_.TrimEnd('\')) })
        $newPath = $kept -join ';'
        if ($newPath -ne $userPath) {
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            Write-Ok "removed old portable-tool directories from the User PATH"
        }
    }
    foreach ($d in $old) { if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue } }
    foreach ($exe in @("starship", "gh", "jq", "omp", "opencode", "chezmoi")) {
        Remove-Item (Join-Path $WsBin "$exe.exe") -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -Path $WsStamps -Filter "*.stamp" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "mise.*" -and $_.Name -notlike "python-env.*" -and $_.Name -notlike "nerd-fonts.*" } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
```
Use `Join-Path $WsRoot "<name>"` for the old directories, as above; the constants are deleted.

The post-tools steps added to the end of `Invoke-MiseBootstrap` (after the marker block, before `Invoke-WslConfigReminder`), only when the tools phase ran (`-not $SkipToolInstall`):
1. `Add-ToUserPath $MiseShims` and `Update-SessionPath`, so later steps (jq, starship, nu, uv) resolve in this session.
2. The Linux-style node-postinstall marker:
   - `$decl = & mise config get -f (Join-Path $RepoPath "config.owned.toml") tools.node`
   - `$sum` = the first 16 hex chars of its SHA256
   - `$marker = Join-Path $WsStamps "node-postinstall.$sum.stamp"`
   - If node was already installed before this run (capture `& mise where node` BEFORE the `mise bootstrap` call) and the marker is missing: run `& mise install --yes --force node`. If that fails with a file-in-use error, warn "close running node processes and re-run" (do not port the old postinstall-replay fallback).
   - On success, delete the old `node-postinstall.*.stamp` files and write the marker.
3. `& mise prune --yes` and `& mise reshim`, both non-fatal (warn on a non-zero exit).

Then fix the RUN SEQUENCE:
1. `Invoke-Preflight`
2. `Invoke-ToolInstall`, which now does Install-Mise, then Invoke-LegacyToolCleanup, then the GUI apps (Task 4)
3. `Invoke-CloneRepo`
4. `Invoke-MiseBootstrap`
5. the rest, unchanged in order

Delete the `Invoke-MiseRuntimes` line. `Initialize-MiseEnv` needs the clone (it writes into `$RepoPath`), so it is called from `Invoke-MiseBootstrap` as today.

- [ ] **Step 1: The tests first (they fail now)**

`scripts/test-ssh-launchers.ps1` and `scripts/test-config-local.ps1` load functions from `bootstrap.ps1`. Read how they do it. Then add `scripts/test-mise-env.ps1` (UTF-8 **with BOM**, same loading pattern; CI's `windows-http` job runs it in both shells, see Step 4). It must:
- load `Initialize-MiseEnv` from `bootstrap.ps1` with `$RepoPath` pointed at a temp dir and `$MiseEnvTokens = @("windows","owned")`
- stub `[Environment]::SetEnvironmentVariable`: if PS 5.1 can't stub a static method, guard the User-scope calls in `Initialize-MiseEnv` behind a script-scope `$script:TestNoUserEnv` the test sets, and say so in a comment
- call it and assert the temp `miserc.toml` reads exactly `env = ["windows", "owned"]` and `auto_env = false`, with no BOM
- assert `$env:MISE_ENV` is unset afterwards
- load `Invoke-LegacyToolCleanup` with `$WsRoot`/`$WsBin`/`$WsStamps` pointed at a temp tree (old dirs, old exes, a `wpy.cmd`, a `mise.2026.9.9.stamp`, a `starship.1.25.1.stamp`), with User-PATH writes disabled the same way. Call it and assert the old dirs and exes are gone, `wpy.cmd` and the `mise.*` stamp survive, and `starship.*.stamp` is gone.

Run it via interop: copy `bootstrap.ps1` + `scripts/` to `$env:TEMP\pr4-test\` first. Expected now: FAIL (functions don't exist yet).

- [ ] **Step 2: Implement** as listed under Files, then run the parse check.

- [ ] **Step 3: Verify**

```bash
cd ~/.config/mise
rg -n 'PortableTools|Install-PortableTool|Invoke-MiseRuntimes|Get-MiseRuntimesStamp|WsHelix|WsNu\b|WsDevToysCli|WsDnGrep|WsLogExpert|workstation\\\\nu' bootstrap.ps1 dotfiles scripts .claude || echo "no stale references"
head -c3 bootstrap.ps1 | od -An -tx1          # ef bb bf
mise run lint                                 # mise three-way via $MiseVersion; no PS1 tool blocks
bash .claude/hooks/test-hooks.sh
```
Run the three PowerShell tests (`test-mise-env.ps1`, `test-ssh-launchers.ps1`, `test-config-local.ps1`) via interop under both `powershell.exe` and, if present, `pwsh.exe`, from the temp copy. All must pass.

- [ ] **Step 4: CI and commit**

Add two steps to the `windows-http` job in `.github/workflows/lint.yml` for `scripts/test-mise-env.ps1`, under `powershell` and under `pwsh`, mirroring the existing pairs (`if: always()`). Then:
```bash
git add -A bootstrap.ps1 scripts dotfiles/windows .claude .github
git commit -q -m "refactor(bootstrap.ps1): install only mise; miserc.toml replaces the User MISE_ENV; shims + node marker after mise bootstrap; legacy portable installs cleaned up

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq"
git push -q
```

---

### Task 3: Drop `-Doctor` / `-CheckForUpdates`

**Files:**
- Modify `bootstrap.ps1`:
  - delete `-Doctor` and `-CheckForUpdates` from `param()` and the header's flag list
  - delete the run-sequence guards and early exits
  - delete `Show-RepoState`, `Get-LatestGitTag`, `Get-LatestWingetVersion`, `Get-InstalledAppVersion`, `Write-UpdateStatus`, `Invoke-Doctor`, `Invoke-CheckForUpdates` and `Write-Bad`, if nothing else uses them; `Install-ElevatedMsi` still does until Task 4, so keep `Write-Bad` until then if needed
  - delete `Get-PythonEnvStamp` only if Doctor was its last other user; `Invoke-PythonEnv` still uses it until Task 5
- Modify: `dotfiles/windows/AppData/Roaming/nushell/config.nu.tera`, removing the `-Doctor` and `-CheckForUpdates` rows from `workstation_bootstrap_flags`. `check_completion_parity` must pass.
- Docs: README's Windows flag list and every `-Doctor`/`-CheckForUpdates` mention. Health on Windows is now `mise doctor`, `mise bootstrap status`, `mise dot status`, and `winget upgrade` for the apps. CLAUDE.md, if it mentions them.

- [ ] **Step 1:** `rg -n 'Doctor|CheckForUpdates' bootstrap.ps1 dotfiles/windows README.md | wc -l` → record the count (non-zero).
- [ ] **Step 2:** Delete as listed, then run the parse check.
- [ ] **Step 3: Verify**
  ```bash
  rg -n -- '-Doctor|-CheckForUpdates|Invoke-Doctor|Invoke-CheckForUpdates|Get-LatestGitTag|Get-LatestWingetVersion|Write-UpdateStatus|Show-RepoState' bootstrap.ps1 dotfiles README.md || echo none
  ```
  Then run `mise run lint`; the flag parity covers `config.nu.tera`.
- [ ] **Step 4:** Commit (`refactor(bootstrap.ps1)!: drop -Doctor and -CheckForUpdates (mise doctor / bootstrap status / dot status / winget upgrade instead)`), with the trailers, then push.

---

### Task 4: GUI apps from one winget table

**Files:**
- Modify `bootstrap.ps1`:
  - Replace `$InstallerTools`, `$WarpTool` and `$ElevatedTools` with `$WingetApps` (below).
  - Replace `Install-InstallerTool`, `Install-ElevatedMsi`, `Install-ElevatedTool`, `Install-Warp` and `Install-WindowsTerminal` with `Install-WingetApps` (below).
  - Delete `Get-GitHubApiHeaders` and `Write-Bad` if now unused.
  - Keep `Test-InstallerPresent`.
  - Remove `-ForceInstaller` (param, header, every use).
  - `Invoke-ToolInstall` calls `Install-WingetApps` after mise and the cleanup.
  - `Invoke-WarpTabConfigs` checks presence with `Test-InstallerPresent "Warp*"`.
  - The `-SkipToolInstall` log line lists what it now skips.
- Modify:
  - `config.nu.tera`: remove the `-ForceInstaller` row, and reword the `-SkipToolInstall` description
  - `scripts/test-ssh-launchers.ps1`: its stubs of `Test-InstallerPresent`/`$WarpTool` follow the new names; it must still pass
- Docs: README's Windows "what bootstrap.ps1 installs", the UAC troubleshooting entry (Zed joins SSHFS-Win; winget is required for both), and the `-ForceInstaller` mention → `winget upgrade --all` (or per id).

```powershell
# GUI apps, installed through winget and then self-updating (or `winget upgrade`).
# Presence = Uninstall-registry DisplayName glob (Test-InstallerPresent): it also
# sees copies installed before winget managed them (e.g. "DevToys Preview"),
# which `winget list` misses. Windows Terminal is an Appx package.
$WingetApps = @(
    @{ Id = "Microsoft.WindowsTerminal";       Name = "Windows Terminal"; Appx = "Microsoft.WindowsTerminal"; Scope = "user" },
    @{ Id = "Warp.Warp";                       Name = "Warp";             Detect = "Warp*";            Scope = "user" },
    @{ Id = "Obsidian.Obsidian";               Name = "Obsidian";         Detect = "Obsidian*";        Scope = "user" },
    @{ Id = "DevToys-app.DevToys";             Name = "DevToys";          Detect = "DevToys*";         Scope = "user" },
    @{ Id = "DBeaver.DBeaver.Community";       Name = "DBeaver";          Detect = "DBeaver*";         Scope = "user" },
    @{ Id = "WinSCP.WinSCP";                   Name = "WinSCP";           Detect = "WinSCP*";          Scope = "user" },
    @{ Id = "ScooterSoftware.BeyondCompare.5"; Name = "Beyond Compare";   Detect = "Beyond Compare*";  Scope = "user" },
    # Machine scope (UAC): winget has no per-user installer for these. -SkipElevated skips them.
    @{ Id = "ZedIndustries.Zed";               Name = "Zed";              Detect = "Zed";              Scope = "machine" },
    @{ Id = "SSHFS-Win.SSHFS-Win";             Name = "SSHFS-Win";        Detect = "SSHFS-Win*";       Scope = "machine" }
)

function Install-WingetApps {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "winget not found — GUI apps skipped (install App Installer from the Microsoft Store, then re-run)"
        return
    }
    foreach ($app in $WingetApps) {
        if ($app.Scope -eq "machine" -and $SkipElevated) { Write-Log "$($app.Name) skipped (-SkipElevated)"; continue }
        $present = if ($app.ContainsKey('Appx')) { [bool](Get-AppxPackage -Name $app.Appx -ErrorAction SilentlyContinue) } else { Test-InstallerPresent $app.Detect }
        if ($present) { Write-Ok "$($app.Name) present"; continue }
        Write-Log "Installing $($app.Name) (winget, $($app.Scope) scope)..."
        & winget install --id $app.Id --exact --scope $app.Scope --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { Write-Ok "$($app.Name) installed" } else { Write-Warn "$($app.Name): winget exited $LASTEXITCODE — install it later with: winget install --id $($app.Id)" }
    }
}
```
Keep the `Zed` Detect exact, as the old table did, so "Zed Preview"/"Zed Nightly" don't count.

- [ ] **Step 1: The presence test first**

Add `scripts/test-winget-apps.ps1` (BOM). It loads `$WingetApps`, `Test-InstallerPresent` and `Install-WingetApps` from `bootstrap.ps1`, with `winget` stubbed as a function that records its arguments, and `Get-AppxPackage`/`Test-InstallerPresent` stubbed to a fake inventory. It asserts:
- present apps are not installed
- missing user-scope apps are installed with `--scope user`
- machine-scope apps are skipped when `$SkipElevated = $true`
- `Zed` doesn't match a "Zed Preview" DisplayName

Also run the REAL `Test-InstallerPresent` read-only on this host for each `Detect` glob, and the Appx check for Windows Terminal. Every app the research found installed (§6) must report present. Print the table. Expected now: FAIL (the table doesn't exist yet).

- [ ] **Step 2: Implement**, then run the parse check.
- [ ] **Step 3: Verify**
  - Run `test-winget-apps.ps1` (both shells) and `test-ssh-launchers.ps1`.
  - `rg -n 'InstallerTools|ElevatedTools|WarpTool|Install-InstallerTool|Install-ElevatedMsi|Install-ElevatedTool|Install-Warp\b|Install-WindowsTerminal|ForceInstaller|Get-GitHubApiHeaders' bootstrap.ps1 dotfiles scripts README.md || echo none`
  - Run `mise run lint`.
  - Add the new test to CI's `windows-http` job (both shells).
- [ ] **Step 4:** Commit (`refactor(bootstrap.ps1): GUI apps from one winget table; vendor-installer resolvers and the MSI fallback removed`), with the trailers, then push.

---

### Task 5: Windows python-env and fonts from mise

**Files:**
- Modify `bootstrap.ps1`:
  - `Invoke-PythonEnv` builds the venv with `uv venv --python "<mise where python>\python.exe"` (use `& mise where python`). It reads the libraries from `scripts\python-env.txt`, skipping `#` and blank lines.
  - Its stamp key is the interpreter path + the SHA256 of `python-env.txt` (`Get-PythonEnvStamp` rewritten or inlined).
  - Delete `$PythonEnvVersion` and `$PythonLibs`. The `wpy`/`textual`/`typer` `.cmd` launchers stay in `$WsBin`.
- Modify `Invoke-InstallNerdFonts`: `$src = & mise where github:ryanoasis/nerd-fonts`, then `& $InstallScript -SourceDir $src`, keeping the `-SkipNerdFonts` gate and the soft-fail.
- Modify `scripts/install-nerd-fonts.ps1` (keep the BOM):
  - add `param([Parameter(Mandatory)][string]$SourceDir)`
  - delete `$Version`, `$Sha256`, `Invoke-CurlRequest` and the download/verify/extract code
  - copy the six Mono TTFs from `$SourceDir` into `%LOCALAPPDATA%\Microsoft\Windows\Fonts`
  - keep the HKCU registration, `Invoke-FontActivation`, `Register-FontLogonTask` and `Test-Installed`
  - key the stamp on the SHA256 of the six source files, not a version
  - update the header comment
- Modify `scripts/check-invariants.sh`:
  - delete the python two-way and Nerd Font two-way pin checks (each value now lives once)
  - delete `check_python_env_parity` and `check_curl_helper_parity` and their calls
  - the BOM check's file list keeps `install-nerd-fonts.ps1` (it still exists)
- Modify `scripts/bump-versions.sh`: drop `github:ryanoasis/nerd-fonts` from `EXCLUDE`; `python` stays.
- Modify `scripts/test-curl.ps1`: it tests only `bootstrap.ps1`'s `Invoke-CurlRequest`; drop the second target and the parity assertion.
- Modify: `.claude/hooks/parity-reminder.sh` (drop the python/font/curl-helper pairs) + `test-hooks.sh` assertions.
- Docs:
  - `README.md`: the Windows python-env and fonts text, and the troubleshooting entries "Tofu boxes" (the font pin now lives only in `config.owned.toml`) and "wpy not found" (Windows: `mise where python`; no stamp deletion needed with `--rebuild`-equivalent text if any)
  - `CLAUDE.md`: the parity pairs, "Values recorded in several places" (only mise, `VCPKG_ROOT`, the zellij floor and the TS major remain), the BOM list

- [ ] **Step 1: Tests first**

Extend `scripts/test-config-local.ps1` or add `scripts/test-python-fonts.ps1` (BOM). It loads `Invoke-PythonEnv` with `mise`/`uv` stubbed as functions that record their arguments, and asserts:
- the `uv venv --python` argument is the stubbed `mise where python` + `\python.exe`
- the libraries passed to `uv pip install` equal `scripts/python-env.txt`'s entries
- a second run with the same inputs skips the rebuild, and a changed interpreter path rebuilds

For fonts, it runs `scripts/install-nerd-fonts.ps1 -SourceDir <temp dir with six fake .ttf files>` with `$env:LOCALAPPDATA` pointed at a temp dir. Font registration (HKCU), activation and the scheduled task must be skippable for the test. If they aren't, add a `-NoRegister` switch used only by the test, and say so in the script's header. It asserts the six files land in the temp Fonts dir.

Expected now: FAIL.

- [ ] **Step 2: Implement**, then run the parse check (both `.ps1` files).
- [ ] **Step 3: Verify**
  - Run the new test (both shells), `test-curl.ps1` (both shells) and `bash .claude/hooks/test-hooks.sh`.
  - Run `mise run lint`.
  - `rg -n 'PythonEnvVersion|PythonLibs|Sha256|Invoke-CurlRequest' scripts/install-nerd-fonts.ps1 bootstrap.ps1`: the only `Invoke-CurlRequest` definition is in `bootstrap.ps1`, and there is no `$PythonEnvVersion`/`$PythonLibs`.
  - Add the new test to CI (both shells).
- [ ] **Step 4:** Commit (`refactor(windows): python-env on mise's python + python-env.txt; the font comes from mise; install-nerd-fonts.ps1 only registers`), with the trailers, then push.

---

### Task 6: Docs, size, leftovers

**Files:** `bootstrap.ps1` (header comment, comment trimming), `README.md`, `CLAUDE.md`, `docs/claude/verification.md`, `.claude/memory/project-mise-runtimes-shipped.md` (`Invoke-MiseRuntimes` is gone; keep the three interop gotchas), `docs/windows/application_list.md` (if it names apps the script now installs or no longer installs)

- [ ] **Step 1:** Record `wc -l bootstrap.ps1`.
- [ ] **Step 2: Trim `bootstrap.ps1`** to ≤ 1,400 lines, by removing comment narrative and comments that restate the next line. Never change code. Each kept comment says why, in the present tense. Run the parse check, then confirm code is unchanged:
  ```bash
  diff <(git show HEAD:bootstrap.ps1 | sed 's/#.*$//' | sed '/^[[:space:]]*$/d') <(sed 's/#.*$//' bootstrap.ps1 | sed '/^[[:space:]]*$/d')
  ```
  Expected: only differences inside here-strings or strings that contain `#`. Inspect each remaining line by hand and list them in the report.
- [ ] **Step 3: Docs**
  - `README.md` Windows setup: what `bootstrap.ps1` does now (≤ 10 steps), its flags, health on Windows.
  - Its troubleshooting entries: sha256 mismatch → only mise is checksum-pinned by the script, and the rest are verified by mise's lock; Git prerequisite; profile; UAC.
  - The `bootstrap.ps1` header comment matches.
  - `CLAUDE.md` Windows section: mise installs every CLI tool; GUI apps via `$WingetApps`; Nushell via the shim; no User `MISE_ENV`.
  - `verification.md`: the Windows recipes match (Tasks 2–5 tests, live checks).
- [ ] **Step 4: Verify** with `wc -l bootstrap.ps1` (≤ 1,400), `wc -c CLAUDE.md docs/claude/*.md`, `wc -l README.md`, `mise run lint`, and the parse check.
- [ ] **Step 5:** Commit (`docs(windows): README/CLAUDE.md for the mise-based Windows bootstrap; bootstrap.ps1 comments trimmed`), with the trailers, then push.

---

### Task 7: Whole-branch verification, the Windows live run, and the PR

- [ ] **Step 1: Branch checks (WSL)**
  - `mise run lint`, `bash scripts/check-templates.sh`, and `mise tasks validate` (0 WARN).
  - `bash …/checks/claude-pr4-linux-tools.sh compare` prints "same tools" ×3.
  - The `mise bootstrap plan` host-state comparison against `main` for the three Linux token sets (as in PR 3) must be identical.
  - Run every `scripts/test-*.ps1` via interop under `powershell.exe` and `pwsh.exe`.
  - Run the parse check.
  - Confirm `wc -l bootstrap.ps1` ≤ 1,400.
- [ ] **Step 2: Live run (the user runs it on Windows)**

  Ask the user, in a Windows PowerShell terminal:
  ```powershell
  git -C $env:USERPROFILE\.config\mise fetch
  git -C $env:USERPROFILE\.config\mise checkout refactor/simplify-windows
  cd $env:USERPROFILE\.config\mise; .\bootstrap.ps1
  ```
  Then, in a NEW PowerShell window:
  ```powershell
  "MISE_ENV=[$env:MISE_ENV]"; Get-Content $env:USERPROFILE\.config\mise\miserc.toml
  Get-Command starship, jq, hx, nu, omp, opencode, DevToys.CLI, gh | Format-Table Name, Source
  mise doctor | Select-String 'activated|shims_on_path'; mise dot status | Select-String -NotMatch 'applied'
  wpy -c "import sys, textual; print(sys.version)"
  (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts\JetBrainsMonoNerdFontMono-*.ttf").Count
  ```
  Then open Windows Terminal (it should land in Nushell) and Warp's Nushell tab.

  Expected:
  - `MISE_ENV=[]`
  - miserc shows `["windows", "owned"]`
  - every command resolves to `%LOCALAPPDATA%\mise\shims\…`, except gh, which may be the machine-wide install
  - `mise doctor` reports `activated: yes` and `shims_on_path: yes`, and `mise dot status` lists nothing unapplied
  - `wpy` prints 3.14.7
  - the font count is 6
  - both terminals start Nushell
  - the bootstrap output shows no installer for already-present apps (no second DevToys/Zed)

  Afterwards the user switches the Windows checkout back with `git checkout main` once the PR merges.
- [ ] **Step 3: Open the PR**

  Title: `Simplify (4/5): Windows on mise — CLI tools, python and font via mise; GUI apps via winget`. The body lists:
  - the tool moves
  - `bootstrap.ps1`'s size before → after
  - removed functions, flags and files
  - the four recorded deviations from the spec
  - the verification (tests, live run)
  - after-merge steps: the Windows checkout back to `main`, open new terminals, run `mise run update` on Linux hosts for the `config.toml`/lock changes

  End with the standard footer:
  ```
  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  https://claude.ai/code/session_01VWVRxP2AmfNHFQSUgyVPqq
  ```
