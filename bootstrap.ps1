# =============================================================================
# bootstrap.ps1 — workstation setup (Windows client side)
#
# The Windows host is a CLIENT — Ansible runs on RHEL VMs only. On Windows
# this script handles its slice of the same workflow: install dev tools via
# Chocolatey, then hand off to chezmoi to deploy the dotfiles tracked in this
# repo (Zed, VSCode, PowerShell profile, WezTerm config, Starship, Git).
#
# Flow:
#   1. preflight        — must run as admin (choco needs it); OpenSSH client
#                         warned-not-failed
#   2. choco install    — bootstrap Chocolatey itself if missing, then
#                         install chezmoi, Git, Starship, zoxide, WezTerm,
#                         Zed, VSCode
#   3. clone repo       — into -RepoPath (default C:\Git\workstation).
#                         Done after choco so the freshly-installed git is
#                         used if the machine didn't have one already.
#   4. chezmoi apply    — applies chezmoi/ to %USERPROFILE% (wezterm,
#                         Zed, VSCode, PowerShell profile, etc.)
#   5. wezterm hardlink — replace the chezmoi-written regular file at
#                         %USERPROFILE%\.config\wezterm\wezterm.lua with a
#                         hardlink to the chezmoi source. Gives WezTerm
#                         live-reload on edits to the repo without losing
#                         chezmoi tracking.
#   6. ssh key          — generate %USERPROFILE%\.ssh\id_ed25519 if missing
#
# WHY CHOCOLATEY (not winget)
#   winget exists on Win10 1909+ / Win11 but its PATH propagation is flaky —
#   tools install but don't always become resolvable in the current shell
#   session, leaving chezmoi unable to find git in step 3. Choco's installs
#   write to a predictable PATH location and the refresh is reliable.
#
# PRIVATE REPO + commit attribution — set GITHUB_TOKEN, GIT_USER_NAME,
# GIT_USER_EMAIL before running. The token authenticates the bootstrap.ps1
# fetch AND the script's internal git clone/pull, then is persisted into the
# cloned repo's .git/config (http.https://github.com/.extraheader, scoped to
# github.com) so subsequent push/pull and manage-hosts.ps1 ops work without
# re-passing the env var.
#
# One-liner from a fresh Windows machine (RUN FROM AN ELEVATED PowerShell —
# Right-click PowerShell → "Run as administrator"):
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
#   -SkipToolInstall    skip the choco step entirely (assume tools installed;
#                       admin not required in this case)
#   -SkipChezmoi        clone + install tools but don't apply dotfiles yet
#   -Reinstall          wipe the cloned repo and chezmoi config first, then
#                       run the normal flow. Does NOT remove installed tools
#                       or deployed dotfiles — the bootstrap is idempotent
#                       over those. Prompts for confirmation unless -Yes
#                       is also passed.
#   -Yes                skip the -Reinstall confirmation prompt.
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoPath = "C:\Git\workstation",
    [switch]$SkipKeyGen,
    [switch]$SkipToolInstall,
    [switch]$SkipChezmoi,
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

# Choco package IDs for everything chezmoi manages on Windows. The `Cmd`
# field is the binary we expect on PATH after install — most match the
# package name; vscode's binary is `code`. Required tools fail the whole
# bootstrap if their install errors out; optional ones warn-not-fail.
$ChocoTools = @(
    @{ Id = "chezmoi";  Cmd = "chezmoi";  Name = "chezmoi";  Required = $true  },
    @{ Id = "git";      Cmd = "git";      Name = "Git";      Required = $true  },
    @{ Id = "starship"; Cmd = "starship"; Name = "Starship"; Required = $false },
    @{ Id = "zoxide";   Cmd = "zoxide";   Name = "zoxide";   Required = $false },
    @{ Id = "wezterm";  Cmd = "wezterm";  Name = "WezTerm";  Required = $false },
    @{ Id = "zed";      Cmd = "zed";      Name = "Zed";      Required = $false },
    @{ Id = "vscode";   Cmd = "code";     Name = "VSCode";   Required = $false }
)

# =============================================================================
# 0. REINSTALL (optional) — wipe the cloned repo + chezmoi config, then let
#    the rest of the script re-bootstrap fresh. Installed tools and deployed
#    dotfiles are left alone — re-running the bootstrap is idempotent on
#    those, so the net effect is a fresh repo + fresh chezmoi init prompt.
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
    Write-Host "    - Chocolatey-installed tools (re-bootstrap will detect them and skip)"
    Write-Host "    - Deployed dotfiles in `$HOME / `$env:APPDATA (chezmoi will re-apply)"
    Write-Host "    - SSH keys"
    Write-Host ""
    Write-Host "  For a deeper uninstall (remove tools too), do that manually first:"
    Write-Host "    choco uninstall -y chezmoi zoxide vscode wezterm zed starship"
    Write-Host ""

    # Self-deletion guard: if this script is being run from inside the path
    # we're about to delete, refuse. Use the curl|iex one-liner instead, which
    # runs from memory and isn't backed by a file on disk. $PSCommandPath is
    # the standard automatic variable for the running script's full path; it
    # is $null when the script is being executed from a string (iex/irm-pipe).
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
# 1. PREFLIGHT — admin check (unless -SkipToolInstall), then soft checks
# =============================================================================
function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [System.Security.Principal.WindowsPrincipal]::new($id)
    return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Is a tool installed and actually usable? `Get-Command $Cmd` is the only
