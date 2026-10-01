# Tests bootstrap.ps1's miserc.toml writer (Initialize-MiseEnv) and the
# one-time cleanup of the pre-mise portable installs (Invoke-LegacyToolCleanup)
# without running the bootstrap: the functions are extracted from the script's
# AST, as scripts/test-config-local.ps1 does. Both reach the User environment
# only through Get-UserEnv/Set-UserEnv, which are stubbed here (PowerShell
# can't stub a static .NET method), so the real User environment is never
# read or written. A function that calls [Environment]::SetEnvironmentVariable
# itself is refused, not loaded. Paths point at a temp dir.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Initialize-MiseEnv', 'Invoke-LegacyToolCleanup'
$refused = New-Object System.Collections.Generic.List[string]
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    if ($f.Extent.Text -match 'Environment\]::SetEnvironmentVariable') { $refused.Add($f.Name); continue }
    . ([scriptblock]::Create($f.Extent.Text))
}
function Write-Ok { param($m) }
function Write-Log { param($m) }
function Write-Warn { param($m) }
# The fake User environment: a case-insensitive name -> value table.
$script:userEnv = @{}
$script:userWrites = New-Object System.Collections.Generic.List[string]
function Get-UserEnv { param([string]$Name) if ($script:userEnv.ContainsKey($Name)) { $script:userEnv[$Name] } }
function Set-UserEnv {
    param([string]$Name, $Value)
    $script:userWrites.Add($Name)
    if ($null -eq $Value) { $script:userEnv.Remove($Name) } else { $script:userEnv[$Name] = $Value }
}
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

$failures = New-Object System.Collections.Generic.List[string]
foreach ($name in $refused) { $failures.Add("$name writes the User environment directly (use Set-UserEnv)") }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}
function New-TestFile([string]$Path) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, 'x')
}

