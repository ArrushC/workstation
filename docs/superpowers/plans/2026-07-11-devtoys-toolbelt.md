# DevToys Toolbelt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-install the DevToys GUI on Windows (installer class) and the DevToys CLI on Windows (pinned portable tree) + Linux dev machines (bespoke tree target), with dual-edit pin enforcement and full docs.

**Architecture:** Three install surfaces off one upstream repo (`DevToys-app/DevToys` @ v2.0.9.0): (1) GUI joins `$InstallerTools` in `bootstrap.ps1` with two new opt-in fields — `IncludePrerelease` (every DevToys 2.x release is `prerelease:true`, so `/releases/latest` returns 2023's v1.0.13.0) and `UpdateHint` (DevToys never self-updates; its in-app check is notification-only); (2) CLI joins `$PortableTools` as a `Layout = "tree"` pin (single-file `DevToys.CLI.exe` + required sibling `Plugins/` tree); (3) Linux CLI is a dev-only bespoke Make target (`lib/devtoys-cli.sh`, pwndbg shape: extract tree under `$(DEST)/_devtoys-cli-<ver>/`, symlink `$(DEST)/devtoys.cli`). `DEVTOYS_CLI_VERSION` in `versions.mk` dual-edits with the `$PortableTools` pin, enforced by `check-invariants.sh`.

**Tech Stack:** PowerShell 5.1-compatible `bootstrap.ps1`, GNU Make, bash (shfmt -i 2, shellcheck-clean), GitHub REST API.

**Spec:** `docs/superpowers/specs/2026-07-11-devtoys-toolbelt-design.md` (committed, `dcd8907`).

## Global Constraints

- Branch: `feat/devtoys` (already created; spec committed on it).
- `bootstrap.ps1` must keep its UTF-8 BOM; it is PowerShell-5.1-compatible and `Set-StrictMode -Version Latest` — probe optional hashtable keys with `.ContainsKey()`, never bare property access on objects without `PSObject.Properties`.
- `makefile/lib/devtoys-cli.sh` must be LF-only, git mode 100755, `shfmt -i 2`-clean, shellcheck-clean at warning+ (the `makefile/lib/*.sh` glob in `check-invariants.sh` auto-covers it once committed).
- Obsidian and Zed behavior must be bit-for-bit unchanged (they set neither new field).
- The GUI is NOT pinned anywhere (installer-class latest model). Only the CLI has a pin: `DEVTOYS_CLI_VERSION := 2.0.9.0` ↔ the `$PortableTools` `Version`/`Url` literals.
- CLI zip sha256 (verified against a real download AND the GitHub API digest): `27327ad18c06d5bba4356f039c76203b0099f864d10f6de0d833225077dd310a`.
- x64 assets only (fleet is x64; Zed precedent). The Linux helper still maps `aarch64→arm` since the case statement costs nothing.
- Every commit message ends with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a`
- The pre-commit hook runs `check-invariants.sh` — every commit below must leave it green.
- Line numbers cited below are pre-change positions in the current files; earlier tasks shift later ones. Match on the quoted text, not the number.

---

### Task 1: DevToys GUI — installer-class entry + IncludePrerelease/UpdateHint mechanisms

**Files:**
- Modify: `bootstrap.ps1` — `$InstallerTools` block (~lines 288-311), `Install-InstallerTool` release resolution (~lines 675-689), Doctor installer loop (~line 1531), `-CheckForUpdates` installer loop (~lines 1659-1672).

**Interfaces:**
- Consumes: existing `Install-InstallerTool`, `Test-InstallerPresent`, `Get-InstalledAppVersion`, `Get-LatestGitTag`, `Write-UpdateStatus`.
- Produces: `$InstallerTools` entries may now carry optional `IncludePrerelease` (bool) and `UpdateHint` (string) keys. Task 5's docs describe exactly this behavior.

- [ ] **Step 1: Extend the `$InstallerTools` banner comment**

The comment currently ends (lines 293-295):

```powershell
# their own Start-menu shortcut). Presence is detected via the Uninstall registry
# (DisplayName), so a manual uninstall makes the next bootstrap reinstall. Force a
# reinstall with -ForceInstaller.
```

Replace those three lines with:

```powershell
# their own Start-menu shortcut). Presence is detected via the Uninstall registry
# (DisplayName), so a manual uninstall makes the next bootstrap reinstall. Force a
# reinstall with -ForceInstaller.
# Two OPT-IN per-tool fields (absent = old behavior, Obsidian/Zed untouched):
#   IncludePrerelease  resolve the newest NON-DRAFT release from /releases
#                      instead of /releases/latest — DevToys flags EVERY 2.x
#                      release prerelease:true, so "latest" returns 2023's
#                      v1.0.13.0 (an MSIX-only release with no .exe asset).
#   UpdateHint         status text for -Doctor/-CheckForUpdates when the
#                      default "self-updates" story is wrong — DevToys' in-app
#                      update check is notification-only (it never installs).
```

- [ ] **Step 2: Add the DevToys entry after Zed**

The Zed entry closes with (lines 304-311):

```powershell
    @{
        Name       = "Zed"
        Repo       = "zed-industries/zed"             # GitHub owner/repo for LATEST (stable; /releases/latest skips -pre)
        AssetMatch = "Zed-x86_64.exe"                 # x64 Windows installer asset (NOT Zed-aarch64.exe)
        SilentArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"  # Inno Setup silent; PrivilegesRequired=lowest -> per-user, no admin (NOT NSIS /S)
        DetectName = "Zed"                            # exact HKCU Uninstall DisplayName (avoids "Zed Preview"/"Zed Nightly")
    }
)
```

Replace with:

```powershell
    @{
        Name       = "Zed"
        Repo       = "zed-industries/zed"             # GitHub owner/repo for LATEST (stable; /releases/latest skips -pre)
        AssetMatch = "Zed-x86_64.exe"                 # x64 Windows installer asset (NOT Zed-aarch64.exe)
        SilentArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"  # Inno Setup silent; PrivilegesRequired=lowest -> per-user, no admin (NOT NSIS /S)
        DetectName = "Zed"                            # exact HKCU Uninstall DisplayName (avoids "Zed Preview"/"Zed Nightly")
    },
    @{
        Name              = "DevToys"
        Repo              = "DevToys-app/DevToys"
        AssetMatch        = "devtoys_win_x64.exe"     # Inno Setup installer (x64 only; NOT arm64/x86, NOT the *_portable.zip)
        SilentArgs        = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"  # Inno; PrivilegesRequired=lowest -> per-user, no admin
        DetectName        = "DevToys*"                # HKCU ...\Uninstall\DevToys_is1 -> DisplayName "DevToys <ver>" (version-suffixed; glob also matches a user's "DevToys Preview" — intended: don't force a stable seed alongside)
        IncludePrerelease = $true                     # see banner: /releases/latest lies for this repo
        UpdateHint        = "update-checks in-app only (no self-update); re-run bootstrap with -ForceInstaller to update"
    }
)
```

- [ ] **Step 3: Add the IncludePrerelease branch to `Install-InstallerTool`**

The current release resolution (inside `Install-InstallerTool`, lines ~681-689):

```powershell
    try {
        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($Tool.Repo)/releases/latest" `
            -Headers $headers -UseBasicParsing
    } catch {
        Write-Warn "$($Tool.Name): GitHub API lookup failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }
```

Replace with:

```powershell
    try {
        if ($Tool.ContainsKey('IncludePrerelease') -and $Tool.IncludePrerelease) {
            # /releases/latest excludes prereleases, and some repos (DevToys)
            # flag EVERY release prerelease:true — take the newest non-draft
            # entry of /releases instead (the list is newest-first).
            $releases = @(Invoke-RestMethod `
                -Uri "https://api.github.com/repos/$($Tool.Repo)/releases?per_page=10" `
                -Headers $headers -UseBasicParsing)
            $release = $releases | Where-Object { -not $_.draft } | Select-Object -First 1
            if (-not $release) { throw "no non-draft release among the newest $($releases.Count)" }
        } else {
            $release = Invoke-RestMethod `
                -Uri "https://api.github.com/repos/$($Tool.Repo)/releases/latest" `
                -Headers $headers -UseBasicParsing
        }
    } catch {
        Write-Warn "$($Tool.Name): GitHub API lookup failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }
```

- [ ] **Step 4: Honor `UpdateHint` in the Doctor installer loop**

Current (line ~1531, inside `foreach ($tool in $InstallerTools)` under `Write-Log "Installer apps + extras"`):

```powershell
        if (Test-InstallerPresent -DisplayName $tool.DetectName) {
            $ver = Get-InstalledAppVersion -DisplayName $tool.DetectName
            $verText = if ($ver) { " $ver" } else { "" }
            Write-Ok "$($tool.Name)$verText installed (self-updates; -ForceInstaller to reseed)"
```

Replace with:

```powershell
        if (Test-InstallerPresent -DisplayName $tool.DetectName) {
            $ver = Get-InstalledAppVersion -DisplayName $tool.DetectName
            $verText = if ($ver) { " $ver" } else { "" }
            $hint = if ($tool.ContainsKey('UpdateHint')) { $tool.UpdateHint } else { "self-updates; -ForceInstaller to reseed" }
            Write-Ok "$($tool.Name)$verText installed ($hint)"
```

- [ ] **Step 5: Honor `UpdateHint` in the `-CheckForUpdates` installer loop**

Current (lines ~1659-1672):

```powershell
    Write-Log "Installer apps (install LATEST + self-update — nothing to pin)"
    foreach ($tool in $InstallerTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $latest    = Get-LatestGitTag -Repo $tool.Repo
        if (-not (Test-InstallerPresent -DisplayName $tool.DetectName)) {
            Write-Warn "$($tool.Name) not installed — re-run .\bootstrap.ps1 (installs the latest release)"
        } elseif ($installed -and $latest) {
            Write-UpdateStatus -Name $tool.Name -Pinned $installed -Latest $latest -Hint 'self-updates in-app; -ForceInstaller reseeds'
        } elseif ($latest) {
            Write-Ok "$($tool.Name) installed (latest upstream: $latest; self-updates in-app)"
        } else {
            Write-Ok "$($tool.Name) installed (self-updates in-app)"
        }
    }
```

Replace with:

```powershell
    Write-Log "Installer apps (install LATEST — nothing to pin; most self-update)"
    foreach ($tool in $InstallerTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $latest    = Get-LatestGitTag -Repo $tool.Repo
        $hasHint   = $tool.ContainsKey('UpdateHint')
        if (-not (Test-InstallerPresent -DisplayName $tool.DetectName)) {
            Write-Warn "$($tool.Name) not installed — re-run .\bootstrap.ps1 (installs the latest release)"
        } elseif ($installed -and $latest) {
            $hint = if ($hasHint) { $tool.UpdateHint } else { 'self-updates in-app; -ForceInstaller reseeds' }
            Write-UpdateStatus -Name $tool.Name -Pinned $installed -Latest $latest -Hint $hint
        } elseif ($latest) {
            $hint = if ($hasHint) { $tool.UpdateHint } else { 'self-updates in-app' }
            Write-Ok "$($tool.Name) installed (latest upstream: $latest; $hint)"
        } else {
            $hint = if ($hasHint) { $tool.UpdateHint } else { 'self-updates in-app' }
            Write-Ok "$($tool.Name) installed ($hint)"
        }
    }
```

(Per-branch fallback literals — a single shared default would change Obsidian/Zed's exact output in the last two branches, violating the Global Constraint. Amended 2026-07-11 after Task 1 review.)

Note: `Get-LatestGitTag` needs NO change — it reads git tags via `git ls-remote` (v2.0.9.0 sorts correctly under `[version]`), so DevToys comparisons are already right.

- [ ] **Step 6: Verify BOM survived and lint**

```bash
head -c 3 bootstrap.ps1 | od -An -tx1        # expect: ef bb bf
make -C makefile ps-lint                     # PSScriptAnalyzer: 0 findings
```

If `pwsh` is unavailable locally, note it — CI (`lint.yml`) enforces; do NOT skip the BOM check.

- [ ] **Step 7: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): DevToys GUI via installer class + prerelease-aware resolver

All DevToys 2.x releases are prerelease:true, so /releases/latest returns
2023's v1.0.13.0 — new opt-in IncludePrerelease field resolves the newest
non-draft release instead. New opt-in UpdateHint field corrects the
Doctor/CheckForUpdates story for apps that don't self-update (DevToys'
in-app check is notification-only). Obsidian/Zed behavior unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 2: DevToys CLI on Windows — pinned `$PortableTools` tree

**Files:**
- Modify: `bootstrap.ps1` — Ws-dir vars (~lines 165-176), `$PortableTools` (append after the omp entry, ~line 286), `-SkipToolInstall` log line (~line 896).

**Interfaces:**
- Consumes: existing `Install-PortableTool` (`Layout = "tree"` wipes+recreates `Dest`, flattens a single wrapper dir, adds `Dest` to User PATH, stamps `<Exe>.<Version>.stamp`).
- Produces: the `DevToys-app/DevToys/releases/download/v2.0.9.0` URL literal that Task 4's invariant check greps; the `devtoys.cli` command name that Task 3 mirrors on Linux.

- [ ] **Step 1: Add the Dest var + comment line**

Current (lines 165-176):

```powershell
# Per-user install root for every binary this script provisions. Admin-free:
#   workstation\bin      — single-exe tools (chezmoi, starship)  → on User PATH
#   workstation\wezterm  — the multi-file WezTerm portable tree  → on User PATH
#   workstation\helix    — the multi-file Helix portable tree    → on User PATH
#   workstation\nu       — the multi-file Nushell portable tree  → on User PATH
#   workstation\stamps   — "<exe>.<version>.stamp" idempotency markers
$WsRoot    = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin     = Join-Path $WsRoot "bin"
$WsWezterm = Join-Path $WsRoot "wezterm"
$WsHelix   = Join-Path $WsRoot "helix"
$WsNu      = Join-Path $WsRoot "nu"
$WsStamps  = Join-Path $WsRoot "stamps"
```

Replace with:

```powershell
# Per-user install root for every binary this script provisions. Admin-free:
#   workstation\bin          — single-exe tools (chezmoi, starship)  → on User PATH
#   workstation\wezterm      — the multi-file WezTerm portable tree  → on User PATH
#   workstation\helix        — the multi-file Helix portable tree    → on User PATH
#   workstation\nu           — the multi-file Nushell portable tree  → on User PATH
#   workstation\devtoys-cli  — the DevToys CLI portable tree         → on User PATH
#   workstation\stamps       — "<exe>.<version>.stamp" idempotency markers
$WsRoot       = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin        = Join-Path $WsRoot "bin"
$WsWezterm    = Join-Path $WsRoot "wezterm"
$WsHelix      = Join-Path $WsRoot "helix"
$WsNu         = Join-Path $WsRoot "nu"
$WsDevToysCli = Join-Path $WsRoot "devtoys-cli"
$WsStamps     = Join-Path $WsRoot "stamps"
```

(Do NOT add `$WsDevToysCli` to the directory pre-create loop at ~line 900 — tree layout wipes and recreates its own `Dest`; WezTerm precedent.)

- [ ] **Step 2: Append the `$PortableTools` entry**

The array currently ends (lines ~274-286):

```powershell
    @{
        Name       = "Oh My Pi"
```
…
```powershell
        UpdateHint = "dual-edit: `$PortableTools here AND OMP_VERSION in makefile/versions.mk"
    }
)
```

Change the closing to append a new entry:

```powershell
        UpdateHint = "dual-edit: `$PortableTools here AND OMP_VERSION in makefile/versions.mk"
    },
    @{
        # DevToys CLI — scriptable command-line half of DevToys; the Windows
        # half of the Linux dev-only devtoys-cli target (see versions.mk).
        # The *_portable zip is self-contained .NET (the plain zip needs a
        # system .NET 8 runtime — never use it). NOT Layout 'single': the
        # single-file DevToys.CLI.exe REQUIRES its sibling Plugins\ tree.
        # Invoked as `devtoys.cli` (Windows resolves DevToys.CLI.exe
        # case-insensitively).
        Name       = "DevToys CLI"
        Exe        = "DevToys.CLI"
        Version    = "2.0.9.0"
        Url        = "https://github.com/DevToys-app/DevToys/releases/download/v2.0.9.0/devtoys.cli_win_x64_portable.zip"
        Sha256     = "27327ad18c06d5bba4356f039c76203b0099f864d10f6de0d833225077dd310a"
        Layout     = "tree"
        Dest       = $WsDevToysCli
        Repo       = "DevToys-app/DevToys"
        TagPrefix  = "v"
        UpdateHint = "dual-edit: `$PortableTools here AND DEVTOYS_CLI_VERSION in makefile/versions.mk (NOTE: this repo flags all releases prerelease — check the releases PAGE, not /latest)"
    }
)
```

- [ ] **Step 3: Extend the `-SkipToolInstall` log line**

Current (line ~896):

```powershell
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix/Nushell/jq/OpenCode/omp on PATH; Obsidian/Zed/SSHFS-Win/Claude Code not installed"
```

Replace with:

```powershell
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix/Nushell/jq/OpenCode/omp/DevToys CLI on PATH; Obsidian/Zed/DevToys/SSHFS-Win/Claude Code not installed"
```

- [ ] **Step 4: Verify BOM + lint**

```bash
head -c 3 bootstrap.ps1 | od -An -tx1        # expect: ef bb bf
make -C makefile ps-lint                     # 0 findings (CI enforces if pwsh absent locally)
```

- [ ] **Step 5: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): DevToys CLI as pinned portable tree (2.0.9.0)

Self-contained portable zip, Layout 'tree' (single-file DevToys.CLI.exe +
required sibling Plugins/ tree) into %LOCALAPPDATA%\\workstation\\devtoys-cli.
Windows half of the upcoming Linux dev-only devtoys-cli target; the pin
dual-edits DEVTOYS_CLI_VERSION in makefile/versions.mk.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

(The dual-edit invariant check doesn't exist until Task 4, and `versions.mk` gains its side in Task 3 — pre-commit stays green at each point.)

---

### Task 3: DevToys CLI on Linux — versions.mk pin + lib/devtoys-cli.sh + Makefile target

**Files:**
- Modify: `makefile/versions.mk` (append at EOF, after `OMP_VERSION` at line 242).
- Create: `makefile/lib/devtoys-cli.sh` (LF, 0755).
- Modify: `makefile/Makefile` — new bespoke target after the vcpkg block (~line 361), `PROVISION_FANOUT` dev line (~line 701), `DOCTOR_ROWS` (~line 745).
- Modify (hook-regenerated, just commit it): `chezmoi/private_dot_claude/CLAUDE.md` — the `sync-tool-memory.sh` hook regenerates the `TOOLS` block when `versions.mk`/`Makefile` are edited. Never hand-edit inside the sentinels.

**Interfaces:**
- Consumes: `DEST`/`SUDO`/`LIB`/`STAMP` from `scope.mk`/`Makefile` (exported to lib scripts); `verify-binary.sh <path>` (exit 0 = runs here); `curl -fsSL --retry 3 --retry-delay 2` + `unzip -q` (archive.sh conventions).
- Produces: `make devtoys-cli MODE=dev` → `$(DEST)/devtoys.cli` symlink → `$(DEST)/_devtoys-cli-2.0.9.0/DevToys.CLI`; `DEVTOYS_CLI_VERSION` make var (Task 4 greps it via `mkval`).

- [ ] **Step 1: Append the versions.mk block**

`makefile/versions.mk` currently ends at line 242 (`OMP_VERSION      := 16.4.4` — line 243 is the EOF newline). Append:

```make

# --- (2026-07) DevToys CLI (dev_machine only) ---------------------------------
# devtoys.cli — scriptable command-line half of DevToys (DevToys-app/DevToys):
# offline dev utilities (json<->yaml, base64, hash, jwt, ...). dev_machine
# ONLY. NOT an EGET_TOOL: the release zip is a self-contained single-file .NET
# executable PLUS a required sibling Plugins/ tree, so lib/devtoys-cli.sh
# extracts the whole tree and symlinks $(DEST)/devtoys.cli (bespoke Makefile
# target, pwndbg's shape). Always the *_portable.zip (self-contained) — the
# plain zip is framework-dependent (needs a system .NET 8 runtime).
# CAVEAT: every DevToys 2.x release is flagged prerelease:true, so GitHub's
# /releases/latest LIES for this repo (returns 2023's v1.0.13.0) — find the
# real newest tag on the releases PAGE. Tags are vX.Y.Z.0. The pin DUAL-EDITS
# with $PortableTools in bootstrap.ps1 (the Windows half; refresh its Sha256
# when bumping) — enforced by check-invariants.sh.
DEVTOYS_CLI_VERSION := 2.0.9.0
```

- [ ] **Step 2: Create `makefile/lib/devtoys-cli.sh`** (complete file):

```bash
#!/usr/bin/env bash
# devtoys-cli.sh — install DevToys CLI (the command-line half of DevToys) from
# the self-contained portable release zip published by DevToys-app/DevToys.
#
# Usage:
#   devtoys-cli.sh <version>
#
#   version   Release version WITHOUT the leading 'v', e.g. 2.0.9.0 (tags are
#             vX.Y.Z.0).
#
# Env:
#   DEST      Destination directory (required; provided by scope.mk).
#
# Why the *_portable zip (not the plain CLI zip): the plain zip is
# framework-dependent (needs a system .NET 8 runtime); the portable zip is
# self-contained. Why not EGET_TOOL: the zip is NOT a single binary — the
# single-file DevToys.CLI executable REQUIRES its sibling Plugins/ tree
# (Plugins/DevToys.Tools), so the whole tree must stay together.
#
# Layout mirrors lib/pwndbg.sh: extract the whole tree to
# $DEST/_devtoys-cli-<ver>/, strip older _devtoys-cli-* trees first
# (idempotent re-install), chmod the executable (zip extraction drops +x),
# gate on verify-binary.sh, then symlink $DEST/devtoys.cli -> the executable
# (command-name parity with Windows, where DevToys.CLI.exe is invoked as
# `devtoys.cli`). Sudo is the Makefile's job (the SUDO wrapper from scope.mk).

set -euo pipefail

: "${DEST:?devtoys-cli.sh: DEST not set}"

if (($# != 1)); then
  printf 'devtoys-cli.sh: usage: %s <version>\n' "$0" >&2
  exit 2
fi

version="$1"

arch="$(uname -m)"
case "$arch" in
x86_64) dt_arch="x64" ;;
aarch64 | arm64) dt_arch="arm" ;;
*)
  printf 'devtoys-cli.sh: unsupported arch %s\n' "$arch" >&2
  exit 1
  ;;
