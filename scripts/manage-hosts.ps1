# =============================================================================
# scripts/manage-hosts.ps1
#
# Windows PowerShell host manager. Reads and edits hosts.conf, the single
# source of truth for the fleet inventory.
#
# Provisioning consumes hosts.conf directly: bootstrap.sh self-registers
# this host into it, scripts/update-hosts.sh iterates over it for bulk
# multi-host updates, and bootstrap.ps1's Invoke-WindowsTerminalFragments
# regenerates the workstation Windows Terminal SSH-profile fragment from
# it on every run. No separate inventory file is generated.
#
# Usage (no args opens the interactive menu):
#   .\scripts\manage-hosts.ps1
#   .\scripts\manage-hosts.ps1 -List
#   .\scripts\manage-hosts.ps1 -Format
#   .\scripts\manage-hosts.ps1 -Remove
#   .\scripts\manage-hosts.ps1 -Add  -Name N -Ip I -User U -Group G [-SkipConfirm]
#   .\scripts\manage-hosts.ps1 -CopyId [-Name N]
#   .\scripts\manage-hosts.ps1 -CopyId -All [-SkipConfirm]
#
# This script is feature-paired with scripts/manage-hosts.sh — every
# capability (flags, prompts, post-add flow) MUST be kept in lockstep.
#
# IMPORTANT: This file is UTF-8 with BOM. PowerShell 5.1 reads scripts as
# Windows-1252 unless a BOM is present, and the file uses Unicode glyphs
# (✓, ✗, ─). Do not save without BOM.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Add,
    [switch]$Remove,
    [switch]$CopyId,
    [switch]$All,
    [string]$Name,
    [string]$Ip,
    [string]$User      = "",
    [string]$Group     = "",
    [switch]$SkipConfirm,
    [switch]$Format
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Resolve paths -----------------------------------------------------------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$HostsConf  = Join-Path $RepoRoot "hosts.conf"

# Valid host groups. dev_machine → MODE=dev provisioning (sudo, system-wide);
# prod_machine → MODE=prod (no sudo, ~/.local/bin). makefile/scope.mk maps
# these groups to scope. An unknown group breaks update-hosts.sh's MODE
# derivation, so we reject anything else at save time.
$ValidGroups = @('dev_machine', 'prod_machine')

# --- ANSI escape codes (matches manage-hosts.sh; rendered by Windows
#     Terminal and modern conhost. Old conhost shows raw codes.) -----
$Esc    = [char]27
$Bold   = "$Esc" + "[1m"
$Reset  = "$Esc" + "[0m"
$Red    = "$Esc" + "[0;31m"
$Green  = "$Esc" + "[0;32m"
$Yellow = "$Esc" + "[1;33m"
$Blue   = "$Esc" + "[0;34m"
$Cyan   = "$Esc" + "[0;36m"

# --- Output helpers ----------------------------------------------------------
function Write-Log    { param($msg) Write-Host "${Blue}==>${Reset} ${Bold}$msg${Reset}" }
function Write-Ok     { param($msg) Write-Host "${Green} ✓${Reset} $msg" }
function Write-Warn   { param($msg) Write-Host "${Yellow} !${Reset} $msg" }
function Write-Fail   { param($msg) Write-Host "${Red} ✗${Reset} $msg"; exit 1 }
function Write-Header {
    param($msg)
    Write-Host ""
    Write-Host "${Bold}${Cyan}$msg${Reset}"
    $rule = "─" * 50
    Write-Host "${Cyan}$rule${Reset}"
}

# =============================================================================
# PARSING
# =============================================================================

function Read-Hosts {
    if (-not (Test-Path $HostsConf)) { Write-Fail "hosts.conf not found at $HostsConf" }
    Get-Content $HostsConf |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' } |
        ForEach-Object {
            $parts = ($_ -split '\s+', 4) | ForEach-Object { $_.Trim() }
            if ($parts.Count -ge 4) {
                [PSCustomObject]@{
                    Name  = $parts[0]
                    Ip    = $parts[1]
                    User  = $parts[2]
                    Group = $parts[3]
                }
            }
        }
}

function Test-HostExists {
    param([string]$HostName)
    $hosts = Read-Hosts
    if (-not $hosts) { return $false }
    return ($hosts | Where-Object { $_.Name -eq $HostName } | Measure-Object).Count -gt 0
}

function Test-ValidGroup {
    param([string]$GroupName)
    return $ValidGroups -contains $GroupName
}

