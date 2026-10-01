# =============================================================================
# bootstrap.ps1 -- workstation setup (Windows client side)
#
# No admin rights needed: installs the pinned mise per-user
# (%LOCALAPPDATA%\workstation) and the GUI apps through winget ($WingetApps),
# then runs `mise bootstrap --only dotfiles,tools` to deploy the tracked
# dotfiles and install every CLI tool those files declare. Windows is
# always the `owned` mode (miserc.toml: windows,owned). Git is a
# hard prerequisite (install it yourself); VSCode is hand-installed --
# its dotfiles still deploy without it.
#
# ONE exception to "no admin": the machine-scope $WingetApps (Zed, and
# SSHFS-Win with its WinFsp kernel driver) can pop a UAC prompt on first
# install. Declining it (or -SkipElevated) soft-fails only those apps.
#
# Public repo, no token needed. $env:GITHUB_TOKEN is optional: used for a
# private-fork clone; mise also uses it to lift the 60-req/hr GitHub API limit.
#
# Bootstrap a fresh machine (no elevation needed) -- the checked curl.exe
# download, same form as README.md's Windows setup:
#   $bootstrapFile = [System.IO.Path]::GetTempFileName()
#   try {
#       $curl = Get-Command curl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
#       & $curl.Source --disable --fail --silent --show-error --location --retry 3 --retry-delay 2 --connect-timeout 30 `
#         --output $bootstrapFile `
#         https://raw.githubusercontent.com/ArrushC/workstation/main/bootstrap.ps1
#       if ($LASTEXITCODE -ne 0) { throw "Bootstrap download failed (curl exit $LASTEXITCODE)" }
#       $bootstrap = [System.IO.File]::ReadAllText($bootstrapFile, [System.Text.Encoding]::UTF8)
#       & ([scriptblock]::Create($bootstrap))
#   } finally {
#       Remove-Item -LiteralPath $bootstrapFile -Force
#   }
#
# Or clone + run:
#   git clone https://github.com/ArrushC/workstation.git "$env:USERPROFILE\.config\mise"
#   cd "$env:USERPROFILE\.config\mise"; .\bootstrap.ps1
#
# Flags (see param() below): -RepoPath -SkipKeyGen -SkipToolInstall
#   -SkipDotfiles -SkipBurntToast -SkipNerdFonts -SkipElevated -Reinstall -Yes
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoPath = (Join-Path $env:USERPROFILE ".config\mise"),
    [switch]$SkipKeyGen,       # skip the SSH-key generation prompt
    [switch]$SkipToolInstall,  # skip mise, the mise tools, the winget GUI apps, the Python env + Claude Code
    [switch]$SkipDotfiles,     # clone + install tools but don't apply dotfiles yet
    [switch]$SkipBurntToast,   # skip the BurntToast PSGallery module install
    [switch]$SkipNerdFonts,    # skip the Nerd Font install
    [switch]$SkipElevated,     # skip the machine-scope winget apps, Zed + SSHFS-Win (the only UAC prompts)
    [switch]$Reinstall,        # wipe the cloned repo, then re-bootstrap (prompts unless -Yes)
    [switch]$Yes               # skip confirmation prompts (-Reinstall)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# CONSTANTS & TOOL TABLES -- repo/install paths, the mise pin and the
# winget app table everything below reads from.
# =============================================================================

$DotfilesRepo = "https://github.com/ArrushC/workstation.git"
$SshKey       = "$env:USERPROFILE\.ssh\id_ed25519"

# Token persisted into .git/config under this key — scoped to github.com so
# it never leaks to other remotes.
$GhHeaderKey = "http.https://github.com/.extraheader"

# Per-user install root for what this script provisions itself. Admin-free:
#   workstation\mise    — the pinned mise (bin\mise.exe + mise-shim.exe) → bin\ on User PATH
#   workstation\bin     — the python-env launchers (wpy/textual/typer)    → on User PATH
#   workstation\stamps  — idempotency markers
# Every CLI tool comes from config*.toml through mise (%LOCALAPPDATA%\mise).
$WsRoot   = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin    = Join-Path $WsRoot "bin"
$WsMise   = Join-Path $WsRoot "mise"
$WsStamps = Join-Path $WsRoot "stamps"

# mise is the one tool this script pins itself: everything else comes from
# config*.toml through mise. Triple-edit with MISE_VERSION in bootstrap.sh and
# min_version in config.toml (scripts/check-invariants.sh checks it).
$MiseVersion = "2026.9.9"
$MiseSha256  = "f758ee4afe061cccd4587c0108c147209a7cb2372704909a8b9d5e230203ec07"
$MiseUrl     = "https://github.com/jdx/mise/releases/download/v$MiseVersion/mise-v$MiseVersion-windows-x64.zip"
$MiseShims   = Join-Path $env:LOCALAPPDATA "mise\shims"
$MiseEnvTokens = @("windows", "owned")

# --- Blessed Python scripting env (Invoke-PythonEnv) -------------------------
# DUAL-EDIT: $PythonEnvVersion pairs with tools.python in config.toml;
# $PythonLibs pairs with PY_LIBS in scripts/lib/python-env.sh. KEEP EACH ON ONE
# LINE — scripts/check-invariants.sh parses both with single-line greps.
$PythonEnvVersion = "3.14.7"
$PythonLibs = @("textual", "textual-dev", "click", "rich", "httpx", "pydantic", "typer", "polars", "duckdb")
$WsPythonEnv = Join-Path $WsRoot "python-env"

# GUI apps, installed through winget and then self-updating (or `winget upgrade`).
# Presence = Uninstall-registry DisplayName glob (Test-InstallerPresent): it also
# sees copies installed before winget managed them (e.g. "DevToys Preview"),
# which `winget list` misses. Windows Terminal is an Appx package. Zed's Detect
# is exact, so "Zed Preview"/"Zed Nightly" don't count.
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

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

# --- ANSI escape codes -------------------------------------------------------
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

# =============================================================================
# HTTP HELPER
# =============================================================================

# Kept self-contained: bootstrap also runs from memory before the repo exists.
# The font script carries the same helper for its independent execution context.
function Invoke-CurlRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$OutFile
    )

    # Get-Command lists EVERY curl.exe on PATH (System32 + Git's mingw64\bin is
    # the everyday case) - take the first, i.e. the one a bare `curl.exe` runs.
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl) {
        throw 'curl.exe is required on PATH. Restore the Windows system curl or install it from https://curl.se/windows/ and reopen your shell.'
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    $headerFile = $null
    try {
        # --speed-limit/--speed-time: a connected-but-stalled transfer aborts
        # (exit 28, which --retry treats as transient) instead of hanging forever.
        $curlArgs = @('--disable', '--fail', '--silent', '--show-error', '--location',
            '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30',
            '--speed-limit', '1', '--speed-time', '60',
            '--output', $tempFile)
        if ($Headers.Count -gt 0) {
            # Headers travel via a file, never argv: a PAT on a command line is
            # visible to process auditing. One header per line; no BOM, or curl
            # would send it as part of the first header name.
            $headerFile = [System.IO.Path]::GetTempFileName()
            $headerLines = @(foreach ($key in $Headers.Keys) { '{0}: {1}' -f $key, $Headers[$key] })
            [System.IO.File]::WriteAllLines($headerFile, [string[]]$headerLines, [System.Text.UTF8Encoding]::new($false))
            $curlArgs += @('--header', "@$headerFile")
        }
        $curlArgs += @('--url', $Uri)
        # PS 5.1 can turn redirected native stderr into PowerShell errors;
        # PS 7 can optionally throw on native exit codes. Handle both ourselves.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $curlOutput = & $curl.Source @curlArgs 2>&1
        $curlExitCode = $LASTEXITCODE
        if ($curlExitCode -ne 0) {
            # --silent --show-error leaves only curl's own diagnostic on stderr
            # (e.g. "curl: (22) The requested URL returned error: 404"); surface it.
            $detail = ((@($curlOutput) | ForEach-Object { "$_".Trim() }) -join ' ').Trim()
            throw "curl.exe request failed (exit $curlExitCode): $Uri [$detail]"
        }
        if ($OutFile) {
            Move-Item -LiteralPath $tempFile -Destination $OutFile -Force -ErrorAction Stop
        } else {
            [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8)
        }
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        if ($headerFile) { Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue }
    }
}

