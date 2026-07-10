# Windows bootstrap de-Chocolatey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Chocolatey + admin requirement in `bootstrap.ps1` with admin-free binary/portable installs under `%LOCALAPPDATA%\workstation`, make Git a hard prerequisite, drop all legacy handling, and update the docs/memory that describe it.

**Architecture:** `bootstrap.ps1` is rewritten so the only auto-installs are chezmoi (official `get.chezmoi.io` binary installer → `workstation\bin`), Starship and WezTerm (pinned, sha256-verified portable `.zip`s → `workstation\bin` / `workstation\wezterm`). Git hard-fails if missing; Zed/VSCode soft-warn; zoxide is dropped. A reusable `Install-PortableTool` helper (modeled on `scripts\install-nerd-fonts.ps1`) does download→verify→extract→PATH. `Invoke-LegacyPathMigrate`, `Test-IsAdmin`, `Install-Chocolatey`, `$ChocoTools`, and the WezTerm legacy-hardlink cleanup are all removed. README.html, CLAUDE_CHANGELOG.md, docs/claude/file-care.md, CLAUDE.md, and the `feedback-windows-chezmoi-check-before-apply` memory are updated to match.

**Tech Stack:** PowerShell 5.1 (Windows host; UTF-8 **with BOM** required), chezmoi, Git, GitHub release artifacts. No `pwsh` on the authoring host — verification here is structural (`grep`, `file`); functional verification runs on the Windows host.

**Spec:** `docs/superpowers/specs/2026-06-05-windows-bootstrap-dechocolatey-design.md`

---

## Pre-flight: source the version pins (do this BEFORE Task 1)

The `$PortableTools` manifest needs real `Sha256` values. WezTerm is pinned to `20240203-110809-5046fc22` to match the vendored terminfo pin already in the repo (CLAUDE.md "config.term='wezterm' ↔ wezterm-terminfo" invariant). Starship is pinned to `1.21.1` (adjust to current stable if desired).

- [ ] **Step P1: Download both artifacts and compute sha256 (from the Linux authoring host, network permitting)**

Run:
```bash
cd /tmp
curl -fL -o starship.zip https://github.com/starship/starship/releases/download/v1.21.1/starship-x86_64-pc-windows-msvc.zip
curl -fL -o wezterm.zip  https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/WezTerm-windows-20240203-110809-5046fc22.zip
sha256sum starship.zip wezterm.zip
# Also inspect the wezterm zip's top-level layout so the 'tree' handler is correct:
unzip -l wezterm.zip | head -20
```
Expected: two sha256 hashes; the wezterm listing shows whether files sit under a single top-level folder (e.g. `wezterm-windows-.../wezterm-gui.exe`) or at the root.

If the network is unavailable here, leave the `Sha256` fields as the literal `<<PIN-ME-...>>` placeholders. `Install-PortableTool` hard-fails on a `*PIN-ME*` value, so nothing ships unverified — the pins must be filled before the script is actually run on Windows. Record the blocker in the final report.

- [ ] **Step P2: Note the two hashes** for use in Task 1's `$PortableTools` block (replace `<<PIN-ME-starship-sha256>>` and `<<PIN-ME-wezterm-sha256>>`). Verify the WezTerm asset name and inner-folder layout match what Task 1 assumes; if the zip has no single top-level folder, the `tree` handler already falls back to copying the temp dir root (no change needed).

---

## Task 1: Rewrite `bootstrap.ps1`

**Files:**
- Modify (wholesale replace): `bootstrap.ps1`

This is a full-file replacement. The file MUST end up as UTF-8 **with BOM** (PS 5.1 mis-parses the `✓`/`✗`/`─` glyphs without it). The `Write` tool produces BOM-less UTF-8, so Step 2 re-adds the BOM and Step 3 verifies.

- [ ] **Step 1: Replace the entire contents of `bootstrap.ps1` with the following**

```powershell
# =============================================================================
# bootstrap.ps1 — workstation setup (Windows client side)
#
# The Windows host is a CLIENT — Ansible/Make run on Linux hosts only. On
# Windows this script provisions its slice with NO package manager and NO admin
# rights: it installs a small set of first-party binaries into a per-user
# location, then hands off to chezmoi to deploy the tracked dotfiles.
#
# Install model (everything under %LOCALAPPDATA%\workstation, added to User PATH):
#   - chezmoi   — official get.chezmoi.io binary installer  → workstation\bin
#   - Starship  — pinned portable .zip (sha256-verified)    → workstation\bin
#   - WezTerm   — pinned portable .zip (sha256-verified)    → workstation\wezterm
#
#   Git is a PREREQUISITE you install yourself — the script HARD-FAILS if git
#   isn't on PATH (https://git-scm.com/download/win or `winget install Git.Git`).
#   Zed + VSCode are also installed by hand; the script soft-warns if they're
#   missing but their chezmoi configs still deploy. zoxide is no longer
#   installed (the PowerShell profile no-ops without it).
#
# Flow:
#   1. preflight    — require git on PATH (hard-fail w/ install link); warn if
#                     ssh-keygen / Zed / VSCode are missing.
#   2. tool install — chezmoi (official installer) + WezTerm/Starship (pinned
#                     portable downloads), all into %LOCALAPPDATA%\workstation.
#   3. clone repo   — into -RepoPath (default %USERPROFILE%\.local\share\chezmoi,
#                     matching bootstrap.sh's $HOME/.local/share/chezmoi and
#                     chezmoi's own default source dir).
#   4. chezmoi apply— applies chezmoi/ to %USERPROFILE% (PowerShell profile,
#                     Zed/VSCode settings, etc.). wezterm.lua is ignored on
#                     Windows; WezTerm reads it via the env var in step 5.
#   5. wezterm env  — set User-scope WEZTERM_CONFIG_FILE at the chezmoi source.
#   6. burnt toast  — PSGallery module (CurrentUser) for Claude Code WSL2 toasts.
#   7. nerd fonts   — JetBrainsMono Nerd Font Mono (per-user, HKCU).
#   8. ssh key      — generate %USERPROFILE%\.ssh\id_ed25519 if missing.
#
# NO ADMIN REQUIRED: every step writes to per-user locations (workstation\ on
# the User PATH, CurrentUser PSGallery, HKCU fonts, ~/.ssh).
#
# PRIVATE REPO + commit attribution — set GITHUB_TOKEN, GIT_USER_NAME,
# GIT_USER_EMAIL before running. The token authenticates the bootstrap.ps1 fetch
# AND the internal git clone/pull, then is persisted into the cloned repo's
# .git/config (http.https://github.com/.extraheader, scoped to github.com) so
# subsequent push/pull and manage-hosts.ps1 ops work without re-passing it.
#
# One-liner from a fresh Windows machine (NO elevation needed):
#
#   $env:GITHUB_TOKEN   = '<your-PAT>'
#   $env:GIT_USER_NAME  = 'Arrush Chaturvedi'
#   $env:GIT_USER_EMAIL = 'contact@arrushc.com'
#   irm -Headers @{Authorization="token $env:GITHUB_TOKEN"} `
#     https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1 | iex
#
# Or clone manually + run:
#
#   git clone https://github.com/ArrushC/workstation.git `
#     "$env:USERPROFILE\.local\share\chezmoi"
#   cd "$env:USERPROFILE\.local\share\chezmoi"
#   .\bootstrap.ps1
#
# Flags:
#   -RepoPath <path>    override clone target
#                       (default $env:USERPROFILE\.local\share\chezmoi)
#   -SkipKeyGen         skip the SSH-key generation prompt
#   -SkipToolInstall    skip the chezmoi/WezTerm/Starship auto-installs
#                       (assume they're already on PATH)
#   -SkipChezmoi        clone + install tools but don't apply dotfiles yet
#   -SkipBurntToast     skip the BurntToast PSGallery module install
#   -SkipNerdFonts      skip the Nerd Font install
#   -Reinstall          wipe the cloned repo + chezmoi config first, then run the
#                       normal flow. Does NOT remove installed tools or deployed
#                       dotfiles — the bootstrap is idempotent over those.
#                       Prompts unless -Yes is also passed.
#   -Yes                skip confirmation prompts (Reinstall).
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoPath = (Join-Path $env:USERPROFILE ".local\share\chezmoi"),
    [switch]$SkipKeyGen,
    [switch]$SkipToolInstall,
    [switch]$SkipChezmoi,
    [switch]$SkipBurntToast,
    [switch]$SkipNerdFonts,
    [switch]$Reinstall,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- ANSI escape codes (matches manage-hosts.{ps1,sh}) ----------------------