# reliable signal — it confirms the binary exists AND is on PATH (which is
# what every subsequent step of the bootstrap actually needs).
#
# We deliberately don't fall back to `choco list`: it can report a package
# as installed when its binary is missing on disk (broken/orphaned entries
# from a previous install that was interrupted or had its files removed),
# which would cause the bootstrap to skip a reinstall that the user actually
# needs. If `choco list` says yes but Get-Command says no, the right
# behaviour is to treat it as missing and let `choco install` either fix it
# or no-op cleanly (already-installed packages exit 0 silently).
function Test-ToolInstalled {
    param([hashtable]$Tool)
    return [bool](Get-Command $Tool.Cmd -ErrorAction SilentlyContinue)
}

# Set by Invoke-Preflight; consumed by Invoke-ChocoInstall to skip work when
# everything's already in place.
$script:NeedsChocoInstall = $false

function Invoke-Preflight {
    Write-Log "Checking prerequisites..."

    if ($SkipToolInstall) {
        # User vouches everything's installed. git is needed for the clone
        # step; chezmoi only matters if the chezmoi-apply step will run.
        $missing = @()
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { $missing += "git" }
        if (-not $SkipChezmoi -and -not (Get-Command chezmoi -ErrorAction SilentlyContinue)) {
            $missing += "chezmoi"
        }
        if ($missing.Count -gt 0) {
            Write-Fail @"
-SkipToolInstall was passed but these required tools aren't on PATH: $($missing -join ', ')
Either drop -SkipToolInstall and re-run from an elevated shell, or install
them yourself first: choco install -y $($missing -join ' ')
"@
        }
    } else {
        # Smart detection: only require admin if there's actually something
        # for choco to install. Three buckets:
        #
        #   - choco itself missing       → need admin to bootstrap it
        #   - $missingReq non-empty      → need admin to install required tools
        #   - only $missingOpt non-empty → installs would help but aren't
        #     critical; if non-admin, skip the install step with a note rather
        #     than failing the whole bootstrap.
        # Classify each tool as installed / missing-required / missing-optional.
        # Primary detection: Get-Command $Cmd works regardless of installer
        # (choco / MSI / scoop / manual). Fallback to `choco list` covers GUI
        # apps that don't put a binary on PATH.
        $needsBootstrap = -not (Get-Command choco -ErrorAction SilentlyContinue)
        $missingReqNames = @()
        $missingReqIds  = @()
        $missingOptNames = @()
        foreach ($tool in $ChocoTools) {
            if (Test-ToolInstalled -Tool $tool) { continue }
            if ($tool.Required) {
                $missingReqNames += $tool.Name
                $missingReqIds   += $tool.Id
            } else {
                $missingOptNames += $tool.Name
            }
        }

        $needsAdminWork = $needsBootstrap -or ($missingReqNames.Count -gt 0)

        if ($needsAdminWork) {
            if (-not (Test-IsAdmin)) {
                $reqList = if ($needsBootstrap) { "Chocolatey itself" } else { $missingReqNames -join ', ' }
                $idList  = if ($needsBootstrap) { "" } else { $missingReqIds -join ' ' }
                Write-Fail @"
Admin required to install: $reqList
Open PowerShell as administrator and re-run.

If you'd rather install $reqList yourself first (admin one-shot:
  choco install -y $idList
), you can then re-run this script non-elevated with:
  .\bootstrap.ps1 -SkipToolInstall
"@
            }
            $script:NeedsChocoInstall = $true
        } elseif ($missingOptNames.Count -gt 0) {
            $optList = $missingOptNames -join ', '
            Write-Warn "Optional tools not installed: $optList"
            Write-Warn "Re-run from an elevated shell to install them, or skip — they aren't required."
            # NeedsChocoInstall stays false; we'll skip the install step.
        } else {
            Write-Ok "All Chocolatey-managed tools already installed"
        }
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
# 2. CHOCOLATEY + DEV TOOLS
# =============================================================================
function Update-SessionPath {
    # Choco installs append to the Machine and User PATH entries in the
    # registry, but the current PowerShell session keeps its own copy. Rebuild
    # $env:PATH from the registry so freshly-installed tools resolve right away.
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Install-Chocolatey {
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Ok "Chocolatey already installed"
        return
    }

    Write-Log "Installing Chocolatey (official bootstrap script from community.chocolatey.org)..."

    # Mirrors the install snippet at https://chocolatey.org/install — we need
    # the TLS-1.2 bump for older default .NET configs and Bypass scope so the
    # script runs even if the user has a restrictive ExecutionPolicy.
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString(
        'https://community.chocolatey.org/install.ps1'))

    Update-SessionPath

    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Fail @"
Chocolatey install completed but `choco` is not on PATH in this session.
Open a new elevated PowerShell and re-run this script — the new shell
will inherit the updated PATH.
"@
    }
    Write-Ok "Chocolatey installed"
}