esac

zip="devtoys.cli_linux_${dt_arch}_portable.zip"
url="https://github.com/DevToys-app/DevToys/releases/download/v${version}/${zip}"
install_dir="${DEST}/_devtoys-cli-${version}"

mkdir -p "$DEST"

# Strip any older _devtoys-cli-* trees so re-installs don't accumulate.
for old in "$DEST"/_devtoys-cli-*; do
  [ -e "$old" ] || continue # no matches → glob stays literal, skip
  rm -rf "$old"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf '  ↓ %s\n' "$url"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/$zip" "$url"

printf '  ↪ extracting to %s\n' "$install_dir"
mkdir -p "$install_dir"
unzip -q "$tmp/$zip" -d "$install_dir"

# DevToys.CLI sits at the zip root today; tolerate a wrapper dir (cf. the
# tree-layout flatten in bootstrap.ps1 and the find in pwndbg.sh).
exe="$install_dir/DevToys.CLI"
if [ ! -f "$exe" ]; then
  exe="$(find "$install_dir" -type f -name 'DevToys.CLI' 2>/dev/null | head -1)"
fi
if [ -z "$exe" ] || [ ! -f "$exe" ]; then
  printf 'devtoys-cli.sh: DevToys.CLI not found under %s\n' "$install_dir" >&2
  exit 1
