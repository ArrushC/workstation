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
#                     portable downloads), all into %LOCALAPPDATA%\workstation.
#   3. clone repo   — into -RepoPath (default %USERPROFILE%\.local\share\chezmoi,
#                     matching bootstrap.sh's $HOME/.local/share/chezmoi and
#                     chezmoi's own default source dir).
#   4. chezmoi apply— applies chezmoi/ to %USERPROFILE% (PowerShell profile,
#                     Zed/VSCode settings, etc.). wezterm.lua is ignored on
#                     Windows; WezTerm reads it via the env var in step 5.
#   5. wezterm env  — set User-scope WEZTERM_CONFIG_FILE at the chezmoi source.
#   5b. profile shim— if Documents is redirected (OneDrive), drop a loader at the
#                     real $PROFILE that sources the chezmoi canonical profile.
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
#   -SkipToolInstall    skip the chezmoi/WezTerm/Starship/Helix auto-installs
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
#   workstation\helix    — the multi-file Helix portable tree    → on User PATH
#   workstation\stamps   — "<exe>.<version>.stamp" idempotency markers
$WsRoot    = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin     = Join-Path $WsRoot "bin"
$WsWezterm = Join-Path $WsRoot "wezterm"
$WsHelix   = Join-Path $WsRoot "helix"
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
        Version = "1.25.1"
        Url     = "https://github.com/starship/starship/releases/download/v1.25.1/starship-x86_64-pc-windows-msvc.zip"
        Sha256  = "a07cf3e428afab09324e510fb786041ebcc491a68b1ca6fba044c5a461f9b017"
        Layout  = "single"
        Dest    = $WsBin
    },
    @{
        Name    = "WezTerm"
        Exe     = "wezterm"
        Version = "20240203-110809-5046fc22"
        Url     = "https://github.com/wez/wezterm/releases/download/20240203-110809-5046fc22/WezTerm-windows-20240203-110809-5046fc22.zip"
        Sha256  = "57e5d03b585303d81e8b8e96d1230362852eb39aca92b3b29c7a42cfb82f9ac4"
        Layout  = "tree"
        Dest    = $WsWezterm
    },
    @{
        Name    = "Helix"
        Exe     = "hx"
        Version = "25.07.1"
        Url     = "https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip"
        Sha256  = "5c8325ced8bacd8418d62706f669e96d9c3578a9237526e34d546900cbc049b6"
        Layout  = "tree"
        Dest    = $WsHelix
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

function Invoke-ToolInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall) — assuming chezmoi/WezTerm/Starship/Helix are on PATH"
        return
    }

    foreach ($d in @($WsRoot, $WsBin, $WsHelix, $WsStamps)) {
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
Invoke-ProfileShim        # bridge Documents redirection (OneDrive) so $PROFILE loads the managed profile
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-InstallNerdFonts   # JetBrainsMono Nerd Font Mono — per-user font install
Invoke-EnsureSshKey

Write-Host ""
Write-Host "${Bold}Bootstrap complete.${Reset}"
Write-Host ""
Write-Host "Open a NEW PowerShell tab so the updated User PATH (${Bold}$WsBin${Reset}, ${Bold}$WsWezterm${Reset},"
Write-Host "${Bold}$WsHelix${Reset}) and the chezmoi-applied `$PROFILE pick up — starship"
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
