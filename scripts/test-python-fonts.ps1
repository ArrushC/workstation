# Tests bootstrap.ps1's Nerd Font step without running the bootstrap:
# Invoke-InstallNerdFonts and Get-MiseToolExe are extracted from the script's
# AST (scripts/lib/test-helpers.ps1), and scripts/install-nerd-fonts.ps1 runs
# for real on fake TTFs. The Python env is no longer a bootstrap.ps1 step: the
# post-tools task (scripts/tool-env.py) builds it, tested by
# scripts/test-tool-env.py and scripts/test-tool-env-real.py.
#
# Nothing real is touched:
#  - `mise` is a function stub
#  - $RepoPath, the workstation dirs and $env:LOCALAPPDATA point at a temp dir
#  - install-nerd-fonts.ps1 mostly runs with -NoRegister: no HKCU Fonts key,
#    no session activation, no logon task. Get-/New-/Remove-ItemProperty,
#    Add-Type and the ScheduledTask cmdlets are stubs here that record their
#    calls: a -NoRegister run that reaches one fails the last case, and the
#    two cases without -NoRegister observe the HKCU pass through them
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$repoRoot = Split-Path -Parent $PSScriptRoot
$fontScript = Join-Path $repoRoot 'scripts\install-nerd-fonts.ps1'
$ast = Read-ScriptAst (Join-Path $repoRoot 'bootstrap.ps1')
. (Import-AstFunction $ast 'Get-MiseToolExe', 'Invoke-InstallNerdFonts', 'Invoke-Native')
# The font script's registry and Task Scheduler calls, recorded in $fontCalls.
# $fontReg is the fake HKCU Fonts key (an ordered name -> value table, or
# $null): Get-ItemProperty answers with it, New-/Remove-ItemProperty change
# it, and New-ItemProperty notes whether the file it registers exists yet.
# Unqualified on purpose: called from inside install-nerd-fonts.ps1,
# `$script:` would mean that script's scope.
$fontCalls = New-Object System.Collections.Generic.List[string]
$fontReg = $null
$script:noRegisterLeaks = New-Object System.Collections.Generic.List[string]
function Get-ItemProperty { [CmdletBinding()] param($Path) $fontCalls.Add('Get-ItemProperty'); if ($null -ne $fontReg) { [pscustomobject]$fontReg } }
function New-ItemProperty {
    [CmdletBinding()] param($Path, $Name, $Value, $PropertyType, [switch]$Force)
    $fontCalls.Add("New-ItemProperty $Name=$Value exists=$(Test-Path -LiteralPath $Value)")
    if ($null -ne $fontReg) { $fontReg[$Name] = $Value }
}
function Remove-ItemProperty {
    [CmdletBinding()] param($Path, $Name)
    $fontCalls.Add("Remove-ItemProperty $Name")
    if ($null -ne $fontReg) { $fontReg.Remove($Name) }
}
function Format-Reg($Table) { (@($Table.Keys | ForEach-Object { "$_=$($Table[$_])" })) -join ' | ' }
function Add-Type { $fontCalls.Add('Add-Type') }
function Register-ScheduledTask { $fontCalls.Add('Register-ScheduledTask') }
function New-ScheduledTaskAction { 'action' }
function New-ScheduledTaskTrigger { 'trigger' }
function New-ScheduledTaskSettingsSet { 'settings' }
function New-ScheduledTaskPrincipal { 'principal' }
Assert-Stub 'mise', 'Get-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Add-Type', 'Register-ScheduledTask',
    'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskSettingsSet', 'New-ScheduledTaskPrincipal'
# A real activation type in this process would let the font script call GDI.
if (([System.Management.Automation.PSTypeName]'Workstation.FontActivator').Type) { throw 'refusing to run: Workstation.FontActivator is loaded' }