# =============================================================================
# PATH HELPERS
# =============================================================================

# User-scope environment variables. One seam, so scripts/test-mise-env.ps1 can
# stub them (a static .NET method can't be); $null as the value deletes.
function Get-UserEnv { param([string]$Name) [Environment]::GetEnvironmentVariable($Name, "User") }
function Set-UserEnv { param([string]$Name, $Value) [Environment]::SetEnvironmentVariable($Name, $Value, "User") }

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

# =============================================================================
# INSTALL FUNCTIONS
# =============================================================================

# Invoke-Reinstall -- wipe the cloned repo, then let the rest of the script
# re-bootstrap fresh. Installed tools + deployed dotfiles are left alone.
function Invoke-Reinstall {
    Write-Log "Reinstall mode — wipe + re-bootstrap"
    Write-Host ""
    Write-Host "  Will REMOVE:"
    Write-Host "    - $RepoPath  (cloned workstation repo)"
    Write-Host ""
    Write-Host "  Will NOT remove (leaving for re-bootstrap to no-op over):"
    Write-Host "    - mise under $WsRoot and its tools (re-bootstrap detects + skips them)"
    Write-Host "    - Deployed dotfiles in `$HOME / `$env:APPDATA (the mise dotfiles+tools bootstrap will re-apply)"
    Write-Host "    - SSH keys"
    Write-Host ""
    Write-Host "  For a deeper uninstall (remove mise too), do that manually first:"
    Write-Host "    Remove-Item -Recurse -Force '$WsRoot'   # mise re-downloads next run"
    Write-Host ""

    # Self-deletion guard: if this script is being run from inside the path we're
    # about to delete, refuse. Use the checked curl.exe download form instead, which runs
    # from memory and isn't backed by a file on disk. $PSCommandPath is $null
    # when the script is executed from a string (a scriptblock).
    if ($PSCommandPath -and $PSCommandPath.StartsWith($RepoPath, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Fail @"
Refusing to reinstall — the running script is inside $RepoPath, which would
be deleted, leaving this invocation orphaned. Either:

  1. Use the checked curl.exe download from README.md with -Reinstall.
     It runs from memory after the complete download succeeds.

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

    Write-Host ""
    Write-Log "Wipe complete — continuing with fresh bootstrap..."
    Write-Host ""
}

# Git is a hard prerequisite; mise presence only matters when
# -SkipToolInstall is set and the dotfiles+tools step will run;
# ssh-keygen soft-warns. No admin check needed.
function Invoke-Preflight {
    Write-Log "Checking prerequisites..."
    $curlCmd = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curlCmd) {
        Write-Fail 'curl.exe is required on PATH. Restore the Windows system curl or install it from https://curl.se/windows/ and reopen your shell.'
    }
    Write-Ok "curl.exe found ($($curlCmd.Source))"

    # Git is a hard prerequisite — you install it yourself. Needed for the
    # clone and for git operations mise performs against this same checkout
    # (mise tracks dotfiles history in it). This script does NOT install Git.
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

    # mise is installed by the tool step unless skipped. If -SkipToolInstall
    # is set and the dotfiles+tools bootstrap step will run, mise must already
    # be present.
    if ($SkipToolInstall -and -not $SkipDotfiles -and -not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Fail @"
-SkipToolInstall was passed but mise isn't on PATH and the dotfiles+tools
bootstrap step will run. Either drop -SkipToolInstall (so the script installs
mise), pass -SkipDotfiles (skip the dotfiles+tools bootstrap), or install mise
yourself first.
"@
    }

    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Warn "ssh-keygen not on PATH — install OpenSSH client to enable the SSH-key step:"
        Write-Warn "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    }

    Write-Ok "Prerequisites OK"
}

# An update renames the old bin\mise.exe and mise-shim.exe to *.old instead
# of deleting them: every shim (WT's Nushell too, via mise\shims\nu.exe) runs
# mise.exe, and Windows can rename a running image but not delete or
# overwrite it. Leftover *.old files go on a later run, once nothing runs them.
function Install-Mise {
    $binDir  = Join-Path $WsMise "bin"
    $miseExe = Join-Path $binDir "mise.exe"
    $stamp   = Join-Path $WsStamps "mise.$MiseVersion.stamp"
    Get-ChildItem -Path $binDir -Filter "*.old" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    if ((Test-Path $stamp) -and (Test-Path $miseExe)) {
        Add-ToUserPath $binDir
        Write-Ok "mise $MiseVersion already installed"
        return
    }
    Write-Log "Installing mise $MiseVersion..."
    $zip = Join-Path $env:TEMP "ws-mise-$MiseVersion.zip"
    $tmp = Join-Path $env:TEMP "ws-mise-$MiseVersion"
    $moved = New-Object System.Collections.Generic.List[object]
    try {
        try {
            Invoke-CurlRequest -Uri $MiseUrl -OutFile $zip
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower()
            if ($actual -ne $MiseSha256) { throw "sha256 mismatch: got $actual, pinned $MiseSha256" }
        } catch {
            # An older mise keeps the host working; only a host with none stops.
            if (Test-Path $miseExe) {
                Add-ToUserPath $binDir
                Write-Warn "mise $MiseVersion not installed ($($_.Exception.Message)) -- continuing on the installed mise; re-run .\bootstrap.ps1 to retry"
                return
            }
            Write-Fail "mise $MiseVersion download failed ($($_.Exception.Message)) and no mise is installed -- check network access to github.com, then re-run .\bootstrap.ps1"
        }
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $top = @(Get-ChildItem -Path $tmp)
        $src = if (($top.Count -eq 1) -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmp }
        try {
            foreach ($name in @("mise.exe", "mise-shim.exe")) {
                $exe = Join-Path $binDir $name
                if (Test-Path -LiteralPath $exe) {
                    $old = Join-Path $binDir "$name.$([guid]::NewGuid().ToString('N')).old"
                    Move-Item -LiteralPath $exe -Destination $old
                    $moved.Add(@{ From = $exe; To = $old })
                }
            }
            New-Item -ItemType Directory -Force -Path $WsMise | Out-Null
            Copy-Item -Path (Join-Path $src '*') -Destination $WsMise -Recurse -Force
        } catch {
            # Put the old exes back so the host keeps a working mise.
            foreach ($m in $moved) {
                if (-not (Test-Path -LiteralPath $m.From)) { Move-Item -LiteralPath $m.To -Destination $m.From -ErrorAction SilentlyContinue }
            }
            Write-Fail "Could not update mise in $WsMise ($($_.Exception.Message)) -- close Nushell tabs and editors started through mise shims, then re-run .\bootstrap.ps1 from a Windows PowerShell window"
        }
        Add-ToUserPath $binDir
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "mise $MiseVersion installed to $WsMise"
    } finally {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# One-time cleanup of the pre-mise portable installs (remove once every
# Windows host has run it): their PATH entries sat ahead of mise's shims.
# Only the old tools' own stamps go; wslconfig.*, node-postinstall.* and
# python-env.* stamps are live markers. Runs after a successful tools phase
# (Invoke-MiseBootstrap), so a failed bootstrap keeps the old tools.
function Invoke-LegacyToolCleanup {
    $old = @("helix", "nu", "devtoys-cli", "dngrep", "logexpert") | ForEach-Object { Join-Path $WsRoot $_ }
    $oldExes = @("starship", "gh", "jq", "omp", "opencode", "chezmoi") | ForEach-Object { Join-Path $WsBin "$_.exe" }
    $userPath = Get-UserEnv "Path"
    if ($userPath) {
        $kept = @($userPath -split ';' | Where-Object { $_ -and ($old -notcontains $_.TrimEnd('\')) })
        $newPath = $kept -join ';'
        if ($newPath -ne $userPath) {
            Set-UserEnv "Path" $newPath
            Write-Ok "removed old portable-tool directories from the User PATH"
        }
    }
    foreach ($d in $old) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
    foreach ($exe in $oldExes) { Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue }
    $left = @(@($old) + @($oldExes) | Where-Object { Test-Path -LiteralPath $_ })
    if ($left.Count -gt 0) {
        Write-Warn "old portable tools still present (in use?): $($left -join ', ') -- close it and re-run .\bootstrap.ps1"
    }
    Get-ChildItem -Path $WsStamps -Filter "*.stamp" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(starship|gh|hx|nu|jq|opencode|omp|DevToys\.CLI|dnGREP|LogExpert|uv|chezmoi|mise-runtimes)\.' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
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

# Install each missing $WingetApps entry with winget (its manifest pins the
# installer's sha256). Best-effort: a failed install warns and the loop goes
# on. -SkipElevated skips the machine-scope apps, the only UAC prompts.
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
        # PS 5.1 can turn a native command's stderr into a terminating error under "Stop".
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & winget install --id $app.Id --exact --scope $app.Scope --silent --disable-interactivity --accept-package-agreements --accept-source-agreements
        $code = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
        if ($code -eq 0) { Write-Ok "$($app.Name) installed" } else { Write-Warn "$($app.Name): winget exited $code — install it later with: winget install --id $($app.Id)" }
    }
}

function Invoke-ToolInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall) — no mise install, GUI apps ($(@($WingetApps | ForEach-Object { $_.Name }) -join ', ')), mise tools, Python env or Claude Code"
        return
    }

    foreach ($d in @($WsRoot, $WsBin, $WsStamps)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    Install-Mise
    Add-ToUserPath $WsBin   # python-env's wpy/textual/typer launchers
    Install-WingetApps      # machine-scope (UAC) entries come last in the table

    Update-SessionPath

    # Soft-warn for the hand-installed editor (VSCode). Zed is installed from
    # $WingetApps above; VSCode's dotfiles config deploys regardless, and the
    # script never installs or fails on it.
    foreach ($app in @(@{ Cmd = 'code'; Name = 'VSCode' })) {
        if (-not (Get-Command $app.Cmd -ErrorAction SilentlyContinue)) {
            Write-Warn "$($app.Name) not on PATH — install it yourself when you want it; its dotfiles still deploy."
        }
    }
}

# =============================================================================
# REPO & MISE FUNCTIONS
# =============================================================================

# Clone the workstation repo (public; optional $env:GITHUB_TOKEN for a private fork).
function Invoke-CloneRepo {
    # HTTP Basic with base64-encoded "x-access-token:<PAT>" — same scheme
    # actions/checkout uses. "Authorization: bearer" works for the REST/raw API
    # (how curl.exe fetches bootstrap.ps1) but is NOT accepted by git's smart-HTTP
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
                Write-Fail "Clone failed. Check network access to github.com, and that `$env:GITHUB_TOKEN is a valid PAT (it is only needed for a private fork)."
            }
            git -C $RepoPath config $GhHeaderKey $headerVal
        } else {
            git clone $DotfilesRepo $RepoPath
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "Clone failed. Check network access to github.com (a private fork also needs `$env:GITHUB_TOKEN set to a PAT with repo read)."
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

# First-apply marker; the name predates mise and stays so existing hosts don't re-force.
$MigratedMarker = Join-Path $WsRoot "dotfiles-migrated"

# The token set lives in miserc.toml (git-ignored), like on Linux; nothing
# exports MISE_ENV. An exported value would override miserc, so the old User
# variable is removed here and in this session.
function Initialize-MiseEnv {
    $rc = Join-Path $RepoPath "miserc.toml"
    $envList = ($MiseEnvTokens | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $body = "# Written by bootstrap.ps1 (Windows is always owned).`nenv = [$envList]`nauto_env = false`n"
    [System.IO.File]::WriteAllText($rc, $body, [System.Text.UTF8Encoding]::new($false))
    if (Get-UserEnv "MISE_ENV") {
        Set-UserEnv "MISE_ENV" $null
        Write-Ok "removed the old User MISE_ENV variable (miserc.toml replaces it)"
    }
    Remove-Item Env:MISE_ENV -ErrorAction SilentlyContinue
}

function Set-ConfigLocalVar {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $escaped = $Value -replace '\\', '\\' -replace '"', '\"'
    $line = "$Key = `"$escaped`""
    # @() keeps an empty or one-line file an array; a bare if-expression
    # unrolls to $null or a string, and .Count on those throws under StrictMode.
    $lines = @(if (Test-Path -LiteralPath $Path) { [System.IO.File]::ReadAllText($Path) -split "`r?`n" })
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        # PowerShell's 0..-1 counts down, so a one-element array needs its own case.
        $lines = @(if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] })
    }
    $out = New-Object System.Collections.Generic.List[string]
    $inVars = $false; $seen = $false; $done = $false
    # Same tolerance as bootstrap.sh's config_set: a spaced or commented
    # [vars] header and indented keys; any other [ header leaves the table.
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    foreach ($l in $lines) {
        if ($l -match '^\s*\[') {
            if ($inVars -and -not $done) { $out.Add($line); $done = $true }
            $inVars = $l -match '^\s*\[\s*vars\s*\]\s*(#.*)?$'; if ($inVars) { $seen = $true }
            $out.Add($l); continue
        }
        if ($inVars -and $l -match $keyPattern) {
            if (-not $done) { $out.Add($line); $done = $true }
            continue
        }
        $out.Add($l)
    }
    if (-not $done) { if (-not $seen) { $out.Add('[vars]') }; $out.Add($line) }
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, (($out -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Windows is always an owned host (no shared mode here). Name/email are asked
# once, interactively; a non-interactive run leaves them for the user to add.
function Invoke-EnsureConfigLocal {
    $target = Join-Path $RepoPath "config.local.toml"
    Set-ConfigLocalVar -Path $target -Key 'mode' -Value 'owned'
    $text = [System.IO.File]::ReadAllText($target)
    $hasName = $text -match '(?m)^[ \t]*name[ \t]*='
    $hasEmail = $text -match '(?m)^[ \t]*email[ \t]*='
    if ($hasName -and $hasEmail) {
        Write-Ok "config.local.toml ready ($target, mode = owned)"
        return
    }
    if ($SkipToolInstall -or [Console]::IsInputRedirected) {
        Write-Warn "No interactive console — add [vars] name / email to $target for git commits."
        return
    }
    Write-Log "First-time setup -- name/email for git commits and the SSH config comment..."
    # An empty answer writes nothing (like bootstrap.sh), so the next run asks again.
    if (-not $hasName) { $answer = Read-Host "  Name"; if ($answer) { Set-ConfigLocalVar -Path $target -Key 'name' -Value $answer; $hasName = $true } }
    if (-not $hasEmail) { $answer = Read-Host "  Email"; if ($answer) { Set-ConfigLocalVar -Path $target -Key 'email' -Value $answer; $hasEmail = $true } }
    if ($hasName -and $hasEmail) {
        Write-Ok "name/email saved to $target"
    } else {
        Write-Warn "name/email incomplete -- add them to $target ([vars] name / email) for git commits; the next run asks again."
    }
}

function Invoke-WslConfigReminder {
    # mise has no run_onchange_* equivalent, and .wslconfig only takes effect
    # after `wsl --shutdown` restarts every distro -- so remind the user only
    # when the deployed content actually changed. Hashes the REPO source
    # (dotfiles/wslconfig): a matching stamp file means "unchanged"; no
    # match means the hash moved, so the reminder fires and a fresh stamp
    # is written.
    $source = Join-Path $RepoPath "dotfiles\wslconfig"
    if (-not (Test-Path -LiteralPath $source)) { return }

    $hash  = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash.Substring(0, 8).ToLower()
    $stamp = Join-Path $WsStamps "wslconfig.$hash.stamp"
    if (Test-Path -LiteralPath $stamp) { return }

    if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
    Get-ChildItem -Path $WsStamps -Filter "wslconfig.*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    New-Item -ItemType File -Force -Path $stamp | Out-Null

    Write-Host ""
    Write-Warn ".wslconfig changed -- run 'wsl --shutdown' from a Windows terminal"
    Write-Warn "for the new WSL2 settings to take effect (restarts all distros)."
}

# Invoke-MiseBootstrap -- `mise bootstrap --only dotfiles,tools` applies the
# [dotfiles] entries (config.toml/config.owned.toml/config.windows.toml) to
# %USERPROFILE% AND installs every tool those same files declare, in one
# call; `--only` skips [bootstrap.files] entirely, so no sudo-only /etc
# entry can ever fire here. -SkipDotfiles drops the dotfiles phase and
# -SkipToolInstall the tools phase (and the post-tools steps below).
#
# The first dotfiles apply on this host can find targets already on disk as
# real files, and template/copy modes refuse to overwrite one that differs
# -- so that FIRST apply passes --force-dotfiles (mirrors bootstrap.sh's own
# apply()). Passed only until $MigratedMarker exists, so a later real
# conflict still surfaces loudly.
#
# Before it, a guard: config.owned.toml must be loaded (miserc.toml honoured).
# After a successful tools phase: the pre-mise portable installs are removed
# (Invoke-LegacyToolCleanup), then, as scripts/lib/mise-install.sh does on
# Linux: the shims dir joins the User PATH and this session (jq, starship,
# nu and uv resolve for the steps after this); node is force-reinstalled
# once when its declaration changed, because mise re-runs node's npm
# postinstall (the language servers) only on a (re)install; prune + reshim.
function Invoke-MiseBootstrap {
    $phases = @()
    if (-not $SkipDotfiles) { $phases += 'dotfiles' }
    if (-not $SkipToolInstall) { $phases += 'tools' }
    if ($phases.Count -eq 0) {
        Write-Log "mise bootstrap skipped (-SkipDotfiles -SkipToolInstall)"
        return
    }

    Initialize-MiseEnv

    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Warn "mise not on PATH after install. Open a new shell and re-run, or install manually from https://mise.jdx.dev/installing-mise.html"
        return
    }

    $forceFlags = @()
    if (-not $SkipDotfiles) {
        # config.local.toml must exist BEFORE the dotfiles apply below -- the
        # Tera templates guard every vars.* reference, but a real value still
        # shapes the rendered git identity.
        Invoke-EnsureConfigLocal
        if (-not (Test-Path -LiteralPath $MigratedMarker)) {
            $forceFlags = @('--force-dotfiles')
            Write-Log "First dotfiles apply on this host -- passing --force-dotfiles (marker absent: $MigratedMarker)"
        }
    }

    # Every mise call runs from %USERPROFILE% (-C), as the ws* commands do,
    # so a project mise.toml in the caller's cwd can't change what resolves.
    # Native stderr must not trip EAP=Stop (PS 5.1 wraps it as errors).
    $miseCd = @('-C', $env:USERPROFILE)

    # miserc.toml must have selected the owned set: without config.owned.toml
    # the tools phase would skip the owned tools and `mise prune` would
    # delete them. (--json: the table output truncates to the console width.)
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $loaded = (@(& mise @miseCd config ls --json 2>&1) | ForEach-Object { "$_" }) -join "`n"
    $ErrorActionPreference = $oldEap
    if ($loaded -notmatch 'config\.owned\.toml') {
        Write-Fail "mise did not load config.owned.toml, so miserc.toml (windows,owned) was not honoured -- an exported MISE_ENV, or -RepoPath outside %USERPROFILE%\.config\mise? Stopping before mise bootstrap/prune could remove the owned tools; 'mise -C `$env:USERPROFILE config ls' shows what loaded."
    }

    # `mise where node` succeeds only when the DECLARED node is installed.
    $hadNode = $false
    if (-not $SkipToolInstall) {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        & mise @miseCd where node *> $null
        $hadNode = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $oldEap
    }

    $onlyPhases = $phases -join ','
    Write-Log "Running mise bootstrap --only $onlyPhases (source: $RepoPath)..."
    $bootstrapArgs = $miseCd + @('bootstrap', '--only', $onlyPhases, '--yes') + $forceFlags
    & mise @bootstrapArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail @"
mise bootstrap (--only $onlyPhases) failed -- see the failing phase above.

A dotfiles conflict aborts the WHOLE dotfiles phase (one bad entry blocks
every entry -- nothing gets applied). If the failure names a target that
already exists as a real file:
  1. resolve that one entry directly:  mise dot apply --force <the path mise named above>
  2. then re-run:                      .\bootstrap.ps1
Any other failure (the tools phase) is idempotent to retry -- fix what's
reported above and re-run.
"@
    }
    Write-Ok "mise bootstrap (--only $onlyPhases) complete"

    if (-not $SkipDotfiles -and -not (Test-Path -LiteralPath $MigratedMarker)) {
        $markerDir = Split-Path $MigratedMarker -Parent
        if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Force -Path $markerDir | Out-Null }
        New-Item -ItemType File -Force -Path $MigratedMarker | Out-Null
        Write-Ok "dotfiles first-apply marker written ($MigratedMarker) -- future runs no longer force-reclaim dotfiles targets"
    }

    if (-not $SkipToolInstall) {
        # The old portable installs go only now that mise's tools are in.
        Invoke-LegacyToolCleanup
        Add-ToUserPath $MiseShims
        Update-SessionPath
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & mise @miseCd where node *> $null
            if ($LASTEXITCODE -eq 0) {
                # Marker = node's declaration hashed (-f: a bare `mise config get`
                # reads only the highest-precedence file, config.windows.toml).
                # An unreadable declaration forces the reinstall and writes no
                # marker, so the next run retries.
                $decl = (@(& mise @miseCd config get -f (Join-Path $RepoPath "config.owned.toml") tools.node 2>$null) -join "`n").Trim()
                $marker = $null
                if (($LASTEXITCODE -eq 0) -and $decl) {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($decl)
                    $stream = New-Object System.IO.MemoryStream (,$bytes)
                    $sum = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.Substring(0, 16).ToLower()
                    $marker = Join-Path $WsStamps "node-postinstall.$sum.stamp"
                } else {
                    Write-Warn "could not read tools.node from config.owned.toml -- forcing the node reinstall so its npm postinstall can't be skipped"
                }
                $nodeOk = $true
                if ($hadNode -and -not ($marker -and (Test-Path -LiteralPath $marker))) {
                    Write-Log "node already installed but its declaration changed -- reinstalling so its npm postinstall (the language servers) re-runs"
                    # Streamed, and kept in $forceOut to spot Windows' file-lock error.
                    $forceOut = @()
                    & mise @miseCd install --yes --force node 2>&1 | ForEach-Object { "$_" } | Tee-Object -Variable forceOut | Out-Host
                    $forceExit = $LASTEXITCODE
                    if ($forceExit -ne 0) {
                        $nodeOk = $false
                        if ((@($forceOut) -join "`n") -match 'os error 32|being used by another process') {
                            Write-Warn "node is in use (an editor's language server, a dev server, an agent) -- close running node processes and re-run .\bootstrap.ps1"
                        } else {
                            Write-Warn "mise install --force node exited $forceExit (output above) -- re-run .\bootstrap.ps1 to retry"
                        }
                    } else {
                        Write-Ok "node reinstalled (language servers refreshed)"
                    }
                }
                if ($nodeOk -and $marker) {
                    Get-ChildItem -Path $WsStamps -Filter "node-postinstall.*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force
                    New-Item -ItemType File -Force -Path $marker | Out-Null
                }
            }
            & mise @miseCd prune --yes
            if ($LASTEXITCODE -ne 0) { Write-Warn "mise prune exited $LASTEXITCODE (non-fatal)" }
            & mise @miseCd reshim
            if ($LASTEXITCODE -ne 0) { Write-Warn "mise reshim exited $LASTEXITCODE (non-fatal)" }
        } finally {
            $ErrorActionPreference = $oldEap
        }
    }

    if (-not $SkipDotfiles) { Invoke-WslConfigReminder }
}

# =============================================================================
# SHELL / TERMINAL INTEGRATION
# =============================================================================

# Bridges Documents redirection (OneDrive): $PROFILE then resolves to the
# redirected dir, but the dotfiles apply writes the canonical profile to
# the LITERAL %USERPROFILE%\Documents\PowerShell, so PowerShell would never
# load it. Drops a tiny loader at the real $PROFILE dir(s) that dot-sources
# the canonical one. No-op when Documents isn't redirected.
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
# redirection), so PowerShell loads $PROFILE from here. Source the
# dotfiles-managed canonical profile at the literal %USERPROFILE%\Documents.
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
            $bak = "$target.pre-dotfiles.bak"
            if (-not (Test-Path $bak)) { Copy-Item $target $bak -Force; Write-Warn "Backed up existing $sub profile to $bak" }
        }
        Set-Content -Path $target -Value $loader -Encoding UTF8
        Write-Ok "Profile loader installed: $target"
    }
    Write-Warn "Restart PowerShell to pick up the managed profile."
}

