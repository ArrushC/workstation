# Tests scripts/herdr-app.ps1, imported from its AST, and runs it whole:
#   Read-Manifest (the live manifest shape for the app and for herdr-core, and refusing
#   what isn't JSON, a bad version, no windows build, an archive URL outside the release
#   prefix or the version's folder, another extension, a malformed SHA-256), Test-Sha256
#   (match and mismatch, on a path with a space), Install-App and Install-Core over
#   file:// fixtures (nothing fetched when installed, a verified build lands with its
#   Start menu shortcut or its conpty folder and hc link, a SHA-256 mismatch or an
#   incomplete archive installs nothing and cleans up, a broken leftover folder is
#   replaced), and whole-script runs (an unreachable release server, both parts installed,
#   a second run fetches nothing; exit 0 each time), and Add-WslMachine against a
#   stand-in herdr-core (a .cmd that logs its arguments): no distro registered asks
#   nothing, a machine named wsl or one whose --via reaches the distro is left alone, a
#   missing one is added with the exact --via argument, and a failing ls or add throws.
#   Get-WslDistro reads a throwaway registry key. The whole-script runs pass -NoWsl
#   so they never reach a real herdr-core's machines.
# Every run uses throwaway install, Start menu and work folders and never touches the
# user PATH (-NoPath, -SetPath $false): never %LOCALAPPDATA%\Programs or the real menu.
# Windows PowerShell 5.1 and pwsh; ASCII only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$script = Join-Path $PSScriptRoot 'herdr-app.ps1'
$shell = (Get-Process -Id $PID).Path
$ast = Read-ScriptAst $script
. (Import-AstFunction $ast 'Read-Manifest', 'Test-Sha256', 'Write-Step', 'Get-Url', 'Expand-Release', 'Add-UserPath', 'Install-Release', 'Install-App', 'Install-Core', 'Get-WslDistro', 'Invoke-Hc', 'Add-WslMachine')
$script:steps = New-Object System.Collections.Generic.List[string]
function Write-Step([string]$Message) { $script:steps.Add($Message) }   # record; the whole-script runs keep the real one
function Add-UserPath([string]$Dir) { throw "the test reached the real user PATH with $Dir" }

