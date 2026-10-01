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
#  - install-nerd-fonts.ps1 runs with -NoRegister: no HKCU Fonts key, no
#    session activation, no logon task. In case it didn't, Get-/New-/
#    Remove-ItemProperty, Add-Type and Register-ScheduledTask are stubs here,
#    and a call to any of them fails the run
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
# install-nerd-fonts.ps1 -NoRegister must call none of these.
$script:touched = New-Object System.Collections.Generic.List[string]
function Get-ItemProperty { $script:touched.Add('Get-ItemProperty') }
function New-ItemProperty { $script:touched.Add('New-ItemProperty') }
function Remove-ItemProperty { $script:touched.Add('Remove-ItemProperty') }
function Add-Type { $script:touched.Add('Add-Type') }
function Register-ScheduledTask { $script:touched.Add('Register-ScheduledTask') }
foreach ($c in 'mise', 'uv', 'Get-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Add-Type', 'Register-ScheduledTask') {
    if ((Get-Command $c).CommandType -ne 'Function') { throw "refusing to run: $c does not resolve to the test stub" }
}
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
    function Assert-Built([string]$PyDir) {
        $venv = Get-UvCall 'venv'
        Assert ($null -ne $venv) "no uv venv call: $(Format-UvCalls)"
        Assert (Test-Args $venv @('venv', '--python', (Join-Path $PyDir 'python.exe'), $script:WsPythonEnv)) "uv venv: $(Format-UvCalls)"
        $pip = Get-UvCall 'pip'
        Assert ($null -ne $pip) "no uv pip call: $(Format-UvCalls)"
        $want = @('pip', 'install', '--python', $envPy, '--upgrade') + @(Get-Lib)
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
    function Invoke-FontScript {
        $env:LOCALAPPDATA = $lad
        try {
            (@(& $fontScript -SourceDir $fontSrc -NoRegister 6>&1) | ForEach-Object { "$_" }) -join "`n"
        } finally { $env:LOCALAPPDATA = $savedLocalAppData }
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

    Test-Case 'install-nerd-fonts.ps1: a changed source TTF is re-copied; an unchanged one in use (as GDI holds loaded fonts) is left alone' {
        New-TestFile (Join-Path $fontSrc $six[2]) 'ttf bold v2'
        $h = [System.IO.File]::Open((Join-Path $fontDir $six[0]), 'Open', 'Read', 'Read')   # no Write/Delete share
        try { $out = Invoke-FontScript } finally { $h.Dispose() }
        Assert ($out -notlike '*already installed*') "output: $out"
        Assert ((Read-Text (Join-Path $fontDir $six[2])) -ceq 'ttf bold v2') 'changed TTF not re-copied'
        Assert ((Read-Text (Join-Path $fontDir $six[0])) -ceq "ttf $($six[0])") 'unchanged TTF rewritten'
    }

    Test-Case 'install-nerd-fonts.ps1: a missing source TTF throws before the installed fonts are touched' {
        Remove-Item -LiteralPath (Join-Path $fontSrc $six[1]) -Force
        $msg = ''
        try { $null = Invoke-FontScript } catch { $msg = $_.Exception.Message }
        Assert ($msg -like "*$($six[1])*") "got: '$msg'"
        foreach ($f in $six) { Assert (Test-Path -LiteralPath (Join-Path $fontDir $f)) "$f removed" }
    }

    Test-Case 'install-nerd-fonts.ps1 -NoRegister: no HKCU read or write, no activation, no logon task' {
        Assert ($script:touched.Count -eq 0) "called: $($script:touched -join ', ')"
    }
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -Recurse -Force $tmp
}
if ($failures.Count -gt 0) { throw "python-env/fonts: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "python-env and font checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