$Esc    = [char]27
$Bold   = "$Esc" + "[1m"
$Reset  = "$Esc" + "[0m"
$Red    = "$Esc" + "[0;31m"
$Green  = "$Esc" + "[0;32m"
$Yellow = "$Esc" + "[1;33m"
$Blue   = "$Esc" + "[0;34m"

function Write-Log    { param($msg) Write-Host "${Blue}==>${Reset} ${Bold}$msg${Reset}" }
function Write-Ok     { param($msg) Write-Host "${Green} ✓${Reset} $msg" }
function Write-Warn   { param($msg) Write-Host "${Yellow} !${Reset} $msg" }
function Write-Fail   { param($msg) Write-Host "${Red} ✗${Reset} $msg"; exit 1 }

$DotfilesRepo = "https://github.com/ArrushC/workstation.git"
$SshKey       = "$env:USERPROFILE\.ssh\id_ed25519"

# Token persisted into .git/config under this key — scoped to github.com so
# it never leaks to other remotes.
$GhHeaderKey = "http.https://github.com/.extraheader"

# Per-user install root for every binary this script provisions. Admin-free:
#   workstation\bin      — single-exe tools (chezmoi, starship)  → on User PATH
#   workstation\wezterm  — the multi-file WezTerm portable tree  → on User PATH
#   workstation\stamps   — "<exe>.<version>.stamp" idempotency markers
$WsRoot    = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin     = Join-Path $WsRoot "bin"
$WsWezterm = Join-Path $WsRoot "wezterm"
$WsStamps  = Join-Path $WsRoot "stamps"

# Pinned portable tools. version + sha256 live HERE (same self-contained pattern
# as scripts\install-nerd-fonts.ps1) — NOT makefile/versions.mk, because Make
# never runs on Windows. Bump = update Version + refresh Sha256 (compute over the
# downloaded .zip). Layout 'single' copies <Exe>.exe into Dest; 'tree' extracts
# the whole archive into Dest. WezTerm is pinned to the same tag as the vendored
# terminfo (see CLAUDE.md's wezterm-terminfo invariant).
$PortableTools = @(
    @{
        Name    = "Starship"
        Exe     = "starship"
        Version = "1.21.1"
        Url     = "https://github.com/starship/starship/releases/download/v1.21.1/starship-x86_64-pc-windows-msvc.zip"
        Sha256  = "<<PIN-ME-starship-sha256>>"
        Layout  = "single"
        Dest    = $WsBin
    },
    @{
        Name    = "WezTerm"
        Exe     = "wezterm"
        Version = "20240203-110809-5046fc22"
        Url     = "https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/WezTerm-windows-20240203-110809-5046fc22.zip"
        Sha256  = "<<PIN-ME-wezterm-sha256>>"
        Layout  = "tree"
        Dest    = $WsWezterm
    }
)

# =============================================================================
# 0. REINSTALL (optional) — wipe the cloned repo + chezmoi config, then let the
#    rest of the script re-bootstrap fresh. Installed tools and deployed
#    dotfiles are left alone — re-running is idempotent over those.
# =============================================================================
function Invoke-Reinstall {
    $chezmoiCfg = Join-Path $env:USERPROFILE ".config\chezmoi"

    Write-Log "Reinstall mode — wipe + re-bootstrap"
    Write-Host ""
    Write-Host "  Will REMOVE:"
    Write-Host "    - $RepoPath  (cloned workstation repo)"
    Write-Host "    - $chezmoiCfg  (chezmoi config + cached init data)"
    Write-Host ""
    Write-Host "  Will NOT remove (leaving for re-bootstrap to no-op over):"
    Write-Host "    - Binary tools under $WsRoot (re-bootstrap detects + skips them)"
    Write-Host "    - Deployed dotfiles in `$HOME / `$env:APPDATA (chezmoi will re-apply)"
    Write-Host "    - SSH keys"
    Write-Host ""
    Write-Host "  For a deeper uninstall (remove the portable tools too), do that manually first:"
    Write-Host "    Remove-Item -Recurse -Force '$WsRoot'   # chezmoi/starship/wezterm re-download next run"
    Write-Host ""

    # Self-deletion guard: if this script is being run from inside the path we're
    # about to delete, refuse. Use the curl|iex one-liner instead, which runs
    # from memory and isn't backed by a file on disk. $PSCommandPath is $null
    # when the script is executed from a string (iex/irm-pipe).
    if ($PSCommandPath -and $PSCommandPath.StartsWith($RepoPath, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Fail @"
Refusing to reinstall — the running script is inside $RepoPath, which would
be deleted, leaving this invocation orphaned. Either:

  1. Use the curl-pipe form from any directory (script runs from memory):
       irm -Headers @{Authorization="token `$env:GITHUB_TOKEN"} ``
         https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1 | iex

  2. Copy this script somewhere outside the repo first, then re-run:
       Copy-Item $PSCommandPath `$env:TEMP\bootstrap.ps1
       & `$env:TEMP\bootstrap.ps1 -Reinstall
"@
    }

    if (-not $Yes) {
        $ans = Read-Host "  Proceed? [y/N]"
        if ($ans -notmatch '^[Yy]') {
            Write-Warn "Aborted."
            exit 0
        }
    }

    if (Test-Path $RepoPath) {
        Write-Log "Removing $RepoPath..."
        Remove-Item -Recurse -Force $RepoPath
        Write-Ok "Repo removed"
    } else {
        Write-Log "$RepoPath not present — nothing to remove"
    }

    if (Test-Path $chezmoiCfg) {
        Write-Log "Removing $chezmoiCfg..."
        Remove-Item -Recurse -Force $chezmoiCfg
        Write-Ok "chezmoi config removed"
    } else {
        Write-Log "$chezmoiCfg not present — nothing to remove"
    }

    Write-Host ""
    Write-Log "Wipe complete — continuing with fresh bootstrap..."
    Write-Host ""
}

# =============================================================================
# 1. PREFLIGHT — Git is a hard prerequisite; chezmoi presence only matters when
#    -SkipToolInstall is set and the apply step will run; ssh-keygen soft-warn.
#    No admin check (nothing in this script needs elevation).
# =============================================================================
function Invoke-Preflight {
    Write-Log "Checking prerequisites..."

    # Git is a hard prerequisite — you install it yourself. Needed for the clone
    # and for chezmoi's git operations. This script does NOT install Git.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Fail @"
Git is required but isn't on PATH.

Install Git for Windows (an admin-free per-user install is available), then
re-run this script:
  https://git-scm.com/download/win
or:  winget install Git.Git

This script does NOT install Git for you.
"@
    }
    Write-Ok "git found ($((Get-Command git).Source))"

    # chezmoi is installed by the tool step unless skipped. If -SkipToolInstall
    # is set and the chezmoi-apply step will run, chezmoi must already be present.
    if ($SkipToolInstall -and -not $SkipChezmoi -and -not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        Write-Fail @"
-SkipToolInstall was passed but chezmoi isn't on PATH and the chezmoi-apply step
will run. Either drop -SkipToolInstall (so the script installs chezmoi), pass
-SkipChezmoi (skip the apply), or install chezmoi yourself first.
"@
    }

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Warn "ssh-keygen not on PATH — install OpenSSH client to enable the SSH-key step:"
        Write-Warn "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    }

    Write-Ok "Prerequisites OK"
}

