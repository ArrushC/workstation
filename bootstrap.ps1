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
#   - Helix     — pinned portable .zip (sha256-verified)    → workstation\helix
#                 (hx.exe + bundled runtime/; no HELIX_RUNTIME env var needed)
#   - SSHFS-Win — BEST-EFFORT ELEVATED (the ONE exception to no-admin): mounts
#                 remote Unix filesystems over SSH (\\sshfs\user@host). Depends
#                 on the WinFsp kernel driver -> machine-scope MSIs -> UAC
#                 prompt. winget first, digest/pin-verified MSI fallback when
#                 winget is absent, soft-fail everywhere. Skip: -SkipElevated.
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
#   2. tool install — chezmoi (official installer) + WezTerm/Starship/Helix (pinned
#                     portable downloads), all into %LOCALAPPDATA%\workstation;
#                     then the installer-class apps (Obsidian, Zed) and the
#                     best-effort elevated class (SSHFS-Win — may pop UAC).
#   3. clone repo   — into -RepoPath (default %USERPROFILE%\.local\share\chezmoi,
#                     matching bootstrap.sh's $HOME/.local/share/chezmoi and
#                     chezmoi's own default source dir).
#   4. chezmoi apply— applies chezmoi/ to %USERPROFILE% (PowerShell profile,
#                     Zed/VSCode settings, etc.). wezterm.lua is ignored on
#                     Windows; WezTerm reads it via the env var in step 5.
#   5. wezterm env  — set User-scope WEZTERM_CONFIG_FILE at the chezmoi source.
#   5b. profile shim— if Documents is redirected (OneDrive), drop a loader at the
#                     real $PROFILE that sources the chezmoi canonical profile.
#   5c. wezterm lnk — drop a per-user Start Menu shortcut for the portable WezTerm
#                     (the .zip ships none); idempotent + duplicate-proof.
#   6. burnt toast  — PSGallery module (CurrentUser) for Claude Code WSL2 toasts.
#   7. nerd fonts   — JetBrainsMono Nerd Font Mono (per-user, HKCU).
#   8. ssh key      — generate %USERPROFILE%\.ssh\id_ed25519 if missing.
#
# NO ADMIN REQUIRED: every step writes to per-user locations (workstation\ on
# the User PATH, CurrentUser PSGallery, HKCU fonts, ~/.ssh) — with ONE
# sanctioned, best-effort exception: $ElevatedTools (SSHFS-Win + its WinFsp
# kernel-driver dependency) pops UAC when not yet installed. Declining the
# prompt (or -SkipElevated, or no winget + no network) soft-fails that step
# only; everything else still completes with zero elevation.
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
#   -SkipToolInstall    skip the chezmoi/WezTerm/Starship/Helix auto-installs
#                       (assume they're already on PATH)
#   -SkipChezmoi        clone + install tools but don't apply dotfiles yet
#   -SkipBurntToast     skip the BurntToast PSGallery module install
#   -SkipNerdFonts      skip the Nerd Font install
#   -ForceInstaller     re-run installer-layout tool installs (e.g. Obsidian) even
#                       if already present. Portable tools (WezTerm/Starship/Helix)
#                       are unaffected — they reinstall on a version-pin bump.
#   -SkipElevated       skip the best-effort ELEVATED installs ($ElevatedTools:
#                       SSHFS-Win + WinFsp). Everything else stays admin-free;
#                       this is the only step that can pop a UAC prompt.
#   -Reinstall          wipe the cloned repo + chezmoi config first, then run the
#                       normal flow. Does NOT remove installed tools or deployed
#                       dotfiles — the bootstrap is idempotent over those.
#                       Prompts unless -Yes is also passed.
#   -Yes                skip confirmation prompts (Reinstall).
#   -Doctor             read-only health report, then exit (installs nothing):
#                       prereqs, repo git state (branch, ahead/behind, dirty),
#                       chezmoi init + drift, portable/installer tools, fonts,
#                       BurntToast, WEZTERM_CONFIG_FILE, Start-menu shortcut,
#                       profile shim, SSH key.
#   -CheckForUpdates    read-only update scan, then exit: the workstation repo
#                       first (fetch + commits-behind), then every pinned tool
#                       against its upstream release tags via git ls-remote
#                       (no GitHub API, no rate limits). Report-only — a pin
#                       bump is still the manual $PortableTools edit.
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoPath = (Join-Path $env:USERPROFILE ".local\share\chezmoi"),
    [switch]$SkipKeyGen,
    [switch]$SkipToolInstall,
    [switch]$SkipChezmoi,
    [switch]$SkipBurntToast,
    [switch]$SkipNerdFonts,
    [switch]$ForceInstaller,
    [switch]$SkipElevated,
    [switch]$Reinstall,
    [switch]$Yes,
    [switch]$Doctor,
    [switch]$CheckForUpdates
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
function Write-Bad    { param($msg) Write-Host "${Red} ✗${Reset} $msg" }  # Write-Fail minus the exit — -Doctor reports, never aborts

function Test-AgeIdentity {
    if (-not $env:WORKSTATION_AGE_RECIPIENT) { return }
    Write-Log "age encryption: recipient configured ($env:WORKSTATION_AGE_RECIPIENT)"
    $key = Join-Path $HOME ".config/chezmoi/key.txt"
    $haveAge = [bool](Get-Command age -ErrorAction SilentlyContinue)
    if ((Test-Path $key) -and $haveAge) {
        Write-Ok "age identity present ($key)"
    } else {
        if (-not (Test-Path $key)) { Write-Warn "age identity missing: $key" }
        if (-not $haveAge) { Write-Warn "age not on PATH - install it to use encrypted dotfiles on Windows (not bundled by this repo)" }
        Write-Warn "  encrypted dotfiles won't decrypt until both are present. Create a key: New-Item -ItemType Directory -Force (Split-Path `"$key`") | Out-Null; age-keygen -o `"$key`""
        Write-Warn "  or copy key.txt from another host / your password store."
    }
}

$DotfilesRepo = "https://github.com/ArrushC/workstation.git"
$SshKey       = "$env:USERPROFILE\.ssh\id_ed25519"

# Token persisted into .git/config under this key — scoped to github.com so
# it never leaks to other remotes.
$GhHeaderKey = "http.https://github.com/.extraheader"

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

