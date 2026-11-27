# Tests scripts/kiri.ps1, imported from its AST, and runs it whole:
#   Read-Feed (the live feed's shape, and refusing what isn't JSON or an object, a missing
#   key, a bad version, an installer URL on another host, under another name or for
#   another architecture, a malformed SHA-256), Test-Sha256, Get-WslDistro (a throwaway
#   registry key) and Get-SetupState (no file, not JSON, not done, done), Install-Kiri over
#   file:// fixtures with a stand-in for msiexec (a .cmd that logs its arguments): nothing
#   fetched when Kiri is there or no WSL distro is registered, a verified MSI is handed
#   to the installer as `/i "<msi>" /qn /norestart`, a SHA-256 mismatch never reaches the
#   installer, a failing installer or one that leaves no kiri-win.exe throws, and the
#   download folder is removed each time. Whole-script runs: an unreachable feed, no WSL,
#   an install and a second run; exit 0 each time.
# Every run uses throwaway install and work folders and the stand-in installer: never
# %LOCALAPPDATA%\Kiri, never msiexec.
# Windows PowerShell 5.1 and pwsh; ASCII only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$script = Join-Path $PSScriptRoot 'kiri.ps1'
$shell = (Get-Process -Id $PID).Path
$ast = Read-ScriptAst $script
. (Import-AstFunction $ast 'Read-Feed', 'Test-Sha256', 'Write-Step', 'Get-Url', 'Get-WslDistro', 'Get-SetupState', 'Install-Kiri')
$script:steps = New-Object System.Collections.Generic.List[string]
function Write-Step([string]$Message) { $script:steps.Add($Message) }   # record; the whole-script runs keep the real one

$tmp = New-TestTempDir 'kiri-'
$work = Join-Path $tmp 'work dir'            # a space, as under a OneDrive profile
$appDir = Join-Path $tmp 'Local\Kiri'
$log = Join-Path $tmp 'installer.log'
$base = 'https://download.runkiri.com'
$live = '{"version":"0.2.2","url":"https://download.runkiri.com/Kiri-0.2.2-x86_64.msi","sha256":"647128f8ca4831020da683f4301f16238d3417bc01519def687073e036271ca8","size":62287872,"notes":"## Security"}'
$lxss = "HKCU:\Software\workstation-test-kiri-$PID"
$noLxss = "$lxss-none"