function Invoke-ChocoInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall)"
        return
    }
    if (-not $script:NeedsChocoInstall) {
        # Preflight already determined there's nothing to install (or only
        # optional packages are missing in a non-elevated session). Nothing
        # to do here.
        Write-Log "No Chocolatey packages to install"
        return
    }

    Install-Chocolatey

    Write-Log "Installing tools via Chocolatey..."

    foreach ($tool in $ChocoTools) {
        # Skip ones that are already installed by any means — keeps the log
        # scannable on partially-installed machines.
        if (Test-ToolInstalled -Tool $tool) {
            Write-Ok "$($tool.Name) already installed"
            continue
        }

        # Orphan detection: choco's local DB might still list this package
        # even though the binary's gone (interrupted install, manual delete,
        # etc.). Plain `choco install` would say "already installed" and
        # skip, leaving us broken. Detect this state and reinstall with -f.
        $forceFlag = $null
        $listOut = choco list --exact $tool.Id --limit-output 2>$null
        if ($listOut -and ($listOut -match "^$([regex]::Escape($tool.Id))\|")) {
            Write-Warn "$($tool.Name) is registered with choco but its binary isn't on PATH — re-installing with --force"
            $forceFlag = "--force"
        }

        Write-Log "Installing $($tool.Name) ($($tool.Id))..."

        # -y / --no-progress / --limit-output: scriptable, scannable output.
        # --force only used when orphan was detected above.
        if ($forceFlag) {
            choco install $tool.Id -y --no-progress --limit-output $forceFlag
        } else {
            choco install $tool.Id -y --no-progress --limit-output
        }

        if ($LASTEXITCODE -ne 0) {
            if ($tool.Required) {
                Write-Fail "$($tool.Name) install failed — required tool, cannot continue."
            } else {
                Write-Warn "$($tool.Name) install failed (choco exit $LASTEXITCODE) — skipping; install manually if needed."
            }
            continue
        }
        Write-Ok "$($tool.Name) installed"
    }

    Update-SessionPath
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
        Write-Warn "chezmoi not on PATH after install. Open a new elevated shell and re-run, or install manually:"
        Write-Warn "  choco install -y chezmoi"
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
# 5. WEZTERM HARDLINK — restore the live-reload link to the chezmoi source.
#    chezmoi writes a regular file at the target path; replacing it with a
#    hardlink lets edits to chezmoi/dot_config/wezterm/wezterm.lua (e.g. from
#    manage-hosts --sync) appear in WezTerm immediately via
#    automatically_reload_config, without needing a `chezmoi apply` after
#    every edit.
# =============================================================================
function Invoke-WeztermHardlink {
    $source = Join-Path $RepoPath "chezmoi\dot_config\wezterm\wezterm.lua"
    $target = "$env:USERPROFILE\.config\wezterm\wezterm.lua"

    if (-not (Test-Path $source)) {
        Write-Warn "Skipping wezterm hardlink — chezmoi source not found at $source"
        return
    }

    $targetDir = Split-Path $target -Parent
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }

    # Always re-create. New-Item -ItemType HardLink fails if the target
    # already exists, so we delete first. This is idempotent: if the existing
    # target was already a correct hardlink, the new one shares the same
    # inode anyway — content is identical, and any other hardlink siblings
    # to the source are unaffected (the source inode persists).
    if (Test-Path $target) {
        Remove-Item $target -Force
    }

    Write-Log "Hardlinking wezterm.lua to chezmoi source..."
    New-Item -ItemType HardLink -Path $target -Target $source | Out-Null
    Write-Ok "Hardlinked: $target -> $source"
}

# =============================================================================
# 6. SSH KEY (optional, prompt-driven)
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
Invoke-ChocoInstall      # before clone — installs git if the machine doesn't have one
Invoke-CloneRepo
Invoke-Chezmoi
Invoke-WeztermHardlink   # after chezmoi apply — restore the live-reload link
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