# Full path of <Exe> in a mise tool's install dir (`mise where <Tool>`), or
# $null when mise, the tool or the exe is missing. The dir is versioned.
function Get-MiseToolExe {
    param([string]$Tool, [string]$Exe)
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) { return $null }
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& mise -C $env:USERPROFILE where $Tool 2>$null); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $oldEap }
    if (($code -ne 0) -or ($out.Count -eq 0) -or -not "$($out[0])".Trim()) { return $null }
    $path = Join-Path "$($out[0])".Trim() $Exe
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

# The GUI zips mise installs (dnGrep, LogExpert) ship no Start Menu
# shortcut, so each gets a per-user "<Name>.lnk" to the exe in its mise
# install dir. Fixed filename per app -> idempotent + duplicate-proof; runs
# every bootstrap (self-heals a deleted shortcut, follows a version bump's
# new install dir). Soft-fails per app.
$MiseShortcuts = @(
    @{ Name = "dnGrep"; Tool = "github:dnGrep/dnGrep"; Exe = "dnGREP.exe"; Description = "dnGrep — search and replace in files (grep GUI)" },
    @{ Name = "LogExpert"; Tool = "github:LogExperts/LogExpert"; Exe = "LogExpert.exe"; Description = "LogExpert — tabbed log-file viewer with tail-follow" }
)
function Invoke-StartMenuShortcuts {
    foreach ($tool in $MiseShortcuts) {
        $exe = Get-MiseToolExe -Tool $tool.Tool -Exe $tool.Exe
        if (-not $exe) {
            Write-Warn "Skipping $($tool.Name) Start Menu shortcut — $($tool.Exe) not found via 'mise where $($tool.Tool)'."
            continue
        }

        # Fixed filename in the per-user Start Menu Programs folder (no admin). The
        # deterministic path is what makes this duplicate-proof: .Save() overwrites.
        $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) "$($tool.Name).lnk"

        try {
            $existed = Test-Path $lnk
            $wsh = New-Object -ComObject WScript.Shell
            try {
                # CreateShortcut loads the existing .lnk when present, so its current
                # TargetPath is readable — skip the rewrite when it already matches.
                $sc = $wsh.CreateShortcut($lnk)
                if ($existed -and ($sc.TargetPath -eq $exe)) {
                    Write-Ok "$($tool.Name) Start Menu shortcut already present"
                    continue
                }
                $sc.TargetPath       = $exe
                $sc.WorkingDirectory = $env:USERPROFILE
                $sc.Description       = $tool.Description
                $sc.Save()
                if ($existed) {
                    Write-Ok "$($tool.Name) Start Menu shortcut updated (target: $exe)"
                } else {
                    Write-Ok "$($tool.Name) Start Menu shortcut created at $lnk"
                }
            } finally {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
            }
        } catch {
            Write-Warn "Could not create the $($tool.Name) Start Menu shortcut: $($_.Exception.Message)"
        }
    }
}

