# Tests scripts/deepseek-harness.ps1, imported from its AST, and runs it whole:
#   Read-Feed (the live feed shape, top-level path over files[].url, quoted one-line
#   values, and refusing a non-feed, a bad version, an installer URL outside the prefix,
#   a missing or malformed SHA-512), Test-Sha512 (match and mismatch, on a path with a
#   space), Test-Signer (an unsigned file; a valid signature from someone else; an
#   unreadable path), Get-InstalledHarness (no key, a lookalike name, the exact name),
#   Invoke-Installer (the exit code; a hung installer times out), whole-script runs (an
#   unreachable feed, an installed app, exit 0 each time), the Install-Harness flow over
#   file:// fixtures (no download when installed, a verified build installs with its
#   progress lines, a SHA-512 mismatch or another signer runs nothing, a failing or
#   unlisted install is reported, a build that failed to install or was refused by the
#   signer check isn't downloaded again until the feed changes), and the PSModulePath
#   regression (5.1 under pwsh's module path still checks the signature). The registry
#   cases use a throwaway HKCU key, never the real Uninstall key, and every run passes a
#   throwaway -StateDir, never %LOCALAPPDATA%\workstation\deepseek-harness.
# Windows PowerShell 5.1 and pwsh; ASCII only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$script = Join-Path $PSScriptRoot 'deepseek-harness.ps1'
$shell = (Get-Process -Id $PID).Path
$ast = Read-ScriptAst $script
. (Import-AstFunction $ast 'Read-Feed', 'Test-Sha512', 'Test-Signer', 'Get-InstalledHarness', 'Write-Step', 'Get-Url', 'Invoke-Installer', 'Install-Harness')
$script:steps = New-Object System.Collections.Generic.List[string]
function Write-Step([string]$Message) { $script:steps.Add($Message) }   # record; the whole-script runs keep the real one

$tmp = New-TestTempDir 'deepseek-harness-'
$work = Join-Path $tmp 'work dir'            # a space, as under a OneDrive profile
$state = Join-Path $tmp 'state'              # throwaway; never the real %LOCALAPPDATA% state
$regRoot = "HKCU:\Software\workstation-test-$([guid]::NewGuid())"
$uninstall = "$regRoot\Uninstall"            # throwaway; never the real Uninstall key
$prefix = 'https://download.deepseek.com/dsh-desk/bin/win-x64/'
$liveFeed = @'
version: 0.2.2-rc.1
files:
  - url: >-
      https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.1-win-x64.exe
    size: 293425336
    sha512: >-
      swcK0J6ofGkaAWLRpOes2ca7CWO8vuM5Vp0FRnQ/DG3q+Z+OhvsgLz3hIiSYpRUETY+fEz+Ww86fNa0jiVIifw==
path: >-
  https://download.deepseek.com/dsh-desk/bin/win-x64/deepseek-harness-0.2.2-rc.1-win-x64.exe
sha512: >-
  swcK0J6ofGkaAWLRpOes2ca7CWO8vuM5Vp0FRnQ/DG3q+Z+OhvsgLz3hIiSYpRUETY+fEz+Ww86fNa0jiVIifw==
