# Tests scripts/wezterm-nightly.ps1 against fake nightly builds served over file://:
# a fresh install, an up-to-date run that downloads no zip, a new nightly (the junction
# moves, the old build goes), a build a running process started through current\ still
# uses (kept whole, then removed by a later up-to-date run), a rebuild of the installed
# version (not reinstalled), a checksum mismatch (the installed build stays, exit 0), a
# new build that doesn't load the config (refused, not downloaded again; on a first
# install, installed with a warning), a root given as an 8.3 short path, and an
# unreachable URL (exit 0, the toast id registered and a deleted shortcut restored),
# %APPDATA%\wezterm, and the User environment (WEZTERM_CONFIG_FILE, the PATH entry once,
# PATH's REG_EXPAND_SZ kept). The toast id and the environment go to throwaway HKCU
# keys, never the real ones. The fake builds can't run, so every run but the config-check
# cases passes -NoConfigCheck, and with the check on, they never load the config.
# Windows PowerShell 5.1 and pwsh; ASCII only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$script = Join-Path $PSScriptRoot 'wezterm-nightly.ps1'
$shell = (Get-Process -Id $PID).Path

$tmp = New-TestTempDir 'wezterm-nightly-'
$src = Join-Path $tmp 'src'
$root = Join-Path $tmp 'root'
$menu = Join-Path $tmp 'menu'
$base = 'file:///' + ($src -replace '\\', '/')
$zip = Join-Path $src 'WezTerm-windows-nightly.zip'
$toastRoot = "HKCU:\Software\workstation-test-$([guid]::NewGuid())"
$toastKey = "$toastRoot\org.wezfurlong.wezterm"
$envKey = "$toastRoot\Environment"
$dataDir = Join-Path $tmp 'appdata\wezterm'
$config = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\dotfiles\config\wezterm\wezterm.lua'))

# A fake nightly of version <tag>: WezTerm-windows-<tag>\wezterm-gui.exe (text) and
# friends, its zip and .sha256. -Rebuild changes the zip but not the version.
function New-Nightly([string]$Tag, [string]$Sha, [string]$Rebuild) {
    $stage = Join-Path $tmp "stage-$Tag"
    New-TestFile (Join-Path $stage "WezTerm-windows-$Tag\wezterm-gui.exe") "gui $Tag"
    New-TestFile (Join-Path $stage "WezTerm-windows-$Tag\wezterm.exe") "cli $Tag"
    New-TestFile (Join-Path $stage "WezTerm-windows-$Tag\mesa\opengl32.dll") "mesa $Tag$Rebuild"
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Compress-Archive -Path (Join-Path $stage "WezTerm-windows-$Tag") -DestinationPath $zip -Force
    $hash = if ($Sha) { $Sha } else { (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() }
    [IO.File]::WriteAllText("$zip.sha256", "$hash  WezTerm-windows-nightly.zip`n")
    return $hash
}
function Invoke-Nightly([string]$Base = $base, [string]$At = $root, [switch]$CheckConfig) {
    $check = @(if (-not $CheckConfig) { '-NoConfigCheck' })
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $script -BaseUrl $Base -Root $At -ShortcutDir $menu -ToastKey $toastKey -EnvKey $envKey -DataDir $dataDir @check 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}
function Get-Current { (Get-Item -LiteralPath (Join-Path $root 'current')).Target }
function Get-ToastName { (Get-ItemProperty -LiteralPath $toastKey -ErrorAction SilentlyContinue).DisplayName }
# The raw User PATH (unexpanded) and its kind, and WEZTERM_CONFIG_FILE, from the test key.
function Get-Env {
    $k = Get-Item -LiteralPath $envKey
    [pscustomobject]@{
        Path = $k.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        Kind = "$($k.GetValueKind('Path'))"
        Config = $k.GetValue('WEZTERM_CONFIG_FILE')
    }
}
function Get-ShortcutTarget {
    $wsh = New-Object -ComObject WScript.Shell
    try { $wsh.CreateShortcut((Join-Path $menu 'WezTerm.lnk')).TargetPath } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) }
}