function Show-Hosts {
    $hosts = Read-Hosts
    if (-not $hosts) { Write-Warn "No hosts configured yet."; return }

    # Dynamic column widths; minimum = header label length.
    $wName  = "NAME".Length
    $wIp    = "IP".Length
    $wUser  = "USER".Length
    $wGroup = "GROUP".Length
    foreach ($h in $hosts) {
        if ($h.Name.Length  -gt $wName)  { $wName  = $h.Name.Length  }
        if ($h.Ip.Length    -gt $wIp)    { $wIp    = $h.Ip.Length    }
        if ($h.User.Length  -gt $wUser)  { $wUser  = $h.User.Length  }
        if ($h.Group.Length -gt $wGroup) { $wGroup = $h.Group.Length }
    }

    $fmt = "{0,-$wName}  {1,-$wIp}  {2,-$wUser}  {3,-$wGroup}"

    Write-Host ""
    Write-Host "${Bold}$($fmt -f 'NAME', 'IP', 'USER', 'GROUP')${Reset}"
    Write-Host ($fmt -f ("-" * $wName), ("-" * $wIp), ("-" * $wUser), ("-" * $wGroup))
    foreach ($h in $hosts) {
        Write-Host ($fmt -f $h.Name, $h.Ip, $h.User, $h.Group)
    }
    Write-Host ""
}

# Printed after any hosts.conf change. Nothing is generated by this script;
# bootstrap.ps1's Invoke-WindowsTerminalFragments regenerates the
# workstation Windows Terminal SSH-profile fragment from hosts.conf on
# every run. PARITY: manage-hosts.sh prints the same note.
function Show-TerminalRefreshNote {
    Write-Log "Windows Terminal SSH profiles (workstation fragment) pick this up on the next bootstrap.ps1 run."
}

# =============================================================================
# CRUD OPERATIONS
# =============================================================================

function Save-Hosts {
    # Rewrites hosts.conf with dynamically padded columns.
    # Preserves comment/blank lines that appear before the first data line.
    # Sorts rows by group then name so hosts.conf is always in deterministic
    # order after a save (matches `sort -k4,4 -k1,1` on the sh side).
    param([System.Collections.Generic.List[PSCustomObject]]$HostList)

    $sorted = @($HostList | Sort-Object -Property Group, Name)

    # Calculate column widths from actual data (minimum widths enforced)
    $wName = 16; $wIp = 14; $wUser = 10
    foreach ($h in $sorted) {
        if ($h.Name.Length  -gt $wName) { $wName = $h.Name.Length  }
        if ($h.Ip.Length    -gt $wIp)   { $wIp   = $h.Ip.Length    }
        if ($h.User.Length  -gt $wUser) { $wUser = $h.User.Length  }
    }

    # Preserve only comment lines from the top. Blank lines are dropped —
    # preserving them caused one more blank to accumulate on every save.
    $header      = [System.Collections.Generic.List[string]]::new()
    $hadComments = $false
    foreach ($line in (Get-Content $HostsConf)) {
        if ($line -match '^\s*#') {
            $header.Add($line)
            $hadComments = $true
        } elseif ($line -match '^\s*$') {
            continue
        } else {
            break
        }
    }

    $output = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $header) { $output.Add($line) }
    if ($hadComments) { $output.Add("") }
    foreach ($h in $sorted) {
        $output.Add(("{0,-$wName}  {1,-$wIp}  {2,-$wUser}  {3}" -f $h.Name, $h.Ip, $h.User, $h.Group))
    }

    # Write LF-only (Environment.NewLine on Windows is CRLF, which propagates
    # stray \r into fields when the file is read on a Linux host).
    $content = ($output -join "`n") + "`n"
    [System.IO.File]::WriteAllText($HostsConf, $content, [System.Text.UTF8Encoding]::new($false))
}