stagingPercentage: 100
releaseDate: '2026-11-04T09:31:49.677Z'
'@
function Get-B64Sha512([byte[]]$Bytes) { [Convert]::ToBase64String([Security.Cryptography.SHA512]::Create().ComputeHash($Bytes)) }
function Assert-Throws([scriptblock]$Body, [string]$Like) {
    try { & $Body } catch { Assert ($_.Exception.Message -like $Like) "threw '$($_.Exception.Message)', wanted '$Like'"; return }
    throw "FAIL: no exception, wanted '$Like'"
}
$script:installs = New-Object System.Collections.Generic.List[string]
$script:installReply = @{ Exit = 0; Register = $true }
$script:signerOk = $true
function New-Feed([string]$Name, [byte[]]$Installer, [string]$Sha) {   # fixtures live under $tmp (no space: curl file:// URLs)
    $dir = Join-Path $tmp $Name
    $exe = Join-Path $dir 'bin\deepseek-harness-0.2.2-rc.1-win-x64.exe'
    New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
    [IO.File]::WriteAllBytes($exe, $Installer)
    $bin = 'file:///' + ((Join-Path $dir 'bin') -replace '\\', '/') + '/'
    if (-not $Sha) { $Sha = Get-B64Sha512 $Installer }
    New-TestFile (Join-Path $dir 'feeds\nightly.yml') "version: 0.2.2-rc.1`npath: ${bin}deepseek-harness-0.2.2-rc.1-win-x64.exe`nsha512: $Sha`n"
    [pscustomobject]@{ FeedUrl = 'file:///' + ((Join-Path $dir 'feeds\nightly.yml') -replace '\\', '/'); Prefix = $bin }
}
function Register-Fake { New-Item -Path "$uninstall\{dsh}" -Force | Out-Null
    Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayName -Value 'DeepSeek Harness'
    Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayVersion -Value '0.2.2-rc.1' }
function Reset-Flow { $script:installs.Clear(); $script:steps.Clear(); Remove-Item -LiteralPath $state -Recurse -Force -ErrorAction SilentlyContinue; $script:installReply = @{ Exit = 0; Register = $true }; $script:signerOk = $true
    Remove-Item -LiteralPath $uninstall -Recurse -Force -ErrorAction SilentlyContinue; New-Item -Path $uninstall -Force | Out-Null
    New-Item -ItemType Directory -Force -Path $work | Out-Null }