fi
chmod 0755 "$exe" # zip extraction drops the executable bit

# Same non-executing capability gate the TOOL/EGET_TOOL macros apply: wrong
# arch / missing loader / too-new glibc fails the install before the stamp.
"$(dirname "$0")/verify-binary.sh" "$exe"

ln -sfn "$exe" "$DEST/devtoys.cli"
printf '  ✓ devtoys.cli %s ready at %s/devtoys.cli\n' "$version" "$DEST"
```

Then set the bits (the PostToolUse hook may auto-repair; run anyway):

```bash
chmod 755 makefile/lib/devtoys-cli.sh
file makefile/lib/devtoys-cli.sh             # must NOT say "with CRLF line terminators"
shfmt -i 2 -d makefile/lib/devtoys-cli.sh    # no diff
shellcheck makefile/lib/devtoys-cli.sh       # clean
```

- [ ] **Step 3: Add the Makefile target after the vcpkg block**

Insert after `clean-vcpkg:`'s last line (`@$(SUDO) rm -rf $(VCPKG_ROOT_DIR)`, ~line 361):

```make
# -----------------------------------------------------------------------------
# devtoys-cli — DevToys CLI (dev_machine only): scriptable command-line
# versions of the DevToys developer tools (json<->yaml, base64, hash, jwt).
# NOT an EGET_TOOL: the single-file DevToys.CLI executable requires its
# sibling Plugins/ tree, so lib/devtoys-cli.sh extracts the whole portable
# zip to $(DEST)/_devtoys-cli-<ver>/ and symlinks $(DEST)/devtoys.cli
# (command-name parity with the Windows $PortableTools install). The pin
# DUAL-EDITS with bootstrap.ps1 (check-invariants.sh enforces). $(SUDO)
# because it deposits under $(DEST). Stamp bakes DEVTOYS_CLI_VERSION so a
# bump in versions.mk reinstalls. No WSL skip (a converter belt is useful in
# a WSL dev guest).
# -----------------------------------------------------------------------------
.PHONY: devtoys-cli clean-devtoys-cli
ifeq ($(MODE),dev)
devtoys-cli: $(STAMP)/devtoys-cli-$(DEVTOYS_CLI_VERSION).done
$(STAMP)/devtoys-cli-$(DEVTOYS_CLI_VERSION).done:
	@printf '==> devtoys-cli %s\n' "$(DEVTOYS_CLI_VERSION)"
	@$(SUDO) $(LIB)/devtoys-cli.sh $(DEVTOYS_CLI_VERSION)
	@mkdir -p $(@D) && touch $@