# =============================================================================
# 2. TOOL INSTALL — admin-free binary/portable installs under %LOCALAPPDATA%\
#    workstation. chezmoi via its official installer; WezTerm + Starship via
#    pinned, sha256-verified portable archives. Zed/VSCode are hand-installed
#    (soft-warn). zoxide is intentionally not installed.
# =============================================================================
function Update-SessionPath {
    # New PATH entries are written to the User registry scope; the current
    # session keeps its own copy. Rebuild $env:PATH from Machine + User so
    # freshly-installed tools resolve right away.
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Add-ToUserPath {
    param([string]$Dir)

    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $userPath) { $userPath = "" }

    # Idempotent: append to the User PATH only if not already present
    # (case-insensitive, trailing-slash-insensitive).
    $present = $userPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }
    if (-not $present) {
        $base = $userPath.TrimEnd(';')
        $newPath = if ($base) { "$base;$Dir" } else { $Dir }
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Ok "Added $Dir to User PATH"
    }

    # Always refresh the in-session PATH so later steps + spawned procs resolve.
    $inSession = ($env:PATH).Split(';', [StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_.TrimEnd('\') -ieq $Dir.TrimEnd('\') }
    if (-not $inSession) {
        $env:PATH = "$(($env:PATH).TrimEnd(';'));$Dir"
    }
}

function Install-Chezmoi {
    if (Get-Command chezmoi -ErrorAction SilentlyContinue) {
        Write-Ok "chezmoi already installed"
        return
    }

    if (-not (Test-Path $WsBin)) { New-Item -ItemType Directory -Force -Path $WsBin | Out-Null }

    Write-Log "Installing chezmoi (official get.chezmoi.io binary installer → $WsBin)..."
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        $installer = Invoke-RestMethod -UseBasicParsing -Uri 'https://get.chezmoi.io/ps1'
        & ([scriptblock]::Create($installer)) -BinDir $WsBin
    } catch {
        if ($SkipChezmoi) {
            Write-Warn "chezmoi install failed ($($_.Exception.Message)) — continuing because -SkipChezmoi was passed."
            return
        }
        Write-Fail @"
chezmoi install failed: $($_.Exception.Message)
Install it manually (admin-free) and re-run, e.g.:
  winget install twpayne.chezmoi
or drop the chezmoi.exe binary from
  https://github.com/twpayne/chezmoi/releases
into $WsBin and re-run.
"@
    }

    Add-ToUserPath $WsBin

    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        if ($SkipChezmoi) {
            Write-Warn "chezmoi installed to $WsBin but isn't resolving on PATH yet (continuing — -SkipChezmoi)."
            return
        }
        Write-Fail "chezmoi installed to $WsBin but isn't resolving on PATH. Open a new shell and re-run."
    }
    Write-Ok "chezmoi installed to $WsBin"
}