try {
    # A User PATH as Windows keeps it: REG_EXPAND_SZ, with a %variable% entry.
    New-Item -Path $envKey -Force | Out-Null
    New-ItemProperty -LiteralPath $envKey -Name Path -Value '%USERPROFILE%\bin;C:\tools' -PropertyType ExpandString | Out-Null
    $first = New-Nightly 'a'
    $firstDir = Join-Path $root $first.Substring(0, 12)

    Test-Case 'fresh install: the build, the current junction, the stamp and the shortcut' {
        $r = Invoke-Nightly
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert (Test-Path -LiteralPath (Join-Path $firstDir 'wezterm-gui.exe')) "no build in $firstDir`n$($r.Out)"
        Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui a') 'current\ is not the new build'
        Assert ("$(Get-Current)" -like "*$($first.Substring(0, 12))") "current points at $(Get-Current)"
        Assert ((Read-Text (Join-Path $root 'current.sha256')) -eq $first) 'stamp is not the published sha256'
        Assert ((Read-Text (Join-Path $root 'current.version')) -eq 'a') 'current.version is not the zip folder version'
        Assert ((Get-ShortcutTarget) -eq (Join-Path $root 'current\wezterm-gui.exe')) "shortcut target: $(Get-ShortcutTarget)"
        Assert ((Get-ToastName) -eq 'WezTerm') "toast id not registered: $($r.Out)"
        Assert ((Test-Path -LiteralPath $dataDir) -and $r.Out -match 'created') "no $dataDir (the palette's recents): $($r.Out)"
    }

    Test-Case 'the User environment: WEZTERM_CONFIG_FILE, and current\ on PATH with its kind kept' {
        $e = Get-Env
        Assert ($e.Config -eq $config -and (Test-Path -LiteralPath $e.Config)) "WEZTERM_CONFIG_FILE: $($e.Config)"
        Assert ($e.Path -eq "%USERPROFILE%\bin;C:\tools;$(Join-Path $root 'current')") "PATH: $($e.Path)"
        Assert ($e.Kind -eq 'ExpandString') "PATH became $($e.Kind)"
    }

    Test-Case 'up to date: no zip download, nothing changes' {
        Remove-Item -LiteralPath $zip
        $r = Invoke-Nightly
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match 'up to date') "no 'up to date': $($r.Out)"
        Assert (@(Get-ChildItem -LiteralPath $root -Directory).Count -eq 2) 'a build directory appeared or went'
        Assert ((Get-Env).Path -eq "%USERPROFILE%\bin;C:\tools;$(Join-Path $root 'current')") "PATH changed: $((Get-Env).Path)"
        Assert ($r.Out -notmatch 'WEZTERM_CONFIG_FILE|User PATH|created') "the environment or data folder was redone: $($r.Out)"
    }

    $second = New-Nightly 'b'
    $secondDir = Join-Path $root $second.Substring(0, 12)
    Test-Case 'new nightly: the junction moves and the old build is removed' {
        $r = Invoke-Nightly
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui b') "current\ is not build b`n$($r.Out)"
        Assert (Test-Path -LiteralPath $secondDir) 'build b missing'
        Assert (-not (Test-Path -LiteralPath $firstDir)) 'build a was not removed'
        Assert ((Get-ShortcutTarget) -eq (Join-Path $root 'current\wezterm-gui.exe')) 'shortcut moved off current\'
    }

    $third = New-Nightly 'c'
    Test-Case 'a build a running process uses is kept whole' {
        # A copy of ping.exe in build b stands in for a running WezTerm. Started through
        # current\ as the shortcut starts WezTerm, so its path names no build.
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination (Join-Path $secondDir 'wezterm-gui-running.exe')
        $proc = Start-Process -FilePath (Join-Path $root 'current\wezterm-gui-running.exe') -ArgumentList '-n', '60', '127.0.0.1' -PassThru -WindowStyle Hidden
        try {
            $r = Invoke-Nightly
            Assert ($r.Code -eq 0) "exit $($r.Code)"
            Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui c') 'current\ is not build c'
            Assert (Test-Path -LiteralPath (Join-Path $secondDir 'mesa\opengl32.dll')) "build b lost files while in use`n$($r.Out)"
            Assert ($r.Out -match 'kept') "no 'kept' message: $($r.Out)"
        } finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $proc.WaitForExit()
        }
    }

    Test-Case 'a later run removes the kept build, even with nothing new' {
        Start-Sleep -Milliseconds 500
        $r = Invoke-Nightly
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match 'up to date') "no 'up to date': $($r.Out)"
        Assert (-not (Test-Path -LiteralPath $secondDir)) "build b is still there`n$($r.Out)"
    }

    Test-Case 'a rebuild of the installed version: the new checksum is recorded, nothing reinstalled' {
        $rebuilt = New-Nightly 'c' '' ' rebuilt'
        Assert ($rebuilt -ne $third) 'the rebuild has the same SHA256'
        $r = Invoke-Nightly
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match 'rebuilt unchanged' -and $r.Out -notmatch 'installed nightly') "reinstalled: $($r.Out)"
        Assert ("$(Get-Current)" -like "*$($third.Substring(0, 12))") "current moved to $(Get-Current)"
        Assert ((Read-Text (Join-Path $root 'current\mesa\opengl32.dll')) -eq 'mesa c') 'the build was replaced'
        Assert ((Read-Text (Join-Path $root 'current.sha256')) -eq $rebuilt) 'the new SHA256 was not recorded'
        Assert (@(Get-ChildItem -LiteralPath $root -Directory).Count -eq 2) 'a build directory appeared'
    }

    Test-Case 'checksum mismatch: the installed build stays, exit 0' {
        $before = Read-Text (Join-Path $root 'current.sha256')
        $null = New-Nightly 'd' ('0' * 64)
        $r = Invoke-Nightly
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match 'does not match') "no mismatch message: $($r.Out)"
        Assert ((Read-Text (Join-Path $root 'current.sha256')) -eq $before) 'stamp changed'
        Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui c') 'current\ changed'
    }

    Test-Case "a new build that doesn't load the config is refused, then not downloaded again" {
        $refused = New-Nightly 'f'
        $r = Invoke-Nightly -CheckConfig
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match "doesn't load wezterm.lua" -and $r.Out -match 'kept the installed build') "no refusal: $($r.Out)"
        Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui c') 'current\ moved to the refused build'
        Assert (-not (Test-Path -LiteralPath (Join-Path $root $refused.Substring(0, 12)))) 'the refused build was unpacked into the root'
        Assert ((Read-Text (Join-Path $root 'rejected.sha256')) -eq $refused) 'the refused SHA256 was not noted'
        Remove-Item -LiteralPath $zip
        $r = Invoke-Nightly -CheckConfig
        Assert ($r.Code -eq 0 -and $r.Out -match 'was refused' -and $r.Out -notmatch 'not updated') "it tried the refused build again: $($r.Out)"
    }

    Test-Case "a first install that doesn't load the config still installs, with a warning" {
        $fresh = Join-Path $tmp 'fresh'
        $null = New-Nightly 'g'
        $r = Invoke-Nightly -At $fresh -CheckConfig
        try {
            Assert ($r.Code -eq 0) "exit $($r.Code)"
            Assert ((Read-Text (Join-Path $fresh 'current\wezterm-gui.exe')) -eq 'gui g') "nothing installed: $($r.Out)"
            Assert ($r.Out -match 'runs on its defaults') "no warning: $($r.Out)"
        } finally {
            if (Test-Path -LiteralPath (Join-Path $fresh 'current')) { [IO.Directory]::Delete((Join-Path $fresh 'current')) }
        }
    }

    Test-Case 'a root given as an 8.3 short path keeps the new build' {
        # %TEMP% is often a short path while listings give long ones; the cleanup must
        # still recognise the build it just installed. (Where 8.3 names are off, the
        # short path is the long one and this runs as a plain update.)
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($root).ShortPath
        $null = New-Nightly 'e'
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $script -BaseUrl $base -Root $short -ShortcutDir $menu -ToastKey $toastKey -EnvKey $envKey -DataDir $dataDir -NoConfigCheck 2>&1 | Out-String
        Assert ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
        Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui e') "current\ is not build e`n$out"
    }

    Test-Case 'unreachable URL: a warning, exit 0, the toast id and a deleted shortcut restored' {
        Remove-Item -LiteralPath $toastKey -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $menu 'WezTerm.lnk')
        $r = Invoke-Nightly ('file:///' + (($tmp -replace '\\', '/') + '/missing'))
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match 'not updated') "no warning: $($r.Out)"
        Assert ((Get-ToastName) -eq 'WezTerm') "toast id not registered again: $($r.Out)"
        Assert ((Get-ShortcutTarget) -eq (Join-Path $root 'current\wezterm-gui.exe')) "the shortcut was not restored offline: $($r.Out)"
    }
} finally {
    $current = Join-Path $root 'current'
    if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $toastRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Test 'wezterm-nightly'