else
devtoys-cli:
	@echo "devtoys-cli is a dev_machine target — skipping (MODE=$(MODE))"
endif
clean-devtoys-cli:
	@rm -f $(STAMP)/devtoys-cli-*.done
	@$(SUDO) rm -f $(DEST)/devtoys.cli
	@$(SUDO) rm -rf $(DEST)/_devtoys-cli-*
```

Recipe lines are TAB-indented (Make hard requirement).

- [ ] **Step 4: Join `PROVISION_FANOUT` + `DOCTOR_ROWS`**

Line ~701, change:

```make
PROVISION_FANOUT += pwndbg vcpkg go-runtime lsp-servers
```

to:

```make
PROVISION_FANOUT += pwndbg vcpkg go-runtime lsp-servers devtoys-cli
```

After `DOCTOR_ROWS += bespoke|go-runtime|$(GO_VERSION)` (~line 745), add:

```make
DOCTOR_ROWS += bespoke|devtoys-cli|$(DEVTOYS_CLI_VERSION)
```

- [ ] **Step 5: Sandbox-install and run it (the behavior test)**

```bash
SANDBOX=$(mktemp -d)
make -C makefile devtoys-cli MODE=dev DEST="$SANDBOX/dest" STAMP="$SANDBOX/stamps" SUDO=
# Expected output: "==> devtoys-cli 2.0.9.0", download+extract lines, verify pass, "✓ devtoys.cli 2.0.9.0 ready"
"$SANDBOX/dest/devtoys.cli" --version       # expect: version string "2.0-preview.9" (self-reported winget-style form of tag v2.0.9.0) after a spurious 4-line "'' was not matched" preamble (upstream System.CommandLine quirk; exit 0) — and NO missing-ICU crash
"$SANDBOX/dest/devtoys.cli" --help | head -20
make -C makefile devtoys-cli MODE=dev DEST="$SANDBOX/dest" STAMP="$SANDBOX/stamps" SUDO=   # second run: no re-download (stamp hit)
make -C makefile devtoys-cli MODE=prod DEST="$SANDBOX/dest" STAMP="$SANDBOX/stamps" SUDO=  # expect the skip message
rm -rf "$SANDBOX"
```

If `--version` aborts with an ICU/globalization error, STOP and report — the fix decision (add `libicu` to `LINUX_OPTIONAL_PACKAGES` vs `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT`) needs the human.

- [ ] **Step 6: Full lint + verify the hook regenerated the TOOLS block**

```bash
make -C makefile lint MODE=prod      # all green (dual-edit check for devtoys doesn't exist yet)
git status --short                   # chezmoi/private_dot_claude/CLAUDE.md should show modified (TOOLS block regen)
git diff chezmoi/private_dot_claude/CLAUDE.md   # devtoys.cli line inside the TOOLS sentinels
```

If the TOOLS block did NOT regenerate (hook only fires on Claude-driven edits), run `bash scripts/gen-tool-memory.sh` — it rewrites the block in place.

- [ ] **Step 7: Commit**

```bash
git add makefile/versions.mk makefile/lib/devtoys-cli.sh makefile/Makefile chezmoi/private_dot_claude/CLAUDE.md
git update-index --chmod=+x makefile/lib/devtoys-cli.sh
git ls-files --stage makefile/lib/devtoys-cli.sh    # must show 100755
git commit -m "feat(tools): DevToys CLI on Linux dev via bespoke tree target (2.0.9.0)