$savedMiseEnv = $env:MISE_ENV
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("miseenv-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Test-Case 'miserc.toml: windows,owned, no BOM, LF; the User and session MISE_ENV go' {
        $script:RepoPath = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
        $script:MiseEnvTokens = @('windows', 'owned')
        $script:userEnv = @{ MISE_ENV = 'windows,owned'; Path = 'C:\x' }
        $script:userWrites.Clear()
        $env:MISE_ENV = 'windows,owned'
        Initialize-MiseEnv
        $rc = Join-Path $script:RepoPath 'miserc.toml'
        $bytes = [System.IO.File]::ReadAllBytes($rc)
        Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'written with a BOM'
        $text = [System.IO.File]::ReadAllText($rc)
        Assert (-not $text.Contains("`r")) 'CR line endings'
        $lines = @($text -split "`n")
        Assert ($lines -ccontains 'env = ["windows", "owned"]') "no env line: $text"
        Assert ($lines -ccontains 'auto_env = false') "no auto_env line: $text"
        Assert (@($lines | Where-Object { $_ -and $_ -notmatch '^#' }).Count -eq 2) "unexpected lines: $text"
        Assert (-not (Test-Path Env:MISE_ENV)) "session MISE_ENV still set: $env:MISE_ENV"
        Assert (-not $script:userEnv.ContainsKey('MISE_ENV')) 'User MISE_ENV not removed'
        Assert ($script:userEnv['Path'] -ceq 'C:\x') 'User Path touched'
    }

    Test-Case 'miserc.toml rewritten; no User MISE_ENV means no User write' {
        $script:RepoPath = Join-Path $tmp 'repo2'
        New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:RepoPath 'miserc.toml'), "env = [`"linux`"]`n")
        $script:MiseEnvTokens = @('windows', 'owned')
        $script:userEnv = @{ Path = 'C:\x' }
        $script:userWrites.Clear()
        Initialize-MiseEnv
        Assert ([System.IO.File]::ReadAllText((Join-Path $script:RepoPath 'miserc.toml')).Contains('env = ["windows", "owned"]')) 'old miserc.toml kept'
        Assert ($script:userWrites.Count -eq 0) "User environment written: $($script:userWrites -join ', ')"
    }

    Test-Case 'legacy cleanup: old dirs, exes, stamps and PATH entries go; the rest stays' {
        $script:WsRoot = Join-Path $tmp 'ws'
        $script:WsBin = Join-Path $script:WsRoot 'bin'
        $script:WsStamps = Join-Path $script:WsRoot 'stamps'
        $oldDirs = 'helix', 'nu', 'devtoys-cli', 'dngrep', 'logexpert'
        foreach ($d in $oldDirs) { New-TestFile (Join-Path $script:WsRoot "$d\tool.exe") }
        $oldExes = 'starship', 'gh', 'jq', 'omp', 'opencode', 'chezmoi'
        foreach ($e in $oldExes) { New-TestFile (Join-Path $script:WsBin "$e.exe") }
        $keepFiles = @(
            (Join-Path $script:WsBin 'wpy.cmd'),
            (Join-Path $script:WsBin 'textual.cmd'),
            (Join-Path $script:WsRoot 'mise\bin\mise.exe'),
            (Join-Path $script:WsStamps 'mise.2026.9.9.stamp'),
            (Join-Path $script:WsStamps 'python-env.3.14.7.abcd1234.stamp'),
            (Join-Path $script:WsStamps 'wslconfig.abcd1234.stamp'),
            (Join-Path $script:WsStamps 'node-postinstall.0123456789abcdef.stamp')
        )
        foreach ($k in $keepFiles) { New-TestFile $k }
        $oldStamps = 'starship.1.25.1.stamp', 'nu.0.113.1.stamp', 'DevToys.CLI.2.0.9.0.stamp', 'dnGREP.5.0.30.0.stamp', 'mise-runtimes.abcd1234.stamp'
        foreach ($s in $oldStamps) { New-TestFile (Join-Path $script:WsStamps $s) }
        $script:userEnv = @{ Path = (@(
            'C:\Windows',
            $script:WsBin,
            (Join-Path $script:WsRoot 'helix'),
            ((Join-Path $script:WsRoot 'nu') + '\'),
            (Join-Path $script:WsRoot 'DevToys-CLI'),
            (Join-Path $script:WsRoot 'dngrep'),
            (Join-Path $script:WsRoot 'logexpert'),
            (Join-Path $script:WsRoot 'mise\bin'),
            'C:\Users\u\AppData\Local\mise\shims'
        ) -join ';') }
        $script:userWrites.Clear()
        Invoke-LegacyToolCleanup
        foreach ($d in $oldDirs) { Assert (-not (Test-Path (Join-Path $script:WsRoot $d))) "$d dir left behind" }
        foreach ($e in $oldExes) { Assert (-not (Test-Path (Join-Path $script:WsBin "$e.exe"))) "$e.exe left behind" }
        foreach ($s in $oldStamps) { Assert (-not (Test-Path (Join-Path $script:WsStamps $s))) "$s left behind" }
        foreach ($k in $keepFiles) { Assert (Test-Path $k) "$k removed" }
        $want = @('C:\Windows', $script:WsBin, (Join-Path $script:WsRoot 'mise\bin'), 'C:\Users\u\AppData\Local\mise\shims') -join ';'
        Assert ($script:userEnv['Path'] -ceq $want) "User Path: $($script:userEnv['Path'])"
    }

    Test-Case 'legacy cleanup: a second run changes nothing' {
        $before = $script:userEnv['Path']
        $script:userWrites.Clear()
        Invoke-LegacyToolCleanup
        Assert ($script:userWrites.Count -eq 0) "User environment written: $($script:userWrites -join ', ')"
        Assert ($script:userEnv['Path'] -ceq $before) 'User Path changed'
        Assert (Test-Path (Join-Path $script:WsStamps 'mise.2026.9.9.stamp')) 'mise stamp removed'
    }
} finally {
    if ($null -eq $savedMiseEnv) { Remove-Item Env:MISE_ENV -ErrorAction SilentlyContinue } else { $env:MISE_ENV = $savedMiseEnv }
    Remove-Item -Recurse -Force $tmp
}
if ($failures.Count -gt 0) { throw "mise env + legacy cleanup: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "mise env + legacy cleanup checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