function Install-PortableTool {
    param([hashtable]$Tool)

    $stamp = Join-Path $WsStamps "$($Tool.Exe).$($Tool.Version).stamp"

    # Idempotency: stamp present AND command resolves → already done. A version
    # bump changes the stamp name, so the old stamp won't match → reinstall.
    if ((Test-Path $stamp) -and (Get-Command $Tool.Exe -ErrorAction SilentlyContinue)) {
        Write-Ok "$($Tool.Name) $($Tool.Version) already installed"
        return
    }

    if ($Tool.Sha256 -like "*PIN-ME*") {
        Write-Fail "$($Tool.Name) has an unfilled sha256 pin ($($Tool.Sha256)). Fill it in `$PortableTools before running."
    }

    Write-Log "Installing $($Tool.Name) $($Tool.Version) (portable)..."

    $tmpZip = Join-Path $env:TEMP "ws-$($Tool.Exe)-$($Tool.Version).zip"
    $tmpDir = Join-Path $env:TEMP "ws-$($Tool.Exe)-$($Tool.Version)"

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $Tool.Url -OutFile $tmpZip -UseBasicParsing
    } catch {
        Write-Warn "$($Tool.Name) download failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }

    # sha256 verify — the ONE hard-fail inside this helper (tamper/corruption).
    $actual = (Get-FileHash -Algorithm SHA256 -Path $tmpZip).Hash.ToLower()
    if ($actual -ne $Tool.Sha256.ToLower()) {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Write-Fail @"
$($Tool.Name) sha256 mismatch — refusing to install.
  expected: $($Tool.Sha256.ToLower())
  actual:   $actual
The pinned hash in `$PortableTools is stale, or the download was corrupted/tampered.
"@
    }

    try {
        if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

        if ($Tool.Layout -eq "single") {
            if (-not (Test-Path $Tool.Dest)) { New-Item -ItemType Directory -Force -Path $Tool.Dest | Out-Null }
            $exe = Get-ChildItem -Path $tmpDir -Recurse -Filter "$($Tool.Exe).exe" | Select-Object -First 1
            if (-not $exe) {
                Write-Warn "$($Tool.Name): $($Tool.Exe).exe not found in archive — skipping"
                return
            }
            Copy-Item $exe.FullName -Destination (Join-Path $Tool.Dest "$($Tool.Exe).exe") -Force
            Add-ToUserPath $Tool.Dest
        } else {
            # 'tree' — the archive may wrap everything in a single top-level
            # folder; flatten that so wezterm-gui.exe lands directly in Dest.
            $top = @(Get-ChildItem -Path $tmpDir)
            $src = if (($top.Count -eq 1) -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmpDir }
            if (Test-Path $Tool.Dest) { Remove-Item -Recurse -Force $Tool.Dest }
            New-Item -ItemType Directory -Force -Path $Tool.Dest | Out-Null
            Copy-Item -Path (Join-Path $src '*') -Destination $Tool.Dest -Recurse -Force
            Add-ToUserPath $Tool.Dest
        }

        if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "$($Tool.Name) $($Tool.Version) installed to $($Tool.Dest)"
    } catch {
        Write-Warn "$($Tool.Name) install failed during extract/place: $($_.Exception.Message)"
    } finally {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ToolInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship are on PATH"
        return
    }

    foreach ($d in @($WsRoot, $WsBin, $WsStamps)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    Install-Chezmoi
    foreach ($tool in $PortableTools) { Install-PortableTool -Tool $tool }

    Update-SessionPath

    # Soft-warn for the hand-installed editors. Their chezmoi configs deploy
    # regardless; the script never installs or fails on them.
    foreach ($app in @(@{ Cmd = 'zed'; Name = 'Zed' }, @{ Cmd = 'code'; Name = 'VSCode' })) {
        if (-not (Get-Command $app.Cmd -ErrorAction SilentlyContinue)) {
            Write-Warn "$($app.Name) not on PATH — install it yourself when you want it; its chezmoi config still deploys."
        }
    }
}

# =============================================================================
# 3. CLONE REPO (with $env:GITHUB_TOKEN support for private repo)
# =============================================================================
function Invoke-CloneRepo {
    # HTTP Basic with base64-encoded "x-access-token:<PAT>" — same scheme
    # actions/checkout uses. "Authorization: bearer" works for the REST/raw API
    # (how irm fetches bootstrap.ps1) but is NOT accepted by git's smart-HTTP
    # endpoint on github.com — git silently falls through to credential
    # prompting, breaking any non-interactive clone.
    $headerVal = ""
    if ($env:GITHUB_TOKEN) {
        $b64 = [Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes("x-access-token:$env:GITHUB_TOKEN"))
        $headerVal = "Authorization: Basic $b64"
    }

    if (-not (Test-Path "$RepoPath\.git")) {
        Write-Log "Cloning workstation repo into $RepoPath..."
        $parent = Split-Path $RepoPath -Parent
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }

        if ($headerVal) {
            git -c "$GhHeaderKey=$headerVal" clone $DotfilesRepo $RepoPath
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Clone failed. For a private repo, set `$env:GITHUB_TOKEN to a PAT with repo read."
            }
            git -C $RepoPath config $GhHeaderKey $headerVal
        } else {
            git clone $DotfilesRepo $RepoPath
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Clone failed. If the repo is private, set `$env:GITHUB_TOKEN and re-run."
            }
        }
        Write-Ok "Repo cloned"
    } else {
        Write-Log "Repo already at $RepoPath — pulling latest..."
        if ($headerVal) {
            git -C $RepoPath config $GhHeaderKey $headerVal
        }
        git -C $RepoPath pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not fast-forward — continuing with current state"
        } else {
            Write-Ok "Repo up to date"
        }
    }
}

# =============================================================================
# 4. CHEZMOI INIT + APPLY — deploys dotfiles tracked in chezmoi/
# =============================================================================
function Invoke-Chezmoi {
    if ($SkipChezmoi) {
        Write-Log "chezmoi step skipped (-SkipChezmoi)"
        return
    }

    if (-not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
        Write-Warn "chezmoi not on PATH after install. Open a new shell and re-run, or install manually:"
        Write-Warn "  winget install twpayne.chezmoi"
        return
    }

    Write-Log "Running chezmoi init --apply (source: $RepoPath)..."

    # --source points at the cloned repo. .chezmoiroot inside redirects the
    # actual source state to the chezmoi/ subdirectory, so all `dot_*` files
    # there map correctly to %USERPROFILE%\... targets.
    chezmoi init --apply --source $RepoPath
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "chezmoi init --apply failed. Inspect with: chezmoi diff --source $RepoPath"
    }
    Write-Ok "chezmoi applied — dotfiles in place"
}

# =============================================================================
# 5. WEZTERM_CONFIG_FILE — point WezTerm directly at the chezmoi source.
#    WezTerm reads its config from whatever $env:WEZTERM_CONFIG_FILE resolves
#    to, and the chezmoi source path is a normal file. automatically_reload_config
#    picks up edits live (e.g. from manage-hosts.ps1 -Sync), and there's no
#    home-path copy to maintain — dot_config/wezterm is in .chezmoiignore.tmpl
#    on Windows, so chezmoi never writes %USERPROFILE%\.config\wezterm\.
#
#    Idempotent: re-running with the same RepoPath is a no-op.
# =============================================================================
function Invoke-WeztermConfigEnv {
    $envName  = 'WEZTERM_CONFIG_FILE'
    $newValue = Join-Path $RepoPath "chezmoi\dot_config\wezterm\wezterm.lua"

    if (-not (Test-Path $newValue)) {
        Write-Warn "Skipping $envName setup — chezmoi source not found at $newValue"
        return
    }

    $current = [Environment]::GetEnvironmentVariable($envName, 'User')

    if ($current -eq $newValue) {
        Write-Ok "$envName already points at the chezmoi source"
    } else {
        Write-Log "Setting User-scope $envName to $newValue..."
        [Environment]::SetEnvironmentVariable($envName, $newValue, 'User')
        # Propagate to the current session so anything later in this script
        # (and any wezterm spawned from the same shell) sees the new value.
        Set-Item "Env:$envName" $newValue
        if ($current) {
            Write-Ok "$envName updated (was: $current)"
        } else {
            Write-Ok "$envName set"
        }
        Write-Warn "Restart any running WezTerm instances to pick up the new config location."
    }
}

# =============================================================================
# 6. BURNTTOAST — PowerShell module that lets `New-BurntToastNotification`
#    surface native Windows 10/11 toasts. Used by the WSL2 branch of
#    chezmoi/private_dot_claude/executable_notify.sh (deployed to
#    ~/.claude/notify.sh on dev_machine Linux hosts), which calls powershell.exe
#    from WSL2 to ping the Windows side when Claude Code needs attention. Falls
#    back to System.Windows.Forms.MessageBox if the module is absent.
#    CurrentUser scope — no admin, idempotent, soft-fails to a warning.
# =============================================================================
function Invoke-InstallBurntToast {
    if ($SkipBurntToast) {
        Write-Log "BurntToast install skipped (-SkipBurntToast)"
        return
    }

    if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
        Write-Ok "BurntToast already installed"
        return
    }

    Write-Log "Installing BurntToast PowerShell module (CurrentUser scope)..."

    try {
        # PSGallery defaults to Untrusted — Install-Module would prompt
        # interactively. Flip to Trusted (process-wide, idempotent) so the
        # install runs unattended. -ErrorAction SilentlyContinue covers the
        # case where PSGallery isn't registered at all (very old PS).
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
        }
        Install-Module -Name BurntToast -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Ok "BurntToast installed"
    } catch {
        Write-Warn "BurntToast install failed: $_"
        Write-Warn "  Claude Code WSL2 notifications will fall back to a MessageBox dialog."
        Write-Warn "  Retry manually:  Install-Module BurntToast -Scope CurrentUser"
    }
}

# =============================================================================
# 7. NERD FONTS — JetBrainsMono Nerd Font Mono installed per-user. Required by
#    chezmoi-tracked configs that assume Nerd Font glyphs (starship, eza --icons,
#    lazygit, k9s, yazi, broot, helix, ccstatusline, Claude Code TUI). Invokes
#    scripts/install-nerd-fonts.ps1. Soft-fails if -SkipNerdFonts or the helper
#    is missing.
# =============================================================================
function Invoke-InstallNerdFonts {
    if ($SkipNerdFonts) {
        Write-Log "Nerd Fonts install skipped (-SkipNerdFonts)"
        return
    }

    $InstallScript = Join-Path $RepoPath 'scripts\install-nerd-fonts.ps1'
    if (-not (Test-Path $InstallScript)) {
        Write-Warn "Nerd Fonts installer not found at $InstallScript — skipping"
        return
    }

    try {
        & $InstallScript
    } catch {
        Write-Warn "Nerd Fonts install failed: $_"
        Write-Warn "  Glyphs in starship / eza / lazygit / etc. will render as tofu."
        Write-Warn "  Retry manually:  & '$InstallScript'"
    }
}

# =============================================================================
# 8. SSH KEY (optional, prompt-driven)
# =============================================================================
function Invoke-EnsureSshKey {
    if ($SkipKeyGen) {
        Write-Log "SSH-key check skipped (-SkipKeyGen)"
        return
    }

    if (Test-Path "$SshKey.pub") {
        Write-Ok "SSH key already present at $SshKey"
        return
    }

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Warn "ssh-keygen unavailable — install OpenSSH client and re-run, or pass -SkipKeyGen."
        return
    }

    Write-Warn "No SSH key at $SshKey"
    $ans = Read-Host "  Generate one now? [Y/n]"
    if (-not $ans) { $ans = "Y" }
    if ($ans -notmatch '^[Yy]') {
        Write-Warn "Skipped — generate later with:  ssh-keygen -t ed25519"
        return
    }

    $sshDir = Split-Path $SshKey -Parent
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    }

    ssh-keygen -t ed25519 -f $SshKey -N '""' -C "$env:USERNAME@$env:COMPUTERNAME"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "ssh-keygen failed"
    }
    Write-Ok "Generated $SshKey"
}

# =============================================================================
# MAIN
# =============================================================================
if ($Reinstall) { Invoke-Reinstall }
Invoke-Preflight
Invoke-ToolInstall        # admin-free binary/portable installs under %LOCALAPPDATA%\workstation
Invoke-CloneRepo
Invoke-Chezmoi
Invoke-WeztermConfigEnv   # after chezmoi apply — point WezTerm at the chezmoi source
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-InstallNerdFonts   # JetBrainsMono Nerd Font Mono — per-user font install
Invoke-EnsureSshKey

Write-Host ""
Write-Host "${Bold}Bootstrap complete.${Reset}"
Write-Host ""
Write-Host "Open a NEW PowerShell tab so the updated User PATH (${Bold}$WsBin${Reset} +"
Write-Host "${Bold}$WsWezterm${Reset}) and the chezmoi-applied `$PROFILE pick up — starship"
Write-Host "prompt, chezmoi/git aliases, etc."
Write-Host "Restart WezTerm too if any instances were running — they need a fresh process"
Write-Host "to see the new ${Bold}WEZTERM_CONFIG_FILE${Reset} env var."
Write-Host ""
Write-Host "Not installed by this script (install yourself if you want them):"
Write-Host "  Zed, VSCode  — their chezmoi configs are already deployed."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Add a host to hosts.conf:"
Write-Host "       cd $RepoPath"
Write-Host "       .\scripts\manage-hosts.ps1     # interactive menu"
Write-Host "  2. Copy your SSH key to a registered host:"
Write-Host "       .\scripts\manage-hosts.ps1 -CopyId -Name <host-name>"
Write-Host "       .\scripts\manage-hosts.ps1 -CopyId -All     # or, bulk to every host"
Write-Host "  3. Launch WezTerm — it auto-opens a tab per host in hosts.conf."
Write-Host ""
Write-Host "Editing dotfiles:"
Write-Host "  cze   # chezmoi edit (opens the file in chezmoi's source)"
Write-Host "  cza   # chezmoi apply (push edits to ~)"
Write-Host "  czd   # chezmoi diff (see what would change)"
```

- [ ] **Step 2: Re-add the UTF-8 BOM** (the `Write` tool strips it; PS 5.1 needs it)

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
python3 - <<'EOF'
p = "bootstrap.ps1"
with open(p, "rb") as f:
    b = f.read()
bom = b"\xef\xbb\xbf"
if not b.startswith(bom):
    with open(p, "wb") as f:
        f.write(bom + b)
    print("BOM added")
else:
    print("BOM already present")
EOF
```
Expected: `BOM added`

- [ ] **Step 3: Verify encoding + structure (these are the "tests")**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- encoding (must say 'with BOM', must NOT say 'CRLF') ---"; file bootstrap.ps1
echo "--- no Chocolatey/admin/legacy residue (expect NO matches) ---"; grep -in -E 'choco|chocolatey|Test-IsAdmin|IsInRole|Invoke-LegacyPathMigrate|C:\\\\Git\\\\workstation|legacy' bootstrap.ps1 || echo "OK: clean"
echo "--- new pieces present (expect matches) ---"; grep -n -E 'Install-PortableTool|Install-Chezmoi|Add-ToUserPath|\$PortableTools|Invoke-ToolInstall|workstation' bootstrap.ps1 | head
echo "--- brace/paren balance ---"; python3 - <<'EOF'
s=open("bootstrap.ps1").read()
for a,b,n in [("{","}","braces"),("(",")","parens")]:
    print(n, s.count(a), s.count(b), "OK" if s.count(a)==s.count(b) else "MISMATCH")
EOF
echo "--- here-strings balanced (@\" ... \"@ count must be even-ish) ---"; grep -c '@"' bootstrap.ps1; grep -c '"@' bootstrap.ps1
```
Expected: `file` → "UTF-8 Unicode (with BOM) text" and NOT "CRLF"; the choco/legacy grep prints `OK: clean`; the new-pieces grep shows hits; braces and parens balanced; `@"` count equals `"@` count.

- [ ] **Step 4: Fill in the real sha256 pins** (from Pre-flight Step P2). If you have the hashes, replace both placeholders:

Use Edit to replace `<<PIN-ME-starship-sha256>>` with the starship.zip hash and `<<PIN-ME-wezterm-sha256>>` with the wezterm.zip hash (lowercase hex). Then re-verify no placeholders remain:
```bash
grep -n 'PIN-ME' bootstrap.ps1 && echo "STILL HAS PLACEHOLDERS" || echo "OK: pins filled"
```
Expected: `OK: pins filled` if network was available in Pre-flight; otherwise leave the placeholders and note the blocker (the script hard-fails on them at runtime, so nothing ships unverified).

- [ ] **Step 5: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add bootstrap.ps1
git commit -m "feat(windows): drop Chocolatey — binary/portable installs, Git as prerequisite

Rewrite bootstrap.ps1 to provision admin-free under %LOCALAPPDATA%\\workstation:
chezmoi via the official get.chezmoi.io installer, WezTerm + Starship via pinned
sha256-verified portable zips. Git is now a hard prerequisite (hard-fail with an
install link); Zed/VSCode soft-warn; zoxide dropped. Remove all Chocolatey, admin,
and legacy-path-migration logic."
```

---

## Task 2: Update `README.html` (user-facing surface)

**Files:**
- Modify: `README.html` (intro card ~152-157, layout note ~1270-1273, §setup-windows ~1861-1990, journal-filter placeholder ~2908, troubleshooting ~3160-3284)

CLAUDE.md rule: user-facing changes update `README.html` in the same change set. Each edit below is an exact before/after.

- [ ] **Step 1: Intro card subtitle (Windows quick-start)** — replace the elevated/choco framing.

Edit `README.html`, replace:
```html
                            <p class="qs-sub">
                                Run from an
                                <strong>elevated</strong> PowerShell. Installs
                                choco + tools, applies dotfiles, hard-links the
                                wezterm config.
                            </p>
```
with:
```html
                            <p class="qs-sub">
                                <strong>No admin needed.</strong> Install Git
                                first, then this installs chezmoi + WezTerm +
                                Starship under your user profile, applies
                                dotfiles, and points WezTerm at the repo config.
                            </p>
```

- [ ] **Step 2: Repo-layout note for bootstrap.ps1.**

Edit `README.html`, replace:
```html
                                        <span class="note"
                                            >&mdash; Windows entry point (choco
                                            + chezmoi apply, elevated)</span
                                        >
```
with:
```html
                                        <span class="note"
                                            >&mdash; Windows entry point
                                            (binary installs + chezmoi apply,
                                            no admin)</span
                                        >
```

- [ ] **Step 3: §setup-windows — the "Run from elevated PowerShell" callout.**

Edit `README.html`, replace:
```html
                    <div class="callout">
                        <strong>Run from elevated PowerShell.</strong>
                        Chocolatey needs admin to install, as do most package
                        installs. Right-click PowerShell &rarr; &ldquo;Run as
                        administrator&rdquo;. With
                        <code>-SkipToolInstall</code>, elevation is not
                        required.
                    </div>
```
with:
```html
                    <div class="callout">
                        <strong>No admin required.</strong> Everything installs
                        into your user profile (<code>%LOCALAPPDATA%\workstation</code>,
                        the User <code>PATH</code>, CurrentUser PSGallery, HKCU
                        fonts). <strong>Git is a prerequisite you install
                        yourself</strong> &mdash; the script hard-fails with an
                        install link if <code>git</code> isn&rsquo;t on PATH.
                    </div>
```

- [ ] **Step 4: §setup-windows — the "Tools installed (via Chocolatey)" paragraph.**

Edit `README.html`, replace:
```html
                    <p>
                        <strong>Tools installed (via Chocolatey):</strong>
                        chezmoi, Git, Starship, zoxide, WezTerm, Zed, VSCode.
                        Required: chezmoi, Git. Optional ones warn-not-fail.
                        Choco rather than winget because winget&rsquo;s PATH
                        propagation is unreliable mid-session.
                    </p>
```
with:
```html
                    <p>
                        <strong>What the script installs (no package manager,
                        no admin):</strong>
                    </p>
                    <ul>
                        <li>
                            <strong>chezmoi</strong> &mdash; official
                            <code>get.chezmoi.io</code> binary installer into
                            <code>%LOCALAPPDATA%\workstation\bin</code>.
                        </li>
                        <li>
                            <strong>WezTerm</strong> &mdash; pinned, sha256-verified
                            portable <code>.zip</code> into
                            <code>%LOCALAPPDATA%\workstation\wezterm</code>.
                        </li>
                        <li>
                            <strong>Starship</strong> &mdash; pinned,
                            sha256-verified portable <code>.zip</code> into
                            <code>%LOCALAPPDATA%\workstation\bin</code>.
                        </li>
                    </ul>
                    <p>
                        <strong>Git</strong> is a prerequisite you install
                        yourself (hard-fail if missing).
                        <strong>Zed</strong> and <strong>VSCode</strong> are
                        installed by hand too &mdash; the script soft-warns if
                        they&rsquo;re missing, but their chezmoi configs deploy
                        regardless. <strong>zoxide</strong> is no longer
                        installed (the PowerShell profile no-ops without it).
                        WezTerm/Starship versions are pinned in
                        <code>bootstrap.ps1</code> (<code>$PortableTools</code>),
                        the same self-contained pattern as
                        <code>install-nerd-fonts.ps1</code>.
                    </p>
```

- [ ] **Step 5: §setup-windows — the Nerd Font note's "runs elevated" clause.**

Edit `README.html`, replace:
```html
                        by <code>scripts/install-nerd-fonts.ps1</code> (invoked
                        from <code>bootstrap.ps1</code> step 8). Per-user install
                        &mdash; no admin needed for the registry registration even
                        though <code>bootstrap.ps1</code> itself runs elevated.
```
with:
```html
                        by <code>scripts/install-nerd-fonts.ps1</code> (invoked
                        from <code>bootstrap.ps1</code> step 7). Per-user install
                        &mdash; no admin needed for the registry registration
                        (nothing in <code>bootstrap.ps1</code> requires
                        elevation).
```

- [ ] **Step 6: §setup-windows — "One-liner (elevated PowerShell)" heading + body.**

Edit `README.html`, replace:
```html
                    <h4>One-liner (elevated PowerShell)</h4>
```
with:
```html
                    <h4>One-liner (no elevation needed)</h4>
```

Then edit the "Or after cloning manually" code block, replace:
```html
.\bootstrap.ps1                                  # default flow (must be elevated)
.\bootstrap.ps1 -RepoPath D:\dev\workstation     # alternate clone path
.\bootstrap.ps1 -SkipToolInstall                 # tools already installed; non-elevated OK
.\bootstrap.ps1 -SkipChezmoi                     # clone + install but don&rsquo;t deploy dotfiles
.\bootstrap.ps1 -SkipKeyGen                      # skip the SSH-key prompt</code></pre>
```
with:
```html
.\bootstrap.ps1                                  # default flow (no admin)
.\bootstrap.ps1 -RepoPath D:\dev\workstation     # alternate clone path
.\bootstrap.ps1 -SkipToolInstall                 # chezmoi/WezTerm/Starship already on PATH
.\bootstrap.ps1 -SkipChezmoi                     # clone + install but don&rsquo;t deploy dotfiles
.\bootstrap.ps1 -SkipKeyGen                      # skip the SSH-key prompt</code></pre>
```

- [ ] **Step 7: §setup-windows — the "Default clone path" note (drop legacy migration).**

Edit `README.html`, replace:
```html
                    <p class="note-row">
                        <strong>Default clone path</strong> is
                        <code>%USERPROFILE%\.local\share\chezmoi</code>, which
                        matches <code>bootstrap.sh</code>&rsquo;s
                        <code>$HOME/.local/share/chezmoi</code> and chezmoi&rsquo;s
                        own default source directory. If you previously cloned to
                        the pre-v2 default <code>C:\Git\workstation</code>,
                        <code>bootstrap.ps1</code> detects it and offers to
                        move the clone to the new location. Pass
                        <code>-RepoPath C:\Git\workstation</code> to keep the
                        legacy path, or <code>-Yes</code> to auto-move without
                        prompting.
                    </p>
```
with:
```html
                    <p class="note-row">
                        <strong>Default clone path</strong> is
                        <code>%USERPROFILE%\.local\share\chezmoi</code>, which
                        matches <code>bootstrap.sh</code>&rsquo;s
                        <code>$HOME/.local/share/chezmoi</code> and chezmoi&rsquo;s
                        own default source directory. Override it with
                        <code>-RepoPath</code> if you keep the repo elsewhere.
                    </p>
```

- [ ] **Step 8: §setup-windows — the "What bootstrap.ps1 does" flow diagram (drop admin-check; relabel choco step).**

Edit `README.html`, replace:
```html
                        <div class="step">
                            <span class="num">1</span
                            ><span class="lbl">Preflight</span
                            ><span class="note">admin check</span>
                        </div>
                        <div class="arrow">&rarr;</div>
                        <div class="step">
                            <span class="num">2</span
                            ><span class="lbl">Bootstrap Choco + tools</span>
                        </div>
```
with:
```html
                        <div class="step">
                            <span class="num">1</span
                            ><span class="lbl">Preflight</span
                            ><span class="note">require git</span>
                        </div>
                        <div class="arrow">&rarr;</div>
                        <div class="step">
                            <span class="num">2</span
                            ><span class="lbl">Install chezmoi + WezTerm + Starship</span
                            ><span class="note">binary, no admin</span>
                        </div>
```

- [ ] **Step 9: §setup-windows — the "Admin is required only if…" note.**

Edit `README.html`, replace:
```html
                    <p class="note-row">
                        Admin is required <strong>only if</strong> there are
                        required tools to install. If everything&rsquo;s on
                        PATH, no admin needed and the install step
                        short-circuits. <code>GITHUB_TOKEN</code> persists into
```
with:
```html
                    <p class="note-row">
                        <strong>No elevation anywhere in this flow.</strong>
                        Pass <code>-SkipToolInstall</code> to skip the
                        chezmoi/WezTerm/Starship installs entirely (assumes
                        they&rsquo;re already on PATH).
                        <code>GITHUB_TOKEN</code> persists into
```

- [ ] **Step 10: §setup-windows — the "WezTerm config model" note (drop legacy-cleanup sentence).**

Edit `README.html`, replace:
```html
                        the pre-v2 hardlink mechanism, which broke whenever
                        chezmoi atomic-wrote the target on a content mismatch.
                        Bootstrap also cleans up any legacy
                        <code>%USERPROFILE%\.config\wezterm\wezterm.lua</code>
                        left from prior hardlinked installs, so a stale fallback
                        can&rsquo;t silently win if you ever unset the env var.
                    </p>
```
with:
```html
                        the pre-v2 hardlink mechanism, which broke whenever
                        chezmoi atomic-wrote the target on a content mismatch.
                    </p>
```

- [ ] **Step 11: Journal-filter placeholder example (swap the `choco` sample term).**

Edit `README.html`, replace:
```html
                        placeholder="Filter entries (e.g. &lsquo;choco&rsquo;, &lsquo;PATH&rsquo;, &lsquo;wezterm&rsquo;)…"
```
with:
```html
                        placeholder="Filter entries (e.g. &lsquo;chezmoi&rsquo;, &lsquo;PATH&rsquo;, &lsquo;wezterm&rsquo;)…"
```

- [ ] **Step 12: Troubleshooting — remove the "Migrated from a pre-v2 install?" paragraph.**

Edit `README.html`, delete this block (it documents the removed legacy-hardlink cleanup):
```html
                            <p>
                                <strong>Migrated from a pre-v2 install?</strong>
                                The old layout hardlinked
                                <code
                                    >%USERPROFILE%\.config\wezterm\wezterm.lua</code
                                >
                                to the chezmoi source. The new bootstrap
                                deletes that file as a hygiene step &mdash; if
                                <code>WEZTERM_CONFIG_FILE</code> is ever
                                unset, WezTerm falls back to its default
                                search path and would find the stale legacy
                                hardlink. If you ever see WezTerm picking up
                                stale content after switching bootstraps,
                                re-run <code>bootstrap.ps1</code> to clear it.
                            </p>
```
(Replace it with an empty string — remove the whole `<p>…</p>`.)

- [ ] **Step 13: Troubleshooting — replace the four choco-specific `<details>` entries with two new ones.**

Edit `README.html`. Replace the entire run of four `<details data-ts>` blocks — starting at `<summary>` containing "Admin required to install" and ending at the `</details>` that closes the "package not found / deprecated" block (the block immediately before the `hosts.ini` entry) — with:
```html
                    <details data-ts>
                        <summary>
                            <code>bootstrap.ps1</code> aborts with
                            <em>&ldquo;Git is required but isn&rsquo;t on
                                PATH&rdquo;</em>
                        </summary>
                        <div class="ts-body">
                            <p>
                                Git is a prerequisite &mdash; the script does
                                not install it. Install Git for Windows (an
                                admin-free per-user install is offered by the
                                installer), reopen PowerShell, and re-run:
                            </p>
                            <pre><code>winget install Git.Git
# or download: https://git-scm.com/download/win</code></pre>
                        </div>
                    </details>

                    <details data-ts>
                        <summary>
                            <code>bootstrap.ps1</code> aborts with
                            <em>&ldquo;&lt;Tool&gt; sha256 mismatch &mdash;
                                refusing to install&rdquo;</em>
                        </summary>
                        <div class="ts-body">
                            <p>
                                WezTerm/Starship are pinned to a specific version
                                <em>and</em> sha256 in
                                <code>$PortableTools</code> inside
                                <code>bootstrap.ps1</code>. A mismatch means the
                                pinned hash is stale (upstream re-published the
                                asset) or the download was corrupted/tampered.
                                The script refuses to install an unverified
                                binary.
                            </p>
                            <p>
                                Fix: re-download the pinned asset, recompute its
                                hash, and update the <code>Sha256</code> field
                                for that tool (then re-run). On a trusted network
                                you can verify the upstream asset:
                            </p>
                            <pre><code>(Get-FileHash -Algorithm SHA256 .\&lt;asset&gt;.zip).Hash.ToLower()</code></pre>
                        </div>
                    </details>
```

- [ ] **Step 14: Verify the README has no Chocolatey/admin residue in the Windows surface.**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- choco residue (expect none) ---"; grep -in -E 'choco|chocolatey|\$ChocoTools' README.html || echo "OK: no choco"
echo "--- stale 'elevated/run as administrator' in Windows context (review any hits) ---"; grep -in -E 'elevated|run as admin' README.html
echo "--- legacy C:\\Git references (expect none) ---"; grep -in 'C:\\\\Git\\\\workstation' README.html || echo "OK: no legacy path"
```
Expected: `OK: no choco`, `OK: no legacy path`. The "elevated" grep may still hit unrelated mentions — review each; the Windows-setup ones should be gone.

- [ ] **Step 15: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add README.html
git commit -m "docs(readme): rewrite Windows setup for de-Chocolatey bootstrap

No-admin binary/portable install model, Git-as-prerequisite, dropped legacy
path-migration + WezTerm-hardlink-cleanup docs, and two new choco-free
troubleshooting entries (git-missing, sha256-mismatch)."
```

---

## Task 3: Update Claude-internal docs (changelog, file-care, CLAUDE.md)

**Files:**
- Modify: `CLAUDE_CHANGELOG.md` (append one row)
- Modify: `docs/claude/file-care.md` (extend the bootstrap.ps1 entry)
- Modify: `CLAUDE.md` (one new invariant line)

- [ ] **Step 1: Append a changelog row.** Add this as the LAST line of `CLAUDE_CHANGELOG.md` (the file is a single-column `|`-delimited table; match the existing 3-cell row shape: change / README-updated? / notes):

```
| Removed Chocolatey + the admin requirement from `bootstrap.ps1` (Windows client). New model: chezmoi via the official `get.chezmoi.io` binary installer → `%LOCALAPPDATA%\workstation\bin`; WezTerm + Starship via pinned, sha256-verified portable `.zip`s → `workstation\wezterm` / `workstation\bin`; all on the User PATH (new `Add-ToUserPath` + reusable `Install-PortableTool` helper modeled on `install-nerd-fonts.ps1`). Git is now a hard prerequisite (`Invoke-Preflight` hard-fails with an install link if `git` isn't on PATH — the script never installs Git). Zed + VSCode soft-warn if missing (configs still deploy); zoxide dropped (profile no-ops without it). Removed `Invoke-LegacyPathMigrate` (the `C:\Git\workstation` move), `Test-IsAdmin`, `Install-Chocolatey`, `$ChocoTools`, `Invoke-ChocoInstall`, and the WezTerm legacy-hardlink cleanup inside `Invoke-WeztermConfigEnv` (clean sweep of all legacy handling). `-SkipToolInstall` repurposed ("skip chezmoi/WezTerm/Starship auto-installs"). WezTerm pinned to `20240203-110809-5046fc22` to match the vendored terminfo. Pins live in `bootstrap.ps1`'s `$PortableTools` (version + sha256), NOT `versions.mk` — Make never runs on Windows, same precedent as `install-nerd-fonts.ps1`. | **Yes** | §setup-windows rewritten: no-admin callout, the three-tool binary/portable install list, Git-as-prerequisite, dropped the legacy-path-migration note + the "Migrated from a pre-v2 install?" troubleshooting paragraph; intro card + repo-layout note de-elevated; flow diagram relabeled (preflight "require git" + "Install chezmoi + WezTerm + Starship / binary, no admin"); the four choco troubleshooting `<details>` (admin-required, registered-with-choco, choco-not-on-PATH, package-not-found) replaced by two (git-missing, sha256-mismatch); journal-filter placeholder example swapped `choco` → `chezmoi`. CLAUDE.md gained one invariant line (Windows installs are admin-free under `%LOCALAPPDATA%\workstation`; WezTerm/Starship pins in `bootstrap.ps1`); `docs/claude/file-care.md` bootstrap.ps1 entry extended with the pinned-version tripwire. The `feedback-windows-chezmoi-check-before-apply` memory updated for the new chezmoi location + reinstall path. |
```

- [ ] **Step 2: Extend the `bootstrap.ps1` entry in `docs/claude/file-care.md`.** Find the line:
```
- **`scripts/manage-hosts.ps1` and `bootstrap.ps1`** — UTF-8 with BOM (PS 5.1 dependency). See CLAUDE.md's Conventions section for the restore one-liner.
```
and replace it with:
```
- **`scripts/manage-hosts.ps1` and `bootstrap.ps1`** — UTF-8 with BOM (PS 5.1 dependency). See CLAUDE.md's Conventions section for the restore one-liner. `bootstrap.ps1` additionally carries **pinned `Version` + `Sha256` per portable tool** in its `$PortableTools` manifest (WezTerm + Starship) — the same self-contained pin pattern as `scripts/install-nerd-fonts.ps1`, NOT `makefile/versions.mk` (Make never runs on Windows). Bumping a tool = edit `Version` and refresh `Sha256` (compute over the downloaded `.zip`); the install helper hard-fails on a `*PIN-ME*` placeholder or a hash mismatch, so a stale/un-filled pin can never silently install an unverified binary. WezTerm's pin tracks the same tag as the vendored `wezterm.terminfo`. chezmoi is the exception — installed via the official `get.chezmoi.io` binary installer (self-verifying, latest), not pinned. All three land under `%LOCALAPPDATA%\workstation` on the User PATH; the script needs no admin.
```

- [ ] **Step 3: Add a CLAUDE.md invariant line.** In `CLAUDE.md`, under the "Load-bearing invariants" bulleted list, add a new bullet immediately AFTER the existing `JETBRAINSMONO_NERD_VERSION` triple-edit bullet (keep them adjacent — both are Windows-pin tripwires). Find:
```
- **`JETBRAINSMONO_NERD_VERSION` triple-edit** — `versions.mk` ↔ `lib/font.sh` SHA case ↔ `install-nerd-fonts.ps1` (`.tar.xz` vs `.zip`, different hashes).
```
and insert after it:
```
- **Windows tool installs are admin-free binary/portable downloads under `%LOCALAPPDATA%\workstation`** (no Chocolatey). `bootstrap.ps1` installs chezmoi via the official `get.chezmoi.io` binary installer (→ `workstation\bin`) and WezTerm + Starship via pinned, sha256-verified portable `.zip`s (→ `workstation\wezterm` / `workstation\bin`), all added to the User PATH. **WezTerm/Starship pins (version + sha256) live in `bootstrap.ps1`'s `$PortableTools`, NOT `versions.mk`** (Make never runs on Windows — same precedent as `install-nerd-fonts.ps1`); WezTerm's pin tracks the vendored-terminfo tag. **Git is a hard prerequisite** the user installs (preflight hard-fails if absent); Zed/VSCode soft-warn; zoxide is not installed. No elevation anywhere.
```

- [ ] **Step 4: Verify the doc edits land and reference real things.**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "--- changelog row present ---"; tail -1 CLAUDE_CHANGELOG.md | grep -q 'Removed Chocolatey' && echo OK || echo MISSING
echo "--- file-care pin tripwire ---"; grep -q 'PortableTools' docs/claude/file-care.md && echo OK || echo MISSING
echo "--- CLAUDE.md invariant ---"; grep -q 'admin-free binary/portable downloads under' CLAUDE.md && echo OK || echo MISSING
```
Expected: three `OK`s.

- [ ] **Step 5: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add CLAUDE_CHANGELOG.md docs/claude/file-care.md CLAUDE.md
git commit -m "docs(claude): record Windows de-Chocolatey bootstrap (changelog, file-care pin tripwire, invariant)"
```

---

## Task 4: Update the stale Windows-chezmoi memory

**Files:**
- Modify: `.claude/memory/feedback-windows-chezmoi-check-before-apply.md`
- Modify (if its hook text mentions choco): `.claude/memory/MEMORY.md`

The memory references the old chezmoi location (`C:\ProgramData\chocoportable\bin\chezmoi.exe`) and `choco install -y chezmoi` — both stale after this change.

- [ ] **Step 1: Update the existence-check path.** In `.claude/memory/feedback-windows-chezmoi-check-before-apply.md`, replace:
```
ALWAYS first check whether the native Windows `chezmoi` binary exists — via WSL interop, e.g. `powershell.exe -NoProfile -Command 'Test-Path "C:\ProgramData\chocoportable\bin\chezmoi.exe"'` or `Get-Command chezmoi`. Then branch:
```
with:
```
ALWAYS first check whether the native Windows `chezmoi` binary exists — via WSL interop, e.g. `powershell.exe -NoProfile -Command 'Get-Command chezmoi'` (or `Test-Path "$env:LOCALAPPDATA\workstation\bin\chezmoi.exe"`, the location `bootstrap.ps1` installs it to). Then branch:
```

- [ ] **Step 2: Update the reinstall hint.** In the same file, replace:
```
- **chezmoi.exe missing** → I deploy the change MANUALLY: hand-produce the Windows-correct content for each affected target (applying the OS-gated logic myself) and copy it into `%USERPROFILE%` via interop. Then flag that the Windows chezmoi needs reinstalling (`choco install -y chezmoi`, per `bootstrap.ps1`). Do NOT point the WSL chezmoi at the Windows state as a shortcut.
```
with:
```
- **chezmoi.exe missing** → I deploy the change MANUALLY: hand-produce the Windows-correct content for each affected target (applying the OS-gated logic myself) and copy it into `%USERPROFILE%` via interop. Then flag that the Windows chezmoi needs reinstalling — re-run `bootstrap.ps1` (it reinstalls chezmoi admin-free via the official `get.chezmoi.io` binary installer into `%LOCALAPPDATA%\workstation\bin`). Do NOT point the WSL chezmoi at the Windows state as a shortcut.
```

- [ ] **Step 3: Update the "Why" reason #1 (EDR-quarantine path reference).** In the same file, replace:
```
1. The Windows `chezmoi.exe` is unreliable on this corporate device — it vanished mid-session once (gone from `C:\ProgramData\chocoportable\bin\`, not a registered choco package), most likely an EDR/AV quarantine. So its presence must be verified, not assumed.
```
with:
```
1. The Windows `chezmoi.exe` is unreliable on this corporate device — it vanished mid-session once (most likely an EDR/AV quarantine), so its presence must be verified, not assumed. (Historically it lived under choco's `chocoportable\bin\`; `bootstrap.ps1` now installs it admin-free to `%LOCALAPPDATA%\workstation\bin`.)
```

- [ ] **Step 4: Check the MEMORY.md index pointer.** Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
grep -n -i 'chezmoi-check\|choco' .claude/memory/MEMORY.md
```
If the pointer line for this memory mentions choco, edit it to drop the word (keep the hook accurate). If it doesn't mention choco, no change.

- [ ] **Step 5: Verify no stale choco path remains in the memory.**

Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
grep -in -E 'chocoportable|choco install' .claude/memory/feedback-windows-chezmoi-check-before-apply.md && echo "STILL STALE" || echo "OK: memory updated"
```
Expected: `OK: memory updated`.

- [ ] **Step 6: Commit**

```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add .claude/memory/
git commit -m "docs(memory): update Windows-chezmoi memory for de-Chocolatey install path"
```

---

## Task 5: Whole-repo residue sweep + Windows manual-test checklist

**Files:** none (verification only) — plus stage the spec/plan if not already committed.

- [ ] **Step 1: Full-tree residue sweep.** Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
echo "=== choco/chocolatey across tracked files (specs/plans/changelog mentions OK) ==="
grep -rin --exclude-dir=.git -E 'choco|chocolatey' . | grep -vE 'docs/superpowers/(specs|plans)/|CLAUDE_CHANGELOG.md'
echo "=== Invoke-LegacyPathMigrate / Test-IsAdmin / Install-Chocolatey (expect none) ==="
grep -rin --exclude-dir=.git -E 'Invoke-LegacyPathMigrate|Test-IsAdmin|Install-Chocolatey|\$ChocoTools' . | grep -vE 'docs/superpowers/(specs|plans)/'
```
Expected: no hits outside the spec/plan/changelog (those legitimately narrate the removal).

- [ ] **Step 2: Final encoding re-check on bootstrap.ps1** (guards against an Edit in Task 1 Step 4 dropping the BOM). Run:
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
file bootstrap.ps1
git ls-files --error-unmatch bootstrap.ps1 >/dev/null 2>&1 && git diff --stat HEAD~4 -- bootstrap.ps1 2>/dev/null | tail -1
```
Expected: "UTF-8 Unicode (with BOM) text", NOT "CRLF".

- [ ] **Step 3: Commit the spec + plan** (if not already tracked):
```bash
cd /home/arrush.chaturvedi/.local/share/chezmoi
git add docs/superpowers/specs/2026-06-05-windows-bootstrap-dechocolatey-design.md docs/superpowers/plans/2026-06-05-windows-bootstrap-dechocolatey.md
git commit -m "docs(superpowers): archive Windows de-Chocolatey bootstrap spec + plan" || echo "already committed"
```

- [ ] **Step 4: Hand the Windows host a manual-test checklist.** `pwsh` isn't available on the Linux authoring host, so functional verification happens on the Windows machine. Surface this checklist to the user (don't run it here):

  1. **Syntax parse:** `powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('bootstrap.ps1', [ref]$null, [ref]$null); 'parsed ok'"` → prints `parsed ok` (catches PS syntax errors the Linux greps can't).
  2. **Fresh-ish run (no admin):** open a NON-elevated PowerShell, set `GITHUB_TOKEN`/`GIT_USER_NAME`/`GIT_USER_EMAIL`, run `.\bootstrap.ps1`. Expect: git found; chezmoi installed to `%LOCALAPPDATA%\workstation\bin`; WezTerm to `workstation\wezterm`; Starship to `workstation\bin`; both dirs added to User PATH; Zed/VSCode soft-warn if absent; no admin prompt.
  3. **Git-missing hard-fail:** temporarily rename git off PATH (or test on a host without it) → the script aborts with the "Git is required" message and the install link.
  4. **Idempotent re-run:** run again → chezmoi "already installed", WezTerm/Starship "already installed" (stamp hit), PATH not duplicated.
  5. **PATH/resolution in a NEW shell:** open a fresh tab → `chezmoi --version`, `starship --version`, `wezterm --version` all resolve; the Starship prompt renders; `z` is gone (zoxide not installed) but the profile loads without error.
  6. **WezTerm config:** `echo $env:WEZTERM_CONFIG_FILE` points at the chezmoi source; WezTerm launches with the repo config.

---

## Self-Review

**Spec coverage** (each spec section → task):
- Install model (Git hard-fail, chezmoi official installer, WezTerm/Starship pinned portable, zoxide dropped, Zed/VSCode soft-warn, aux steps kept) → Task 1 (`Invoke-Preflight`, `Install-Chezmoi`, `$PortableTools`/`Install-PortableTool`, `Invoke-ToolInstall`; BurntToast/NerdFonts/SshKey kept verbatim). ✅
- Admin/elevation removed (`Test-IsAdmin`, admin gate) → Task 1 (functions absent; verified by grep in Step 3). ✅
- Remove all legacy (`Invoke-LegacyPathMigrate` + WezTerm hardlink cleanup) → Task 1 (absent) + Task 2 (docs) + grep sweep Task 5. ✅
- `Install-PortableTool` design (stamp gate, sha256 hard-fail, single/tree layout, PATH) → Task 1, function included verbatim. ✅
- Version pinning in `bootstrap.ps1` → Task 1 `$PortableTools` + Pre-flight pin sourcing + Task 3 file-care/CLAUDE.md. ✅
- `-SkipToolInstall` repurposed → Task 1 (`Invoke-ToolInstall` + preflight guard) + README Step 6/9. ✅
- `Invoke-Reinstall` choco-uninstall text → Task 1 (updated to `Remove-Item …\workstation`). ✅
- Files to touch: bootstrap.ps1 (T1), README.html (T2), CLAUDE_CHANGELOG.md + file-care.md + CLAUDE.md (T3), memory (T4). ✅
- Risks: BOM (T1 S2-3, T5 S2), sha256 sourcing (Pre-flight), WezTerm asset/folder naming (Pre-flight S2 + `tree` flatten in `Install-PortableTool`), PATH propagation (`Add-ToUserPath` + closing message), `get.chezmoi.io -BinDir` (Task 1 `Install-Chezmoi` + Windows checklist S1), Zed soft-warn (Task 1). ✅

**Placeholder scan:** the only `<<PIN-ME-...>>` tokens are deliberate, sourced in the Pre-flight section and filled in Task 1 Step 4; `Install-PortableTool` hard-fails on them so nothing ships unverified. No "TBD/TODO/handle edge cases" prose. ✅

**Type/name consistency:** `$WsRoot`/`$WsBin`/`$WsWezterm`/`$WsStamps`, `$PortableTools` (fields `Name`/`Exe`/`Version`/`Url`/`Sha256`/`Layout`/`Dest`), `Install-PortableTool`/`Install-Chezmoi`/`Add-ToUserPath`/`Invoke-ToolInstall`/`Update-SessionPath` are spelled identically everywhere they appear (manifest, helpers, MAIN, docs). MAIN calls match defined function names. ✅