# Pinned portable tools. version + sha256 live HERE (same self-contained pattern
# as scripts\install-nerd-fonts.ps1) — NOT makefile/versions.mk, because Make
# never runs on Windows. Bump = update Version + refresh Sha256 (compute over the
# downloaded .zip). Layout 'single' copies <Exe>.exe into Dest; 'tree' extracts
# the whole archive into Dest. WezTerm is pinned to the same tag as the vendored
# terminfo (see CLAUDE.md's wezterm-terminfo invariant).
#
# The Repo/Tag* keys feed -CheckForUpdates only (latest upstream tag via
# `git ls-remote`): TagPrefix is what precedes the version in the tag,
# TagFilter accepts version shapes after the prefix is stripped, TagSort
# 'string' is for WezTerm's date-style tags ([version] can't parse them),
# and UpdateHint is appended to the "update available" line.
$PortableTools = @(
    @{
        Name       = "Starship"
        Exe        = "starship"
        Version    = "1.25.1"
        Url        = "https://github.com/starship/starship/releases/download/v1.25.1/starship-x86_64-pc-windows-msvc.zip"
        Sha256     = "a07cf3e428afab09324e510fb786041ebcc491a68b1ca6fba044c5a461f9b017"
        Layout     = "single"
        Dest       = $WsBin
        Repo       = "starship/starship"
        TagPrefix  = "v"
        UpdateHint = "bump Version + refresh Sha256 in `$PortableTools"
    },
    @{
        Name       = "WezTerm"
        Exe        = "wezterm"
        Version    = "20240203-110809-5046fc22"
        Url        = "https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/WezTerm-windows-20240203-110809-5046fc22.zip"
        Sha256     = "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"
        Layout     = "tree"
        Dest       = $WsWezterm
        Repo       = "wez/wezterm"
        TagPrefix  = ""
        TagFilter  = '^\d{8}-\d{6}-[0-9a-f]+$'   # date-stamped release tags; excludes 'nightly'
        TagSort    = "string"
        UpdateHint = "pin tracks the vendored wezterm.terminfo tag — bump both together (see CLAUDE.md)"
    },
    @{
        Name       = "Helix"
        Exe        = "hx"
        Version    = "25.07.1"
        Url        = "https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip"
        Sha256     = "5c8325ced8bacd8418d62706f669e96d9c3578a9237526e34d546900cbc049b6"
        Layout     = "tree"
        Dest       = $WsHelix
        Repo       = "helix-editor/helix"
        TagPrefix  = ""
        UpdateHint = "dual-edit: `$PortableTools here AND HELIX_VERSION in makefile/versions.mk"
    },
    @{
        # Nushell — the default LOCAL Windows shell (wezterm.lua default_prog +
        # the Windows Terminal "Nushell" profile both point at this install).
        # Pre-1.0 and churny: bump deliberately and upgrade INCREMENTALLY (the
        # pin/stamp model here is exactly the "pin it, read the changelog" hygiene
        # Nushell's 0.x cadence needs). Tags are bare "0.113.1" (no prefix).
        Name       = "Nushell"
        Exe        = "nu"
        Version    = "0.113.1"
        Url        = "https://github.com/nushell/nushell/releases/download/0.113.1/nu-0.113.1-x86_64-pc-windows-msvc.zip"
        Sha256     = "fd3e56dac9f866d2d3fe2fabd6580c14371afdcec9ddda54624a50986d36b3d2"
        Layout     = "tree"   # zip bundles nu.exe + nu_plugin_*.exe
        Dest       = $WsNu
        Repo       = "nushell/nushell"
        TagPrefix  = ""
        UpdateHint = "bump Version + refresh Sha256 in `$PortableTools — pre-1.0: READ the release's Breaking-changes section and upgrade incrementally (skipping releases can break config.nu)"
    },
    @{
        Name       = "jq"
        Exe        = "jq"
        Version    = "1.8.2"
        Url        = "https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe"
        Sha256     = "a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627"
        Layout     = "exe"
        Dest       = $WsBin
        Repo       = "jqlang/jq"
        TagPrefix  = "jq-"
        UpdateHint = "dual-edit: `$PortableTools here AND JQ_VERSION in makefile/versions.mk (jq powers the Claude Code hooks' JSON parsing on Windows)"
    }
)

# Installer-layout tools — apps that publish a silent, admin-free installer (.exe)
# instead of a portable zip. Unlike $PortableTools these are NOT version-pinned:
# we resolve the LATEST GitHub release at run time (the app self-updates after),
# verify the download against the GitHub API's per-asset sha256 'digest', run the
# installer silently PER-USER (no admin), and add NOTHING to PATH (GUI apps create
# their own Start-menu shortcut). Presence is detected via the Uninstall registry
# (DisplayName), so a manual uninstall makes the next bootstrap reinstall. Force a
# reinstall with -ForceInstaller.
$InstallerTools = @(
    @{
        Name       = "Obsidian"
        Repo       = "obsidianmd/obsidian-releases"  # GitHub owner/repo for LATEST
        AssetMatch = "Obsidian-*.exe"                # selects the Windows installer asset
        SilentArgs = "/S"                            # NSIS per-user silent (NO /allusers -> no admin)
        DetectName = "Obsidian*"                      # HKCU/HKLM Uninstall DisplayName glob
    },
    @{
        Name       = "Zed"
        Repo       = "zed-industries/zed"             # GitHub owner/repo for LATEST (stable; /releases/latest skips -pre)
        AssetMatch = "Zed-x86_64.exe"                 # x64 Windows installer asset (NOT Zed-aarch64.exe)
        SilentArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"  # Inno Setup silent; PrivilegesRequired=lowest -> per-user, no admin (NOT NSIS /S)
        DetectName = "Zed"                            # exact HKCU Uninstall DisplayName (avoids "Zed Preview"/"Zed Nightly")
    }
)

