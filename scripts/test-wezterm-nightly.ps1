# Tests scripts/wezterm-nightly.ps1 against fake nightly builds served over file://:
# a fresh install, an up-to-date run that downloads no zip, a new nightly (the junction
# moves, the old build goes), a build a running process still uses (kept), a checksum
# mismatch (the installed build stays, exit 0), a root given as an 8.3 short path, and
# an unreachable URL (exit 0, the toast id still registered), and the User environment
# (WEZTERM_CONFIG_FILE, the PATH entry once, PATH's REG_EXPAND_SZ kept). The toast id and
# the environment go to throwaway HKCU keys, never the real ones.
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
$config = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\dotfiles\config\wezterm\wezterm.lua'))

# A fake nightly: WezTerm-windows-<tag>\wezterm-gui.exe (text), its zip and .sha256.
function New-Nightly([string]$Tag, [string]$Sha) {
    $stage = Join-Path $tmp "stage-$Tag"
    New-TestFile (Join-Path $stage "WezTerm-windows-$Tag\wezterm-gui.exe") "gui $Tag"
    New-TestFile (Join-Path $stage "WezTerm-windows-$Tag\wezterm.exe") "cli $Tag"
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Compress-Archive -Path (Join-Path $stage "WezTerm-windows-$Tag") -DestinationPath $zip -Force
    $hash = if ($Sha) { $Sha } else { (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() }
    [IO.File]::WriteAllText("$zip.sha256", "$hash  WezTerm-windows-nightly.zip`n")
    return $hash
}
function Invoke-Nightly([string]$Base = $base) {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $script -BaseUrl $Base -Root $root -ShortcutDir $menu -ToastKey $toastKey -EnvKey $envKey 2>&1 | Out-String
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
        Assert ((Get-ShortcutTarget) -eq (Join-Path $root 'current\wezterm-gui.exe')) "shortcut target: $(Get-ShortcutTarget)"
        Assert ((Get-ToastName) -eq 'WezTerm') "toast id not registered: $($r.Out)"
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
        Assert ($r.Out -notmatch 'WEZTERM_CONFIG_FILE|User PATH') "the environment was rewritten: $($r.Out)"
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

    Test-Case 'a build a running process uses is kept' {
        # A copy of ping.exe started from build b's directory stands in for a running WezTerm.
        $fake = Join-Path $secondDir 'wezterm-gui-running.exe'
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $fake
        $proc = Start-Process -FilePath $fake -ArgumentList '-n', '60', '127.0.0.1' -PassThru -WindowStyle Hidden
        try {
            $null = New-Nightly 'c'
            $r = Invoke-Nightly
            Assert ($r.Code -eq 0) "exit $($r.Code)"
            Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui c') 'current\ is not build c'
            Assert (Test-Path -LiteralPath (Join-Path $secondDir 'wezterm-gui.exe')) 'build b was removed while in use'
            Assert ($r.Out -match 'kept') "no 'kept' message: $($r.Out)"
        } finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $proc.WaitForExit()
        }
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

    Test-Case 'a root given as an 8.3 short path keeps the new build' {
        # %TEMP% is often a short path while listings give long ones; the cleanup must
        # still recognise the build it just installed. (Where 8.3 names are off, the
        # short path is the long one and this runs as a plain update.)
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($root).ShortPath
        $null = New-Nightly 'e'
        $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $script -BaseUrl $base -Root $short -ShortcutDir $menu -ToastKey $toastKey -EnvKey $envKey 2>&1 | Out-String
        Assert ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
        Assert ((Read-Text (Join-Path $root 'current\wezterm-gui.exe')) -eq 'gui e') "current\ is not build e`n$out"
    }

    Test-Case 'unreachable URL: a warning, exit 0, the toast id still registered' {
        Remove-Item -LiteralPath $toastKey -Recurse -Force
        $r = Invoke-Nightly ('file:///' + (($tmp -replace '\\', '/') + '/missing'))
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match 'not updated') "no warning: $($r.Out)"
        Assert ((Get-ToastName) -eq 'WezTerm') "toast id not registered again: $($r.Out)"
    }
} finally {
    $current = Join-Path $root 'current'
    if (Test-Path -LiteralPath $current) { [IO.Directory]::Delete($current) }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $toastRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Test 'wezterm-nightly'
