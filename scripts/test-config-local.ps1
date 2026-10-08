# Tests bootstrap.ps1's config.local.toml writer (Set-ConfigLocalVar and
# Invoke-EnsureConfigLocal) without running the bootstrap: the two functions
# are extracted from the script's AST (scripts/lib/test-helpers.ps1).
# StrictMode matches bootstrap.ps1's own, so a strict-only crash fails here too.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = Read-ScriptAst (Join-Path $repoRoot 'bootstrap.ps1')
. (Import-AstFunction $ast 'Set-ConfigLocalVar', 'Invoke-EnsureConfigLocal')

function New-CaseDir([string]$Name) {
    $script:RepoPath = Join-Path $tmp $Name
    New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
    return (Join-Path $script:RepoPath 'config.local.toml')
}
function Get-MatchCount([string]$Text, [string]$Pattern) { return ([regex]::Matches($Text, $Pattern)).Count }

$tmp = New-TestTempDir 'cfglocal-'
$script:SkipToolInstall = $true
try {
    Test-Case 'existing file with name and email: left byte-for-byte' {
        $cfg = New-CaseDir 'a'
        $before = "[vars]`nname = `"N`"`nemail = `"e@x`"`n`n[dotfiles]`n`"~/.x`" = { source = `"x`", mode = `"copy`", enabled = false }`n"
        [System.IO.File]::WriteAllText($cfg, $before)
        Invoke-EnsureConfigLocal
        Assert ((Read-Text $cfg) -ceq $before) "file changed: $(Read-Text $cfg)"
    }

    Test-Case 'missing file, non-interactive: nothing written' {
        $cfg = New-CaseDir 'b'
        Invoke-EnsureConfigLocal
        Assert (-not (Test-Path $cfg)) 'file created'
        Assert (($script:warnings -join ' ') -like '*name / email*') "no name/email warning: $($script:warnings -join ' | ')"
    }

    Test-Case 'Set-ConfigLocalVar escapes quotes and replaces in place' {
        $cfg = New-CaseDir 'c'
        Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'Q "q"'
        Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'R'
        $text = Read-Text $cfg
        Assert ((Get-MatchCount $text '(?m)^name = ') -eq 1) 'duplicated a key'
        Assert ($text -match '(?m)^name = "R"$') 'did not replace'
        Set-ConfigLocalVar -Path $cfg -Key 'email' -Value 'a\b"c'
        Assert ((Read-Text $cfg) -match [regex]::Escape('email = "a\\b\"c"')) 'did not escape'
    }

    Test-Case 'empty file' {
        $cfg = New-CaseDir 'empty'
        [System.IO.File]::WriteAllText($cfg, '')
        Invoke-EnsureConfigLocal
        Assert ((Read-Text $cfg) -ceq '') "got: $(Read-Text $cfg)"
    }

    Test-Case 'one-line file, no trailing newline' {
        $cfg = New-CaseDir 'one-nonl'
        [System.IO.File]::WriteAllText($cfg, '[vars]')
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        Assert ((Read-Text $cfg) -ceq "[vars]`neditor = `"hx`"`n") "got: $(Read-Text $cfg)"
    }

    Test-Case 'one-line file, trailing newline' {
        $cfg = New-CaseDir 'one-nl'
        [System.IO.File]::WriteAllText($cfg, "[vars]`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        Assert ((Read-Text $cfg) -ceq "[vars]`neditor = `"hx`"`n") "got: $(Read-Text $cfg)"
    }

    Test-Case '[vars] header with a trailing space' {
        $cfg = New-CaseDir 'hdr-space'
        [System.IO.File]::WriteAllText($cfg, "[vars] `r`nname = `"N`"`r`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        $text = Read-Text $cfg
        Assert ((Get-MatchCount $text '(?m)^\s*\[\s*vars\s*\]') -eq 1) "duplicate [vars] table: $text"
        Assert ($text -match '(?m)^editor = "hx"$') "key not added: $text"
    }

    Test-Case '[vars] header with a trailing comment' {
        $cfg = New-CaseDir 'hdr-comment'
        [System.IO.File]::WriteAllText($cfg, "[vars] # identity`nname = `"N`"`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        $text = Read-Text $cfg
        Assert ((Get-MatchCount $text '(?m)^\s*\[\s*vars\s*\]') -eq 1) "duplicate [vars] table: $text"
        Assert ($text -match '(?m)^editor = "hx"$') "key not added: $text"
    }

    Test-Case 'indented key is replaced, not duplicated' {
        $cfg = New-CaseDir 'indent-key'
        [System.IO.File]::WriteAllText($cfg, "[vars]`n  editor = `"vi`"`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        $text = Read-Text $cfg
        Assert ((Get-MatchCount $text '(?m)^\s*editor\s*=') -eq 1) "duplicate key: $text"
        Assert ($text -match '(?m)^editor = "hx"$') "key not replaced: $text"
    }

    Test-Case 'indented header of another table leaves [vars]' {
        $cfg = New-CaseDir 'indent-hdr'
        [System.IO.File]::WriteAllText($cfg, "[vars]`nname = `"N`"`n  [dotfiles]`nx = 1`n")
        Set-ConfigLocalVar -Path $cfg -Key 'editor' -Value 'hx'
        Assert ((Read-Text $cfg) -ceq "[vars]`nname = `"N`"`neditor = `"hx`"`n  [dotfiles]`nx = 1`n") "key not kept in [vars]: $(Read-Text $cfg)"
    }

    Test-Case 'indented name/email count as present' {
        $cfg = New-CaseDir 'indent-identity'
        [System.IO.File]::WriteAllText($cfg, "[vars]`n  name = `"N`"`n  email = `"e@x`"`n")
        $script:events.Clear()
        Invoke-EnsureConfigLocal
        Assert ($script:warnings.Count -eq 0) "asked for name/email again: $($script:warnings -join ' | ')"
        Assert (@($script:events | Where-Object { $_ -like 'ok: config.local.toml ready*' }).Count -eq 1) "no ready message: $($script:events -join ' | ')"
    }
} finally {
    Remove-Item -Recurse -Force $tmp
}
Complete-Test 'config.local.toml writer'