# Elevated tools — the ONE sanctioned exception to the no-admin rule. SSHFS-Win
# mounts remote Unix filesystems over SSH (\\sshfs\user@host UNC paths / net use
# drive letters); it depends on WinFsp, a kernel-mode filesystem driver, so both
# MSIs are machine-scope and a UAC prompt is unavoidable. Install is BEST-EFFORT:
# Uninstall-registry detect first (an already-provisioned machine never sees
# UAC), then winget (its manifest pulls WinFsp.WinFsp as a dependency), then a
# digest/pin-verified direct-MSI fallback when winget is ABSENT. EVERY failure
# mode (declined UAC, offline, hash mismatch) warns and continues — this class
# never aborts the bootstrap. -SkipElevated skips it; -ForceInstaller reinstalls
# (and adds --force on the winget path). NOT pinned in versions.mk — latest-
# release model, same as $InstallerTools (winget installs latest anyway).
$ElevatedTools = @(
    @{
        Name       = "SSHFS-Win"
        WingetId   = "SSHFS-Win.SSHFS-Win"   # manifest declares WinFsp.WinFsp as a dependency
        DetectName = "SSHFS-Win*"            # HKLM Uninstall DisplayName glob (machine-scope MSI)
        Repo       = "winfsp/sshfs-win"      # for -CheckForUpdates tag lookups
        # MSI fallback chain (winget absent) — installed IN ORDER; each entry is
        # skipped when its own DetectName is already registered:
        Msi        = @(
            @{
                Name       = "WinFsp"
                WingetId   = "WinFsp.WinFsp"
                Repo       = "winfsp/winfsp"
                AssetMatch = "winfsp-*.msi"
                DetectName = "WinFsp*"
            },
            @{
                Name       = "SSHFS-Win"
                WingetId   = "SSHFS-Win.SSHFS-Win"
                Repo       = "winfsp/sshfs-win"
                AssetMatch = "sshfs-win-*-x64.msi"
                DetectName = "SSHFS-Win*"
                # v3.5.20357 (2020) predates GitHub's per-asset digests (the API
                # reports digest: null); official x64 sha256 from the winget
                # manifest (microsoft/winget-pkgs manifests/s/SSHFS-Win) instead:
                Sha256Pin  = "1657e397f8dce1c2d2e3220007f9c9f882631882b9bec4608f7835e87dcd096c"
            }
        )
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
    Write-Host "    Remove-Item -Recurse -Force '$WsRoot'   # chezmoi/starship/wezterm/helix re-download next run"
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
#    workstation. chezmoi via its official installer; WezTerm + Starship + Helix via
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
        if ($Tool.Layout -eq "exe") {
            # Bare single-binary release (jq ships jq-windows-amd64.exe, not a
            # .zip) — the sha256-verified download IS the binary; place it under
            # Dest as <Exe>.exe, no Expand-Archive. ($tmpZip holds the raw .exe.)
            if (-not (Test-Path $Tool.Dest)) { New-Item -ItemType Directory -Force -Path $Tool.Dest | Out-Null }
            Copy-Item $tmpZip -Destination (Join-Path $Tool.Dest "$($Tool.Exe).exe") -Force
            Add-ToUserPath $Tool.Dest
            if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
            New-Item -ItemType File -Force -Path $stamp | Out-Null
            Write-Ok "$($Tool.Name) $($Tool.Version) installed to $($Tool.Dest)"
            return
        }
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
            # NOTE: if the tool is running from $Dest its files are locked — this wipe then throws and the outer try/catch warn-not-fails. Close the app (WezTerm/Helix) before re-running to refresh it.
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

# True if an app with a matching Uninstall-registry DisplayName is installed —
# per-user (HKCU) or machine-wide (HKLM / WOW6432Node). Path-independent presence
# check; a Control-Panel uninstall removes the key, so the next bootstrap reinstalls.
function Test-InstallerPresent {
    param([string]$DisplayName)
    $roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $roots) {
        $hit = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
               Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $DisplayName }
        if ($hit) { return $true }
    }
    return $false
}

# Install a silent, admin-free .exe installer at its LATEST GitHub release. NOT
# version-pinned (app self-updates after); verified against the API 'digest'.
function Install-InstallerTool {
    param([hashtable]$Tool)

    # Idempotency: skip if already installed, unless -ForceInstaller. Detection is by
    # Uninstall-registry DisplayName (not a version stamp) — these are LATEST/
    # self-updating, so there is no version to stamp.
    if ((-not $ForceInstaller) -and (Test-InstallerPresent -DisplayName $Tool.DetectName)) {
        Write-Ok "$($Tool.Name) already installed (use -ForceInstaller to reinstall)"
        return
    }

    Write-Log "Installing $($Tool.Name) (latest, installer)..."

    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    # Resolve the latest release. $env:GITHUB_TOKEN (already used for the private-repo
    # clone) lifts the 60-req/hr anonymous API rate limit. A User-Agent is required
    # by the GitHub API.
    $headers = @{ "User-Agent" = "workstation-bootstrap" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }

    try {
        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($Tool.Repo)/releases/latest" `
            -Headers $headers -UseBasicParsing
    } catch {
        Write-Warn "$($Tool.Name): GitHub API lookup failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }

    $assets = @($release.assets | Where-Object { $_.name -like $Tool.AssetMatch })
    if ($assets.Count -eq 0) {
        Write-Warn "$($Tool.Name): no asset matching '$($Tool.AssetMatch)' in $($release.tag_name) — skipping"
        return
    }
    if ($assets.Count -gt 1) {
        Write-Warn "$($Tool.Name): $($assets.Count) assets match '$($Tool.AssetMatch)' — using $($assets[0].name)"
    }
    $asset  = $assets[0]
    $tmpExe = Join-Path $env:TEMP "ws-$($Tool.Name)-installer.exe"

    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpExe -UseBasicParsing
    } catch {
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
        Write-Warn "$($Tool.Name) download failed: $($_.Exception.Message)"
        Write-Warn "  Skipping — install it manually or re-run later."
        return
    }

    try {
        # Verify against the API-reported sha256 digest. Mismatch is a HARD fail
        # (corruption/tamper); a missing digest warns but proceeds (HTTPS + GitHub).
        # NOTE: Write-Fail calls exit 1; remove the temp file BEFORE it so cleanup
        # is guaranteed regardless of whether finally runs on exit — mirrors
        # Install-PortableTool. Under Set-StrictMode -Version Latest an absent
        # 'digest' property THROWS on access, so probe it via PSObject.Properties
        # (not $asset.digest directly) to keep the warn-and-proceed path working.
        $digest = if ($asset.PSObject.Properties['digest']) { $asset.digest } else { $null }
        if ($digest -and $digest.StartsWith("sha256:")) {
            $expected = $digest.Substring(7).ToLower()
            $actual   = (Get-FileHash -Algorithm SHA256 -Path $tmpExe).Hash.ToLower()
            if ($actual -ne $expected) {
                Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
                Write-Fail @"
$($Tool.Name) sha256 mismatch — refusing to install.
  expected: $expected
  actual:   $actual
The GitHub-reported digest doesn't match the download (corrupted or tampered).
"@
            }
        } else {
            Write-Warn "$($Tool.Name): GitHub published no sha256 digest for $($asset.name) — skipping hash verification."
        }

        # Silent, per-user install. No Add-ToUserPath — GUI apps make their own
        # Start-menu shortcut and self-update from here.
        $proc = Start-Process -FilePath $tmpExe -ArgumentList $Tool.SilentArgs -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            Write-Warn "$($Tool.Name) installer exited with code $($proc.ExitCode) — verify it installed."
        } else {
            Write-Ok "$($Tool.Name) installed ($($release.tag_name))"
        }
    } finally {
        Remove-Item $tmpExe -Force -ErrorAction SilentlyContinue
    }
}