Self-contained portable zip -> \$(DEST)/_devtoys-cli-<ver>/ +
\$(DEST)/devtoys.cli symlink (lib/devtoys-cli.sh, pwndbg shape; verify-binary
gate). Dev-only: joins PROVISION_FANOUT under MODE=dev. Pin dual-edits
\$PortableTools in bootstrap.ps1.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 4: check-invariants.sh dual-edit check (TDD)

**Files:**
- Modify: `scripts/check-invariants.sh` — inside `check_version_pins()`, after the omp block (ends line ~104).

**Interfaces:**
- Consumes: `mkval` helper; the `DevToys-app/DevToys/releases/download/v2.0.9.0` URL literal from Task 2; `DEVTOYS_CLI_VERSION` from Task 3.
- Produces: a `devtoys-cli @ <ver>` line in every `make lint` run.

- [ ] **Step 1: Add the check block**

After the omp block:

```bash
  v=$(mkval OMP_VERSION)
  ref=$(grep -oE 'can1357/oh-my-pi/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "omp @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "omp drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi
```

append (same function, same style):

```bash

  v=$(mkval DEVTOYS_CLI_VERSION)
  ref=$(grep -oE 'DevToys-app/DevToys/releases/download/v[0-9][0-9.]+' bootstrap.ps1 |
    head -1 | sed 's#.*/v##')
  if [ -n "$v" ] && [ "$v" = "$ref" ]; then
    ok "devtoys-cli @ $v  (versions.mk == bootstrap.ps1)"
  else
    bad "devtoys-cli drift: versions.mk='$v' bootstrap.ps1='$ref'"
  fi
```

