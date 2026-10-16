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
#   3. else download the zip and refuse it unless its SHA256 matches. WezTerm rebuilds
#      the nightly daily even without a new commit, so when its top folder
#      (WezTerm-windows-<version>) names the version in <Root>\current.version, only
#      record the new SHA256;
#   4. else check that the new build loads this checkout's config (Test-LoadsConfig). One
#      that doesn't is refused while a working build is installed, and its SHA256 goes to
#      <Root>\rejected.sha256 so later runs don't download it again; the next nightly is
#      tried. Otherwise unpack it into <Root>\<first 12 hex of the sha256>\ (per-user, no
#      admin) and point the junction <Root>\current at it;
#   5. on every run, delete the other builds no running process uses (a running
#      WezTerm keeps its own directory; a later run deletes it).
# Every run also, whatever the download does: registers WezTerm's toast id
# (Register-ToastId); creates %APPDATA%\wezterm (New-DataDir); sets the User environment
# (Set-UserEnvironment): WEZTERM_CONFIG_FILE at this checkout's
# dotfiles\config\wezterm\wezterm.lua, and <Root>\current on PATH for the wezterm CLI; and
# points the Start Menu shortcut at <Root>\current\wezterm-gui.exe, so the shortcut and a
# taskbar pin survive updates (and a deleted shortcut comes back, even offline).
# Every failure warns and exits 0: a failing hook would stop `mise bootstrap`.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.
# scripts/test-wezterm-nightly.ps1 tests it against file:// URLs (-BaseUrl), with
# throwaway registry keys (-ToastKey, -EnvKey) and folders (-Root, -ShortcutDir, -DataDir);
# its fake builds can't run, so -NoConfigCheck skips step 4's check for them.
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/wezterm-nightly.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://github.com/wezterm/wezterm/releases/download/nightly',
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'workstation\wezterm'),
    [string]$ShortcutDir = [Environment]::GetFolderPath('Programs'),
    [string]$ToastKey = 'HKCU:\Software\Classes\AppUserModelId\org.wezfurlong.wezterm',
    [string]$EnvKey = 'HKCU:\Environment',
    [string]$DataDir = (Join-Path $env:APPDATA 'wezterm'),
    [switch]$NoConfigCheck
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$zipName = 'WezTerm-windows-nightly.zip'
$current = Join-Path $Root 'current'
$stamp = Join-Path $Root 'current.sha256'
$versionStamp = Join-Path $Root 'current.version'
$rejectStamp = Join-Path $Root 'rejected.sha256'
$exe = Join-Path $current 'wezterm-gui.exe'
$config = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\dotfiles\config\wezterm\wezterm.lua'))

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