# One MSI of an elevated tool's fallback chain: resolve the LATEST GitHub
# release, download, verify (API digest -> Sha256Pin -> warn+proceed), install
# via msiexec -Verb RunAs. A silent machine-scope msiexec from a non-elevated
# shell does NOT trigger UAC — it fails with MSI error 1925; -Verb RunAs is
# what pops the prompt, and a DECLINED prompt THROWS (caught into a soft-fail).
# A hash mismatch refuses this MSI (Write-Bad, never Write-Fail — this class
# must not abort the bootstrap; refusing to run an elevated binary is the safe
# side). Returns $true when the MSI is (already) installed, $false otherwise.
function Install-ElevatedMsi {
    param([hashtable]$Msi)

    if (Test-InstallerPresent -DisplayName $Msi.DetectName) {
        Write-Ok "$($Msi.Name) already installed"
        return $true
    }

    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

    $headers = @{ "User-Agent" = "workstation-bootstrap" }
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }

    try {
        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($Msi.Repo)/releases/latest" `
            -Headers $headers -UseBasicParsing
    } catch {
        Write-Warn "$($Msi.Name): GitHub API lookup failed: $($_.Exception.Message)"
        return $false
    }

    $assets = @($release.assets | Where-Object { $_.name -like $Msi.AssetMatch })
    if ($assets.Count -eq 0) {
        Write-Warn "$($Msi.Name): no asset matching '$($Msi.AssetMatch)' in $($release.tag_name)"
        return $false
    }
    if ($assets.Count -gt 1) {
        Write-Warn "$($Msi.Name): $($assets.Count) assets match '$($Msi.AssetMatch)' — using $($assets[0].name)"
    }
    $asset  = $assets[0]
    $tmpMsi = Join-Path $env:TEMP "ws-$($Msi.Name).msi"

    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpMsi -UseBasicParsing
    } catch {
        Remove-Item $tmpMsi -Force -ErrorAction SilentlyContinue
        Write-Warn "$($Msi.Name) download failed: $($_.Exception.Message)"
        return $false
    }

    try {
        # Verify: GitHub API digest -> Sha256Pin fallback -> warn+proceed (same
        # escalation as Install-InstallerTool; the pin covers digest-less
        # pre-2025 releases like sshfs-win v3.5.20357). Probe 'digest' via
        # PSObject.Properties — StrictMode throws on bare access when absent.
        $digest   = if ($asset.PSObject.Properties['digest']) { $asset.digest } else { $null }
        $expected = $null
        if ($digest -and $digest.StartsWith("sha256:")) {
            $expected = $digest.Substring(7).ToLower()
        } elseif ($Msi.ContainsKey('Sha256Pin')) {
            $expected = $Msi.Sha256Pin.ToLower()
        }
        if ($expected) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $tmpMsi).Hash.ToLower()
            if ($actual -ne $expected) {
                Write-Bad "$($Msi.Name) sha256 mismatch — refusing to install (corrupted or tampered download)."
                Write-Bad "  expected: $expected"
                Write-Bad "  actual:   $actual"
                return $false
            }
        } else {
            Write-Warn "$($Msi.Name): no sha256 available for $($asset.name) — skipping hash verification."
        }

        try {
            $proc = Start-Process msiexec -ArgumentList "/i `"$tmpMsi`" /qn /norestart" `
                -Verb RunAs -Wait -PassThru
        } catch {
            Write-Warn "$($Msi.Name): elevation declined or unavailable ($($_.Exception.Message))"
            return $false
        }
        if ($proc.ExitCode -eq 3010) {
            Write-Ok "$($Msi.Name) installed ($($release.tag_name)) — reboot may be required"
            return $true
        }
        if ($proc.ExitCode -ne 0) {
            Write-Warn "$($Msi.Name): msiexec exited with code $($proc.ExitCode) — verify it installed"
            return $false
        }
        Write-Ok "$($Msi.Name) installed ($($release.tag_name))"
        return $true
    } finally {
        Remove-Item $tmpMsi -Force -ErrorAction SilentlyContinue
    }
}

# Install an elevated (machine-scope) tool — the ONE exception to the no-admin
# rule; see $ElevatedTools. BEST-EFFORT: every failure path warns and returns.
# Chain: Uninstall-registry detect (no UAC when present) -> winget (manifest
# dependencies pull WinFsp; UAC pops) -> direct-MSI fallback ONLY when winget
# is ABSENT (a winget FAILURE is deliberately not retried via MSI — the cause,
# a declined UAC or no network, would recur and just pop a second prompt) ->
# manual instructions.
function Install-ElevatedTool {
    param([hashtable]$Tool)

    # Idempotency first — an already-provisioned machine must never see UAC.
    if ((-not $ForceInstaller) -and (Test-InstallerPresent -DisplayName $Tool.DetectName)) {
        Write-Ok "$($Tool.Name) already installed (use -ForceInstaller to reinstall)"
        return
    }

    Write-Log "Installing $($Tool.Name) (machine-scope)..."
    Write-Warn "$($Tool.Name) needs a machine-wide install (WinFsp kernel driver) — the ONE elevated step; expect a UAC prompt (skip with -SkipElevated)"

    $manualHint = "install manually later:  winget install $($Tool.WingetId)"

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $wingetArgs = @(
            "install", "--id", $Tool.WingetId, "--exact",
            "--accept-source-agreements", "--accept-package-agreements"
        )
        if ($ForceInstaller) { $wingetArgs += "--force" }
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & winget @wingetArgs
        $code = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
        if ($code -eq 0) {
            Write-Ok "$($Tool.Name) installed (winget $($Tool.WingetId))"
        } else {
            Write-Warn "$($Tool.Name): winget exited with code $code (declined UAC? offline?) — skipping; $manualHint"
        }
        return
    }

    Write-Warn "winget not found — falling back to direct MSI downloads"
    foreach ($msi in $Tool.Msi) {
        if (-not (Install-ElevatedMsi -Msi $msi)) {
            Write-Warn "$($Tool.Name): MSI chain stopped at $($msi.Name) — $manualHint"
            return
        }
    }
    Write-Ok "$($Tool.Name) installed (MSI fallback)"
}