(Only the CLI's `$PortableTools` `Url` contains that literal path — the GUI resolves its URL at run time via the API, so the grep can't mis-hit it.)

- [ ] **Step 2: RED — prove the check catches drift**

```bash
sed -i 's/^DEVTOYS_CLI_VERSION := 2.0.9.0/DEVTOYS_CLI_VERSION := 9.9.9.9/' makefile/versions.mk
bash scripts/check-invariants.sh; echo "exit=$?"
# Expected: "✗ devtoys-cli drift: versions.mk='9.9.9.9' bootstrap.ps1='2.0.9.0'" and exit=1
```

- [ ] **Step 3: GREEN — restore and re-run**

```bash
git checkout -- makefile/versions.mk
bash scripts/check-invariants.sh; echo "exit=$?"
# Expected: "✓ devtoys-cli @ 2.0.9.0  (versions.mk == bootstrap.ps1)" and exit=0
```

- [ ] **Step 4: Commit**

```bash
git add scripts/check-invariants.sh
git commit -m "chore(invariants): enforce DEVTOYS_CLI_VERSION dual-edit (versions.mk <-> bootstrap.ps1)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 5: Docs — application_list, README.html, CLAUDE.md, claude-docs, changelog

**Files:**
- Modify: `docs/windows/application_list.md` (working tree already has an uncommitted `- DevToys` line — this task replaces it).
- Modify: `README.html` (six edit sites).
- Modify: `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `CLAUDE_CHANGELOG.md`.

