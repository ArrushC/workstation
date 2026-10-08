# test-helpers.ps1 -- shared plumbing for scripts/test-*.ps1, which test bootstrap.ps1's
# functions without running the bootstrap. Each test dot-sources it first:
#   . (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
# It gives them:
#  - Read-ScriptAst / Get-AstFunction / Import-AstFunction: a script's functions, taken
#    from its AST (a parse error or a missing function stops the test)
#  - Write-Log/Ok/Warn/Fail stand-ins: every line goes to $script:events ("log: ...",
#    "ok: ...", "warn: ..."), warnings also to $script:warnings, and Write-Fail throws
#    "WRITE-FAIL: ..." instead of exiting
#  - a `mise` stub that records each call in $script:miseCalls and answers from
#    $script:miseReply (the first key found in the call -> its Out and Exit)
#  - Assert, Test-Case (each case runs on its own, so one failure doesn't hide the
#    rest), New-TestTempDir, New-TestFile, Read-Text, Assert-Stub, Complete-Test
# A test redefines any of these after the dot-source when it needs its own.
# Windows PowerShell 5.1 and pwsh; ASCII only (5.1 reads a BOM-less file in the ANSI
# code page).

# Parsed with its errors checked: a broken script fails here, not later as a
# missing command.
function Read-ScriptAst {
    param([Parameter(Mandatory)][string]$Path)
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw "parse errors in ${Path}: $(($parseErrors | ForEach-Object { $_.ToString() }) -join '; ')" }
    return $ast
}

# The named functions' definitions; throws when one is missing.
function Get-AstFunction {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string[]]$Name)
    $found = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Name }, $true))
    $missing = @($Name | Where-Object { $_ -notin @($found | ForEach-Object { $_.Name }) })
    if ($missing.Count -gt 0) { throw "missing function(s): $($missing -join ', ')" }
    return $found
}

# A script block that defines the named functions; dot-source it so they land in the
# caller's scope:  . (Import-AstFunction $ast 'Install-Mise', 'Initialize-MiseEnv')
function Import-AstFunction {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string[]]$Name)
    $text = @(Get-AstFunction -Ast $Ast -Name $Name | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    return [scriptblock]::Create($text)
}

$script:events = New-Object System.Collections.Generic.List[string]
$script:warnings = New-Object System.Collections.Generic.List[string]
function Write-Log { param($m) $script:events.Add("log: $m") }
function Write-Ok { param($m) $script:events.Add("ok: $m") }
function Write-Warn { param($m) $script:events.Add("warn: $m"); $script:warnings.Add([string]$m) }
# Write-Fail exits bootstrap.ps1; here it throws so a case can assert on it.
function Write-Fail { param($m) throw "WRITE-FAIL: $m" }

# Functions win over mise.exe on PATH; Assert-Stub 'mise' checks that one did.
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

# Refuse to run unless each name resolves to a function (a stub), never the real tool.
function Assert-Stub {
    param([Parameter(Mandatory)][string[]]$Name)
    foreach ($c in $Name) {
        if ((Get-Command $c).CommandType -ne 'Function') { throw "refusing to run: $c does not resolve to the test stub" }
    }
}

function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

$script:failures = New-Object System.Collections.Generic.List[string]
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        $script:warnings.Clear()
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $script:failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}

function New-TestTempDir([string]$Prefix) {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}
function New-TestFile([string]$Path, [string]$Content = 'x') {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content)
}
function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path) }

# The last line of every test: throw when a case failed. A CI step ends with
# `exit $LASTEXITCODE`, and a test's last native call may have failed on purpose,
# so a pass resets it.
function Complete-Test([string]$Label) {
    if ($script:failures.Count -gt 0) { throw "$Label checks: $($script:failures.Count) case(s) failed: $($script:failures -join '; ')" }
    Write-Host "$Label checks passed on PowerShell $($PSVersionTable.PSVersion)"
    $global:LASTEXITCODE = 0
}
