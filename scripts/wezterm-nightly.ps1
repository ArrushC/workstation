#Requires -Version 5.1
# =============================================================================
# wezterm-nightly.ps1 -- install or update WezTerm's nightly build for this user.
#
# Run by config.windows.toml's `wezterm-nightly-win` task (the post-tools hook, so
# bootstrap.ps1 and wsu). WezTerm's last versioned release is 20240203; the project
# publishes everything since as one rolling `nightly` release, which its docs
# recommend. A rolling asset can't be a mise pin (the lock's checksum goes stale with
# the next build) or come from winget (wez.wezterm.nightly's manifest checksum lags the
# asset, and its installer raises UAC). So, Scoop-style:
#   1. fetch WezTerm-windows-nightly.zip.sha256, which WezTerm publishes beside the zip;
#   2. stop there when <Root>\current.sha256 already holds it (a few bytes per run);
#   3. else download the zip, refuse it unless its SHA256 matches, and unpack it into
#      <Root>\<first 12 hex of the sha256>\ (per-user, no admin);
#   4. point the junction <Root>\current at it, and the Start Menu shortcut at
#      <Root>\current\wezterm-gui.exe, so the shortcut and a taskbar pin survive updates;
#   5. delete older builds no running process uses (a running WezTerm keeps its own
#      directory; the next run deletes it).
# Every run also registers WezTerm's toast id (Register-ToastId), whatever the download does.
# Every failure warns and exits 0: a failing hook would stop `mise bootstrap`.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.
# scripts/test-wezterm-nightly.ps1 tests it against file:// URLs (-BaseUrl).
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wezterm-nightly.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://github.com/wezterm/wezterm/releases/download/nightly',
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'workstation\wezterm'),
    [string]$ShortcutDir = [Environment]::GetFolderPath('Programs'),
    [string]$ToastKey = 'HKCU:\Software\Classes\AppUserModelId\org.wezfurlong.wezterm'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$zipName = 'WezTerm-windows-nightly.zip'
$current = Join-Path $Root 'current'
$stamp = Join-Path $Root 'current.sha256'

function Write-Step([string]$Message) { Write-Host "  wezterm: $Message" }

# curl.exe with bootstrap.ps1's Invoke-CurlRequest flags: retries, and a stalled
# transfer aborts instead of hanging.
function Get-Url([string]$Uri, [string]$OutFile) {
    $curlArgs = @('--disable', '--fail', '--silent', '--show-error', '--location',
        '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30',
        '--speed-limit', '1', '--speed-time', '60', '--output', $OutFile, '--url', $Uri)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & curl.exe @curlArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe exit ${LASTEXITCODE} for ${Uri}: $((@($out) | ForEach-Object { "$_".Trim() }) -join ' ')"
    }
}

# The Start Menu entry, (re)written only when it is missing or points elsewhere.
function Set-Shortcut([string]$Target) {
    New-Item -ItemType Directory -Force -Path $ShortcutDir | Out-Null
    $lnk = Join-Path $ShortcutDir 'WezTerm.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    try {
        $existed = Test-Path -LiteralPath $lnk
        $sc = $wsh.CreateShortcut($lnk)
        if ($existed -and $sc.TargetPath -eq $Target) { return }
        $sc.TargetPath = $Target
        $sc.WorkingDirectory = $env:USERPROFILE
        $sc.Description = 'WezTerm (nightly): GPU terminal, config ~\.wezterm.lua'
        $sc.Save()
        Write-Step "Start Menu shortcut -> $Target"
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
    }
}

