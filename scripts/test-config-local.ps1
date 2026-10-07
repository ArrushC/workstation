# Tests bootstrap.ps1's config.local.toml writer (Set-ConfigLocalVar and
# Invoke-EnsureConfigLocal) without running the bootstrap: the two functions
# are extracted from the script's AST, the same way scripts/test-curl.ps1 works.
# StrictMode matches bootstrap.ps1's own, so a strict-only crash fails here too.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Set-ConfigLocalVar', 'Invoke-EnsureConfigLocal'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$script:okMsg = $null
$script:warnMsg = $null
function Write-Ok { param($m) $script:okMsg = $m }
function Write-Log { param($m) }
function Write-Warn { param($m) $script:warnMsg = $m }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

# Each case runs on its own, so one failure doesn't hide the rest.
$failures = New-Object System.Collections.Generic.List[string]
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}
function New-CaseDir([string]$Name) {
    $script:RepoPath = Join-Path $tmp $Name
    New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
    return (Join-Path $script:RepoPath 'config.local.toml')
}
function Read-Cfg([string]$Path) { return [System.IO.File]::ReadAllText($Path) }
function Get-MatchCount([string]$Text, [string]$Pattern) { return ([regex]::Matches($Text, $Pattern)).Count }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cfglocal-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:SkipToolInstall = $true
try {
    Test-Case 'existing file with name and email: left byte-for-byte' {
        $cfg = New-CaseDir 'a'
        $before = "[vars]`nname = `"N`"`nemail = `"e@x`"`n`n[dotfiles]`n`"~/.x`" = { source = `"x`", mode = `"copy`", enabled = false }`n"
        [System.IO.File]::WriteAllText($cfg, $before)
        Invoke-EnsureConfigLocal
        Assert ((Read-Cfg $cfg) -ceq $before) "file changed: $(Read-Cfg $cfg)"
    }

    Test-Case 'missing file, non-interactive: nothing written' {
        $cfg = New-CaseDir 'b'
        $script:warnMsg = $null
        Invoke-EnsureConfigLocal
        Assert (-not (Test-Path $cfg)) 'file created'
        Assert ("$script:warnMsg" -like '*name / email*') "no name/email warning: $script:warnMsg"
    }

    Test-Case 'Set-ConfigLocalVar escapes quotes and replaces in place' {
        $cfg = New-CaseDir 'c'
        Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'Q "q"'
        Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'R'
        $text = Read-Cfg $cfg
        Assert ((Get-MatchCount $text '(?m)^name = ') -eq 1) 'duplicated a key'
        Assert ($text -match '(?m)^name = "R"$') 'did not replace'
        Set-ConfigLocalVar -Path $cfg -Key 'email' -Value 'a\b"c'
        Assert ((Read-Cfg $cfg) -match [regex]::Escape('email = "a\\b\"c"')) 'did not escape'
    }

    Test-Case 'empty file' {
        $cfg = New-CaseDir 'empty'
        [System.IO.File]::WriteAllText($cfg, '')
        Invoke-EnsureConfigLocal
        Assert ((Read-Cfg $cfg) -ceq '') "got: $(Read-Cfg $cfg)"
    }

    Test-Case 'one-line file, no trailing newline' {
        $cfg = New-CaseDir 'one-nonl'
        [System.IO.File]::WriteAllText($cfg, '[vars]')
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        Assert ((Read-Cfg $cfg) -ceq "[vars]`neditor = `"hx`"`n") "got: $(Read-Cfg $cfg)"
    }

    Test-Case 'one-line file, trailing newline' {
        $cfg = New-CaseDir 'one-nl'
        [System.IO.File]::WriteAllText($cfg, "[vars]`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        Assert ((Read-Cfg $cfg) -ceq "[vars]`neditor = `"hx`"`n") "got: $(Read-Cfg $cfg)"
    }

    Test-Case '[vars] header with a trailing space' {
        $cfg = New-CaseDir 'hdr-space'
        [System.IO.File]::WriteAllText($cfg, "[vars] `r`nname = `"N`"`r`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        $text = Read-Cfg $cfg
        Assert ((Get-MatchCount $text '(?m)^\s*\[\s*vars\s*\]') -eq 1) "duplicate [vars] table: $text"
        Assert ($text -match '(?m)^editor = "hx"$') "key not added: $text"
    }

    Test-Case '[vars] header with a trailing comment' {
        $cfg = New-CaseDir 'hdr-comment'
        [System.IO.File]::WriteAllText($cfg, "[vars] # identity`nname = `"N`"`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        $text = Read-Cfg $cfg
        Assert ((Get-MatchCount $text '(?m)^\s*\[\s*vars\s*\]') -eq 1) "duplicate [vars] table: $text"
        Assert ($text -match '(?m)^editor = "hx"$') "key not added: $text"
    }

    Test-Case 'indented key is replaced, not duplicated' {
        $cfg = New-CaseDir 'indent-key'
        [System.IO.File]::WriteAllText($cfg, "[vars]`n  editor = `"vi`"`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        $text = Read-Cfg $cfg
        Assert ((Get-MatchCount $text '(?m)^\s*editor\s*=') -eq 1) "duplicate key: $text"
        Assert ($text -match '(?m)^editor = "hx"$') "key not replaced: $text"
    }

    Test-Case 'indented header of another table leaves [vars]' {
        $cfg = New-CaseDir 'indent-hdr'
        [System.IO.File]::WriteAllText($cfg, "[vars]`nname = `"N`"`n  [dotfiles]`nx = 1`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        Assert ((Read-Cfg $cfg) -ceq "[vars]`nname = `"N`"`neditor = `"hx`"`n  [dotfiles]`nx = 1`n") "key not kept in [vars]: $(Read-Cfg $cfg)"
    }

    Test-Case 'indented name/email count as present' {
        $cfg = New-CaseDir 'indent-identity'
        [System.IO.File]::WriteAllText($cfg, "[vars]`n  name = `"N`"`n  email = `"e@x`"`n")
        $script:okMsg = $null; $script:warnMsg = $null
        Invoke-EnsureConfigLocal
        Assert ($null -eq $script:warnMsg) "asked for name/email again: $script:warnMsg"
        Assert ("$script:okMsg" -like 'config.local.toml ready*') "no ready message: $script:okMsg"
    }
} finally {
    Remove-Item -Recurse -Force $tmp
}
if ($failures.Count -gt 0) { throw "config.local.toml writer: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "config.local.toml writer checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