**Interfaces:**
- Consumes: the behavior implemented in Tasks 1-4 (descriptions must match it: newest-non-draft resolver, notification-only updates, tree layout, dual-edit).
- Produces: user- and Claude-facing docs; nothing downstream.

- [ ] **Step 1: application_list.md — Zed pattern**

Line 2 currently reads:

```
Apps auto-installed by bootstrap.ps1 (WezTerm, Starship, Obsidian, Zed, Claude Code — plus chezmoi, Helix, and the JetBrainsMono Nerd Font, which were never listed here) are omitted; where they had in-row alternatives, those alternatives are kept.
```

Change `Obsidian, Zed, Claude Code` → `Obsidian, Zed, DevToys, Claude Code`. Delete the trailing `- DevToys` line (line 24, the uncommitted working-tree edit).

- [ ] **Step 2: README.html — DevToys CLI portable `<li>`**

After the OpenCode/omp `</li>` (line 2829), before the Obsidian `<li>` (2830), insert:

```html
                        <li>
                            <strong>DevToys CLI</strong>
                            (<code>devtoys.cli</code>) &mdash; scriptable
                            command-line DevToys utilities; pinned,
                            sha256-verified portable tree into
                            <code>%LOCALAPPDATA%\workstation\devtoys-cli</code>
                            (the single-file exe needs its sibling
                            <code>Plugins\</code> tree). The Windows half of
                            the Linux dev-only install (version dual-edit
                            with <code>makefile/versions.mk</code>).
                        </li>
```

- [ ] **Step 3: README.html — DevToys installer-class `<li>`**

After the Zed `</li>` (line 2852), before the SSHFS-Win `<li>`, insert:

```html
                        <li>
                            <strong>DevToys</strong> &mdash; same
                            installer-class path: silent, per-user install of
                            its Inno Setup <code>.exe</code>, verified against
                            the GitHub API&rsquo;s sha256 digest and detected
                            via the Uninstall registry. Two wrinkles: DevToys
                            flags every release pre-release, so the script
                            resolves the newest non-draft release (not
                            <em>latest</em>); and it only <em>notifies</em>
                            about updates (no self-update) &mdash; refresh
                            with <code>-ForceInstaller</code>.
                        </li>
```

- [ ] **Step 4: README.html — the four enumeration edits**

1. Line ~2987: `# re-install installer tools (Obsidian, Zed) even if present` → `# re-install installer tools (Obsidian, Zed, DevToys) even if present`
2. Line ~3044: `chezmoi/WezTerm/Starship/Helix/Nushell/OpenCode/omp` → `chezmoi/WezTerm/Starship/Helix/Nushell/OpenCode/omp/DevToys CLI`
3. Lines ~3045-3048: `the installer-class apps
                        (Obsidian, Zed) and the native` → `the installer-class apps
                        (Obsidian, Zed, DevToys) and the native`, and `Obsidian and Zed install
                        silently per-user` → `Obsidian, Zed, and DevToys install
                        silently per-user`
4. Lines ~4615-4616: `(<code>$InstallerTools</code>, e.g. Obsidian,
                                Zed) are` → `(<code>$InstallerTools</code>, e.g. Obsidian,
                                Zed, DevToys) are`

- [ ] **Step 5: README.html — `devtoys.cli` chip in the Data/SQL stack card**

In the `cat-data` card (opens line 1023), insert after the `fx` chip's closing `>` (the chip pattern is jq's at lines 1026-1033):

```html
                                <span
                                    class="chip"
                                    tabindex="0"
                                    data-tip="DevToys CLI — scriptable DevToys utilities: convert, encode/decode, hash, format (dev_machine only); also in the Windows portable belt"
                                    >devtoys.cli<span class="sr-only">
                                        — DevToys CLI: scriptable developer
                                        utilities (json/yaml convert, base64,
                                        hash, jwt; dev_machine only; Windows
                                        gets the pinned portable tree via
                                        bootstrap.ps1)</span
                                    ></span
                                >
```

- [ ] **Step 6: CLAUDE.md — three edits**

1. In the Windows-installs invariant bullet, extend `(…e.g. Obsidian + Zed)` → `(…e.g. Obsidian + Zed + DevToys)`, and after the sentence ending "`-ForceInstaller` forces reinstall; `-SkipToolInstall` skips installer tools too." append:

