# =============================================================================
# bootstrap.ps1 — workstation setup (Windows client side)
#
# The Windows host is a CLIENT — Ansible runs on RHEL VMs only. On Windows
# this script handles its slice of the same workflow: install dev tools via
# winget, then hand off to chezmoi to deploy the dotfiles tracked in this
# repo (Zed, VSCode, PowerShell profile, WezTerm config, Starship, Git).
#
# Flow:
#   1. preflight        — git on PATH; OpenSSH client warned-not-failed
#   2. clone repo       — into -RepoPath (default C:\Git\workstation)
#   3. winget install   — chezmoi + every tool whose dotfiles we manage
#   4. chezmoi apply    — applies chezmoi/ to %USERPROFILE% (wezterm,
#                         Zed, VSCode, PowerShell profile, etc.)
#   5. ssh key          — generate %USERPROFILE%\.ssh\id_ed25519 if missing
#
# PRIVATE REPO + commit attribution — set GITHUB_TOKEN, GIT_USER_NAME,
# GIT_USER_EMAIL before running. The token authenticates the bootstrap.ps1
# fetch AND the script's internal git clone/pull, then is persisted into the
# cloned repo's .git/config (http.https://github.com/.extraheader, scoped to
# github.com) so subsequent push/pull and manage-hosts.ps1 ops work without
# re-passing the env var.
#
# One-liner from a fresh Windows machine (PowerShell 5.1 or 7+):
#
#   $env:GITHUB_TOKEN  = '<your-PAT>'
#   $env:GIT_USER_NAME = 'Arrush Chaturvedi'
#   $env:GIT_USER_EMAIL = 'contact@arrushc.com'
#   irm -Headers @{Authorization="token $env:GITHUB_TOKEN"} `
#     https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1 | iex
#
# Or clone manually + run:
#
#   git clone https://github.com/ArrushC/workstation.git C:\Git\workstation
#   cd C:\Git\workstation
#   .\bootstrap.ps1
#
# Flags:
#   -RepoPath <path>    override clone target (default C:\Git\workstation)
#   -SkipKeyGen         skip the SSH-key generation prompt
#   -SkipToolInstall    skip the winget step (assume tools already installed)
#   -SkipChezmoi        clone + install tools but don't apply dotfiles yet
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoPath = "C:\Git\workstation",
    [switch]$SkipKeyGen,
    [switch]$SkipToolInstall,
    [switch]$SkipChezmoi
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

# winget IDs for everything chezmoi manages on Windows. Chezmoi is required;
# the rest are skipped silently (with a warning) if winget can't find them.
$WingetTools = @(
    @{ Id = "twpayne.chezmoi";     Name = "chezmoi";    Required = $true  },
    @{ Id = "Git.Git";             Name = "Git";        Required = $true  },
    @{ Id = "Starship.Starship";   Name = "Starship";   Required = $false },
    @{ Id = "ajeetdsouza.zoxide";  Name = "zoxide";     Required = $false },
    @{ Id = "wez.wezterm";         Name = "WezTerm";    Required = $false },
    @{ Id = "Zed.Zed";             Name = "Zed";        Required = $false },
    @{ Id = "Microsoft.VisualStudioCode"; Name = "VSCode"; Required = $false }
)

# =============================================================================
# 1. PREFLIGHT
# =============================================================================
function Invoke-Preflight {
    Write-Log "Checking prerequisites..."

    $missing = @()
    if (-not (Get-Command git    -ErrorAction SilentlyContinue)) { $missing += "git" }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { $missing += "winget" }

    if ($missing.Count -gt 0) {
        Write-Fail @"
Missing required prerequisites: $($missing -join ', ')
  git    : winget install --id Git.Git    (or https://git-scm.com/download/win)
  winget : built into Windows 10 1909+ / Windows 11. Update via Microsoft Store
           (search 'App Installer') if missing.
"@
    }

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Warn "ssh-keygen not on PATH — install OpenSSH client to enable the SSH-key step:"
        Write-Warn "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    }

    Write-Ok "Prerequisites OK"
}

# =============================================================================
# 2. CLONE REPO (with $env:GITHUB_TOKEN support for private repo)
# =============================================================================
function Invoke-CloneRepo {
    $headerVal = ""
    if ($env:GITHUB_TOKEN) {
        $headerVal = "Authorization: bearer $env:GITHUB_TOKEN"
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
# 3. WINGET INSTALL — chezmoi + every tool whose dotfiles we manage
# =============================================================================
function Test-WingetInstalled {
    param([string]$PackageId)
    $listOutput = winget list --id $PackageId --exact 2>&1 | Out-String
    return ($LASTEXITCODE -eq 0 -and $listOutput -match [regex]::Escape($PackageId))
}

function Invoke-WingetInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall)"
        return
    }

    Write-Log "Installing tools via winget..."

    foreach ($tool in $WingetTools) {
        if (Test-WingetInstalled -PackageId $tool.Id) {
            Write-Ok "$($tool.Name) already installed"
            continue
        }

        Write-Log "Installing $($tool.Name) ($($tool.Id))..."
        winget install --id $tool.Id --exact --silent --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) {
            if ($tool.Required) {
                Write-Fail "$($tool.Name) install failed — required tool, cannot continue."
            } else {
                Write-Warn "$($tool.Name) install failed (winget exit $LASTEXITCODE) — skipping; install manually if needed."
            }
            continue
        }
        Write-Ok "$($tool.Name) installed"
    }

    # winget installs may have added entries to PATH that this session doesn't
    # see yet. Refresh from the registry so chezmoi etc. resolve in step 4.
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
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
        Write-Warn "chezmoi not on PATH after winget install. Open a new shell and re-run, or install manually:"
        Write-Warn "  winget install --id twpayne.chezmoi"
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
# 5. SSH KEY (optional, prompt-driven)
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
Invoke-Preflight
Invoke-CloneRepo
Invoke-WingetInstall
Invoke-Chezmoi
Invoke-EnsureSshKey

Write-Host ""
Write-Host "${Bold}Bootstrap complete.${Reset}"
Write-Host ""
Write-Host "Restart your shell (or open a new PowerShell tab) so the chezmoi-applied"
Write-Host "$PROFILE picks up — starship prompt, chezmoi/git aliases, etc."
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Add a VM to hosts.conf:"
Write-Host "       cd $RepoPath"
Write-Host "       .\scripts\manage-hosts.ps1     # interactive menu"
Write-Host "  2. Copy your SSH key to a registered VM:"
Write-Host "       .\scripts\manage-hosts.ps1 -CopyId -Name <vm-name>"
Write-Host "  3. Launch WezTerm — it auto-opens a tab per VM in hosts.conf."
Write-Host ""
Write-Host "Editing dotfiles:"
Write-Host "  cze   # chezmoi edit (opens the file in chezmoi's source)"
Write-Host "  cza   # chezmoi apply (push edits to ~)"
Write-Host "  czd   # chezmoi diff (see what would change)"