function Invoke-ToolInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix on PATH; Obsidian/Zed/SSHFS-Win not installed"
        return
    }

    foreach ($d in @($WsRoot, $WsBin, $WsHelix, $WsNu, $WsStamps)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    Install-Chezmoi
    foreach ($tool in $PortableTools) { Install-PortableTool -Tool $tool }
    foreach ($tool in $InstallerTools) { Install-InstallerTool -Tool $tool }

    # Elevated class last, so a declined UAC can't interrupt the admin-free
    # installs above. Best-effort; -SkipElevated opts out entirely.
    if ($SkipElevated) {
        Write-Log "Elevated tool install skipped (-SkipElevated) — SSHFS-Win/WinFsp not installed"
    } else {
        foreach ($tool in $ElevatedTools) { Install-ElevatedTool -Tool $tool }
    }

    Update-SessionPath

    # Soft-warn for the hand-installed editor (VSCode). Zed is auto-installed via
    # $InstallerTools above; VSCode's chezmoi config deploys regardless, and the
    # script never installs or fails on it.
    foreach ($app in @(@{ Cmd = 'code'; Name = 'VSCode' })) {
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
# 5b. POWERSHELL PROFILE SHIM (Documents redirection) — when Documents is
#    redirected (OneDrive / corporate folder redirection), $PROFILE resolves to
#    the redirected dir, but chezmoi deploys the canonical profile to the LITERAL
#    %USERPROFILE%\Documents\PowerShell — so PowerShell never loads the managed
#    profile. Drop a tiny loader at the real $PROFILE dir(s) that dot-sources the
#    chezmoi canonical. No-op when Documents isn't redirected (chezmoi's normal
#    deploy already lands in the right place). The literal-path canonical stays
#    the single source of truth; this only bridges the redirect.
# =============================================================================
function Invoke-ProfileShim {
    $canonical = Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
    if (-not (Test-Path $canonical)) {
        Write-Warn "Canonical PowerShell profile not at $canonical — skipping profile shim."
        return
    }
    $realDocs    = [Environment]::GetFolderPath("MyDocuments")
    $literalDocs = Join-Path $env:USERPROFILE "Documents"
    if ([string]::IsNullOrEmpty($realDocs) -or ($realDocs -eq $literalDocs)) {
        Write-Ok "Documents not redirected — PowerShell loads the managed profile directly."
        return
    }

    Write-Log "Documents redirected to $realDocs — installing profile loader(s)..."
    $loader = @'
# Loader (managed by bootstrap.ps1) — Documents is redirected (OneDrive / folder
# redirection), so PowerShell loads $PROFILE from here. Source the chezmoi-managed
# canonical profile at the literal %USERPROFILE%\Documents.
$canonical = Join-Path $env:USERPROFILE "Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
if (Test-Path $canonical) { . $canonical }
'@
    foreach ($sub in @("WindowsPowerShell", "PowerShell")) {
        $dir    = Join-Path $realDocs $sub
        $target = Join-Path $dir "Microsoft.PowerShell_profile.ps1"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Back up a pre-existing non-loader profile once, so we never silently
        # clobber a hand-written one.
        if ((Test-Path $target) -and -not (Select-String -Path $target -Pattern "managed by bootstrap.ps1" -Quiet)) {
            $bak = "$target.pre-chezmoi.bak"
            if (-not (Test-Path $bak)) { Copy-Item $target $bak -Force; Write-Warn "Backed up existing $sub profile to $bak" }
        }
        Set-Content -Path $target -Value $loader -Encoding UTF8
        Write-Ok "Profile loader installed: $target"
    }
    Write-Warn "Restart PowerShell to pick up the managed profile."
}

# =============================================================================
# 5c. WEZTERM START MENU SHORTCUT — the portable WezTerm .zip ships no shortcut
#    (unlike the installer-class apps, whose own installers create one), so the
#    Start menu has nothing to launch and the GUI hides behind the PATH'd exe.
#    Drop a per-user Start Menu .lnk pointing at wezterm-gui.exe (the GUI binary,
#    NOT the wezterm.exe CLI/mux).
#
#    Idempotent + duplicate-proof: a fixed filename (WezTerm.lnk) means a re-run
#    overwrites the same path in place — a second copy can never appear. Runs on
#    EVERY bootstrap, independent of the install stamp, so deleting the shortcut
#    and re-running restores it (self-healing). Soft-fails to a warning; never
#    blocks the rest of the bootstrap.
# =============================================================================
function Invoke-WeztermShortcut {
    # Resolve the GUI launcher. Prefer the portable install dir; fall back to PATH
    # (e.g. -SkipToolInstall with WezTerm already installed somewhere else).
    $exe = Join-Path $WsWezterm "wezterm-gui.exe"
    if (-not (Test-Path $exe)) {
        $cmd = Get-Command "wezterm-gui" -ErrorAction SilentlyContinue
        if ($cmd) {
            $exe = $cmd.Source
        } else {
            Write-Warn "Skipping WezTerm Start Menu shortcut — wezterm-gui.exe not found at $WsWezterm or on PATH."
            return
        }
    }

    # Fixed filename in the per-user Start Menu Programs folder (no admin). The
    # deterministic path is what makes this duplicate-proof: .Save() overwrites.
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) "WezTerm.lnk"

    try {
        $existed = Test-Path $lnk
        $wsh = New-Object -ComObject WScript.Shell
        try {
            # CreateShortcut loads the existing .lnk when present, so its current
            # TargetPath is readable — skip the rewrite when it already matches.
            $sc = $wsh.CreateShortcut($lnk)
            if ($existed -and ($sc.TargetPath -eq $exe)) {
                Write-Ok "WezTerm Start Menu shortcut already present"
                return
            }
            $sc.TargetPath       = $exe
            $sc.WorkingDirectory = $env:USERPROFILE
            $sc.Description       = "WezTerm terminal emulator"
            $sc.Save()
            if ($existed) {
                Write-Ok "WezTerm Start Menu shortcut updated (target: $exe)"
            } else {
                Write-Ok "WezTerm Start Menu shortcut created at $lnk"
            }
        } finally {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
        }
    } catch {
        Write-Warn "Could not create the WezTerm Start Menu shortcut: $($_.Exception.Message)"
    }
}

# =============================================================================
# 5d. NUSHELL STARSHIP PROMPT — Nushell wires the Starship prompt through a
#    GENERATED file in its autoload dir. Unlike PowerShell's
#    `Invoke-Expression (& starship init powershell)`, nu's init output can't be
#    eval'd at parse time, so it must be written to
#    %APPDATA%\nushell\vendor\autoload\starship.nu — everything under
#    vendor/autoload is auto-sourced on every nu startup. The chezmoi-managed
#    config.nu owns the hand-written config (aliases, env); this owns ONLY the
#    generated prompt, so the two never fight. Runs EVERY bootstrap independent
#    of any stamp, so a Starship pin-bump refreshes it and a deleted file
#    self-heals — same pattern as Invoke-WeztermShortcut. Per-user, no admin;
#    soft-fails to a warning, never blocks the rest of the bootstrap.
# =============================================================================
function Invoke-NushellStarship {
    if (-not (Get-Command starship -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell starship prompt — starship not on PATH (install step skipped?)."
        return
    }
    if (-not (Get-Command nu -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell starship prompt — nu not on PATH (install step skipped?)."
        return
    }

    $autoload = Join-Path $env:APPDATA "nushell\vendor\autoload"
    $target   = Join-Path $autoload "starship.nu"
    try {
        if (-not (Test-Path $autoload)) { New-Item -ItemType Directory -Force -Path $autoload | Out-Null }
        # starship emits the nu prompt wiring on stdout. Write UTF-8 WITHOUT a
        # BOM — nu chokes on a leading BOM in sourced scripts.
        $init = (& starship init nu) -join "`n"
        [System.IO.File]::WriteAllText($target, $init, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Nushell starship prompt generated ($target)"
    } catch {
        Write-Warn "Could not generate the Nushell starship prompt: $($_.Exception.Message)"
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
#    scripts/install-nerd-fonts.ps1, which also registers a per-user at-logon
#    scheduled task (WorkstationNerdFontActivate) that re-activates the font each
#    sign-in — HKCU per-user fonts do not reliably load at logon on their own.
#    Soft-fails if -SkipNerdFonts or the helper is missing.
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
# DOCTOR / CHECK-FOR-UPDATES — read-only report modes (-Doctor /
# -CheckForUpdates). Both exit before the provisioning flow starts: nothing
# is installed, cloned, applied, or written. The Windows counterpart of
# bootstrap.sh --doctor / --check-for-updates (whose tool knowledge lives in
# makefile/; here the manifests in THIS script are the source of truth).
# =============================================================================

# Shared by both modes: fetch (best-effort), then report branch, ahead/behind
# the upstream, and working-tree cleanliness. Returns $true when a repo exists.
function Show-RepoState {
    Write-Log "Workstation repo ($RepoPath)"
    if (-not (Test-Path "$RepoPath\.git")) {
        Write-Bad "no repo at $RepoPath — run .\bootstrap.ps1 first (or pass -RepoPath)"
        return $false
    }

    # PS 5.1: native stderr + 2>$null under $ErrorActionPreference=Stop throws
    # NativeCommandError — relax EAP around every git call in this function.
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $null = git -C $RepoPath fetch --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "git fetch failed (offline or stale credentials) — using last-known remote state"
        } else {
            Write-Ok "fetched origin"
        }

        $branch   = git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
        $dirty    = @(git -C $RepoPath status --porcelain 2>$null).Count
        $upstream = git -C $RepoPath rev-parse --abbrev-ref '@{upstream}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $upstream) {
            $behind = [int](git -C $RepoPath rev-list --count "HEAD..@{upstream}" 2>$null)
            $ahead  = [int](git -C $RepoPath rev-list --count "@{upstream}..HEAD" 2>$null)
            if ($behind -gt 0) {
                Write-Warn "branch $branch is $behind commit(s) behind $upstream — update with: git -C $RepoPath pull --ff-only"
            } else {
                Write-Ok "branch $branch is up to date with $upstream"
            }
            if ($ahead -gt 0) { Write-Warn "$ahead local commit(s) not pushed — push with: git -C $RepoPath push" }
        } else {
            Write-Warn "branch $branch has no upstream — behind/ahead unknown"
        }

        if ($dirty -gt 0) {
            Write-Warn "$dirty uncommitted change(s) — review with: git -C $RepoPath status"
        } else {
            Write-Ok "working tree clean"
        }
    } finally {
        $ErrorActionPreference = $oldEap
    }
    return $true
}

# Newest upstream tag via `git ls-remote --tags` — plain git, no GitHub API,
# no rate limits. $Repo is owner/repo or a full git URL; $TagPrefix is what
# precedes the version in the tag name; $Filter accepts version shapes after
# the prefix strip (default: clean dotted numerics — drops -rc/-pre tags);
# -StringSort for tags [version] can't parse (WezTerm's date stamps).
# Returns $null when nothing matches (offline, renamed tag scheme).
function Get-LatestGitTag {
    param(
        [string]$Repo,
        [string]$TagPrefix = "v",
        [string]$Filter = '^\d+(\.\d+)*$',
        [switch]$StringSort
    )
    $url = if ($Repo -match '://') { $Repo } else { "https://github.com/$Repo.git" }

    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $env:GIT_TERMINAL_PROMPT = '0'
    $refs = git ls-remote --tags --refs $url "refs/tags/$TagPrefix*" 2>$null
    $ErrorActionPreference = $oldEap
    if ($LASTEXITCODE -ne 0 -or -not $refs) { return $null }

    $vers = @(foreach ($line in @($refs)) {
        $tag = ($line -split "`t")[-1] -replace '^refs/tags/', ''
        if ($TagPrefix -and -not $tag.StartsWith($TagPrefix)) { continue }
        $v = $tag.Substring($TagPrefix.Length)
        if ($v -match $Filter) { $v }
    })
    if ($vers.Count -eq 0) { return $null }
    if ($StringSort) { return ($vers | Sort-Object -Descending | Select-Object -First 1) }
    return ($vers | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
}

# DisplayVersion from the Uninstall registry (same three roots as
# Test-InstallerPresent). $null when not installed or no version recorded.
function Get-InstalledAppVersion {
    param([string]$DisplayName)
    $roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($root in $roots) {
        $hit = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
               Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $DisplayName } |
               Select-Object -First 1
        if ($hit -and $hit.PSObject.Properties['DisplayVersion']) { return $hit.DisplayVersion }
    }
    return $null
}

# One report line comparing a pinned/installed version against the upstream
# latest. -StringSort for date-style tags; otherwise [version] comparison with
# a string-inequality fallback.
function Write-UpdateStatus {
    param([string]$Name, [string]$Pinned, [string]$Latest, [string]$Hint = "", [switch]$StringSort)
    if (-not $Latest) {
        Write-Warn "${Name}: couldn't resolve the latest release (offline? upstream tag scheme changed?)"
        return
    }
    if ($Latest -eq $Pinned) {
        Write-Ok "$Name $Pinned is up to date"
        return
    }
    $newer = $false
    if ($StringSort) {
        $newer = ($Latest -gt $Pinned)
    } else {
        try   { $newer = ([version]$Latest -gt [version]$Pinned) }
        catch { $newer = $true }   # unparseable mismatch — surface it as an update
    }
    if ($newer) {
        $suffix = if ($Hint) { " — $Hint" } else { "" }
        Write-Warn "$Name $Pinned -> $Latest available$suffix"
    } else {
        Write-Ok "$Name $Pinned (newest upstream tag: $Latest)"
    }
}

function Invoke-Doctor {
    Write-Log "Doctor — read-only health report; nothing is installed or changed"
    Write-Host ""

    Write-Log "Prerequisites"
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) { Write-Ok "git ($($gitCmd.Source))" }
    else         { Write-Bad "git missing (hard prerequisite) — https://git-scm.com/download/win or: winget install Git.Git" }
    if (Get-Command ssh-keygen -ErrorAction SilentlyContinue) { Write-Ok "ssh-keygen" }
    else { Write-Warn "ssh-keygen not on PATH — Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0" }
    Write-Host ""

    if ($gitCmd) { $null = Show-RepoState; Write-Host "" }

    Write-Log "chezmoi / dotfiles"
    $chezmoiCmd = Get-Command chezmoi -ErrorAction SilentlyContinue
    if ($chezmoiCmd) {
        Write-Ok "chezmoi on PATH ($($chezmoiCmd.Source))"
        $cfg = Join-Path $env:USERPROFILE ".config\chezmoi\chezmoi.toml"
        if (Test-Path $cfg) {
            Write-Ok "initialized ($cfg)"
            $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            $pending = @(chezmoi status 2>$null)
            $statusRc = $LASTEXITCODE
            $ErrorActionPreference = $oldEap
            if ($statusRc -ne 0) {
                Write-Warn "chezmoi status failed — inspect with: chezmoi doctor"
            } elseif ($pending.Count -gt 0) {
                Write-Warn "$($pending.Count) path(s) differ from the source — review: chezmoi diff · apply: chezmoi apply"
            } else {
                Write-Ok "deployed dotfiles in sync with the source"
            }
        } else {
            Write-Warn "not initialized — re-run .\bootstrap.ps1 (runs chezmoi init --apply)"
        }
    } else {
        Write-Warn "chezmoi not on PATH — re-run .\bootstrap.ps1 (or open a NEW shell if it just installed)"
    }
    Write-Host ""

    Write-Log "Portable tools ($WsRoot)"
    foreach ($tool in $PortableTools) {
        $stamp = Join-Path $WsStamps "$($tool.Exe).$($tool.Version).stamp"
        $cmd   = Get-Command $tool.Exe -ErrorAction SilentlyContinue
        if ($cmd -and (Test-Path $stamp)) {
            Write-Ok "$($tool.Name) $($tool.Version) installed ($($cmd.Source))"
        } elseif ($cmd) {
            Write-Warn "$($tool.Name) on PATH but no $($tool.Version) stamp — pin moved? next bootstrap reinstalls"
        } elseif (Test-Path $stamp) {
            Write-Bad "$($tool.Name) stamped but $($tool.Exe).exe doesn't resolve — open a NEW shell, or re-run .\bootstrap.ps1"
        } else {
            Write-Bad "$($tool.Name) missing — re-run .\bootstrap.ps1"
        }
    }
    Write-Host ""

    Write-Log "Installer apps + extras"
    foreach ($tool in $InstallerTools) {
        if (Test-InstallerPresent -DisplayName $tool.DetectName) {
            $ver = Get-InstalledAppVersion -DisplayName $tool.DetectName
            $verText = if ($ver) { " $ver" } else { "" }
            Write-Ok "$($tool.Name)$verText installed (self-updates; -ForceInstaller to reseed)"
        } else {
            Write-Bad "$($tool.Name) not installed — re-run .\bootstrap.ps1 (installs the latest release)"
        }
    }

    foreach ($tool in $ElevatedTools) {
        if (Test-InstallerPresent -DisplayName $tool.DetectName) {
            $ver = Get-InstalledAppVersion -DisplayName $tool.DetectName
            $verText = if ($ver) { " $ver" } else { "" }
            Write-Ok "$($tool.Name)$verText installed (elevated class; update via: winget upgrade $($tool.WingetId))"
        } else {
            Write-Warn "$($tool.Name) not installed (best-effort elevated tool) — re-run .\bootstrap.ps1 (UAC prompt) or: winget install $($tool.WingetId)"
        }
        # Report the tool's dependency MSIs (WinFsp kernel driver) separately so
        # a half-install (driver without sshfs, or vice versa) is visible.
        foreach ($msi in $tool.Msi) {
            if ($msi.DetectName -eq $tool.DetectName) { continue }
            if (Test-InstallerPresent -DisplayName $msi.DetectName) {
                $depVer = Get-InstalledAppVersion -DisplayName $msi.DetectName
                $depText = if ($depVer) { " $depVer" } else { "" }
                Write-Ok "$($msi.Name)$depText installed ($($tool.Name)'s kernel-driver dependency)"
            } else {
                Write-Warn "$($msi.Name) not installed — $($tool.Name) can't mount without it (winget installs both)"
            }
        }
    }
    if (Get-Command code -ErrorAction SilentlyContinue) { Write-Ok "VSCode on PATH (hand-installed)" }
    else { Write-Warn "VSCode not on PATH — hand-install when wanted; its chezmoi config deploys regardless" }
    $bt = Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue |
          Sort-Object Version -Descending | Select-Object -First 1
    if ($bt) { Write-Ok "BurntToast $($bt.Version) module available (WSL2 toast notifications)" }
    else { Write-Warn "BurntToast module missing — Claude Code WSL2 toasts fall back to a MessageBox; re-run .\bootstrap.ps1" }
    $fontStamps = @(Get-ChildItem -Path $WsRoot -Filter "nerd-fonts.*.stamp" -ErrorAction SilentlyContinue)
    if ($fontStamps.Count -gt 0) {
        $fontVer = $fontStamps[0].Name -replace '^nerd-fonts\.', '' -replace '\.stamp$', ''
        Write-Ok "Nerd Fonts (JetBrainsMono) $fontVer installed (per-user)"
    } else {
        Write-Warn "Nerd Fonts not stamped — glyphs may render as tofu; re-run .\bootstrap.ps1 (or scripts\install-nerd-fonts.ps1)"
    }
    Write-Host ""

    Write-Log "Environment"
    $expectedCfg = Join-Path $RepoPath "chezmoi\dot_config\wezterm\wezterm.lua"
    $currentCfg  = [Environment]::GetEnvironmentVariable('WEZTERM_CONFIG_FILE', 'User')
    if ($currentCfg -eq $expectedCfg) {
        Write-Ok "WEZTERM_CONFIG_FILE points at the chezmoi source"
    } elseif ($currentCfg) {
        Write-Warn "WEZTERM_CONFIG_FILE points at $currentCfg (expected $expectedCfg) — re-run .\bootstrap.ps1"
    } else {
        Write-Bad "WEZTERM_CONFIG_FILE not set (User scope) — WezTerm won't find the tracked config; re-run .\bootstrap.ps1"
    }
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) "WezTerm.lnk"
    if (Test-Path $lnk) { Write-Ok "WezTerm Start Menu shortcut present" }
    else { Write-Warn "WezTerm Start Menu shortcut missing — re-run .\bootstrap.ps1 (self-heals it)" }

    $nuStarship = Join-Path $env:APPDATA "nushell\vendor\autoload\starship.nu"
    if (Test-Path $nuStarship) { Write-Ok "Nushell starship prompt generated ($nuStarship)" }
    else { Write-Warn "Nushell starship prompt missing — re-run .\bootstrap.ps1 (regenerates it)" }

    $realDocs    = [Environment]::GetFolderPath("MyDocuments")
    $literalDocs = Join-Path $env:USERPROFILE "Documents"
    if ([string]::IsNullOrEmpty($realDocs) -or ($realDocs -eq $literalDocs)) {
        Write-Ok "Documents not redirected — PowerShell loads the managed profile directly"
    } else {
        $loaderOk = $true
        foreach ($sub in @("WindowsPowerShell", "PowerShell")) {
            if (-not (Test-Path (Join-Path (Join-Path $realDocs $sub) "Microsoft.PowerShell_profile.ps1"))) { $loaderOk = $false }
        }
        if ($loaderOk) { Write-Ok "Documents redirected ($realDocs) — profile loaders in place" }
        else { Write-Warn "Documents redirected ($realDocs) but profile loader(s) missing — re-run .\bootstrap.ps1" }
    }

    if (Test-Path "$SshKey.pub") { Write-Ok "SSH key present ($SshKey)" }
    else { Write-Warn "no SSH key at $SshKey — generate with: ssh-keygen -t ed25519 (or re-run .\bootstrap.ps1)" }
}

function Invoke-CheckForUpdates {
    Write-Log "Check for updates — workstation repo first, then tool pins vs upstream (read-only)"
    Write-Host ""

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Fail "git is required for -CheckForUpdates (repo state + ls-remote tag lookups)."
    }

    $repoOk = Show-RepoState
    if ($repoOk) {
        Write-Host "    (tool pins live in `$PortableTools of THIS clone's bootstrap.ps1 — if the repo"
        Write-Host "     is behind, pull first so the pins you're comparing are current)"
    }
    Write-Host ""

    Write-Log "Pinned portable tools"
    foreach ($tool in $PortableTools) {
        $filter    = if ($tool.ContainsKey('TagFilter')) { $tool.TagFilter } else { '^\d+(\.\d+)*$' }
        $useString = ($tool.ContainsKey('TagSort') -and $tool.TagSort -eq 'string')
        $hint      = if ($tool.ContainsKey('UpdateHint')) { $tool.UpdateHint } else { "" }
        $latest    = Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tool.TagPrefix -Filter $filter -StringSort:$useString
        Write-UpdateStatus -Name $tool.Name -Pinned $tool.Version -Latest $latest -Hint $hint -StringSort:$useString
    }
    # chezmoi is installed unpinned via the official installer — compare the
    # installed binary against upstream instead of a pin.
    $chezmoiCmd = Get-Command chezmoi -ErrorAction SilentlyContinue
    if ($chezmoiCmd) {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $verOut = chezmoi --version 2>$null
        $ErrorActionPreference = $oldEap
        $installed = if ("$verOut" -match 'v(\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
        if ($installed) {
            $latest = Get-LatestGitTag -Repo 'twpayne/chezmoi'
            Write-UpdateStatus -Name 'chezmoi' -Pinned $installed -Latest $latest -Hint 'not pinned — re-run the official installer (or winget upgrade twpayne.chezmoi)'
        } else {
            Write-Warn "chezmoi: couldn't parse the installed version from 'chezmoi --version'"
        }
    } else {
        Write-Warn "chezmoi not on PATH — re-run .\bootstrap.ps1"
    }
    Write-Host ""

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
    Write-Host ""

    Write-Log "Elevated tools (best-effort; update via winget when flagged)"
    foreach ($tool in $ElevatedTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $latest    = Get-LatestGitTag -Repo $tool.Repo
        if (-not (Test-InstallerPresent -DisplayName $tool.DetectName)) {
            Write-Warn "$($tool.Name) not installed (best-effort elevated tool) — re-run .\bootstrap.ps1 or: winget install $($tool.WingetId)"
        } elseif ($installed -and $latest) {
            Write-UpdateStatus -Name $tool.Name -Pinned $installed -Latest $latest -Hint "winget upgrade $($tool.WingetId)"
        } elseif ($latest) {
            Write-Ok "$($tool.Name) installed (latest upstream: $latest)"
        } else {
            Write-Ok "$($tool.Name) installed"
        }
        foreach ($msi in $tool.Msi) {
            if ($msi.DetectName -eq $tool.DetectName) { continue }
            $depInstalled = Get-InstalledAppVersion -DisplayName $msi.DetectName
            $depLatest    = Get-LatestGitTag -Repo $msi.Repo
            if (-not (Test-InstallerPresent -DisplayName $msi.DetectName)) {
                Write-Warn "$($msi.Name) not installed — $($tool.Name)'s kernel-driver dependency"
            } elseif ($depInstalled -and $depLatest) {
                Write-UpdateStatus -Name $msi.Name -Pinned $depInstalled -Latest $depLatest -Hint "winget upgrade $($msi.WingetId)"
            } elseif ($depLatest) {
                Write-Ok "$($msi.Name) installed ($($tool.Name)'s kernel-driver dependency; latest upstream: $depLatest)"
            } else {
                Write-Ok "$($msi.Name) installed ($($tool.Name)'s kernel-driver dependency)"
            }
        }
    }
    Write-Host ""

    Write-Log "Other components"
    $fontStamps = @(Get-ChildItem -Path $WsRoot -Filter "nerd-fonts.*.stamp" -ErrorAction SilentlyContinue)
    if ($fontStamps.Count -gt 0) {
        $fontVer = $fontStamps[0].Name -replace '^nerd-fonts\.', '' -replace '\.stamp$', ''
        $latest  = Get-LatestGitTag -Repo 'ryanoasis/nerd-fonts'
        Write-UpdateStatus -Name 'Nerd Fonts (JetBrainsMono)' -Pinned $fontVer -Latest $latest -Hint 'triple-edit: versions.mk + lib/font.sh + install-nerd-fonts.ps1 (see CLAUDE.md)'
    } else {
        Write-Warn "Nerd Fonts not stamped — re-run .\bootstrap.ps1 (or scripts\install-nerd-fonts.ps1)"
    }
    $bt = Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue |
          Sort-Object Version -Descending | Select-Object -First 1
    if ($bt) { Write-Ok "BurntToast $($bt.Version) installed — update via: Update-Module BurntToast" }
    else { Write-Warn "BurntToast module missing — re-run .\bootstrap.ps1" }
}

# =============================================================================
# MAIN
# =============================================================================
# Read-only report modes exit here, before any provisioning state changes.
if ($Doctor -and $CheckForUpdates) {
    Write-Fail "-Doctor and -CheckForUpdates are mutually exclusive (run them one at a time)."
}
if (($Doctor -or $CheckForUpdates) -and $Reinstall) {
    Write-Fail "-Reinstall can't be combined with -Doctor/-CheckForUpdates (they are read-only and exit early)."
}
if ($Doctor)          { Invoke-Doctor;          exit 0 }
if ($CheckForUpdates) { Invoke-CheckForUpdates; exit 0 }

if ($Reinstall) { Invoke-Reinstall }
Invoke-Preflight
Invoke-ToolInstall        # admin-free binary/portable installs under %LOCALAPPDATA%\workstation
Invoke-CloneRepo
Invoke-Chezmoi
Invoke-WeztermConfigEnv   # after chezmoi apply — point WezTerm at the chezmoi source
Test-AgeIdentity          # warn if age key / binary missing when recipient is configured
Invoke-WeztermShortcut    # drop a per-user Start Menu .lnk for the portable WezTerm GUI
Invoke-NushellStarship    # generate the Nushell starship prompt (vendor/autoload — self-heals)
Invoke-ProfileShim        # bridge Documents redirection (OneDrive) so $PROFILE loads the managed profile
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-InstallNerdFonts   # JetBrainsMono Nerd Font Mono — per-user font install
Invoke-EnsureSshKey

Write-Host ""
Write-Host "${Bold}Bootstrap complete.${Reset}"
Write-Host ""
Write-Host "Open a NEW shell so the updated User PATH (${Bold}$WsBin${Reset}, ${Bold}$WsWezterm${Reset},"
Write-Host "${Bold}$WsHelix${Reset}, ${Bold}$WsNu${Reset}) and the chezmoi-applied configs pick up — starship"
Write-Host "prompt, chezmoi/git aliases, etc. Nushell is now the default local shell;"
Write-Host "PowerShell stays installed (for .NET/COM tasks + the WSL2 notify hook)."
Write-Host "Restart WezTerm too if any instances were running — they need a fresh process"
Write-Host "to see the new ${Bold}WEZTERM_CONFIG_FILE${Reset} env var."
Write-Host ""
Write-Host "Not installed by this script (install yourself if you want them):"
Write-Host "  Zed, VSCode  — their chezmoi configs are already deployed."
Write-Host ""

# Print the curated hand-install shopping list (docs/windows/application_list.md).
# Personal preference order — terminals, file managers, search, editors, etc.
# Soft-skip if the file is missing (partial clone, older repo snapshot).
$appList = Join-Path $RepoPath "docs\windows\application_list.md"
if (Test-Path $appList) {
    Write-Host "${Bold}Hand-install shopping list${Reset} (docs\windows\application_list.md):"
    Get-Content $appList | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

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