$tmp = New-TestTempDir 'herdr-app-'
$work = Join-Path $tmp 'work dir'            # a space, as under a OneDrive profile
$appDir = Join-Path $tmp 'Programs\herdr-app'
$coreDir = Join-Path $tmp 'Programs\herdr-core'
$menu = Join-Path $tmp 'Start Menu'
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$appPrefix = 'https://releases.herdr.dev/app/'
$corePrefix = 'https://releases.herdr.dev/core/'
$liveApp = @'
{
  "version": "0.1.18",
  "core_min": "0.1.11",
  "notes": "Herdr 0.1.18",
  "targets": {
    "linux-x86_64": {
      "url": "https://releases.herdr.dev/app/0.1.18/herdr-app-linux-x86_64.tar.gz",
      "sha256": "8a11edd79dd40b349f7286cf51910b62e21136daf8f03005a9fd2c4dc5830f83"
    },
    "windows-x86_64": {
      "url": "https://releases.herdr.dev/app/0.1.18/herdr-app-windows-x86_64.tar.gz",
      "sha256": "e6e78e1bec1f47bd0d94dbc872a5670f4ac9c8f6740210b62365ab8b28f897c1"
    }
  }
}
'@
$liveCore = @'
{
  "version": "0.1.22",
  "generation": 1,
  "notes": "**A subscription can name the documents it wants.** (#273)",
  "targets": {
    "linux-x86_64": {
      "url": "https://releases.herdr.dev/core/0.1.22/herdr-core-linux-x86_64.tar.gz",
      "sha256": "3054ec3992ce80c5715d721caa9dcefa6056721d15dc113f4750afce763ba5df"
    },
    "windows-x86_64": {
      "url": "https://releases.herdr.dev/core/0.1.22/herdr-core-windows-x86_64.zip",
      "sha256": "37cae9d6c522e205efcdb55a42d354285f41b8cbb4c6e60fb505b73b151966c9"
    }
  }
}
'@
function Get-HexSha256([string]$Path) {
    $s = [IO.File]::OpenRead($Path)
    try { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) } finally { $s.Dispose() }
}
function Assert-Throws([scriptblock]$Body, [string]$Like) {
    try { & $Body } catch { Assert ($_.Exception.Message -like $Like) "threw '$($_.Exception.Message)', wanted '$Like'"; return }
    throw "FAIL: no exception, wanted '$Like'"
}
function ConvertTo-FileUrl([string]$Path) { 'file:///' + ($Path -replace '\\', '/') }
# A release server as a folder (no space in it: curl file:// URLs): <name>\app\latest.json
# with app\1.2.3\herdr-app-windows-x86_64.tar.gz, and <name>\core\latest.json with
# core\4.5.6\herdr-core-windows-x86_64.zip. $App / $Core: 'ok', 'badsha', 'incomplete' or
# 'none' (no manifest).
function New-Releases([string]$Name, [string]$App = 'ok', [string]$Core = 'ok') {
    $root = Join-Path $tmp $Name
    $url = ConvertTo-FileUrl $root
    foreach ($part in @(@{ Kind = 'app'; How = $App; Ver = '1.2.3'; File = 'herdr-app-windows-x86_64.tar.gz' },
                        @{ Kind = 'core'; How = $Core; Ver = '4.5.6'; File = 'herdr-core-windows-x86_64.zip' })) {
        if ($part.How -eq 'none') { continue }
        $dir = Join-Path $root "$($part.Kind)\$($part.Ver)"
        $src = Join-Path $root "src-$($part.Kind)"
        New-Item -ItemType Directory -Force -Path $dir, $src | Out-Null
        if ($part.Kind -eq 'app') {
            New-TestFile (Join-Path $src 'herdr-app\resources\app.txt') 'resources'
            if ($part.How -ne 'incomplete') { New-TestFile (Join-Path $src 'herdr-app\herdr-app.exe') 'fake app' }
        } else {
            New-TestFile (Join-Path $src 'herdr-core.exe') 'fake core'
            New-TestFile (Join-Path $src 'THIRD-PARTY-NOTICES') 'notices'
            if ($part.How -ne 'incomplete') { New-TestFile (Join-Path $src 'conpty\conpty.dll') 'fake conpty' }
        }
        $archive = Join-Path $dir $part.File
        $flags = @('-czf')
        if ($part.Kind -ne 'app') { $flags = @('-a', '-cf') }   # -a: the format from the name (.zip)
        & $tar @flags $archive -C $src '.'
        if ($LASTEXITCODE -ne 0) { throw "fixture: tar failed for $archive" }
        $sha = if ($part.How -eq 'badsha') { '0' * 64 } else { Get-HexSha256 $archive }
        New-TestFile (Join-Path $root "$($part.Kind)\latest.json") (
            '{"version":"' + $part.Ver + '","targets":{"windows-x86_64":{"url":"' + "$url/$($part.Kind)/$($part.Ver)/$($part.File)" + '","sha256":"' + $sha + '"}}}')
    }
    return $url
}
function Reset-Flow {
    $script:steps.Clear()
    foreach ($d in (Join-Path $tmp 'Programs'), $menu, $work) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
}
function Get-WorkLeft { @(Get-ChildItem -LiteralPath $work -Force).Count }
function Invoke-Script([string]$Releases, [string]$Exe = $shell) {
    $out = & $Exe -NoProfile -ExecutionPolicy Bypass -File $script -ReleasesUrl $Releases -AppDir $appDir -CoreDir $coreDir -MenuDir $menu -WorkDir $work -NoPath -NoWsl 2>&1 | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}