# WezTerm raises its toasts (OSC 9 / 777 from programs, ~/.claude/notify.sh) under the
# AppUserModelId org.wezfurlong.wezterm, and Windows silently drops a toast from an id
# nobody registered. WezTerm's installer registers it; a zip can't, so this does, per user
# (DisplayName is all Windows needs), on every run so a deleted key comes back.
function Register-ToastId {
    try {
        $cur = Get-ItemProperty -LiteralPath $ToastKey -ErrorAction SilentlyContinue
        if ($cur -and $cur.PSObject.Properties['DisplayName'] -and $cur.DisplayName -eq 'WezTerm') { return }
        New-Item -Path $ToastKey -Force | Out-Null
        New-ItemProperty -LiteralPath $ToastKey -Name DisplayName -Value 'WezTerm' -PropertyType String -Force | Out-Null
        Write-Step 'registered the toast id, so WezTerm notifications can show'
    } catch {
        Write-Step "! could not register the toast id: $($_.Exception.Message)"
    }
}

# True when a running process's image lives under $Dir.
function Test-InUse([string]$Dir) {
    $prefix = $Dir.TrimEnd('\') + '\'
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        $path = $null
        try { $path = $p.Path } catch { $path = $null }
        if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

Register-ToastId
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wezterm-nightly-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Force -Path $Root, $tmp | Out-Null
    Get-Url "$BaseUrl/$zipName.sha256" (Join-Path $tmp 'sha256')
    $want = (([IO.File]::ReadAllText((Join-Path $tmp 'sha256'))).Trim() -split '\s+')[0].ToLowerInvariant()
    if ($want -notmatch '^[0-9a-f]{64}$') { throw "unexpected $zipName.sha256 contents" }
    $exe = Join-Path $current 'wezterm-gui.exe'
    $have = if (Test-Path -LiteralPath $stamp) { ([IO.File]::ReadAllText($stamp)).Trim() } else { '' }
    if ($have -eq $want -and (Test-Path -LiteralPath $exe)) {
        Set-Shortcut $exe
        Write-Step "nightly up to date ($($want.Substring(0, 12)))"
        exit 0
    }

    $zip = Join-Path $tmp $zipName
    Get-Url "$BaseUrl/$zipName" $zip
    $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($got -ne $want) {
        # A new nightly can land between the two downloads; the next run gets a matching pair.
        throw "$zipName SHA256 $got does not match the published $want; kept the installed build"
    }
    $unpacked = Join-Path $tmp 'x'
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
    # The zip holds one top-level folder (WezTerm-windows-<version>).
    $top = @(Get-ChildItem -LiteralPath $unpacked)
    $content = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $unpacked }
    if (-not (Test-Path -LiteralPath (Join-Path $content 'wezterm-gui.exe'))) { throw "$zipName has no wezterm-gui.exe" }

    $build = $want.Substring(0, 12)
    $dest = Join-Path $Root $build
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Move-Item -LiteralPath $content -Destination $dest
    # A non-recursive delete removes the junction itself (RemoveDirectory), never what it
    # points to. No cmd /c rmdir: 5.1 turns cmd's stderr into a terminating error.
    if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
    New-Item -ItemType Junction -Path $current -Target $dest | Out-Null
    [IO.File]::WriteAllText($stamp, $want)
    $version = try { (& (Join-Path $dest 'wezterm.exe') --version 2>$null | Select-Object -First 1) } catch { $null }
    Write-Step "installed nightly $build $(if ($version) { "($version)" })"
    Set-Shortcut $exe

    # By name: a listing gives long paths, and $Root may be an 8.3 short one (%TEMP%).
    foreach ($old in Get-ChildItem -LiteralPath $Root -Directory) {
        if ($old.Name -eq $build -or ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if (Test-InUse $old.FullName) {
            Write-Step "kept $($old.Name): a running WezTerm uses it (the next run removes it)"
            continue
        }
        try { Remove-Item -LiteralPath $old.FullName -Recurse -Force } catch { Write-Step "could not remove $($old.Name): $($_.Exception.Message)" }
    }
} catch {
    Write-Step "! $($_.Exception.Message)"
    Write-Step "! WezTerm nightly not updated; re-run: mise run wezterm-nightly-win"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
