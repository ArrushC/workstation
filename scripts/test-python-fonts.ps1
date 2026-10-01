# Tests bootstrap.ps1's python-env and Nerd Font steps without running the
# bootstrap: Invoke-PythonEnv, Invoke-InstallNerdFonts and Get-MiseToolExe
# are extracted from the script's AST, as scripts/test-mise-env.ps1 does,
# and scripts/install-nerd-fonts.ps1 runs for real on fake TTFs.
#
# Nothing real is touched:
#  - `mise` and `uv` are function stubs that record their arguments
#    (functions win over mise.exe/uv.exe on PATH); the script stops unless
#    both resolve to them
#  - $RepoPath, the workstation dirs and $env:LOCALAPPDATA point at a temp dir
#  - install-nerd-fonts.ps1 mostly runs with -NoRegister: no HKCU Fonts key,
#    no session activation, no logon task. Get-/New-/Remove-ItemProperty,
#    Add-Type and the ScheduledTask cmdlets are stubs here that record their
#    calls: a -NoRegister run that reaches one fails the last case, and the
#    two cases without -NoRegister observe the HKCU pass through them
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$fontScript = Join-Path $repoRoot 'scripts\install-nerd-fonts.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Get-MiseToolExe', 'Invoke-PythonEnv', 'Invoke-InstallNerdFonts'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$script:warnings = New-Object System.Collections.Generic.List[string]
function Write-Ok { param($m) }
function Write-Log { param($m) }
function Write-Warn { param($m) $script:warnings.Add([string]$m) }
# The mise stub: records each call (args joined) in $script:miseCalls and
# answers from $script:miseReply (first key found in the call -> Out/Exit).
$script:miseCalls = New-Object System.Collections.Generic.List[string]
$script:miseReply = @{}
function mise {
    $line = $args -join ' '
    $script:miseCalls.Add("mise $line")
    $exit = 0
    foreach ($k in $script:miseReply.Keys) {
        if ($line.Contains($k)) {
            $r = $script:miseReply[$k]
            if ($r.ContainsKey('Out')) { $r.Out }
            $exit = $r.Exit
            break
        }
    }
    $global:LASTEXITCODE = $exit
}
# The uv stub (`mise which uv` answers "uv", so `& $uvExe` lands here). Each
# call keeps its arguments unjoined, so an unsplatted library list shows up.
$script:uvCalls = New-Object System.Collections.Generic.List[object]
$script:uvExit = 0
function uv { $script:uvCalls.Add(@($args)); $global:LASTEXITCODE = $script:uvExit }
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
foreach ($c in 'mise', 'uv', 'Get-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Add-Type', 'Register-ScheduledTask',
    'New-ScheduledTaskAction', 'New-ScheduledTaskTrigger', 'New-ScheduledTaskSettingsSet', 'New-ScheduledTaskPrincipal') {
    if ((Get-Command $c).CommandType -ne 'Function') { throw "refusing to run: $c does not resolve to the test stub" }
}
# A real activation type in this process would let the font script call GDI.
if (([System.Management.Automation.PSTypeName]'Workstation.FontActivator').Type) { throw 'refusing to run: Workstation.FontActivator is loaded' }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

$failures = New-Object System.Collections.Generic.List[string]
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        $script:warnings.Clear()
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}
function New-TestFile([string]$Path, [string]$Content = 'x') {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content)
}
function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path) }
# The first recorded uv call whose first argument is $Verb (unrolled: no).
function Get-UvCall([string]$Verb) {
    foreach ($c in $script:uvCalls) { if (@($c).Count -gt 0 -and $c[0] -ceq $Verb) { return ,$c } }
    return $null
}
function Format-UvCalls { (@(foreach ($c in $script:uvCalls) { "uv $(@($c) -join ' ')" })) -join ' | ' }
# True when every argument is a string and the list equals $Want exactly.
function Test-Args($Call, [string[]]$Want) {
    $c = @($Call)
    if ($c.Count -ne $Want.Count) { return $false }
    for ($i = 0; $i -lt $c.Count; $i++) {
        if (-not ($c[$i] -is [string]) -or ($c[$i] -cne $Want[$i])) { return $false }
    }
    return $true
}