$savedLocalAppData = $env:LOCALAPPDATA
$tmp = New-TestTempDir 'pyfonts-'
try {
    $script:RepoPath = Join-Path $tmp 'repo'
    New-Item -ItemType Directory -Force -Path (Join-Path $script:RepoPath 'scripts') | Out-Null
    $script:WsRoot = Join-Path $tmp 'ws'
    $script:WsBin = Join-Path $script:WsRoot 'bin'
    $script:WsStamps = Join-Path $script:WsRoot 'stamps'
    New-Item -ItemType Directory -Force -Path $script:WsBin, $script:WsStamps | Out-Null
    $script:SkipToolInstall = $false
    $script:SkipNerdFonts = $false

    # Invoke-InstallNerdFonts against a fake installer that records -SourceDir.
    $fontSrc = Join-Path $tmp 'mise\nerd-fonts\3.5.1'
    $six = 'Regular', 'Italic', 'Bold', 'BoldItalic', 'Medium', 'MediumItalic' | ForEach-Object { "JetBrainsMonoNerdFontMono-$_.ttf" }
    foreach ($f in @($six) + 'JetBrainsMonoNerdFontMono-Thin.ttf', 'JetBrainsMonoNerdFont-Regular.ttf') { New-TestFile (Join-Path $fontSrc $f) "ttf $f" }
    # The fake installer leaves its -SourceDir in ran.txt, and throws when a
    # "fail" file sits next to it.
    $ranFile = Join-Path $script:RepoPath 'scripts\ran.txt'
    $failFlag = Join-Path $script:RepoPath 'scripts\fail'
    New-TestFile (Join-Path $script:RepoPath 'scripts\install-nerd-fonts.ps1') @'
param([string]$SourceDir)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ran.txt'), "-SourceDir=$SourceDir")
if (Test-Path (Join-Path $PSScriptRoot 'fail')) { throw 'fake installer failed' }
'@
    function Invoke-Fonts([bool]$Fails = $false) {
        Remove-Item -LiteralPath $ranFile, $failFlag -Force -ErrorAction SilentlyContinue
        if ($Fails) { New-TestFile $failFlag }
        $script:miseCalls.Clear()
        Invoke-InstallNerdFonts
    }
    $fontWhere = 'where github:ryanoasis/nerd-fonts'

    Test-Case 'fonts: install-nerd-fonts.ps1 -SourceDir is `mise where github:ryanoasis/nerd-fonts`, pinned with -C' {
        $script:miseReply = @{ $fontWhere = @{ Out = $fontSrc; Exit = 0 } }
        Invoke-Fonts
        Assert (Test-Path -LiteralPath $ranFile) 'installer not run'
        Assert ((Read-Text $ranFile) -ceq "-SourceDir=$fontSrc") "installer got: $(Read-Text $ranFile)"
        Assert ($script:miseCalls -ccontains "mise -C $env:USERPROFILE $fontWhere") "mise calls: $($script:miseCalls -join ' | ')"
        Assert ($script:warnings.Count -eq 0) "unexpected warning: $($script:warnings -join ' | ')"
    }

    Test-Case 'fonts: no font from mise -> a warning; the installer does not run' {
        $script:miseReply = @{ $fontWhere = @{ Exit = 1 } }
        Invoke-Fonts
        Assert (-not (Test-Path -LiteralPath $ranFile)) 'installer ran without a font'
        Assert ($script:warnings.Count -eq 1) "warnings: $($script:warnings -join ' | ')"
    }

    Test-Case 'fonts: an installer failure is a warning, not fatal' {
        $script:miseReply = @{ $fontWhere = @{ Out = $fontSrc; Exit = 0 } }
        Invoke-Fonts $true
        Assert (Test-Path -LiteralPath $ranFile) 'installer not run'
        Assert (($script:warnings -join ' ') -like '*Nerd Fonts install failed*') "warnings: $($script:warnings -join ' | ')"
    }

    Test-Case 'fonts: -SkipNerdFonts -> neither mise nor the installer runs' {
        $script:SkipNerdFonts = $true
        try { Invoke-Fonts } finally { $script:SkipNerdFonts = $false }
        Assert (-not (Test-Path -LiteralPath $ranFile) -and $script:miseCalls.Count -eq 0) "ran: $($script:miseCalls -join ' | ')"
    }

    # The real install-nerd-fonts.ps1, on $fontSrc, into a temp %LOCALAPPDATA%.
    $lad = Join-Path $tmp 'LocalAppData'
    $fontDir = Join-Path $lad 'Microsoft\Windows\Fonts'
    $stampFile = Join-Path $lad 'workstation\nerd-fonts.stamp'
    # -Register drops -NoRegister: the HKCU pass then runs against the stubs.
    function Invoke-FontScript([switch]$Register) {
        $env:LOCALAPPDATA = $lad
        $fontCalls.Clear()
        $fontArgs = @{ SourceDir = $fontSrc }
        if (-not $Register) { $fontArgs['NoRegister'] = $true }
        try {
            (@(& $fontScript @fontArgs 3>&1 6>&1) | ForEach-Object { "$_" }) -join "`n"
        } finally {
            $env:LOCALAPPDATA = $savedLocalAppData
            if (-not $Register) { foreach ($t in $fontCalls) { $script:noRegisterLeaks.Add($t) } }
        }
    }

    Test-Case 'install-nerd-fonts.ps1: the six Mono TTFs from -SourceDir land in %LOCALAPPDATA%\Microsoft\Windows\Fonts' {
        New-TestFile (Join-Path $fontDir 'JetBrainsMonoNerdFontMono-Old.ttf') 'a name an older release used'
        $null = Invoke-FontScript
        foreach ($f in $six) {
            $p = Join-Path $fontDir $f
            Assert ((Test-Path -LiteralPath $p) -and ((Read-Text $p) -ceq "ttf $f")) "$f not copied"
        }
        $names = @(Get-ChildItem -LiteralPath $fontDir | ForEach-Object { $_.Name })
        Assert ($names.Count -eq 6) "Fonts dir holds: $($names -join ', ')"
    }

    Test-Case 'install-nerd-fonts.ps1: the same sources again -> already installed' {
        $out = Invoke-FontScript
        Assert ($out -like '*already installed*') "output: $out"
    }

    Test-Case 'install-nerd-fonts.ps1: a bump replaces a changed TTF held open like a loaded font (Read, Delete share); an unchanged one held without Delete is left alone' {
        New-TestFile (Join-Path $fontSrc $six[2]) 'ttf bold v2'
        $held = [System.IO.File]::Open((Join-Path $fontDir $six[2]), 'Open', 'Read', [System.IO.FileShare]'Read, Delete')
        $h = [System.IO.File]::Open((Join-Path $fontDir $six[0]), 'Open', 'Read', 'Read')   # no Write/Delete share
        try { $out = Invoke-FontScript } finally { $h.Dispose(); $held.Dispose() }
        Assert ($out -notlike '*already installed*') "output: $out"
        Assert ((Read-Text (Join-Path $fontDir $six[2])) -ceq 'ttf bold v2') 'changed TTF not replaced'
        Assert ((Read-Text (Join-Path $fontDir $six[0])) -ceq "ttf $($six[0])") 'unchanged TTF rewritten'
        $out = Invoke-FontScript
        Assert ($out -like '*already installed*') "stamp not rewritten after the bump: $out"
    }

    # The installed family's HKCU entries (a stale name included) plus another font.
    function New-FontReg {
        $t = [ordered]@{ 'Consolas (TrueType)' = 'consola.ttf'; 'JetBrainsMonoNerdFontMono-Old (TrueType)' = 'old.ttf' }
        foreach ($f in $six) { $t["$([System.IO.Path]::GetFileNameWithoutExtension($f)) (TrueType)"] = Join-Path $fontDir $f }
        return $t
    }

    Test-Case 'install-nerd-fonts.ps1: a TTF that cannot be replaced throws a clear message before HKCU and the stamp; the registrations stay unchanged; the next run retries' {
        $stampBefore = Read-Text $stampFile
        New-TestFile (Join-Path $fontSrc $six[4]) 'ttf medium v2'
        $script:fontReg = New-FontReg
        $h = [System.IO.File]::Open((Join-Path $fontDir $six[4]), 'Open', 'Read', 'Read')   # no Delete share: undeletable
        $msg = ''
        try { $null = Invoke-FontScript -Register } catch { $msg = $_.Exception.Message } finally { $h.Dispose(); $reg = $script:fontReg; $script:fontReg = $null }
        Assert ($msg -like "*could not replace*$($six[4])*next*retries*") "got: '$msg'"
        $writes = @($fontCalls | Where-Object { $_ -like 'New-ItemProperty*' -or $_ -like 'Remove-ItemProperty*' -or $_ -eq 'Register-ScheduledTask' })
        Assert ($writes.Count -eq 0) "HKCU/task calls after a failed replace: $($writes -join ' | ')"
        Assert ((Format-Reg $reg) -ceq (Format-Reg (New-FontReg))) "HKCU after a failed replace: $(Format-Reg $reg)"
        Assert ((Read-Text $stampFile) -ceq $stampBefore) 'stamp rewritten after a failed replace'
        Assert ((Read-Text (Join-Path $fontDir $six[4])) -ceq "ttf $($six[4])") 'held TTF changed'
        $null = Invoke-FontScript
        Assert ((Read-Text (Join-Path $fontDir $six[4])) -ceq 'ttf medium v2') 'the next run did not replace it'
    }

    Test-Case 'install-nerd-fonts.ps1: after the copy, HKCU drops only stale names of the family and registers the six by full path' {
        $script:fontReg = New-FontReg
        New-TestFile (Join-Path $fontSrc $six[5]) 'ttf mediumitalic v2'
        try { $null = Invoke-FontScript -Register } finally { $script:fontReg = $null }
        $removed = @($fontCalls | Where-Object { $_ -like 'Remove-ItemProperty*' })
        Assert ($removed.Count -eq 1 -and $removed[0] -ceq 'Remove-ItemProperty JetBrainsMonoNerdFontMono-Old (TrueType)') "removed: $($removed -join ' | ')"
        foreach ($f in $six) {
            $want = "New-ItemProperty $([System.IO.Path]::GetFileNameWithoutExtension($f)) (TrueType)=$(Join-Path $fontDir $f) exists=True"
            Assert ($fontCalls -ccontains $want) "missing: $want -- calls: $($fontCalls -join ' | ')"
        }
        Assert ((Read-Text (Join-Path $fontDir $six[5])) -ceq 'ttf mediumitalic v2') 'changed TTF not replaced'
        Assert ($fontCalls -ccontains 'Register-ScheduledTask') 'logon task not re-registered'
    }

    Test-Case 'install-nerd-fonts.ps1: a missing source TTF throws before the installed fonts are touched' {
        Remove-Item -LiteralPath (Join-Path $fontSrc $six[1]) -Force
        $msg = ''
        try { $null = Invoke-FontScript } catch { $msg = $_.Exception.Message }
        Assert ($msg -like "*$($six[1])*") "got: '$msg'"
        foreach ($f in $six) { Assert (Test-Path -LiteralPath (Join-Path $fontDir $f)) "$f removed" }
    }

    Test-Case 'install-nerd-fonts.ps1 -NoRegister: no HKCU read or write, no activation, no logon task' {
        Assert ($script:noRegisterLeaks.Count -eq 0) "called: $($script:noRegisterLeaks -join ', ')"
    }
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -Recurse -Force $tmp
}
Complete-Test 'font'