# The Start Menu entry, (re)written only when it is missing or differs.
function Set-Shortcut([string]$Target) {
    New-Item -ItemType Directory -Force -Path $ShortcutDir | Out-Null
    $lnk = Join-Path $ShortcutDir 'WezTerm.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    try {
        $existed = Test-Path -LiteralPath $lnk
        $sc = $wsh.CreateShortcut($lnk)
        $description = 'WezTerm (nightly): GPU terminal'
        if ($existed -and $sc.TargetPath -eq $Target -and $sc.Description -eq $description) { return }
        $sc.TargetPath = $Target
        $sc.WorkingDirectory = $env:USERPROFILE
        $sc.Description = $description
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

# WezTerm keeps the command palette's recent commands in %APPDATA%\wezterm but never
# creates that folder, so without it every palette pick logs "Error while saving recents".
function New-DataDir {
    if (Test-Path -LiteralPath $DataDir) { return }
    try {
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        Write-Step "created $DataDir (the command palette's recent commands)"
    } catch {
        Write-Step "! could not create ${DataDir}: $($_.Exception.Message)"
    }
}

# WezTerm loads its config straight from this checkout, so a save there or a wsu pull
# reloads it and no copy is deployed; <Root>\current on PATH gives the wezterm CLI
# (wezterm imgcat, wezterm cli) to every shell. Written to the registry with PATH's kind
# kept (usually REG_EXPAND_SZ, which [Environment]::SetEnvironmentVariable would flatten
# to REG_SZ), then announced, so Explorer, and the Start Menu shortcut it launches,
# picks them up without a sign-out. A running WezTerm keeps its old environment.
function Set-UserEnvironment([string]$Config, [string]$Bin) {
    try {
        if (-not (Test-Path -LiteralPath $EnvKey)) { New-Item -Path $EnvKey -Force | Out-Null }
        $key = Get-Item -LiteralPath $EnvKey
        $changed = $false
        if ($key.GetValue('WEZTERM_CONFIG_FILE') -ne $Config) {
            New-ItemProperty -LiteralPath $EnvKey -Name WEZTERM_CONFIG_FILE -Value $Config -PropertyType String -Force | Out-Null
            Write-Step "WEZTERM_CONFIG_FILE -> $Config"
            $changed = $true
        }
        $path = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $onPath = $path.Split(';') | Where-Object {
            $_ -and [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -ieq $Bin.TrimEnd('\')
        }
        if (-not $onPath) {
            $kind = if ($key.GetValueNames() -contains 'Path') { "$($key.GetValueKind('Path'))" } else { 'ExpandString' }
            $new = if ($path.TrimEnd(';')) { "$($path.TrimEnd(';'));$Bin" } else { $Bin }
            New-ItemProperty -LiteralPath $EnvKey -Name Path -Value $new -PropertyType $kind -Force | Out-Null
            Write-Step "added $Bin to the User PATH (the wezterm CLI)"
            $changed = $true
        }
        if ($changed) { Send-EnvironmentChange }
    } catch {
        Write-Step "! could not set the User environment: $($_.Exception.Message)"
    }
}

# WM_SETTINGCHANGE "Environment" to every top-level window, as setx sends it.
function Send-EnvironmentChange {
    if (-not ('Workstation.EnvironmentChange' -as [type])) {
        Add-Type -Namespace Workstation -Name EnvironmentChange -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    # HWND_BROADCAST = 0xffff, WM_SETTINGCHANGE = 0x001A, SMTO_ABORTIFHUNG = 0x0002
    $res = [UIntPtr]::Zero
    [void][Workstation.EnvironmentChange]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$res)
}

# True when the wezterm.exe in $Build loads this checkout's config (no window opens). A
# config that fails to load still exits 0 and lists WezTerm's default keys, so the test is
# that show-keys lists this config's Ctrl+Alt+L launcher; scripts/test-wezterm-config.ps1
# checks the rest of its bindings.
function Test-LoadsConfig([string]$Build) {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $keys = & (Join-Path $Build 'wezterm.exe') --config-file $config show-keys 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0 -and $keys -match 'ALT \| CTRL\s+l\s+->\s+ShowLauncherArgs')
    } catch {
        return $false
    }
}

# Moves the unpacked build into the root, trying for 5 s. Windows refuses to move a folder
# while another process has a file in it open, and a program that has just run can be held
# for a moment: on GitHub's Windows runners, their provjobd.exe agent opens each new
# program (wezterm-gui.exe, run by Test-LoadsConfig) for up to 250 ms, measured; an
# antivirus can do the same. A rename, not Move-Item: when the rename fails, Move-Item falls
# back to copying and leaves an empty $To, and moving again would nest the build inside it.
# The same volume only (%TEMP% and %LOCALAPPDATA%), as Windows PowerShell's Move-Item was.
function Move-Build([string]$From, [string]$To, [int]$Tries = 20, [int]$DelayMs = 250) {
    for ($try = 1; ; $try++) {
        try {
            [IO.Directory]::Move($From, $To)
            return
        } catch {
            if ($try -ge $Tries) {
                $e = $_.Exception
                while ($e.InnerException) { $e = $e.InnerException }
                throw "could not move the new build to $To in $($Tries * $DelayMs / 1000) s: $($e.Message)"
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# True when a running process has one of $Dir's programs or libraries loaded: Windows
# refuses to open a loaded image for writing (nothing is written). A process's own path
# can't tell: WezTerm started from the shortcut runs as <Root>\current\wezterm-gui.exe,
# whichever build current pointed at then.
function Test-InUse([string]$Dir) {
    foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File -Include *.exe, *.dll) {
        try { [IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'ReadWrite').Dispose() } catch { return $true }
    }
    return $false
}

# Deletes every build but the one current points at, unless it is in use. By name: a
# listing gives long paths, and $Root may be an 8.3 short one (%TEMP%).
function Remove-OldBuilds {
    $keep = Split-Path -Leaf ([string]@((Get-Item -LiteralPath $current).Target)[0])
    foreach ($old in Get-ChildItem -LiteralPath $Root -Directory) {
        if ($old.Name -eq $keep -or ($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        if (Test-InUse $old.FullName) {
            Write-Step "kept $($old.Name): a running WezTerm uses it (a later run removes it)"
            continue
        }
        try { Remove-Item -LiteralPath $old.FullName -Recurse -Force } catch { Write-Step "could not remove $($old.Name): $($_.Exception.Message)" }
    }
}

Register-ToastId
New-DataDir
Set-UserEnvironment $config $current
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wezterm-nightly-" + [guid]::NewGuid())
try {
    New-Item -ItemType Directory -Force -Path $Root, $tmp | Out-Null
    Get-Url "$BaseUrl/$zipName.sha256" (Join-Path $tmp 'sha256')
    $want = (([IO.File]::ReadAllText((Join-Path $tmp 'sha256'))).Trim() -split '\s+')[0].ToLowerInvariant()
    if ($want -notmatch '^[0-9a-f]{64}$') { throw "unexpected $zipName.sha256 contents" }
    $have = if (Test-Path -LiteralPath $stamp) { ([IO.File]::ReadAllText($stamp)).Trim() } else { '' }
    $rejected = if (Test-Path -LiteralPath $rejectStamp) { ([IO.File]::ReadAllText($rejectStamp)).Trim() } else { '' }
    if ($have -eq $want -and (Test-Path -LiteralPath $exe)) {
        Write-Step "nightly up to date ($($want.Substring(0, 12)))"
    } elseif ($want -eq $rejected -and -not $NoConfigCheck -and (Test-Path -LiteralPath $exe)) {
        Write-Step "nightly $($want.Substring(0, 12)) was refused (it doesn't load wezterm.lua); kept the installed build until the next nightly (delete $rejectStamp to try it again)"
    } else {
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
        $version = if ($content -ne $unpacked) { $top[0].Name -replace '^WezTerm-windows-', '' } else { '' }
        $installed = if (Test-Path -LiteralPath $versionStamp) { ([IO.File]::ReadAllText($versionStamp)).Trim() } else { '' }
        $unchanged = $version -and $version -eq $installed -and (Test-Path -LiteralPath $exe)
        $loads = $unchanged -or $NoConfigCheck -or (Test-LoadsConfig $content)

        if ($unchanged) {
            [IO.File]::WriteAllText($stamp, $want)
            Write-Step "nightly up to date ($version, rebuilt unchanged)"
        } elseif (-not $loads -and (Test-Path -LiteralPath $exe)) {
            # The installed build keeps working with the config; this one would start on
            # WezTerm's defaults.
            [IO.File]::WriteAllText($rejectStamp, $want)
            Write-Step "! nightly $version doesn't load wezterm.lua (a WezTerm regression, or an error in the config); kept the installed build"
        } else {
            $build = $want.Substring(0, 12)
            $dest = Join-Path $Root $build
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            Move-Build $content $dest
            # A non-recursive delete removes the junction itself (RemoveDirectory), never what it
            # points to. No cmd /c rmdir: 5.1 turns cmd's stderr into a terminating error.
            if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
            New-Item -ItemType Junction -Path $current -Target $dest | Out-Null
            [IO.File]::WriteAllText($stamp, $want)
            [IO.File]::WriteAllText($versionStamp, $version)
            $reported = try { (& (Join-Path $dest 'wezterm.exe') --version 2>$null | Select-Object -First 1) } catch { $null }
            Write-Step "installed nightly $build $(if ($reported) { "($reported)" })"
            if (-not $loads) { Write-Step "! it doesn't load wezterm.lua, so WezTerm runs on its defaults (a WezTerm regression, or an error in the config)" }
        }
    }
    Remove-OldBuilds
} catch {
    Write-Step "! $($_.Exception.Message)"
    Write-Step "! WezTerm nightly not updated; re-run: mise run wezterm-nightly-win"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $exe) {
    try { Set-Shortcut $exe } catch { Write-Step "! could not write the Start Menu shortcut: $($_.Exception.Message)" }
}
exit 0