function Get-WorkLeft { @(Get-ChildItem -LiteralPath $work -Force).Count }
function Invoke-Script([string]$FeedUrl, [string]$Prefix, [string]$Exe = $shell) {
    $out = & $Exe -NoProfile -ExecutionPolicy Bypass -File $script -FeedUrl $FeedUrl -InstallerPrefix $Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state 2>&1 | Out-String
    [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}
$missingFeed = 'file:///' + ($tmp -replace '\\', '/') + '/missing.yml'

try {
    Test-Case 'Read-Feed: the live feed shape' {
        $f = Read-Feed $liveFeed $prefix
        Assert ($f.Version -ceq '0.2.2-rc.1') "version $($f.Version)"
        Assert ($f.Url -ceq "${prefix}deepseek-harness-0.2.2-rc.1-win-x64.exe") "url $($f.Url)"
        Assert ($f.Sha512 -ceq 'swcK0J6ofGkaAWLRpOes2ca7CWO8vuM5Vp0FRnQ/DG3q+Z+OhvsgLz3hIiSYpRUETY+fEz+Ww86fNa0jiVIifw==') "sha512 $($f.Sha512)"
    }
    Test-Case 'Read-Feed: top-level path wins over files[].url' {
        $f = Read-Feed ($liveFeed -replace '(?m)^(      )https://.*\.exe$', "`$1${prefix}other.exe") $prefix
        Assert ($f.Url -ceq "${prefix}deepseek-harness-0.2.2-rc.1-win-x64.exe") $f.Url
    }
    Test-Case 'Read-Feed: quoted one-line values' {
        $sha = Get-B64Sha512 ([byte[]](1, 2, 3))
        $f = Read-Feed "version: '0.3.0'`npath: `"${prefix}deepseek-harness-0.3.0-win-x64.exe`"`nsha512: $sha`n" $prefix
        Assert ($f.Version -ceq '0.3.0' -and $f.Sha512 -ceq $sha -and $f.Url -ceq "${prefix}deepseek-harness-0.3.0-win-x64.exe") 'parsed'
    }
    Test-Case 'Read-Feed: refuses what is not a usable feed' {
        $ok = "version: 0.3.0`npath: ${prefix}x.exe`nsha512: $(Get-B64Sha512 ([byte[]](1)))`n"
        Assert-Throws { Read-Feed '<!doctype html><html lang="en"><head><title>DeepSeek App</title></head><body></body></html>' $prefix } '*no version*'
        Assert-Throws { Read-Feed ($ok -replace '(?m)^sha512:.*$', '') $prefix } '*no sha512*'
        Assert-Throws { Read-Feed ($ok -replace '0\.3\.0', 'latest') $prefix } "*bad version*"
        foreach ($bad in 'http://download.deepseek.com/dsh-desk/bin/win-x64/x.exe', 'https://download.deepseek.com.evil.example/dsh-desk/bin/win-x64/x.exe',
                         "${prefix}../x.exe", "${prefix}x.exe?a=1", "${prefix}sub/x.exe", "${prefix}x.zip") {
            Assert-Throws { Read-Feed ($ok -replace '(?m)^path:.*$', "path: $bad") $prefix } '*outside*'
        }
        Assert-Throws { Read-Feed ($ok -replace '(?m)^sha512:.*$', 'sha512: abc') $prefix } '*SHA-512*'
    }
    Test-Case 'Test-Sha512: match and mismatch' {
        $p = Join-Path $tmp 'fake installer.exe'; New-TestFile $p 'fake installer'
        Assert (Test-Sha512 $p (Get-B64Sha512 ([IO.File]::ReadAllBytes($p)))) 'match'
        Assert (-not (Test-Sha512 $p (Get-B64Sha512 ([byte[]](0))))) 'mismatch'
    }
    Test-Case 'Test-Signer: an unsigned file is refused' {
        $p = Join-Path $tmp 'unsigned installer.exe'; New-TestFile $p 'fake installer'
        $r = Test-Signer $p
        Assert (-not $r.Ok -and $r.Status -ne 'Valid') "status $($r.Status)"
    }
    Test-Case 'Test-Signer: a valid signature from someone else is refused' {
        $r = Test-Signer (Join-Path $env:SystemRoot 'System32\cmd.exe')   # catalog-signed: Valid, "Microsoft Windows"
        Assert ($r.Status -eq 'Valid') "status $($r.Status)"
        Assert (-not $r.Ok) "accepted signer '$($r.Signer)'"
        Assert ($r.Signer -like '*Microsoft*') "signer '$($r.Signer)'"
    }
    Test-Case 'Test-Signer: Ok when the signer matches exactly, case-sensitively' {
        $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $actual = (Test-Signer $cmd).Signer
        Assert ($actual -ne '') 'no signer'
        $r = Test-Signer $cmd -Expected $actual
        Assert ($r.Ok -and $r.Status -eq 'Valid') "Ok $($r.Ok), status $($r.Status)"
        $r = Test-Signer $cmd -Expected $actual.ToLowerInvariant()
        Assert (-not $r.Ok) 'a different case was accepted'
    }
    Test-Case 'Test-Signer: an unreadable path gives Error, not a throw' {
        foreach ($bad in (Join-Path $tmp 'no such installer.exe'), $tmp) {   # missing file; a directory
            $r = Test-Signer $bad
            Assert (-not $r.Ok -and $r.Signer -ceq '' -and $r.Status -like 'Error:*') "status '$($r.Status)' for $bad"
        }
    }
    Test-Case 'Get-InstalledHarness: missing key, lookalike, exact name' {
        Assert ($null -eq (Get-InstalledHarness $uninstall)) 'no key'
        New-Item -Path "$uninstall\{lookalike}" -Force | Out-Null
        Set-ItemProperty -Path "$uninstall\{lookalike}" -Name DisplayName -Value 'DeepSeek Harness Desktop'
        Assert ($null -eq (Get-InstalledHarness $uninstall)) 'lookalike counted'
        New-Item -Path "$uninstall\{noname}" -Force | Out-Null   # no DisplayName at all
        Assert ($null -eq (Get-InstalledHarness $uninstall)) 'nameless subkey counted'
        New-Item -Path "$uninstall\{nover}" -Force | Out-Null
        Set-ItemProperty -Path "$uninstall\{nover}" -Name DisplayName -Value 'DeepSeek Harness'
        $n = Get-InstalledHarness $uninstall
        Assert ($null -ne $n -and $n.Version -ceq '' -and $n.Name -ceq '{nover}') 'no DisplayVersion'
        Remove-Item -LiteralPath "$uninstall\{nover}" -Force
        New-Item -Path "$uninstall\{dsh}" -Force | Out-Null
        Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayName -Value 'DeepSeek Harness'
        Set-ItemProperty -Path "$uninstall\{dsh}" -Name DisplayVersion -Value '0.2.2-rc.1'
        $h = Get-InstalledHarness $uninstall
        Assert ($null -ne $h -and $h.Version -ceq '0.2.2-rc.1' -and $h.Name -ceq '{dsh}') 'exact name not found'
        Remove-Item -LiteralPath $uninstall -Recurse -Force
    }
    Test-Case 'Invoke-Installer: returns the exit code' {
        Assert ((Invoke-Installer -Path $shell -ArgumentList '-NoProfile', '-Command', 'exit 3' -TimeoutSec 60) -eq 3) 'exit code'
    }
    Test-Case 'Invoke-Installer: a hung installer times out' {
        $t = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { Invoke-Installer -Path $shell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 5' -TimeoutSec 1 } "*didn't finish within 1 s*"
        Assert ($t.Elapsed.TotalSeconds -lt 4) "took $($t.Elapsed.TotalSeconds) s"
    }
    Test-Case 'script: an unreachable feed warns and exits 0' {
        Reset-Flow; $r = Invoke-Script -FeedUrl $missingFeed -Prefix 'file:///nowhere/'
        Assert ($r.Code -eq 0) "exit $($r.Code)"; Assert ($r.Out -match '  deepseek-harness: not installed: ') $r.Out
    }
    Test-Case 'script: installed already prints and exits 0' {
        Reset-Flow; Register-Fake; $r = Invoke-Script -FeedUrl $missingFeed -Prefix 'file:///nowhere/'
        Assert ($r.Code -eq 0 -and $r.Out -match 'DeepSeek Harness 0\.2\.2-rc\.1 is installed; it updates itself') $r.Out
    }
    Test-Case "script: 5.1 under pwsh's PSModulePath still checks the signature" {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $mods = @($(if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'Modules' }), (Join-Path $env:ProgramFiles 'PowerShell\7\Modules')) |
            Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'Microsoft.PowerShell.Security')) } | Select-Object -First 1
        if (-not $mods) { Write-Host '  skip  no pwsh 7 modules on this host'; return }
        Reset-Flow; $f = New-Feed 'unsigned' ([Text.Encoding]::ASCII.GetBytes('fake installer'))
        $old = $env:PSModulePath
        try { $env:PSModulePath = "$mods;$old"; $r = Invoke-Script -FeedUrl $f.FeedUrl -Prefix $f.Prefix -Exe $ps51 } finally { $env:PSModulePath = $old }
        Assert ($r.Code -eq 0) "exit $($r.Code)"
        Assert ($r.Out -match "isn't signed by Hangzhou DeepSeek") $r.Out
        Assert ($r.Out -notmatch 'could not be loaded|is not recognized') $r.Out
    }

    function Test-Signer([string]$Path) { [pscustomobject]@{ Ok = $script:signerOk; Status = 'Valid'; Signer = 'stub' } }
    function Invoke-Installer([string]$Path, [string[]]$ArgumentList = @('/S'), [int]$TimeoutSec = 900) {
        $script:installs.Add("$Path|$($ArgumentList -join ' ')"); if ($script:installReply.Register) { Register-Fake }; return $script:installReply.Exit }
    $fake = [Text.Encoding]::ASCII.GetBytes('fake installer')

    Test-Case 'Install-Harness: installed already means no download' {
        Reset-Flow; Register-Fake
        $r = Install-Harness -FeedUrl $missingFeed -Prefix 'file:///nowhere/' -UninstallKey $uninstall -WorkDir $work -StateDir $state
        Assert ($r.State -eq 'present' -and $r.Version -ceq '0.2.2-rc.1') "$($r.State)"; Assert ($script:installs.Count -eq 0) 'installer ran'
    }
    Test-Case 'Install-Harness: installs a verified build' {
        Reset-Flow; $f = New-Feed 'good' $fake
        $r = Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state
        Assert ($r.State -eq 'installed' -and $r.Version -ceq '0.2.2-rc.1') "$($r.State)"
        Assert ($script:installs.Count -eq 1 -and $script:installs[0] -like "$work\*\deepseek-harness-0.2.2-rc.1-win-x64.exe|/S") "$($script:installs)"
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
        Assert ($script:steps -contains 'downloading DeepSeek Harness 0.2.2-rc.1 (about 290 MB)') "steps: $($script:steps -join ' / ')"
        Assert ($script:steps -contains 'installing DeepSeek Harness 0.2.2-rc.1 (this can take a few minutes)') "steps: $($script:steps -join ' / ')"
    }
    Test-Case 'Install-Harness: a SHA-512 mismatch runs nothing' {
        Reset-Flow; $f = New-Feed 'badsha' $fake (Get-B64Sha512 ([byte[]](0)))
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } "*SHA-512 doesn't match*"
        Assert ($script:installs.Count -eq 0) 'installer ran'; Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
        Assert (-not (Test-Path -LiteralPath (Join-Path $state 'rejected.sha512'))) 'a mismatch was remembered'
    }
    Test-Case 'Install-Harness: another signer runs nothing' {
        Reset-Flow; $script:signerOk = $false; $f = New-Feed 'badsig' $fake
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } "*isn't signed by Hangzhou DeepSeek Artificial Intelligence Co., Ltd.*"
        Assert ($script:installs.Count -eq 0) 'installer ran'; Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
    Test-Case 'Install-Harness: a failing installer is reported' {
        Reset-Flow; $script:installReply = @{ Exit = 2; Register = $false }; $f = New-Feed 'exit2' $fake
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } '*installer exited 2*'
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
    Test-Case 'Install-Harness: exit 0 without a listing is reported' {
        Reset-Flow; $script:installReply = @{ Exit = 0; Register = $false }; $f = New-Feed 'unlisted' $fake
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } '*lists no DeepSeek Harness*'
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
    Test-Case "Install-Harness: a build that failed to install isn't downloaded again" {
        Reset-Flow; $script:installReply = @{ Exit = 2; Register = $false }; $f = New-Feed 'rej1' $fake
        $rej = Join-Path $state 'rejected.sha512'
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } '*exited 2*delete*rejected.sha512*'
        Assert (Test-Path -LiteralPath $rej) 'no rejected.sha512'
        Assert (([IO.File]::ReadAllLines($rej))[0] -ceq (Get-B64Sha512 $fake)) 'line 1 is not the feed sha512'
        Remove-Item -Path (Join-Path $tmp 'rej1\bin\*.exe') -Force   # a download attempt would now fail differently
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } '*failed to install before*'
        Assert ($script:installs.Count -eq 1) "installer ran $($script:installs.Count) times"
        $script:installReply = @{ Exit = 0; Register = $true }
        $g = New-Feed 'rej2' ([Text.Encoding]::ASCII.GetBytes('a newer installer'))
        $r = Install-Harness -FeedUrl $g.FeedUrl -Prefix $g.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state
        Assert ($r.State -eq 'installed') "$($r.State)"
        Assert (-not (Test-Path -LiteralPath $rej)) 'rejected.sha512 kept after a successful install'
    }
    Test-Case 'Install-Harness: a signer refusal is remembered' {
        Reset-Flow; $script:signerOk = $false; $f = New-Feed 'rejsig' $fake
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } "*isn't signed by*"
        Assert (Test-Path -LiteralPath (Join-Path $state 'rejected.sha512')) 'no rejected.sha512'
        Assert-Throws { Install-Harness -FeedUrl $f.FeedUrl -Prefix $f.Prefix -UninstallKey $uninstall -WorkDir $work -StateDir $state } '*failed to install before*'
        Assert ((Get-WorkLeft) -eq 0) 'WorkDir not cleaned'
    }
} finally {
    Remove-Item $regRoot, $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Test 'deepseek-harness'