try {
    Test-Case 'Read-Manifest: the live app and core manifests' {
        $a = Read-Manifest $liveApp $appPrefix '.tar.gz'
        Assert ($a.Version -ceq '0.1.18' -and $a.Url -ceq "${appPrefix}0.1.18/herdr-app-windows-x86_64.tar.gz") "app: $($a.Version) $($a.Url)"
        Assert ($a.Sha256 -ceq 'e6e78e1bec1f47bd0d94dbc872a5670f4ac9c8f6740210b62365ab8b28f897c1') "app sha $($a.Sha256)"
        $c = Read-Manifest $liveCore $corePrefix '.zip'
        Assert ($c.Version -ceq '0.1.22' -and $c.Url -ceq "${corePrefix}0.1.22/herdr-core-windows-x86_64.zip") "core: $($c.Version) $($c.Url)"
    }
    Test-Case 'Read-Manifest: refuses what is not a usable manifest' {
        Assert-Throws { Read-Manifest '<!doctype html><html></html>' $appPrefix '.tar.gz' } '*not JSON*'
        Assert-Throws { Read-Manifest '{"targets":{}}' $appPrefix '.tar.gz' } '*no version*'
        Assert-Throws { Read-Manifest ($liveApp -replace '"0\.1\.18",', '"latest",') $appPrefix '.tar.gz' } '*bad version*'
        Assert-Throws { Read-Manifest ($liveApp -replace 'windows-x86_64"', 'windows-arm64"') $appPrefix '.tar.gz' } '*no windows-x86_64 build*'
        Assert-Throws { Read-Manifest $liveApp $appPrefix '.zip' } "*isn't one .zip*"
        foreach ($bad in 'http://releases.herdr.dev/app/0.1.18/x.tar.gz', 'https://releases.herdr.dev.evil.example/app/0.1.18/x.tar.gz',
                         "${appPrefix}0.1.17/x.tar.gz", "${appPrefix}0.1.18/../x.tar.gz", "${appPrefix}0.1.18/x.tar.gz?a=1", "${appPrefix}0.1.18/sub/x.tar.gz") {
            $text = $liveApp -replace 'https://releases\.herdr\.dev/app/0\.1\.18/herdr-app-windows-x86_64\.tar\.gz', $bad
            Assert-Throws { Read-Manifest $text $appPrefix '.tar.gz' } "*isn't one .tar.gz under*"
        }
        Assert-Throws { Read-Manifest ($liveApp -replace 'e6e78e1bec1f47bd0d94dbc872a5670f4ac9c8f6740210b62365ab8b28f897c1', 'abc') $appPrefix '.tar.gz' } "*isn't a SHA-256*"
    }
    Test-Case 'Test-Sha256: match and mismatch' {
        $p = Join-Path $tmp 'fake archive.zip'; New-TestFile $p 'fake archive'
        Assert (Test-Sha256 $p (Get-HexSha256 $p)) 'match'
        Assert (-not (Test-Sha256 $p ('0' * 64))) 'mismatch'
    }
    Test-Case 'Install-App: a verified build lands, with its Start menu shortcut' {
        Reset-Flow; $rel = New-Releases 'ok1'
        $r = Install-App -ReleasesUrl $rel -AppDir $appDir -MenuDir $menu -WorkDir $work -SetPath $false
        Assert ($r.State -eq 'installed' -and $r.Version -ceq '1.2.3') "$($r.State) $($r.Version)"
        Assert ((Read-Text (Join-Path $appDir 'herdr-app.exe')) -ceq 'fake app') 'herdr-app.exe is not the archive''s'
        Assert (Test-Path -LiteralPath (Join-Path $appDir 'resources\app.txt')) 'the rest of the app folder is missing'
        Assert (Test-Path -LiteralPath (Join-Path $menu 'Herdr.lnk')) 'no Start menu shortcut'
        $target = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $menu 'Herdr.lnk')).TargetPath
        Assert ($target -ieq (Join-Path $appDir 'herdr-app.exe')) "shortcut target $target"
        Assert (@($script:steps | Where-Object { $_ -like 'downloading the Herdr app 1.2.3' }).Count -eq 1) "steps: $($script:steps -join ' | ')"
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
    Test-Case 'Install-App: nothing is fetched when it is installed' {
        $script:steps.Clear()
        $r = Install-App -ReleasesUrl (ConvertTo-FileUrl (Join-Path $tmp 'nowhere')) -AppDir $appDir -MenuDir $menu -WorkDir $work -SetPath $false
        Assert ($r.State -eq 'present' -and $script:steps.Count -eq 0) "$($r.State); steps: $($script:steps -join ' | ')"
    }
    Test-Case 'Install-App: a SHA-256 mismatch or an incomplete archive installs nothing' {
        Reset-Flow; $rel = New-Releases 'bad1' -App 'badsha'
        Assert-Throws { Install-App -ReleasesUrl $rel -AppDir $appDir -MenuDir $menu -WorkDir $work -SetPath $false } "*SHA-256 doesn't match*"
        Assert (-not (Test-Path -LiteralPath $appDir) -and -not (Test-Path -LiteralPath (Join-Path $menu 'Herdr.lnk'))) 'something was installed'
        $rel = New-Releases 'bad2' -App 'incomplete'
        Assert-Throws { Install-App -ReleasesUrl $rel -AppDir $appDir -MenuDir $menu -WorkDir $work -SetPath $false } '*holds no herdr-app\herdr-app.exe*'
        Assert (-not (Test-Path -LiteralPath $appDir)) 'an incomplete app was installed'
        Assert-Throws { Install-App -ReleasesUrl (New-Releases 'bad3' -App 'none') -AppDir $appDir -MenuDir $menu -WorkDir $work -SetPath $false } "*manifest*isn't usable*"
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
    Test-Case 'Install-App: a leftover folder without the exe is replaced' {
        Reset-Flow; New-TestFile (Join-Path $appDir 'stale.txt') 'stale'
        $r = Install-App -ReleasesUrl (New-Releases 'ok2') -AppDir $appDir -MenuDir $menu -WorkDir $work -SetPath $false
        Assert ($r.State -eq 'installed' -and (Test-Path -LiteralPath (Join-Path $appDir 'herdr-app.exe'))) $r.State
        Assert (-not (Test-Path -LiteralPath (Join-Path $appDir 'stale.txt'))) 'the leftover survived'
    }
    Test-Case 'Install-Core: a verified build lands, with conpty and hc' {
        Reset-Flow; $rel = New-Releases 'ok3'
        $r = Install-Core -ReleasesUrl $rel -CoreDir $coreDir -WorkDir $work -SetPath $false
        if ($r.State -eq 'present') {
            # This machine already has a herdr-core on PATH: the script leaves it alone.
            Assert (-not (Test-Path -LiteralPath $coreDir)) 'installed beside one that is on PATH'
        } else {
            Assert ($r.Version -ceq '4.5.6') $r.Version
            Assert ((Read-Text (Join-Path $coreDir 'herdr-core.exe')) -ceq 'fake core') 'herdr-core.exe is not the archive''s'
            Assert (Test-Path -LiteralPath (Join-Path $coreDir 'conpty\conpty.dll')) 'no conpty\conpty.dll'
            if (-not (Get-Command hc -CommandType Application -ErrorAction SilentlyContinue)) {
                Assert ((Read-Text (Join-Path $coreDir 'hc.exe')) -ceq 'fake core') 'hc.exe is not a link to herdr-core.exe'
            }
            $again = Install-Core -ReleasesUrl (ConvertTo-FileUrl (Join-Path $tmp 'nowhere')) -CoreDir $coreDir -WorkDir $work -SetPath $false
            Assert ($again.State -eq 'present' -and $again.Where -ieq (Join-Path $coreDir 'herdr-core.exe')) "$($again.State) $($again.Where)"
        }
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
    Test-Case 'Install-Core: a SHA-256 mismatch or an incomplete archive installs nothing' {
        if (Get-Command herdr-core -CommandType Application -ErrorAction SilentlyContinue) { return }
        Reset-Flow
        Assert-Throws { Install-Core -ReleasesUrl (New-Releases 'bad4' -Core 'badsha') -CoreDir $coreDir -WorkDir $work -SetPath $false } "*SHA-256 doesn't match*"
        Assert-Throws { Install-Core -ReleasesUrl (New-Releases 'bad5' -Core 'incomplete') -CoreDir $coreDir -WorkDir $work -SetPath $false } '*holds no complete hc*'
        Assert (-not (Test-Path -LiteralPath (Join-Path $coreDir 'herdr-core.exe'))) 'an unverified or incomplete core was installed'
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
    Test-Case 'Get-WslDistro: the registered names' {
        $reg = "HKCU:\Software\workstation-test-$([guid]::NewGuid())"
        try {
            Assert (@(Get-WslDistro "$reg\Lxss").Count -eq 0) 'a missing key lists distros'
            New-Item -Path "$reg\Lxss\{a}" -Force | Out-Null
            Set-ItemProperty -Path "$reg\Lxss\{a}" -Name DistributionName -Value 'AlmaLinux-9'
            New-Item -Path "$reg\Lxss\{b}" -Force | Out-Null   # no DistributionName
            $got = @(Get-WslDistro "$reg\Lxss")
            Assert ($got.Count -eq 1 -and $got[0] -ceq 'AlmaLinux-9') "got: $($got -join ',')"
        } finally { Remove-Item $reg -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Test-Case 'Add-WslMachine: adds only a missing machine, with the exact --via' {
        $fake = Join-Path $tmp 'fakehc'
        New-Item -ItemType Directory -Force -Path $fake | Out-Null
        $log = Join-Path $fake 'log.txt'; $json = Join-Path $fake 'ls.json'; $hc = Join-Path $fake 'hc.cmd'
        # ls prints ls.json; anything else exits with rc.txt's number. Every call is logged.
        New-TestFile $hc "@echo off`r`necho %*>>`"$log`"`r`nif `"%2`"==`"ls`" ( type `"$json`" & exit /b 0 )`r`nset /p rc=<`"$fake\rc.txt`"`r`nexit /b %rc%`r`n"
        function Reset-Fake([string]$Machines, [string]$Rc = '0') { Remove-Item $log -Force -ErrorAction SilentlyContinue; New-TestFile $json ('{"machines":[' + $Machines + ']}'); New-TestFile (Join-Path $fake 'rc.txt') $Rc }
        function Get-Calls { if (Test-Path $log) { @(Get-Content $log | ForEach-Object { $_.Trim() }) } else { @() } }
        $ssh = '{"name":"dev10","target":"me@dev10","via":false}'
        Push-Location $tmp   # cmd.exe (the stand-in) prints a warning when its directory is a UNC path
        try {

        Reset-Fake $ssh
        $r = Add-WslMachine -Hc $hc -Distro 'AlmaLinux-9' -Distros @('Ubuntu')
        Assert ($r.State -eq 'no-distro' -and @(Get-Calls).Count -eq 0) "unregistered distro: $($r.State); calls: $(Get-Calls)"
        $r = Add-WslMachine -Hc $hc -Distro '' -Distros @('AlmaLinux-9')
        Assert ($r.State -eq 'no-distro' -and @(Get-Calls).Count -eq 0) "empty distro: $($r.State)"

        $r = Add-WslMachine -Hc $hc -Distro 'AlmaLinux-9' -Distros @('AlmaLinux-9')
        $calls = @(Get-Calls)
        Assert ($r.State -eq 'added' -and $calls.Count -eq 2) "$($r.State); calls: $($calls -join ' || ')"
        Assert ($calls[0] -ceq 'machine ls --json') $calls[0]
        Assert ($calls[1] -ceq 'machine add --json --via "wsl.exe -d AlmaLinux-9 -e sh -c" --name wsl') $calls[1]

        foreach ($have in '{"name":"wsl","target":"wsl.exe -d Other -e sh -c","via":true}',
                          '{"name":"alma","target":"wsl.exe -d AlmaLinux-9 -e sh -c","via":true}',
                          '{"name":"alma","target":"C:\\Windows\\System32\\wsl.exe --distribution AlmaLinux-9 -e sh -c","via":true}') {
            Reset-Fake "$ssh,$have"
            $r = Add-WslMachine -Hc $hc -Distro 'AlmaLinux-9' -Distros @('AlmaLinux-9')
            if ($have -like '*System32*') {
                # A full path isn't recognised as the same distro: it is added under the name wsl.
                Assert ($r.State -eq 'added') "full-path via: $($r.State)"
            } else {
                Assert ($r.State -eq 'present' -and @(Get-Calls).Count -eq 1) "$have -> $($r.State); calls: $(Get-Calls)"
            }
        }
        Reset-Fake '{"name":"alma9","target":"wsl.exe -d AlmaLinux-90 -e sh -c","via":true}'
        Assert ((Add-WslMachine -Hc $hc -Distro 'AlmaLinux-9' -Distros @('AlmaLinux-9')).State -eq 'added') 'a longer distro name counted as this one'

        Reset-Fake $ssh '5'
        Assert-Throws { Add-WslMachine -Hc $hc -Distro 'AlmaLinux-9' -Distros @('AlmaLinux-9') } '*machine add exited 5*'
        New-TestFile $json 'not json'
        Assert-Throws { Add-WslMachine -Hc $hc -Distro 'AlmaLinux-9' -Distros @('AlmaLinux-9') } '*printed no JSON*'
        Assert-Throws { Add-WslMachine -Hc $hc -Distro 'bad name' -Distros @('bad name') } "*can't carry*"
        } finally { Pop-Location }
    }
    Test-Case 'whole script: an unreachable release server warns and exits 0' {
        Reset-Flow
        $r = Invoke-Script (ConvertTo-FileUrl (Join-Path $tmp 'nowhere'))
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -like '*the Herdr app was not installed*') $r.Out
        Assert (-not (Test-Path -LiteralPath $appDir)) 'something was installed'
    }
    Test-Case 'whole script: installs both, then fetches nothing' {
        Reset-Flow; $rel = New-Releases 'ok4'
        $r = Invoke-Script $rel
        Assert ($r.Code -eq 0 -and $r.Out -like '*installed the Herdr app 1.2.3*') "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -like '*herdr-core*') $r.Out
        Assert (Test-Path -LiteralPath (Join-Path $appDir 'herdr-app.exe')) 'no app'
        $r = Invoke-Script (ConvertTo-FileUrl (Join-Path $tmp 'nowhere'))
        Assert ($r.Code -eq 0 -and $r.Out -like '*the Herdr app is installed; it updates itself*') "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -like '*herdr-core is installed*') $r.Out
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Test 'herdr-app'