# SSH host launchers: every concrete Host alias in the untracked
# ~\.ssh\config.local becomes an "SSH: <alias>" entry in Windows Terminal's
# new-tab menu and Warp's + menu, running `ssh -t <alias> zellij attach
# --create main`. The hosts stay on this machine; the public repo has none.
# Patterns (* ?), negations (!) and aliases that would need quoting on a
# command line are skipped; Include lines inside config.local aren't followed.
function Get-SshLauncherHosts {
    param([string]$Path = (Join-Path $env:USERPROFILE ".ssh\config.local"))
    $aliases = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^\s*Host(?:\s*=\s*|\s+)(.+)$') { continue }
        foreach ($token in (($Matches[1] -replace '\s#.*$', '').Trim() -split '\s+')) {
            if (-not $token -or $token -match '[*?!]') { continue }
            if ($token -notmatch '^[A-Za-z0-9._@-]+$') {
                Write-Warn "Skipping SSH host alias with unsafe characters: $token"
                continue
            }
            if (-not $aliases.Contains($token)) { $aliases.Add($token) }
        }
    }
    $aliases.ToArray()
}

# RFC 4122 v5 GUID, Windows Terminal's fragment convention: name bytes are
# UTF-16LE (namespace {f65ddb7e-706b-4499-8a50-40313caf510a} -> app ->
# profile name), so a profile keeps its identity across regenerations.
function New-Uuid5 {
    param([Parameter(Mandatory)][Guid]$Namespace, [Parameter(Mandatory)][string]$Name)
    $ns = $Namespace.ToByteArray()
    [Array]::Reverse($ns, 0, 4); [Array]::Reverse($ns, 4, 2); [Array]::Reverse($ns, 6, 2)  # to big-endian
    $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($Name)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($ns + $nameBytes) } finally { $sha1.Dispose() }
    $b = $hash[0..15]
    $b[6] = [byte](($b[6] -band 0x0F) -bor 0x50)   # version 5
    $b[8] = [byte](($b[8] -band 0x3F) -bor 0x80)   # RFC 4122 variant
    [Array]::Reverse($b, 0, 4); [Array]::Reverse($b, 4, 2); [Array]::Reverse($b, 6, 2)     # back to GUID layout
    return [Guid]::new([byte[]]$b)
}