# The stand-in for msiexec: logs its arguments, then does what KIRI_TEST_MODE says:
# 'fail' exits 1603, 'empty' exits 0 and installs nothing, 'restart' installs and exits
# 3010, anything else installs (a kiri-win.exe in KIRI_TEST_APPDIR) and exits 0.
$installer = Join-Path $tmp 'msiexec-standin.cmd'
New-TestFile $installer (@'
@echo off
>"%KIRI_TEST_LOG%" echo %*
if "%KIRI_TEST_MODE%"=="fail" exit /b 1603
if "%KIRI_TEST_MODE%"=="empty" exit /b 0
if not exist "%KIRI_TEST_APPDIR%" mkdir "%KIRI_TEST_APPDIR%"
>"%KIRI_TEST_APPDIR%\kiri-win.exe" echo fake kiri
if "%KIRI_TEST_MODE%"=="restart" exit /b 3010
exit /b 0
'@ -replace "`r?`n", "`r`n")
$env:KIRI_TEST_LOG = $log
$env:KIRI_TEST_APPDIR = $appDir

function Get-HexSha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $alg = [Security.Cryptography.SHA256]::Create()
        try { -join ($alg.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) } finally { $alg.Dispose() }
    } finally { $stream.Dispose() }
}
function Assert-Throws([scriptblock]$Body, [string]$Like) {
    try { & $Body } catch { Assert ($_.Exception.Message -like $Like) "threw '$($_.Exception.Message)', wanted '$Like'"; return }
    throw "FAIL: no exception, wanted '$Like'"
}
function ConvertTo-FileUrl([string]$Path) { 'file:///' + ($Path -replace '\\', '/') }
# A feed server as a folder (no space in it: curl file:// URLs): <name>\latest-windows-
# x86_64.json and <name>\Kiri-9.8.7-x86_64.msi. $How: 'ok' or 'badsha'.
function New-Feed([string]$Name, [string]$How = 'ok') {
    $root = Join-Path $tmp $Name
    $url = ConvertTo-FileUrl $root
    $msi = Join-Path $root 'Kiri-9.8.7-x86_64.msi'
    New-TestFile $msi 'not a real msi'
    $sha = if ($How -eq 'badsha') { '0' * 64 } else { Get-HexSha256 $msi }
    New-TestFile (Join-Path $root 'latest-windows-x86_64.json') ('{"version":"9.8.7","url":"' + "$url/Kiri-9.8.7-x86_64.msi" + '","sha256":"' + $sha + '","size":14}')
    return $url
}
function Reset-Flow([string]$Mode = 'ok') {
    $script:steps.Clear()
    $env:KIRI_TEST_MODE = $Mode
    foreach ($d in (Join-Path $tmp 'Local'), $work) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $work | Out-Null
}
function Get-WorkLeft { @(Get-ChildItem -LiteralPath $work -Force).Count }
function Install-Test([string]$Feed, [string[]]$Distros = @('AlmaLinux-9')) {
    Install-Kiri -FeedBase $Feed -Arch 'x86_64' -AppDir $appDir -WorkDir $work -Msiexec $installer -Distros $Distros
}
function Invoke-Script([string]$Feed, [string]$Key = $lxss) {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $script -FeedBase $Feed -AppDir $appDir -WorkDir $work -Msiexec $installer -LxssKey $Key -Arch x86_64 2>&1 | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

try {
    New-Item -Path "$lxss\{one}" -Force | Out-Null
    New-ItemProperty -Path "$lxss\{one}" -Name DistributionName -Value 'AlmaLinux-9' | Out-Null

    Test-Case 'Read-Feed: the live feed' {
        $f = Read-Feed $live $base 'x86_64'
        Assert ($f.Version -ceq '0.2.2' -and $f.Url -ceq "$base/Kiri-0.2.2-x86_64.msi" -and $f.Sha256.Length -eq 64) "$($f.Version) $($f.Url)"
    }
    Test-Case 'Read-Feed: refuses what is not a usable feed' {
        Assert-Throws { Read-Feed '{ "version": ' $base 'x86_64' } '*not JSON*'
        Assert-Throws { Read-Feed '[1, 2]' $base 'x86_64' } '*not a JSON object*'
        Assert-Throws { Read-Feed '{"version":"1.0.0","url":"x"}' $base 'x86_64' } '*no sha256*'
        Assert-Throws { Read-Feed ($live -replace '0\.2\.2","url', '0.2","url') $base 'x86_64' } "*bad version*"
        Assert-Throws { Read-Feed ($live -replace 'download\.runkiri\.com/Kiri', 'evil.example/Kiri') $base 'x86_64' } "*isn't $base/Kiri-0.2.2-x86_64.msi*"
        Assert-Throws { Read-Feed ($live -replace 'Kiri-0\.2\.2-x86_64\.msi', 'Kiri-0.2.2-x86_64.msi.exe') $base 'x86_64' } "*installer URL*"
        Assert-Throws { Read-Feed ($live -replace 'Kiri-0\.2\.2-x86_64\.msi', '../Kiri-0.2.2-x86_64.msi') $base 'x86_64' } "*installer URL*"
        Assert-Throws { Read-Feed $live $base 'arm64' } "*installer URL*"
        Assert-Throws { Read-Feed ($live -replace '647128f8', '647128F8') $base 'x86_64' } "*isn't a SHA-256*"
    }
    Test-Case 'Test-Sha256: match and mismatch, on a path with a space' {
        $f = Join-Path $work 'a file.bin'; New-Item -ItemType Directory -Force -Path $work | Out-Null
        New-TestFile $f 'abc'
        Assert (Test-Sha256 $f 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') 'sha of abc'
        Assert (-not (Test-Sha256 $f ('0' * 64))) 'a wrong sha matched'
    }
    Test-Case 'Get-WslDistro: the registered names, none without the key' {
        Assert ((Get-WslDistro $lxss) -join ',' -ceq 'AlmaLinux-9') ((Get-WslDistro $lxss) -join ',')
        Assert (@(Get-WslDistro $noLxss).Count -eq 0) 'distros from a missing key'
    }
    Test-Case 'Get-SetupState: done only when setup.json says so' {
        $d = Join-Path $tmp 'setup state'; $f = Join-Path $d 'setup.json'
        Assert ((Get-SetupState $d) -ceq 'pending') 'no file'
        foreach ($text in '{ "done": ', '[true]', '{"done":false}', '{"linux":"kiri"}', '{"done":"yes"}') {
            New-TestFile $f $text
            Assert ((Get-SetupState $d) -ceq 'pending') "done from: $text"
        }
        New-TestFile $f '{"done":true,"linux":"kiri","distro":"kiri","lastError":null}'
        Assert ((Get-SetupState $d) -ceq 'done') 'not done from the live shape'
    }
    Test-Case 'Install-Kiri: nothing fetched when Kiri is there' {
        Reset-Flow; New-TestFile (Join-Path $appDir 'kiri-win.exe') 'mine'
        $r = Install-Test (ConvertTo-FileUrl (Join-Path $tmp 'nowhere'))
        Assert ($r.State -eq 'present' -and -not (Test-Path -LiteralPath $log) -and (Get-WorkLeft) -eq 0) $r.State
        Assert ((Read-Text (Join-Path $appDir 'kiri-win.exe')) -ceq 'mine') 'the install was touched'
    }
    Test-Case 'Install-Kiri: nothing fetched without a WSL distro' {
        Reset-Flow
        $r = Install-Test (ConvertTo-FileUrl (Join-Path $tmp 'nowhere')) @()
        Assert ($r.State -eq 'no-wsl' -and -not (Test-Path -LiteralPath $log) -and (Get-WorkLeft) -eq 0) $r.State
    }
    Test-Case 'Install-Kiri: a verified MSI goes to the installer, silently' {
        Reset-Flow; $feed = New-Feed 'ok1'
        $r = Install-Test $feed
        Assert ($r.State -eq 'installed' -and $r.Version -ceq '9.8.7') "$($r.State) $($r.Version)"
        $argv = (Read-Text $log).Trim()
        Assert ($argv -like '/i "*\Kiri-9.8.7-x86_64.msi" /qn /norestart') "installer arguments: $argv"
        Assert ($argv -like "*$work\kiri-*") "the MSI wasn't in the work folder: $argv"
        Assert ((Get-WorkLeft) -eq 0) 'the download folder was left behind'
        Assert ($script:steps -contains 'downloading Kiri 9.8.7') ($script:steps -join '; ')
    }
    Test-Case 'Install-Kiri: 3010 (restart wanted) counts as installed' {
        Reset-Flow 'restart'; $feed = New-Feed 'ok2'
        Assert ((Install-Test $feed).State -eq 'installed') 'not installed'
    }
    Test-Case 'Install-Kiri: a SHA-256 mismatch never reaches the installer' {
        Reset-Flow; $feed = New-Feed 'bad1' 'badsha'
        Assert-Throws { Install-Test $feed } "*SHA-256 doesn't match*"
        Assert (-not (Test-Path -LiteralPath $log)) 'the installer ran'
        Assert (-not (Test-Path -LiteralPath $appDir) -and (Get-WorkLeft) -eq 0) 'something was left'
    }
    Test-Case 'Install-Kiri: a failing installer, and one that installs nothing, throw' {
        Reset-Flow 'fail'; $feed = New-Feed 'ok3'
        Assert-Throws { Install-Test $feed } '*the installer exited 1603*'
        Reset-Flow 'empty'
        Assert-Throws { Install-Test $feed } "*kiri-win.exe isn't there*"
        Assert ((Get-WorkLeft) -eq 0) 'the download folder was left behind'
    }
    Test-Case 'Install-Kiri: an unusable feed names the feed' {
        Reset-Flow
        Assert-Throws { Install-Test (ConvertTo-FileUrl (Join-Path $tmp 'nowhere')) } "*latest-windows-x86_64.json isn't usable*"
        Assert ((Get-WorkLeft) -eq 0) 'the download folder was left behind'
    }
    Test-Case 'whole script: an unreachable feed warns and exits 0' {
        Reset-Flow
        $r = Invoke-Script (ConvertTo-FileUrl (Join-Path $tmp 'nowhere'))
        Assert ($r.Code -eq 0 -and $r.Out -like '*Kiri was not installed*') "exit $($r.Code): $($r.Out)"
        Assert (-not (Test-Path -LiteralPath $appDir)) 'something was installed'
    }
    Test-Case 'whole script: no WSL distro installs nothing' {
        Reset-Flow; $feed = New-Feed 'ok4'
        $r = Invoke-Script $feed $noLxss
        Assert ($r.Code -eq 0 -and $r.Out -like '*no WSL distro is registered*') "exit $($r.Code): $($r.Out)"
        Assert (-not (Test-Path -LiteralPath $log)) 'the installer ran'
    }
    Test-Case 'whole script: installs, asks for the setup, then fetches nothing' {
        Reset-Flow; $feed = New-Feed 'ok5'
        $r = Invoke-Script $feed
        Assert ($r.Code -eq 0 -and $r.Out -like '*installed Kiri 9.8.7*') "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -like '*open Kiri once to finish its setup*') $r.Out
        $r = Invoke-Script (ConvertTo-FileUrl (Join-Path $tmp 'nowhere'))
        Assert ($r.Code -eq 0 -and $r.Out -like '*open Kiri once*' -and $r.Out -notlike '*downloading*') "exit $($r.Code): $($r.Out)"
        New-TestFile (Join-Path $appDir 'setup.json') '{"done":true}'
        $r = Invoke-Script (ConvertTo-FileUrl (Join-Path $tmp 'nowhere'))
        Assert ($r.Code -eq 0 -and $r.Out -like '*Kiri is installed and set up; it updates itself*') "exit $($r.Code): $($r.Out)"
    }
} finally {
    Remove-Item -LiteralPath $lxss -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:KIRI_TEST_LOG, Env:KIRI_TEST_APPDIR, Env:KIRI_TEST_MODE -ErrorAction SilentlyContinue
}
Complete-Test 'kiri'
