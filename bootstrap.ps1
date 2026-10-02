# =============================================================================
# bootstrap.ps1 -- workstation setup (Windows), per-user, no admin. It checks
# for git and curl.exe (it never installs Git), installs the sha256-pinned mise,
# clones this repo, writes miserc.toml (windows,owned) and runs `mise bootstrap
# --only dotfiles,tools` (the dotfiles and every CLI tool), then `mise bootstrap
# --only packages` (config.windows.toml's winget GUI apps), then the steps under
# RUN SEQUENCE. The one admin step: SSHFS-Win raises UAC (two prompts on a host
# without WinFsp); declining it, or -SkipElevated, skips only that app.
# Run it as README.md's Windows setup shows. $env:GITHUB_TOKEN is optional (a
# private-fork clone; mise's GitHub API limit). Health: mise doctor, mise
# bootstrap status, mise dot status, mise bootstrap packages status.
# =============================================================================

[CmdletBinding()]
param(
    [string]$RepoPath = (Join-Path $env:USERPROFILE ".config\mise"),
    [switch]$SkipKeyGen,       # skip the SSH-key generation prompt
    [switch]$SkipToolInstall,  # skip mise, the mise tools, the winget GUI apps, the Python env + Claude Code
    [switch]$SkipDotfiles,     # clone + install tools but don't apply dotfiles yet
    [switch]$SkipBurntToast,   # skip the BurntToast PSGallery module install
    [switch]$SkipNerdFonts,    # skip the Nerd Font install
    [switch]$SkipElevated,     # skip SSHFS-Win/WinFsp (the one UAC prompt)
    [switch]$Reinstall,        # wipe the cloned repo, then re-bootstrap (prompts unless -Yes)
    [switch]$Yes               # skip confirmation prompts (-Reinstall)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# CONSTANTS
# =============================================================================

$DotfilesRepo = "https://github.com/ArrushC/workstation.git"
$SshKey       = "$env:USERPROFILE\.ssh\id_ed25519"

# Scoped to github.com, so the token persisted in .git/config never reaches another remote.
$GhHeaderKey = "http.https://github.com/.extraheader"

# mise\bin (the pinned mise) and bin (python-env launchers) go on the User PATH.
$WsRoot   = Join-Path $env:LOCALAPPDATA "workstation"
$WsBin    = Join-Path $WsRoot "bin"
$WsMise   = Join-Path $WsRoot "mise"
$WsStamps = Join-Path $WsRoot "stamps"

# The one pin here: triple-edit with MISE_VERSION (bootstrap.sh) and min_version (config.toml).
$MiseVersion = "2026.9.9"
$MiseSha256  = "f758ee4afe061cccd4587c0108c147209a7cb2372704909a8b9d5e230203ec07"
$MiseUrl     = "https://github.com/jdx/mise/releases/download/v$MiseVersion/mise-v$MiseVersion-windows-x64.zip"
$MiseShims   = Join-Path $env:LOCALAPPDATA "mise\shims"
$MiseEnvTokens = @("windows", "owned")

$WsPythonEnv = Join-Path $WsRoot "python-env"

# =============================================================================
# HELPERS: output, HTTP, PATH
# =============================================================================

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

# Self-contained: bootstrap also runs from memory, before the repo exists.
function Invoke-CurlRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$OutFile
    )

    # PATH can hold several (System32, Git's mingw64\bin): take the one a bare `curl.exe` runs.
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl) {
        throw 'curl.exe is required on PATH. Restore the Windows system curl or install it from https://curl.se/windows/ and reopen your shell.'
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    $headerFile = $null
    try {
        # --speed-limit/--speed-time: a stalled transfer aborts (exit 28, retried) instead of hanging.
        $curlArgs = @('--disable', '--fail', '--silent', '--show-error', '--location',
            '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30',
            '--speed-limit', '1', '--speed-time', '60',
            '--output', $tempFile)
        if ($Headers.Count -gt 0) {
            # A file, never argv (process auditing shows a PAT); no BOM, or curl sends it in the first header.
            $headerFile = [System.IO.Path]::GetTempFileName()
            $headerLines = @(foreach ($key in $Headers.Keys) { '{0}: {1}' -f $key, $Headers[$key] })
            [System.IO.File]::WriteAllLines($headerFile, [string[]]$headerLines, [System.Text.UTF8Encoding]::new($false))
            $curlArgs += @('--header', "@$headerFile")
        }
        $curlArgs += @('--url', $Uri)
        # PS 5.1 can turn native stderr into errors and PS 7 can throw on exit codes: handle both here.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $curlOutput = & $curl.Source @curlArgs 2>&1
        $curlExitCode = $LASTEXITCODE
        if ($curlExitCode -ne 0) {
            # --silent --show-error leaves only curl's own diagnostic on stderr.
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

# A seam scripts/test-mise-env.ps1 can stub (a static .NET method can't be); $null deletes.
function Get-UserEnv { param([string]$Name) [Environment]::GetEnvironmentVariable($Name, "User") }
function Set-UserEnv { param([string]$Name, $Value) [Environment]::SetEnvironmentVariable($Name, $Value, "User") }

function Update-SessionPath {
    # The session keeps its own PATH copy; rebuild it so new User PATH entries resolve now.
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

function Add-ToUserPath {
    param([string]$Dir)

    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $userPath) { $userPath = "" }

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
# PREFLIGHT, MISE, GUI APPS
# =============================================================================

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

    # A script inside $RepoPath would delete itself; the curl.exe form runs from memory ($PSCommandPath $null).
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

function Invoke-Preflight {
    Write-Log "Checking prerequisites..."
    $curlCmd = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curlCmd) {
        Write-Fail 'curl.exe is required on PATH. Restore the Windows system curl or install it from https://curl.se/windows/ and reopen your shell.'
    }
    Write-Ok "curl.exe found ($($curlCmd.Source))"

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

# An update renames bin\mise.exe and mise-shim.exe to *.old (a later run removes them): every shim
# (WT's Nushell too) runs mise.exe, and Windows can rename a running image but not delete or overwrite it.
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
    $shaMismatch = $false
    try {
        try {
            Invoke-CurlRequest -Uri $MiseUrl -OutFile $zip
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLower()
            if ($actual -ne $MiseSha256) { $shaMismatch = $true; throw "sha256 mismatch: got $actual, pinned $MiseSha256" }
        } catch {
            # An older mise keeps the host working; only a host with none stops.
            if (Test-Path $miseExe) {
                Add-ToUserPath $binDir
                Write-Warn "mise $MiseVersion not installed ($($_.Exception.Message)) -- continuing on the installed mise, but config.toml's min_version may need $MiseVersion, so the mise steps below may refuse until a re-run of .\bootstrap.ps1 installs it"
                return
            }
            if ($shaMismatch) { Write-Fail "mise $MiseVersion download did not match the pinned checksum ($($_.Exception.Message)) and no mise is installed -- re-run .\bootstrap.ps1; if it persists, `$MiseSha256 in bootstrap.ps1 is wrong for `$MiseVersion" }
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

# Removes the portable installs mise replaced (their User PATH entries shadow the
# shims) and only their own stamps: wslconfig/node-postinstall/python-env stamps are
# live. Runs after a good tools phase. Remove once every Windows host has run it.
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

# Path-independent, and a Control-Panel uninstall removes the key, so the next run reinstalls.
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

# Appx (no Uninstall key); wt.exe on PATH also counts (a non-Store install, or no Appx module).
function Test-WindowsTerminalPresent {
    $pkg = $null
    try { $pkg = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue } catch { $pkg = $null }
    return ([bool]$pkg -or [bool](Get-Command wt.exe -ErrorAction SilentlyContinue))
}

# The GUI apps are config.windows.toml's [bootstrap.packages] (winget), installed by
# `mise bootstrap --only packages` once the dotfiles phase has deployed winget's
# settings.json (prefer per-user installers). mise installs silently, so SSHFS-Win,
# whose WinFsp MSI must raise UAC, is Install-SshfsWin's. Best-effort: a failure
# warns and the bootstrap goes on.
function Install-WingetApps {
    if ($SkipToolInstall) { Write-Log "GUI apps skipped (-SkipToolInstall)"; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn "winget not found — GUI apps skipped (install App Installer from the Microsoft Store, then re-run)"
        return
    }
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        Write-Warn "mise not on PATH — the GUI apps in config.windows.toml were skipped (open a new shell and re-run .\bootstrap.ps1)"
    } else {
        Write-Log "Installing missing GUI apps (mise bootstrap --only packages: config.windows.toml's winget list)..."
        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'   # PS 5.1 can turn native stderr into a terminating error under "Stop"
            & mise -C $env:USERPROFILE bootstrap --only packages --yes
            $code = $LASTEXITCODE
            $why = "exited $code"
        } catch {
            $code = -1
            $why = "could not start ($($_.Exception.Message))"
        } finally {
            $ErrorActionPreference = $oldEap
        }
        if ($code -eq 0) { Write-Ok "GUI apps installed or present ('mise bootstrap packages status' lists them)" }
        else { Write-Warn "mise bootstrap --only packages $why (output above) — retry: mise bootstrap packages apply --manager winget" }
    }
    Install-SshfsWin
}

# The one UAC install, from winget (sha256-checked). No --silent: it would run the
# MSI in-process at UI level None, where UAC can't appear (MSI error 1925). Only
# "no installed package found" (0x8A150014) from `winget list` installs, so a
# broken winget never raises a surprise prompt.
function Install-SshfsWin {
    $id = "SSHFS-Win.SSHFS-Win"
    if ($SkipElevated) { Write-Log "SSHFS-Win skipped (-SkipElevated)"; return }
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & winget list --id $id --exact --disable-interactivity --accept-source-agreements *> $null
        $listHex = '0x{0:X8}' -f [int]$LASTEXITCODE
    } catch {
        $listHex = "error: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $oldEap
    }
    if ($listHex -eq '0x00000000') { Write-Ok "SSHFS-Win present"; return }
    if ($listHex -ne '0x8A150014') {
        Write-Warn "SSHFS-Win: could not check it (winget list $listHex) — not installing; check with: winget list --id $id"
        return
    }
    Write-Warn "SSHFS-Win installs machine-wide — expect a UAC prompt; a host without WinFsp sees two, one for WinFsp and one for SSHFS-Win (skip with -SkipElevated)"
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & winget install --id $id --exact --scope machine --disable-interactivity --accept-package-agreements --accept-source-agreements
        $code = $LASTEXITCODE
        $why = "winget exited " + ('0x{0:X8}' -f [int]$code)
    } catch {
        $code = -1
        $why = "winget could not start ($($_.Exception.Message))"
    } finally {
        $ErrorActionPreference = $oldEap
    }
    # UPDATE_NOT_APPLICABLE, PACKAGE_ALREADY_INSTALLED, INSTALL_ALREADY_INSTALLED.
    if ($code -eq 0) { Write-Ok "SSHFS-Win installed" }
    elseif (@("0x8A15002B", "0x8A150061", "0x8A15010D") -contains ('0x{0:X8}' -f [int]$code)) { Write-Ok "SSHFS-Win present (winget)" }
    else { Write-Warn "SSHFS-Win: $why — install it later with: winget install --id $id" }
}

function Invoke-ToolInstall {
    if ($SkipToolInstall) {
        Write-Log "Tool install skipped (-SkipToolInstall) — no mise install, mise tools, GUI apps, Python env or Claude Code"
        return
    }

    foreach ($d in @($WsRoot, $WsBin, $WsStamps)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }

    Install-Mise
    Add-ToUserPath $WsBin   # python-env's wpy/textual/typer launchers

    Update-SessionPath

    foreach ($app in @(@{ Cmd = 'code'; Name = 'VSCode' })) {
        if (-not (Get-Command $app.Cmd -ErrorAction SilentlyContinue)) {
            Write-Warn "$($app.Name) not on PATH — install it yourself when you want it; its dotfiles still deploy."
        }
    }
}

# =============================================================================
# REPO & MISE
# =============================================================================

function Invoke-CloneRepo {
    # HTTP Basic "x-access-token:<PAT>", as actions/checkout does: git's smart-HTTP
    # endpoint on github.com refuses "Authorization: bearer" and silently falls
    # back to a credential prompt, which breaks a non-interactive clone.
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

# miserc.toml (git-ignored) holds the token set, as on Linux. An exported MISE_ENV
# would override it, so a User MISE_ENV is removed, and this session's too.
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

# Windows is always owned. Name/email are asked once; a non-interactive run leaves them to the user.
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
    # .wslconfig takes effect only after `wsl --shutdown`, so remind only when the
    # repo source changed: the stamp is named by its hash (mise has no run_onchange_).
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

# `mise bootstrap --only dotfiles,tools`: the [dotfiles] entries and every tool;
# `--only` keeps the sudo-only [bootstrap.files] out. A host's first apply passes
# --force-dotfiles (a target can already be a differing real file); $MigratedMarker
# then stops it, so a later real conflict surfaces. After a good tools phase, as
# scripts/lib/mise-install.sh does on Linux: shims on PATH (later steps need jq,
# starship, nu, uv), node reinstalled when its declaration changed, prune, reshim.
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
        # Before the apply: templates guard vars.*, but real values shape the git identity.
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

    # Without config.owned.toml loaded (miserc.toml ignored), the tools phase would skip
    # the owned tools and `mise prune` delete them; a failing `config ls` (min_version,
    # a TOML error) stops too. --json: the table output truncates to the console width.
    $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $lsOut = @(& mise @miseCd config ls --json 2>&1 | ForEach-Object { "$_" })
    $lsCode = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    if ($lsCode -ne 0) {
        $head = @($lsOut | Where-Object { $_.Trim() } | Select-Object -First 5) -join "`n  "
        Write-Fail "'mise config ls' failed (exit $lsCode) -- an older mise than config.toml's min_version? re-run .\bootstrap.ps1 after a download succeeds:`n  $head"
    }
    if (($lsOut -join "`n") -notmatch 'config\.owned\.toml') {
        Write-Fail "mise did not load config.owned.toml, so miserc.toml (windows,owned) was not honoured -- -RepoPath outside %USERPROFILE%\.config\mise? Stopping before mise bootstrap/prune could remove the owned tools; 'mise -C `$env:USERPROFILE config ls' shows what loaded."
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
        Invoke-LegacyToolCleanup
        Add-ToUserPath $MiseShims
        Update-SessionPath
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & mise @miseCd where node *> $null
            if ($LASTEXITCODE -eq 0) {
                # Marker = node's declaration hashed (-f: a bare `config get` reads only
                # config.windows.toml). Unreadable: reinstall, no marker, the next run retries.
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
# AFTER MISE: shell, terminals, Claude, python-env, font, SSH key
# =============================================================================

# With Documents redirected (OneDrive), $PROFILE is in the redirected dir but the
# dotfiles deploy to the literal %USERPROFILE%\Documents\PowerShell, so a loader
# at each real $PROFILE dot-sources it. No-op when Documents isn't redirected.
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
        # Back up a hand-written profile once, never clobber it silently.
        if ((Test-Path $target) -and -not (Select-String -Path $target -Pattern "managed by bootstrap.ps1" -Quiet)) {
            $bak = "$target.pre-dotfiles.bak"
            if (-not (Test-Path $bak)) { Copy-Item $target $bak -Force; Write-Warn "Backed up existing $sub profile to $bak" }
        }
        Set-Content -Path $target -Value $loader -Encoding UTF8
        Write-Ok "Profile loader installed: $target"
    }
    Write-Warn "Restart PowerShell to pick up the managed profile."
}

# <Exe> in `mise where <Tool>` (a versioned dir), or $null when mise, the tool or the exe is missing.
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

# mise's GUI zips ship no Start Menu shortcut: a fixed per-user <Name>.lnk (.Save()
# overwrites, so no duplicates), re-pointed when a version bump moves the exe.
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

        $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) "$($tool.Name).lnk"

        try {
            $existed = Test-Path $lnk
            $wsh = New-Object -ComObject WScript.Shell
            try {
                # CreateShortcut loads an existing .lnk, so a matching target skips the rewrite.
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

# Each concrete Host alias in the untracked ~\.ssh\config.local (the public repo has
# no hosts) becomes an "SSH: <alias>" WT profile and Warp Tab Config. Patterns,
# negations and aliases that need quoting are skipped; Include isn't followed.
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

# RFC 4122 v5 GUID over UTF-16LE names (WT's fragment convention: namespace -> app ->
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

# Only Fragments\workstation is owned here, rewritten every run so a removed host
# disappears; other apps' fragments and the tracked settings.json are never touched.
function Invoke-WindowsTerminalFragments {
    if (-not (Test-WindowsTerminalPresent)) {
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

# Warp's + menu has no profile list, so the local shells and each SSH host get a
# Tab Config; workstation-* files are rewritten every run, others never touched.
# Warp can't run Nushell, so pwsh launches mise's nu.exe shim (a stable path; the
# install dir is versioned); Nushell's real home is Windows Terminal.
function Invoke-WarpTabConfigs {
    if (-not (Test-InstallerPresent "Warp*")) {
        Write-Warn "Skipping Warp Tab Config generation — Warp is not installed."
        return
    }

    $dir = Join-Path $env:APPDATA "warp\Warp\data\tab_configs"
    try {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
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

# dnGrep keeps settings next to the exe, in mise's versioned dir, so a seeded
# dnGrep.config.xml points them at %APPDATA%\dnGREP (expanded: dnGrep doesn't expand
# %ENV%). Seed-if-absent: dnGrep's Options dialog rewrites it; a new dir is reseeded.
function Invoke-DnGrepConfig {
    $exe = Get-MiseToolExe -Tool "github:dnGrep/dnGrep" -Exe "dnGREP.exe"
    if (-not $exe) {
        Write-Warn "Skipping dnGrep config seed — dnGREP.exe not found via 'mise where github:dnGrep/dnGrep' (tools phase skipped?)."
        return
    }

    $cfg = Join-Path (Split-Path $exe -Parent) "dnGrep.config.xml"

    # The target dirs must exist: dnGrep enumerates DataDirectory at startup and
    # crashes (DirectoryNotFoundException) on a missing one it didn't default to.
    # Read them from the file, so a user-customised location is healed too.
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
        # Dirs first (-Force creates $dataDir too): if that fails, no config is
        # written and dnGrep keeps its exe-dir default instead of crashing.
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        [System.IO.File]::WriteAllText($cfg, $xml, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "dnGrep config seeded (settings dir -> $dataDir)"
    } catch {
        Write-Warn "Could not seed the dnGrep config: $($_.Exception.Message)"
    }
}

# BurntToast gives dotfiles/claude/notify.sh's WSL2 branch native Windows toasts
# when Claude Code needs attention (without it, a MessageBox).
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
        # PSGallery is Untrusted by default, so Install-Module would prompt; trust
        # it so the install runs unattended (a missing PSGallery is skipped).
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
    # seed (set-if-absent) -> live -> enforced (always wins), the jq filter of
    # scripts/lib/claude-settings-merge.sh. A failure warns; it never aborts the bootstrap.
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

    # jq.exe writes UTF-8: read it as UTF-8 whatever the console code page.
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
    # Seed-if-absent, as on Linux: no enforced layer, so a later edit is never clobbered.
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

# The official installer verifies claude.exe against the signed manifest and it
# self-updates: not a mise tool, nor a winget GUI app (no Uninstall key). A child
# powershell.exe runs it because it calls `exit` on its error paths.
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

# The `python-env` task's Windows half: a uv venv on mise's python with python-env.txt's
# libraries. The stamp is the interpreter path + the parsed list, so a python bump or
# a list change rebuilds and a comment edit doesn't (to upgrade, delete the stamp).
function Invoke-PythonEnv {
    if ($SkipToolInstall) {
        Write-Log "Python env skipped (-SkipToolInstall)"
        return
    }
    $python = Get-MiseToolExe -Tool python -Exe python.exe
    $uvExe = $null
    if ($python) {
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = @(& mise -C $env:USERPROFILE which uv 2>$null); $code = $LASTEXITCODE } finally { $ErrorActionPreference = $oldEap }
        if (($code -eq 0) -and ($out.Count -gt 0)) { $uvExe = "$($out[0])".Trim() }
    }
    $libsFile = Join-Path $RepoPath "scripts\python-env.txt"
    if (-not $python -or -not $uvExe -or -not (Test-Path -LiteralPath $libsFile)) {
        Write-Warn "Python env skipped — needs mise's python + uv ('mise where python', 'mise which uv': did the tools phase fail?) and $libsFile"
        return
    }
    # One name per line; `#` starts a comment (whole line, or after whitespace).
    $libs = @(Get-Content -Encoding UTF8 -LiteralPath $libsFile | ForEach-Object { ($_ -replace '(^|\s+)#.*$', '').Trim() } | Where-Object { $_ })
    $want = (@($python) + $libs) -join "`n"
    $stamp = Join-Path $WsStamps "python-env.stamp"
    $wpyShim = Join-Path $WsBin "wpy.cmd"
    if ((Test-Path $stamp) -and ([System.IO.File]::ReadAllText($stamp).Trim() -eq $want) -and (Test-Path $wpyShim)) {
        Write-Ok "Python env already built ($WsPythonEnv on $python)"
        return
    }

    Write-Log "Building Python scripting env on $python ($($libs.Count) libs)..."
    try {
        if (Test-Path $WsPythonEnv) { Remove-Item -Recurse -Force $WsPythonEnv }
        & $uvExe venv --python $python $WsPythonEnv
        if ($LASTEXITCODE -ne 0) { throw "uv venv exited $LASTEXITCODE" }
        $envPy = Join-Path $WsPythonEnv "Scripts\python.exe"
        & $uvExe pip install --python $envPy --upgrade @libs
        if ($LASTEXITCODE -ne 0) { throw "uv pip install exited $LASTEXITCODE" }

        $scripts = Join-Path $WsPythonEnv "Scripts"
        Set-Content -Path $wpyShim -Value "@echo off`r`n`"$envPy`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "textual.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'textual.exe')`" %*" -Encoding Ascii
        Set-Content -Path (Join-Path $WsBin "typer.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'typer.exe')`" %*" -Encoding Ascii

        if (-not (Test-Path $WsStamps)) { New-Item -ItemType Directory -Force -Path $WsStamps | Out-Null }
        # python-env*: also the older python-env.<pin>.<hash>.stamp names.
        Get-ChildItem -Path $WsStamps -Filter "python-env*.stamp" -ErrorAction SilentlyContinue | Remove-Item -Force
        [System.IO.File]::WriteAllText($stamp, $want)
        Write-Ok "Python env built ($WsPythonEnv on $python; launchers: wpy, textual, typer)"
    } catch {
        Write-Warn "Python env build failed: $($_.Exception.Message)"
        Write-Warn "  Re-run .\bootstrap.ps1 to retry (no stamp was written)."
    }
}

# mise installs JetBrainsMono Nerd Font (config.owned.toml, as tasks/fonts uses on
# Linux); scripts/install-nerd-fonts.ps1 copies the six Mono TTFs and registers
# them per-user, plus an at-logon task, since HKCU fonts don't reliably load alone.
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
    $ttf = Get-MiseToolExe -Tool "github:ryanoasis/nerd-fonts" -Exe "JetBrainsMonoNerdFontMono-Regular.ttf"
    if (-not $ttf) {
        Write-Warn "Nerd Fonts skipped — 'mise where github:ryanoasis/nerd-fonts' has no JetBrainsMono Nerd Font Mono TTFs (did the tools phase fail?)"
        return
    }
    $src = Split-Path -Parent $ttf

    try {
        & $InstallScript -SourceDir $src
    } catch {
        Write-Warn "Nerd Fonts install failed: $_"
        Write-Warn "  Retry: re-run .\bootstrap.ps1, or  & '$InstallScript' -SourceDir '$src'"
    }
}

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
Invoke-ToolInstall        # the pinned mise under %LOCALAPPDATA%\workstation
Invoke-CloneRepo
Invoke-MiseBootstrap      # `mise bootstrap --only dotfiles,tools` -- dotfiles + every CLI tool; old portable tools removed, shims on PATH, node marker, prune; .wslconfig reminder; its post-tools hook regenerates Nushell's init files (mise run nu-init)
Install-WingetApps        # GUI apps: mise bootstrap --only packages (config.windows.toml's winget list), then SSHFS-Win (UAC)
Invoke-StartMenuShortcuts # per-user Start Menu .lnks for the mise-installed GUI tools (dnGrep/LogExpert)
Invoke-WarpTabConfigs     # regenerate Warp Tab Configs (local shells + ~\.ssh\config.local hosts) — self-heals
Invoke-WindowsTerminalFragments # Windows Terminal "SSH: <host>" profiles from ~\.ssh\config.local — self-heals
Invoke-DnGrepConfig       # seed dnGrep.config.xml (settings dir -> %APPDATA%\dnGREP; re-seeded per mise install dir)
Invoke-ProfileShim        # bridge Documents redirection (OneDrive) so $PROFILE loads the managed profile
Invoke-InstallBurntToast  # PowerShell-module install for Claude Code WSL2 notification hooks
Invoke-InstallClaudeCode  # native Claude Code via the official installer (manifest-verified; self-updates)
Invoke-ClaudeSettingsMerge     # ~/.claude/settings.json seed+live+enforced jq merge
Invoke-ClaudeSettingsLocalSeed # ~/.claude/settings.local.json seed-if-absent
Invoke-PythonEnv          # blessed uv venv on mise's python + scripts\python-env.txt (wpy/textual/typer shims)
Invoke-InstallNerdFonts   # JetBrainsMono Nerd Font Mono from mise — per-user registration + logon task
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

# Skipped when the list is missing (a partial clone or an older snapshot).
$appList = Join-Path $RepoPath "docs\windows\application_list.md"
if (Test-Path $appList) {
    Write-Host "${Bold}Hand-install shopping list${Reset} (docs\windows\application_list.md):"
    # -Encoding UTF8: the list has no BOM, and 5.1's default (the ANSI code page) mangles its em dashes.
    Get-Content -Encoding UTF8 $appList | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
}

Write-Host "Editing dotfiles (new Nushell/PowerShell shell):"
Write-Host "  wse <path>   # edit a tracked file in the repo source"
Write-Host "  wsd          # see what would change"
Write-Host "  wsa          # apply; asks first if a deployed file has a local edit it would overwrite"
Write-Host "  wsr          # record an app's own edit to a deployed file back into the repo"