# Windows Terminal reads profile fragments from Fragments\<app>\*.json at
# launch. The "workstation" app dir is owned here: its *.json are rewritten
# every run, so a host removed from config.local disappears. Nothing else is
# touched -- not other apps' fragments, not the tracked settings.json.
function Invoke-WindowsTerminalFragments {
    $present = (Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue) -or
               (Get-Command wt.exe -ErrorAction SilentlyContinue)
    if (-not $present) {
        Write-Warn "Windows Terminal not detected — skipping its SSH host profiles."
        return
    }
    $fragDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\Fragments\workstation"
    try {
        Get-ChildItem -Path $fragDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Remove-Item -Force
        $hosts = @(Get-SshLauncherHosts)
        if ($hosts.Count -eq 0) {
            Write-Ok "Windows Terminal: no SSH host profiles (no Host entries in ~\.ssh\config.local)"
            return
        }
        if (-not (Test-Path $fragDir)) { New-Item -ItemType Directory -Path $fragDir -Force | Out-Null }
        $appNs = New-Uuid5 -Namespace ([Guid]"f65ddb7e-706b-4499-8a50-40313caf510a") -Name "workstation"
        $profiles = @(foreach ($h in $hosts) {
            [ordered]@{
                guid        = (New-Uuid5 -Namespace $appNs -Name "SSH: $h").ToString("B")
                name        = "SSH: $h"
                commandline = "ssh -t $h zellij attach --create main"
                tabTitle    = $h
                tabColor    = "#94e2d5"
                icon        = [string][char]0xE839
            }
        })
        $json = ConvertTo-Json -InputObject ([ordered]@{ profiles = $profiles }) -Depth 5
        # PS 5.1 joins JSON lines with CRLF; write LF, UTF-8 without a BOM.
        [System.IO.File]::WriteAllText((Join-Path $fragDir "hosts.json"), (($json -replace "`r`n", "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Windows Terminal SSH host profiles: $($hosts.Count) from ~\.ssh\config.local — restart Windows Terminal to see them"
    } catch {
        Write-Warn "Could not write the Windows Terminal SSH host profiles: $($_.Exception.Message)"
    }
}

# Deterministic Warp launch entries. Warp's + menu is its launch surface
# (no profile list), so unlike Windows Terminal the local shells need
# generated entries, plus one "SSH: <alias>" entry per Get-SshLauncherHosts
# host. Files prefixed workstation- are owned by this
# function; every run wipes and rewrites them; user-created configs are
# never touched. Warp supports pwsh/PowerShell 5/WSL2/Git Bash only, NOT
# Nushell -- the Nushell entry is a compatibility shim (pwsh launches
# mise's nu.exe shim as a child; mise's install dir is versioned, the shim
# path isn't); Nushell's first-class home stays Windows Terminal's
# defaultProfile.
function Invoke-WarpTabConfigs {
    if (-not (Test-InstallerPresent "Warp*")) {
        Write-Warn "Skipping Warp Tab Config generation — Warp is not installed."
        return
    }

    $dir = Join-Path $env:APPDATA "warp\Warp\data\tab_configs"
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # The workstation- prefix IS the managed namespace: wipe only those.
        Get-ChildItem -Path $dir -Filter "workstation-*.toml" -File -ErrorAction SilentlyContinue |
            Remove-Item -Force

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $configs = @{
            "workstation-wsl-almalinux-9.toml" = @'
name = "WSL: AlmaLinux-9"
title = "AlmaLinux-9"
color = "blue"

[[panes]]
id = "main"
type = "terminal"
shell = "pwsh"
commands = ['wsl.exe --distribution AlmaLinux-9 --cd ~']
is_focused = true
'@
            "workstation-powershell.toml" = @'
name = "Windows PowerShell"
title = "PowerShell"
color = "blue"

[[panes]]
id = "main"
type = "terminal"
shell = "pwsh"
commands = []
is_focused = true
'@
            "workstation-nushell-compat.toml" = @'
name = "Nushell (compatibility)"
title = "Nushell compatibility"
color = "magenta"

[[panes]]
id = "main"
type = "terminal"
shell = "pwsh"
commands = ['& "$env:LOCALAPPDATA\mise\shims\nu.exe" --login']
is_focused = true
'@
        }
        foreach ($entry in $configs.GetEnumerator()) {
            [System.IO.File]::WriteAllText((Join-Path $dir $entry.Key), $entry.Value.Trim() + "`n", $utf8)
        }
        $hosts = @(Get-SshLauncherHosts)
        $slugs = @{}
        foreach ($h in $hosts) {
            # ssh aliases are case-sensitive but file names here are not.
            $slug = $h.ToLower() -replace '[^a-z0-9-]', '-'
            while ($slugs.ContainsKey($slug)) { $slug = "$slug-" }
            $slugs[$slug] = $true
            $body = @"
name = "SSH: $h"
title = "$h"
color = "cyan"

[[panes]]
id = "main"
type = "terminal"
shell = "pwsh"
commands = ['ssh -t $h zellij attach --create main']
is_focused = true
"@
            [System.IO.File]::WriteAllText((Join-Path $dir "workstation-ssh-$slug.toml"), $body.Trim() + "`n", $utf8)
        }
        Write-Ok "Warp Tab Configs regenerated ($($configs.Count) local shells + $($hosts.Count) SSH host(s), $dir)"
    } catch {
        Write-Warn "Could not generate Warp Tab Configs: $($_.Exception.Message)"
    }
}

# Nushell can't `eval`, so the Starship prompt is a GENERATED file written
# to %APPDATA%\nushell\vendor\autoload\starship.nu (auto-sourced on every
# nu startup). config.nu owns the hand-written config; this owns only the
# generated prompt. Runs every bootstrap, no stamp -- self-heals a deleted
# file or a Starship pin-bump.
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

# dnGrep stores settings NEXT TO THE EXE, and mise's install dir is
# versioned, so a version bump would start from scratch. Seeds
# dnGrep.config.xml beside dnGREP.exe redirecting DataDirectory/
# LogDirectory to %APPDATA%\dnGREP instead (values must be EXPANDED paths
# -- dnGrep doesn't expand %ENV% vars); a new install dir has none, so it
# is re-seeded. Seed-if-absent ONLY: dnGrep's Options dialog rewrites this
# same file, so overwriting every run would clobber a user's choice.
function Invoke-DnGrepConfig {
    $exe = Get-MiseToolExe -Tool "github:dnGrep/dnGrep" -Exe "dnGREP.exe"
    if (-not $exe) {
        Write-Warn "Skipping dnGrep config seed — dnGREP.exe not found via 'mise where github:dnGrep/dnGrep' (tools phase skipped?)."
        return
    }

    $cfg = Join-Path (Split-Path $exe -Parent) "dnGrep.config.xml"

    # The redirect TARGETS must exist, not just the config file: dnGrep
    # enumerates DataDirectory at startup (AppTheme.LoadExternalThemes does
    # Directory.GetFiles over it) and CRASHES with DirectoryNotFoundException
    # if it's missing — it auto-creates only its DEFAULT data folder, never a
    # config-file value. On the already-present path, read the dirs from the
    # file itself so a user-customized location is healed too.
    if (Test-Path $cfg) {
        try {
            $existing = [xml](Get-Content -Raw $cfg)
            foreach ($dir in @($existing.DirectoryConfiguration.DataDirectory,
                               $existing.DirectoryConfiguration.LogDirectory)) {
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            }
        } catch {
            Write-Warn "Could not verify the dnGrep data dirs: $($_.Exception.Message)"
        }
        Write-Ok "dnGrep config already present ($cfg)"
        return
    }

    $dataDir = Join-Path $env:APPDATA "dnGREP"
    $logDir  = Join-Path $dataDir "logs"
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<DirectoryConfiguration>
  <DataDirectory>$dataDir</DataDirectory>
  <LogDirectory>$logDir</LogDirectory>
</DirectoryConfiguration>
"@
    try {
        # Dirs first, config second — if creation fails, no config is written
        # and dnGrep falls back to its built-in (exe-dir) behavior instead of
        # crashing on a dangling redirect. -Force creates $dataDir with it.
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        # UTF-8 without BOM (matches the XML declaration; dnGrep reads it fine).
        [System.IO.File]::WriteAllText($cfg, $xml, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "dnGrep config seeded (settings dir -> $dataDir)"
    } catch {
        Write-Warn "Could not seed the dnGrep config: $($_.Exception.Message)"
    }
}

# `mise activate nu` output saved as a GENERATED file under vendor\autoload
# (auto-sourced on startup, exactly like starship.nu), regenerated every
# run so it tracks the installed mise. Never hand-edited, never in
# config.nu; its export-env hook puts mise's real bin dirs on PATH ahead of
# the shims dir Invoke-MiseBootstrap added.
function Invoke-NushellMise {
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell mise activation — mise not on PATH (install step skipped?)."
        return
    }
    if (-not (Get-Command nu -ErrorAction SilentlyContinue)) {
        Write-Warn "Skipping Nushell mise activation — nu not on PATH (install step skipped?)."
        return
    }

    $autoload = Join-Path $env:APPDATA "nushell\vendor\autoload"
    $target   = Join-Path $autoload "mise.nu"
    try {
        if (-not (Test-Path $autoload)) { New-Item -ItemType Directory -Force -Path $autoload | Out-Null }
        # UTF-8 WITHOUT a BOM — nu chokes on a leading BOM in sourced scripts.
        $init = (& mise activate nu) -join "`n"
        [System.IO.File]::WriteAllText($target, $init, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "Nushell mise activation generated ($target)"
    } catch {
        Write-Warn "Could not generate the Nushell mise activation: $($_.Exception.Message)"
    }
}

# =============================================================================
# CLAUDE / PYTHON / FONTS / SSH
# =============================================================================

# BurntToast -- lets `New-BurntToastNotification` surface native Windows
# toasts. Used by the WSL2 branch of dotfiles/claude/notify.sh (deployed to
# ~/.claude/notify.sh on owned Linux hosts) to ping Windows when Claude
# Code needs attention; falls back to a MessageBox if the module is absent.
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

function Invoke-ClaudeSettingsMerge {
    # ~/.claude/settings.json three-layer merge: seed (personal defaults,
    # set-if-absent) -> live file -> enforced (infra keys that always win).
    # Ports the SAME jq filter (`.[0] * .[1] * .[2]`) scripts/lib/
    # claude-settings-merge.sh uses on Linux -- one source of truth for the
    # merge semantics, two callers. Soft-failing by design: every expected
    # failure (no jq, missing source, invalid JSON, a write failure) warns
    # and returns, never aborts bootstrap.
    $seed     = Join-Path $RepoPath "dotfiles\claude\settings.seed.json"
    $enforced = Join-Path $RepoPath "dotfiles\claude\settings.enforced.json"
    $dest     = Join-Path $env:USERPROFILE ".claude\settings.json"

    if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
        Write-Warn "jq not found on PATH -- skipping Claude settings merge ($dest left as-is)"
        return
    }
    if (-not (Test-Path -LiteralPath $seed)) {
        Write-Warn "missing $seed -- skipping Claude settings merge"
        return
    }
    if (-not (Test-Path -LiteralPath $enforced)) {
        Write-Warn "missing $enforced -- skipping Claude settings merge"
        return
    }

    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

    # jq.exe writes UTF-8; force the same on the read side regardless of the
    # console's default code page (mirrors $PROFILE's own
    # [Console]::OutputEncoding override) so a non-ASCII value round-trips.
    $prevOutputEncoding = $OutputEncoding
    $OutputEncoding = [System.Text.Encoding]::UTF8
    $currentTmp = Join-Path $destDir ".settings.json.current.$PID.tmp"
    $outTmp     = Join-Path $destDir ".settings.json.$PID.tmp"
    try {
        if (Test-Path -LiteralPath $dest) {
            $currentOut = & jq -c '.' $dest 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $currentOut) {
                Write-Warn "$dest is not valid JSON -- leaving it untouched"
                return
            }
            [System.IO.File]::WriteAllText($currentTmp, ($currentOut -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        } else {
            [System.IO.File]::WriteAllText($currentTmp, '{}', (New-Object System.Text.UTF8Encoding($false)))
        }

        $mergedOut = & jq -s '.[0] * .[1] * .[2]' $seed $currentTmp $enforced 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $mergedOut) {
            Write-Warn "jq merge failed -- leaving $dest untouched"
            return
        }

        [System.IO.File]::WriteAllText($outTmp, ($mergedOut -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -Force -LiteralPath $outTmp -Destination $dest
        Write-Ok "merged seed + live + enforced -> $dest"
    } catch {
        Write-Warn "Claude settings merge failed: $_"
    } finally {
        $OutputEncoding = $prevOutputEncoding
        Remove-Item -Force -ErrorAction SilentlyContinue $currentTmp
        Remove-Item -Force -ErrorAction SilentlyContinue $outTmp
    }
}

function Invoke-ClaudeSettingsLocalSeed {
    # ~/.claude/settings.local.json -- seed-if-absent (Windows half of Linux
    # tasks/bootstrap step 6b). Unlike settings.json there's no enforced
    # layer reapplied every run: a plain seed, written ONLY when the live
    # file doesn't exist yet, so a fresh host gets the tracked default
    # ({"spinnerTipsEnabled": false}) without ever clobbering a later edit.
    $seedSrc = Join-Path $RepoPath "dotfiles\claude\settings.local.json"
    $dest    = Join-Path $env:USERPROFILE ".claude\settings.local.json"

    if (-not (Test-Path -LiteralPath $seedSrc)) {
        Write-Warn "missing $seedSrc -- skipping settings.local.json seed"
        return
    }
    if (Test-Path -LiteralPath $dest) {
        return # already present -- never overwrite a live file here (seed-if-absent only)
    }
    try {
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        Copy-Item -LiteralPath $seedSrc -Destination $dest
        Write-Ok "seeded $dest"
    } catch {
        Write-Warn "failed to seed $dest -- inspect by hand: $_"
    }
}

# Native Windows install via Anthropic's official installer script (verifies
# claude.exe's sha256 against the signed release manifest, then wires up the
# launcher/PATH/shell integration itself). NOT a mise tool -- it
# self-updates in the background (mirrors the rolling Linux install). NOT
# a $WingetApps entry -- no Uninstall-registry entry to detect it by.
# Detect-by-command, skip when present. Runs in a CHILD powershell.exe: the
# installer script calls `exit` on its error paths, which would kill this
# bootstrap if dot-run in-process.
function Invoke-InstallClaudeCode {
    if ($SkipToolInstall) {
        Write-Log "Claude Code install skipped (-SkipToolInstall)"
        return
    }
    $claudeExe = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if ((Get-Command claude -ErrorAction SilentlyContinue) -or (Test-Path $claudeExe)) {
        Write-Ok "Claude Code already installed (self-updates in the background)"
        return
    }
    Write-Log "Installing Claude Code (official installer, manifest-verified)..."
    $tmp = Join-Path $env:TEMP "claude-install-$PID.ps1"
    try {
        # Download-then-run with checked curl.exe status — same posture as
        # the Linux side's `curl -fsSL … | bash`.
        Invoke-CurlRequest -Uri "https://claude.ai/install.ps1" -OutFile $tmp
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
        if ($LASTEXITCODE -ne 0) { throw "installer exited with code $LASTEXITCODE" }
        Write-Ok "Claude Code installed (launcher in ~\.local\bin; self-updates)"
    } catch {
        Write-Warn "Claude Code install failed: $_"
        Write-Warn "  Retry by re-running bootstrap.ps1 (leave -SkipToolInstall unset)."
    } finally {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Get-PythonEnvStamp — the exact stamp path Invoke-PythonEnv writes on
# success (pin + a hash of the lib list). One helper owns the path so the check
# can never drift onto a stale stamp left behind
# by an older pin.
function Get-PythonEnvStamp {
    $libBytes = [System.Text.Encoding]::UTF8.GetBytes(($PythonLibs -join ' '))
    $libStream = New-Object System.IO.MemoryStream (,$libBytes)
    $libHash = (Get-FileHash -InputStream $libStream -Algorithm SHA256).Hash.Substring(0, 8).ToLower()
    return Join-Path $WsStamps "python-env.$PythonEnvVersion.$libHash.stamp"
}

# The blessed uv-built venv (Windows half of the Linux `python-env` mise
# task). uv (mise-managed, via `mise which uv`) installs the pinned CPython
# and rebuilds the env from scratch; wpy/textual/typer .cmd shims land in
# $WsBin. Stamp bakes the pin + lib list, so a bump rebuilds on the next
# bootstrap (a lib upgrade alone is "delete the stamp, re-run").
function Invoke-PythonEnv {
    if ($SkipToolInstall) {
        Write-Log "Python env skipped (-SkipToolInstall)"
        return
    }
    # uv is a mise runtime now: ask mise for the binary config.toml declares
    # (no fixed path — mise's data dir owns the install).
    $uvExe = $null
    if (Get-Command mise -ErrorAction SilentlyContinue) {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $uvExe = (& mise which uv 2>$null | Select-Object -First 1)
        $ErrorActionPreference = $oldEap
    }
    if (-not $uvExe -or -not (Test-Path $uvExe)) {
        Write-Warn "Python env skipped — uv not resolvable via 'mise which uv' (mise runtimes step failed?)"
        return
    }

    # Stamp bakes pin + lib list (the Linux stamp's cksum analog).
    $stamp = Get-PythonEnvStamp
    $wpyShim = Join-Path $WsBin "wpy.cmd"
    if ((Test-Path $stamp) -and (Test-Path $wpyShim)) {
        Write-Ok "Python env $PythonEnvVersion already built ($WsPythonEnv)"
        return
    }

    Write-Log "Building Python scripting env $PythonEnvVersion ($($PythonLibs.Count) libs)..."
    try {
        & $uvExe python install $PythonEnvVersion
        if ($LASTEXITCODE -ne 0) { throw "uv python install exited $LASTEXITCODE" }
        if (Test-Path $WsPythonEnv) { Remove-Item -Recurse -Force $WsPythonEnv }
        & $uvExe venv --python $PythonEnvVersion $WsPythonEnv
        if ($LASTEXITCODE -ne 0) { throw "uv venv exited $LASTEXITCODE" }
        $envPy = Join-Path $WsPythonEnv "Scripts\python.exe"
        & $uvExe pip install --python $envPy --upgrade $PythonLibs
        if ($LASTEXITCODE -ne 0) { throw "uv pip install exited $LASTEXITCODE" }

        # Launcher shims — wpy calls the env python; textual/typer call the
        # env's entry-point exes. $WsBin is already on the User PATH.
        $scripts = Join-Path $WsPythonEnv "Scripts"
        Set-Content -Path $wpyShim -Value "@echo off`r`n`"$envPy`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "textual.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'textual.exe')`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "typer.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'typer.exe')`" %*" -Encoding Ascii

        if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
        Get-ChildItem -Path $WsStamps -Filter "python-env.*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force
        New-Item -ItemType File -Force -Path $stamp | Out-Null
        Write-Ok "Python env $PythonEnvVersion built ($WsPythonEnv; launchers: wpy, textual, typer)"
    } catch {
        Write-Warn "Python env build failed: $($_.Exception.Message)"
        Write-Warn "  Re-run .\bootstrap.ps1 to retry (no stamp was written)."
    }
}

# JetBrainsMono Nerd Font Mono, per-user. Required by dotfiles-tracked
# configs that assume Nerd Font glyphs (starship, eza, lazygit, k9s, yazi,
# broot, helix, ccstatusline, Claude Code TUI). Delegates to
# scripts/install-nerd-fonts.ps1, which also registers a per-user at-logon
# scheduled task -- HKCU per-user fonts don't reliably load at logon alone.
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

# SSH key (optional, prompt-driven).
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
# RUN SEQUENCE
# =============================================================================

if ($Reinstall) { Invoke-Reinstall }
Invoke-Preflight
Invoke-ToolInstall        # the pinned mise under %LOCALAPPDATA%\workstation, then the GUI apps
Invoke-CloneRepo
Invoke-MiseBootstrap      # `mise bootstrap --only dotfiles,tools` -- dotfiles + every CLI tool; old portable tools removed, shims on PATH, node marker, prune; .wslconfig reminder
Invoke-StartMenuShortcuts # per-user Start Menu .lnks for the mise-installed GUI tools (dnGrep/LogExpert)
Invoke-WarpTabConfigs     # regenerate Warp Tab Configs (local shells + ~\.ssh\config.local hosts) — self-heals
Invoke-WindowsTerminalFragments # Windows Terminal "SSH: <host>" profiles from ~\.ssh\config.local — self-heals
Invoke-NushellStarship    # generate the Nushell starship prompt (vendor/autoload — self-heals)
Invoke-DnGrepConfig       # seed dnGrep.config.xml (settings dir -> %APPDATA%\dnGREP; re-seeded per mise install dir)
Invoke-NushellMise        # generate the Nushell mise activation (vendor/autoload — self-heals)
Invoke-ProfileShim        # bridge Documents redirection (OneDrive) so $PROFILE loads the managed profile
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-InstallClaudeCode  # native Claude Code via the official installer (manifest-verified; self-updates)
Invoke-ClaudeSettingsMerge     # ~/.claude/settings.json seed+live+enforced jq merge
Invoke-ClaudeSettingsLocalSeed # ~/.claude/settings.local.json seed-if-absent
Invoke-PythonEnv          # blessed uv-built Python scripting env (wpy/textual/typer shims)
Invoke-InstallNerdFonts   # JetBrainsMono Nerd Font Mono — per-user font install
Invoke-EnsureSshKey

Write-Host ""
Write-Host "${Bold}Bootstrap complete.${Reset}"
Write-Host ""
Write-Host "Open a NEW shell so the updated User PATH (${Bold}$WsMise\bin${Reset}, ${Bold}$MiseShims${Reset} — mise and its tools)"
Write-Host "and the mise-applied dotfiles pick up — starship prompt, git aliases, etc."
Write-Host ""
Write-Host "${Bold}Two terminals are managed.${Reset} Warp is the day-to-day one: it opens into"
Write-Host "AlmaLinux-9 (WSL zsh), and its + menu carries the generated Tab Configs for"
Write-Host "WSL, PowerShell and Nushell-compat. Windows Terminal stays fully configured as"
Write-Host "the compatibility path: Nushell is its default profile, and it keeps the"
Write-Host "Windows default-terminal-application role (Warp cannot take it). Warp"
Write-Host "hot-reloads its settings but needs a restart to notice new Tab Configs."
Write-Host ""
Write-Host "Not installed by this script (install yourself if you want it):"
Write-Host "  VSCode  — its dotfiles are already deployed."
Write-Host ""

# Print the curated hand-install shopping list (docs/windows/application_list.md).
# Personal preference order — terminals, file managers, search, editors, etc.
# Soft-skip if the file is missing (partial clone, older repo snapshot).
$appList = Join-Path $RepoPath "docs\windows\application_list.md"
if (Test-Path $appList) {
    Write-Host "${Bold}Hand-install shopping list${Reset} (docs\windows\application_list.md):"
    # -Encoding UTF8: the list is UTF-8 without a BOM, so PowerShell 5.1's
    # default (the ANSI codepage) printed every em dash as "â€”".
    Get-Content -Encoding UTF8 $appList | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

Write-Host "Editing dotfiles (new Nushell/PowerShell shell):"
Write-Host "  wse <path>   # edit a tracked file in the repo source"
Write-Host "  wsd          # see what would change"
Write-Host "  wsa          # apply; asks first if a deployed file has a local edit it would overwrite"
Write-Host "  wsr          # record an app's own edit to a deployed file back into the repo"