$savedLocalAppData = $env:LOCALAPPDATA
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pyfonts-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $script:RepoPath = Join-Path $tmp 'repo'
    $txt = Join-Path $script:RepoPath 'scripts\python-env.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path $txt -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\python-env.txt') -Destination $txt
    $script:WsRoot = Join-Path $tmp 'ws'
    $script:WsBin = Join-Path $script:WsRoot 'bin'
    $script:WsStamps = Join-Path $script:WsRoot 'stamps'
    $script:WsPythonEnv = Join-Path $script:WsRoot 'python-env'
    New-Item -ItemType Directory -Force -Path $script:WsBin, $script:WsStamps | Out-Null
    $script:SkipToolInstall = $false
    $script:SkipNerdFonts = $false
    $envPy = Join-Path $script:WsPythonEnv 'Scripts\python.exe'

    # A fake `mise where python` dir with a python.exe in it.
    function New-Python([string]$Name) {
        $d = Join-Path $tmp $Name
        New-TestFile (Join-Path $d 'python.exe')
        return $d
    }
    function Use-Python([string]$Dir) {
        $script:miseReply = @{ 'where python' = @{ Out = $Dir; Exit = 0 }; 'which uv' = @{ Out = 'uv'; Exit = 0 } }
    }
    function Invoke-Py {
        $script:uvCalls.Clear()
        $script:miseCalls.Clear()
        Invoke-PythonEnv
    }
    # python-env.txt's entries, read the way scripts/lib/python-env.sh does.
    function Get-Lib { @(Get-Content -LiteralPath $txt | Where-Object { $_ -notmatch '^\s*(#|$)' }) }
    function Assert-Built([string]$PyDir, [string[]]$Libs = @(Get-Lib)) {
        $venv = Get-UvCall 'venv'
        Assert ($null -ne $venv) "no uv venv call: $(Format-UvCalls)"
        Assert (Test-Args $venv @('venv', '--python', (Join-Path $PyDir 'python.exe'), $script:WsPythonEnv)) "uv venv: $(Format-UvCalls)"
        $pip = Get-UvCall 'pip'
        Assert ($null -ne $pip) "no uv pip call: $(Format-UvCalls)"
        $want = @('pip', 'install', '--python', $envPy, '--upgrade') + $Libs
        Assert (Test-Args $pip $want) "uv pip: $(Format-UvCalls) -- want: uv $($want -join ' ')"
    }
    $py1 = New-Python 'mise\python\3.14.7'
    $py2 = New-Python 'mise\python\3.15.0'

    Test-Case 'python-env: uv venv on `mise where python`\python.exe; the libraries are python-env.txt; launchers; mise pinned with -C' {
        Use-Python $py1
        Invoke-Py
        Assert-Built $py1
        Assert (@(Get-Lib).Count -ge 5) "python-env.txt lists only $(@(Get-Lib).Count) libraries"
        Assert ($null -eq (Get-UvCall 'python')) "uv downloaded its own CPython: $(Format-UvCalls)"
        Assert ($script:miseCalls.Count -ge 2) "mise calls: $($script:miseCalls -join ' | ')"
        foreach ($c in $script:miseCalls) { Assert ($c.StartsWith("mise -C $env:USERPROFILE ")) "not pinned to %USERPROFILE%: $c" }
        foreach ($n in 'wpy', 'textual', 'typer') { Assert (Test-Path (Join-Path $script:WsBin "$n.cmd")) "$n.cmd missing" }
        Assert ((Read-Text (Join-Path $script:WsBin 'wpy.cmd')).Contains("`"$envPy`" %*")) "wpy.cmd: $(Read-Text (Join-Path $script:WsBin 'wpy.cmd'))"
        Assert ($script:warnings.Count -eq 0) "unexpected warning: $($script:warnings -join ' | ')"
    }

    Test-Case 'python-env: the same interpreter and library list again -> no rebuild' {
        Invoke-Py
        Assert ($script:uvCalls.Count -eq 0) "rebuilt: $(Format-UvCalls)"
    }

    Test-Case 'python-env: another interpreter path (a tools.python bump) rebuilds on it' {
        Use-Python $py2
        Invoke-Py
        Assert-Built $py2
    }

    Test-Case 'python-env: an edited python-env.txt rebuilds with the new list' {
        Add-Content -LiteralPath $txt -Value 'attrs'
        Invoke-Py
        Assert-Built $py2
        Assert ((Get-UvCall 'pip') -ccontains 'attrs') "attrs not installed: $(Format-UvCalls)"
    }

    Test-Case 'python-env: a failed uv step warns, writes no stamp, and the next run retries' {
        Use-Python $py1
        $script:uvExit = 1
        try { Invoke-Py } finally { $script:uvExit = 0 }
        Assert (($script:warnings -join ' ') -like '*Python env build failed*') "warnings: $($script:warnings -join ' | ')"
        $script:warnings.Clear()
        Invoke-Py
        Assert-Built $py1
        Assert ($script:warnings.Count -eq 0) "unexpected warning: $($script:warnings -join ' | ')"
    }

    Test-Case 'python-env: inline comments, CRLF and padding parse to the same list, so such an edit does not rebuild' {
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\python-env.txt') -Destination $txt -Force
        $canon = @(Get-Lib)
        Use-Python $py1
        Invoke-Py
        Assert-Built $py1 $canon
        $noisy = @('# a new header line', '') + @($canon | ForEach-Object { "  $_   # why it is here" })
        [System.IO.File]::WriteAllText($txt, (($noisy -join "`r`n") + "`r`n"))
        Invoke-Py
        Assert ($script:uvCalls.Count -eq 0) "rebuilt after a comment/CRLF edit: $(Format-UvCalls)"
        Remove-Item -LiteralPath (Join-Path $script:WsStamps 'python-env.stamp') -Force
        Invoke-Py
        Assert-Built $py1 $canon
    }

    Test-Case 'python-env: a UTF-8 BOM on python-env.txt parses to the same list, so it does not rebuild' {
        Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\python-env.txt') -Destination $txt -Force
        Use-Python $py1
        Invoke-Py
        [System.IO.File]::WriteAllText($txt, (Read-Text $txt), (New-Object System.Text.UTF8Encoding $true))
        $head = [System.IO.File]::ReadAllBytes($txt)
        try { Invoke-Py } finally { Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\python-env.txt') -Destination $txt -Force }
        Assert (($head[0] -eq 0xEF) -and ($head[1] -eq 0xBB) -and ($head[2] -eq 0xBF)) 'no BOM written'
        Assert ($script:uvCalls.Count -eq 0) "rebuilt after adding a BOM: $(Format-UvCalls)"
    }

    Test-Case 'python-env: no python from mise -> a warning; uv never runs' {
        $script:miseReply = @{ 'where python' = @{ Exit = 1 }; 'which uv' = @{ Out = 'uv'; Exit = 0 } }
        Get-ChildItem -LiteralPath $script:WsStamps | Remove-Item -Force
        Invoke-Py
        Assert ($script:uvCalls.Count -eq 0) "uv ran: $(Format-UvCalls)"
        Assert ($script:warnings.Count -eq 1) "warnings: $($script:warnings -join ' | ')"
    }

    Test-Case 'python-env: -SkipToolInstall -> neither mise nor uv runs' {
        Use-Python $py1
        $script:SkipToolInstall = $true
        try { Invoke-Py } finally { $script:SkipToolInstall = $false }
        Assert ($script:miseCalls.Count -eq 0 -and $script:uvCalls.Count -eq 0) "ran: $($script:miseCalls -join ' | ') $(Format-UvCalls)"
    }

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
if ($failures.Count -gt 0) { throw "python-env/fonts: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "python-env and font checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