function Add-Host {
    param(
        [string]$HostName  = "",
        [string]$HostIp    = "",
        [string]$HostUser  = "",
        [string]$HostGroup = "",
        [bool]$NoConfirm   = $false
    )

    if (-not $HostName) {
        Write-Header "Add a new host"
        $HostName = Read-Host "  Host name (e.g. dev-01)"
        if (-not $HostName) { Write-Fail "Name cannot be empty" }
    }

    if (Test-HostExists $HostName) {
        Write-Warn "Host '$HostName' already exists in hosts.conf -- skipping."
        return
    }

    if (-not $HostIp) {
        $HostIp = Read-Host "  IP / hostname"
        if (-not $HostIp) { Write-Fail "IP cannot be empty" }
    }

    if (-not $HostUser) {
        $currentUser = $env:USERNAME
        $lowerUser   = $currentUser.ToLower()
        $upperUser   = $currentUser.ToUpper()

        Write-Host ""
        Write-Host "  SSH user options:"
        Write-Host "    1) $currentUser  (as-is)"
        Write-Host "    2) $lowerUser  (lowercase)"
        Write-Host "    3) $upperUser  (uppercase)"
        Write-Host "    4) custom"
        $choice = Read-Host "  Choice [1]"
        if (-not $choice) { $choice = "1" }

        switch ($choice) {
            "1" { $HostUser = $currentUser }
            "2" { $HostUser = $lowerUser }
            "3" { $HostUser = $upperUser }
            "4" {
                $custom = Read-Host "  Custom username"
                $HostUser = if ($custom) { $custom } else { $currentUser }
            }
            default {
                Write-Warn "Unknown choice -- using as-is"
                $HostUser = $currentUser
            }
        }
    }

    if (-not $HostGroup) {
        Write-Host ""
        Write-Host "  Host group options:"
        Write-Host "    1) prod_machine  (no sudo, user-wide -- default)"
        Write-Host "    2) dev_machine   (sudo, system-wide)"
        $groupChoice = Read-Host "  Choice [1]"
        if (-not $groupChoice) { $groupChoice = "1" }

        switch ($groupChoice) {
            "1" { $HostGroup = "prod_machine" }
            "2" { $HostGroup = "dev_machine" }
            default { Write-Fail "Invalid choice '$groupChoice'. Pick 1 or 2." }
        }
    }

    if (-not (Test-ValidGroup $HostGroup)) {
        Write-Fail "Invalid group '$HostGroup'. Must be one of: $($ValidGroups -join ', ')"
    }

    Write-Host ""
    Write-Host ("  Adding: ${Bold}{0,-20} {1,-18} {2,-14} {3,-14}${Reset}" -f $HostName, $HostIp, $HostUser, $HostGroup)

    if (-not $NoConfirm) {
        $confirm = Read-Host "  Confirm? [Y/n]"
        if ($confirm -and $confirm -notmatch '^[Yy]') { Write-Warn "Aborted."; return }
    }

    $all = [System.Collections.Generic.List[PSCustomObject]](Read-Hosts)
    if (-not $all) { $all = [System.Collections.Generic.List[PSCustomObject]]::new() }
    $all.Add([PSCustomObject]@{ Name = $HostName; Ip = $HostIp; User = $HostUser; Group = $HostGroup })
    Save-Hosts $all
    Write-Ok "Host '$HostName' added to hosts.conf"

    if ($NoConfirm) {
        # Non-interactive default: don't copy keys.
        Show-TerminalRefreshNote
        return
    }

    Write-Host ""
    $copyAns = Read-Host "  Copy SSH key now? [y/N]"
    if ($copyAns -match '^[Yy]$') {
        Invoke-CopyId -TargetName $HostName
    }

    Show-TerminalRefreshNote
}

function Remove-HostEntry {
    Write-Header "Remove a host"
    Show-Hosts

    $hosts = Read-Hosts
    if (-not $hosts) { return }

    $HostName = Read-Host "  Host name to remove"
    if (-not $HostName) { return }

    if (-not (Test-HostExists $HostName)) {
        Write-Warn "Host '$HostName' not found."
        return
    }

    $confirm = Read-Host "  Remove '$HostName'? This cannot be undone. [y/N]"
    if ($confirm -notmatch '^[Yy]') { Write-Warn "Aborted."; return }

    $remaining = [System.Collections.Generic.List[PSCustomObject]](Read-Hosts | Where-Object { $_.Name -ne $HostName })
    Save-Hosts $remaining
    Write-Ok "Host '$HostName' removed from hosts.conf"
    Show-TerminalRefreshNote
}

function Edit-HostEntry {
    Write-Header "Edit a host"
    Show-Hosts

    $hosts = Read-Hosts
    if (-not $hosts) { return }

    $HostName = Read-Host "  Host name to edit"
    if (-not $HostName) { return }

    if (-not (Test-HostExists $HostName)) {
        Write-Warn "Host '$HostName' not found."
        return
    }

    $current = $hosts | Where-Object { $_.Name -eq $HostName } | Select-Object -First 1

    Write-Host ""
    Write-Host "  Current values (press Enter to keep):"

    $newIp = Read-Host "  IP / hostname [$($current.Ip)]"
    $newIp = if ($newIp) { $newIp } else { $current.Ip }

    $newUser = Read-Host "  SSH user [$($current.User)]"
    $newUser = if ($newUser) { $newUser } else { $current.User }

    $newGroup = Read-Host "  Host group [$($current.Group)]"
    $newGroup = if ($newGroup) { $newGroup } else { $current.Group }

    if (-not (Test-ValidGroup $newGroup)) {
        Write-Fail "Invalid group '$newGroup'. Must be one of: $($ValidGroups -join ', ')"
    }

    Write-Host ""
    Write-Host ("  Updated: ${Bold}{0,-20} {1,-18} {2,-14} {3,-14}${Reset}" -f $HostName, $newIp, $newUser, $newGroup)
    $confirm = Read-Host "  Confirm? [Y/n]"
    if ($confirm -and $confirm -notmatch '^[Yy]') { Write-Warn "Aborted."; return }

    $updated = [System.Collections.Generic.List[PSCustomObject]](Read-Hosts | ForEach-Object {
        if ($_.Name -eq $HostName) {
            [PSCustomObject]@{ Name = $HostName; Ip = $newIp; User = $newUser; Group = $newGroup }
        } else { $_ }
    })
    Save-Hosts $updated
    Write-Ok "Host '$HostName' updated"
    Show-TerminalRefreshNote
}