```
DevToys carries the class's two OPT-IN fields: `IncludePrerelease` (all its 2.x releases are `prerelease:true`, so `/releases/latest` returns 2023's v1.0.13.0 — the resolver takes the newest non-draft of `/releases` instead) and `UpdateHint` (DevToys does NOT self-update — its in-app check is notification-only; Doctor/CheckForUpdates print the hint instead of "self-updates").
```

2. In the same bullet, after the OpenCode/Oh My Pi portable-tools sentence, append:

```
**DevToys CLI is a pinned portable tool too** (`Layout = "tree"` → `workstation\devtoys-cli` — self-contained single-file exe + REQUIRED sibling `Plugins/` tree, invoked as `devtoys.cli`); its pin dual-edits `DEVTOYS_CLI_VERSION` in `versions.mk` (the Windows half of the dev-only Linux bespoke target `devtoys-cli`).
```

3. In "Files Claude should be careful with" → the **Version-pin dual/triple-edits** list, after the `OPENCODE_VERSION + OMP_VERSION` entry, add:

```
`DEVTOYS_CLI_VERSION` (`versions.mk` ↔ `bootstrap.ps1` `$PortableTools`, `Layout = "tree"` — verified by `check-invariants.sh`)
```

Also add a one-line bullet to the Load-bearing invariants index, right after the `go-runtime + lsp-servers` bullet:

```
- **`devtoys-cli` is a dev-only bespoke target** — `lib/devtoys-cli.sh` (pwndbg shape: portable zip → `$(DEST)/_devtoys-cli-<ver>/`, `verify-binary.sh` gate, symlink `$(DEST)/devtoys.cli`); NOT eget-able (exe needs its sibling `Plugins/` tree); Windows half pinned in `$PortableTools` (dual-edit above).
```

- [ ] **Step 7: docs/claude/invariants.md + docs/claude/file-care.md**

Read each file, find its `OPENCODE_VERSION`/`OMP_VERSION` dual-edit entry, and add a matching `DEVTOYS_CLI_VERSION` entry alongside, carrying: versions.mk ↔ `$PortableTools`, the prerelease-trap warning (`/releases/latest` lies for this repo), and "refresh the Windows `Sha256` on every bump". In file-care.md, if lib scripts are enumerated by name anywhere, add `makefile/lib/devtoys-cli.sh` to that enumeration (the LF+0755 glob already covers it mechanically).

- [ ] **Step 8: CLAUDE_CHANGELOG.md — append the row**

```markdown
| Added DevToys: GUI as a third installer-class app in `bootstrap.ps1` with two new opt-in fields — `IncludePrerelease` (all DevToys 2.x releases are `prerelease:true`, so `/releases/latest` returns 2023's v1.0.13.0; resolver takes the newest non-draft of `/releases`) and `UpdateHint` (DevToys never self-updates; in-app check is notification-only) — plus DevToys CLI as a pinned `$PortableTools` tree on Windows AND a dev-only bespoke tree target on Linux (`lib/devtoys-cli.sh`, pwndbg shape; `DEVTOYS_CLI_VERSION` dual-edit enforced by `check-invariants.sh`). DevToys removed from the manual Windows app list (Zed precedent). | **Yes** | §setup-windows: DevToys installer-class entry + DevToys CLI portable entry; `-ForceInstaller`/`-SkipToolInstall` doc lines extended; §troubleshooting installer-class enumeration; Stack §Data/SQL card gains `devtoys.cli` chip. |
```

- [ ] **Step 9: Lint + commit**

```bash
make -C makefile lint MODE=prod     # all green
git add docs/windows/application_list.md README.html CLAUDE.md docs/claude/invariants.md docs/claude/file-care.md CLAUDE_CHANGELOG.md
git commit -m "docs: DevToys GUI + CLI across README, app list, CLAUDE docs, changelog

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014CLutxJQcXvocK6Tc3Rg7a"
```

---

### Task 6: Final verification + real dev install

**Files:** none new — verification only (plus the real install on this WSL dev host).

- [ ] **Step 1: Full local gate**

```bash
make -C makefile lint MODE=prod              # invariants (devtoys-cli ✓ row), shfmt, shellcheck, gitleaks, templates
make -C makefile ps-lint                     # PSScriptAnalyzer (or note CI-enforced if pwsh absent)
bash .claude/hooks/test-hooks.sh             # hook suite still green
```

- [ ] **Step 2: Real install on this host (it's the dev machine)**

```bash
make -C makefile devtoys-cli MODE=dev        # real /usr/local install via sudo
devtoys.cli --version                        # expect "2.0-preview.9" after the spurious matcher preamble (see Task 3 Step 5 note)
ls -l /usr/local/bin/devtoys.cli             # symlink -> /usr/local/bin/_devtoys-cli-2.0.9.0/DevToys.CLI
```

- [ ] **Step 3: Windows-side note (cannot run here)**

Record in the PR body: on the Windows host after merge — re-run `bootstrap.ps1`; verify HKCU `...\Uninstall\DevToys_is1` exists, Start-menu entry present, no UAC prompt; `devtoys.cli --version` from a fresh shell; `.\bootstrap.ps1 -CheckForUpdates` shows DevToys with the custom hint and "DevToys CLI 2.0.9.0" pinned-vs-latest; `.\bootstrap.ps1 -Doctor` green.

- [ ] **Step 4: Finish the branch**

Use superpowers:finishing-a-development-branch — push `feat/devtoys`, open the PR (body includes the Windows verification checklist above), request review.

```bash
git log --oneline main..feat/devtoys         # spec + 5 implementation commits
```