# Ensure %USERPROFILE%\.ssh\id_ed25519.pub exists; prompt to ssh-keygen if
# missing. Calls Write-Fail if the user declines. Returns the pubkey path.
# Single-host Invoke-CopyId and bulk Invoke-CopyIdAll both call this once
# at the top so the keygen prompt only ever fires zero or one times.
function Invoke-EnsureSshKey {
    $privKey = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
    $pubKey  = "$privKey.pub"

    if (Test-Path $pubKey) { return $pubKey }

    Write-Warn "No SSH key at $privKey"
    $ans = Read-Host "  Generate one now? [y/N]"
    if ($ans -match '^[Yy]') {
        $sshDir = Split-Path $privKey -Parent
        if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
        ssh-keygen -t ed25519 -f $privKey -N '""' -C "$env:USERNAME@$env:COMPUTERNAME"
        if ($LASTEXITCODE -ne 0) { Write-Fail "ssh-keygen failed" }
        Write-Ok "Generated $privKey"
        return $pubKey
    } else {
        Write-Fail "Cannot copy without a key. Generate with: ssh-keygen -t ed25519"
    }
}

# Push the local pubkey to <User>@<Ip>. Returns $true on success, $false
# on failure. Windows OpenSSH ships no ssh-copy-id, so we always emulate
# it via ssh + remote mkdir/chmod. Caller decides whether to abort
# (single-host) or continue (bulk).
function Invoke-DoCopySshId {
    param(
        [string]$User,
        [string]$Ip,
        [string]$PubKey
    )

    $keyContent = (Get-Content $PubKey -Raw).Trim()
    $remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && " +
                 "echo '$keyContent' >> ~/.ssh/authorized_keys && " +
                 "sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && " +
                 "chmod 600 ~/.ssh/authorized_keys"

    ssh "$User@$Ip" $remoteCmd
    return ($LASTEXITCODE -eq 0)
}

function Invoke-CopyId {
    param([string]$TargetName)

    $hosts = Read-Hosts
    if (-not $hosts) { Write-Fail "No hosts in hosts.conf" }

    if (-not $TargetName) {
        Write-Header "Copy SSH key to a host"
        Show-Hosts
        $TargetName = Read-Host "  Host name"
        if (-not $TargetName) { Write-Warn "Cancelled."; return }
    }

    if (-not (Test-HostExists $TargetName)) {
        Write-Fail "Host '$TargetName' not found in hosts.conf"
    }

    $target = $hosts | Where-Object { $_.Name -eq $TargetName } | Select-Object -First 1
    $pubKey = Invoke-EnsureSshKey

    Write-Log "Copying $pubKey to $($target.User)@$($target.Ip)..."
    if (Invoke-DoCopySshId -User $target.User -Ip $target.Ip -PubKey $pubKey) {
        Write-Ok "Key copied to $($target.User)@$($target.Ip)"
    } else {
        Write-Fail "ssh failed (exit $LASTEXITCODE) -- check connectivity, password, sshd"
    }
}

# Bulk: copy the local pubkey to every host in hosts.conf. Loop is
# deliberately best-effort -- partial success is normal (some hosts
# offline, password fatigue, key already installed). Final summary lists
# failures.
function Invoke-CopyIdAll {
    param([bool]$NoConfirm = $false)

    Write-Header "Copy SSH key to ALL hosts"

    $hosts = Read-Hosts
    if (-not $hosts) { Write-Warn "No hosts in hosts.conf"; return }

    Show-Hosts

    $count = ($hosts | Measure-Object).Count

    if (-not $NoConfirm) {
        $confirm = Read-Host "  Copy SSH key to all $count hosts? [Y/n]"
        if (-not $confirm) { $confirm = "Y" }
        if ($confirm -notmatch '^[Yy]') { Write-Warn "Aborted."; return }
    }

    $pubKey = Invoke-EnsureSshKey
    Write-Host ""

    $okCount   = 0
    $failCount = 0
    $failed    = [System.Collections.Generic.List[string]]::new()

    foreach ($h in $hosts) {
        Write-Host "  ${Bold}$($h.Name)${Reset} ($($h.User)@$($h.Ip))... " -NoNewline
        if (Invoke-DoCopySshId -User $h.User -Ip $h.Ip -PubKey $pubKey) {
            Write-Host "${Green}✓${Reset}"
            $okCount++
        } else {
            Write-Host "${Red}✗${Reset}"
            $failed.Add($h.Name)
            $failCount++
        }
    }

    Write-Host ""
    Write-Ok "$okCount host(s) successful"
    if ($failCount -gt 0) {
        Write-Warn "$failCount host(s) failed: $($failed -join ', ')"
    }
}

function Test-SshConnection {
    Write-Header "Test SSH connection"
    Show-Hosts

    $hosts = Read-Hosts
    if (-not $hosts) { return }

    $target = Read-Host "  Host name to test (or 'all')"

    $isAll  = ($target -eq "all")
    $toTest = if ($isAll) {
        $hosts
    } else {
        $h = $hosts | Where-Object { $_.Name -eq $target }
        if (-not $h) { Write-Warn "Host '$target' not found."; return }
        $h
    }

    foreach ($h in $toTest) {
        Write-Host "  Testing ${Bold}$($h.Name)${Reset} ($($h.User)@$($h.Ip))... " -NoNewline
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$($h.User)@$($h.Ip)" exit 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $msg = if ($isAll) { "✓ OK" } else { "✓ Connected successfully" }
            Write-Host "${Green}${msg}${Reset}"
        } else {
            $msg = if ($isAll) { "✗ Failed" } else { "✗ Connection failed -- check IP, user, and SSH key" }
            Write-Host "${Red}${msg}${Reset}"
        }
    }
}

function Invoke-FormatHosts {
    $hosts = Read-Hosts
    if (-not $hosts) { Write-Warn "No hosts to format."; return }
    $list = [System.Collections.Generic.List[PSCustomObject]]$hosts
    Save-Hosts $list
    Write-Ok "hosts.conf reformatted ($($list.Count) hosts)"
}

# =============================================================================
# MENU
# =============================================================================

function Show-Menu {
    Write-Header "Workstation host manager"
    Show-Hosts
    Write-Host "${Bold}Pick an option:${Reset}"
    Write-Host "  ${Bold}1)${Reset} Add host"
    Write-Host "  ${Bold}2)${Reset} Remove host"
    Write-Host "  ${Bold}3)${Reset} Edit host"
    Write-Host "  ${Bold}4)${Reset} Test SSH connection"
    Write-Host "  ${Bold}5)${Reset} Copy SSH key"
    Write-Host "  ${Bold}6)${Reset} Copy SSH key to ALL hosts"
    Write-Host "  ${Bold}7)${Reset} View hosts.conf"
    Write-Host "  ${Bold}8)${Reset} Reformat hosts.conf"
    Write-Host "  ${Bold}q)${Reset} Quit"
    Write-Host ""
    $choice = Read-Host "Choice"

    switch ($choice) {
        "1" { Add-Host }
        "2" { Remove-HostEntry }
        "3" { Edit-HostEntry }
        "4" { Test-SshConnection }
        "5" { Invoke-CopyId }
        "6" { Invoke-CopyIdAll }
        "7" { Get-Content $HostsConf }
        "8" { Invoke-FormatHosts }
        "q" { Write-Host "Bye."; exit 0 }
        default { Write-Warn "Unknown option: $choice" }
    }
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

if (-not (Test-Path $HostsConf)) { Write-Fail "hosts.conf not found at $HostsConf" }

if ($Format) { Invoke-FormatHosts; exit 0 }
if ($List)   { Show-Hosts; exit 0 }
if ($Remove) { Remove-HostEntry; exit 0 }
if ($CopyId) {
    if ($All.IsPresent) {
        # -All wins over -Name if both are passed
        Invoke-CopyIdAll -NoConfirm $SkipConfirm.IsPresent
    } else {
        Invoke-CopyId -TargetName $Name
    }
    exit 0
}

if ($Add) {
    Add-Host `
        -HostName  $Name `
        -HostIp    $Ip `
        -HostUser  $User `
        -HostGroup $Group `
        -NoConfirm $SkipConfirm.IsPresent
    exit 0
}

while ($true) { Show-Menu }