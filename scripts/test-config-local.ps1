# Tests bootstrap.ps1's config.local.toml writer (Set-ConfigLocalVar and
# Invoke-EnsureConfigLocal) without running the bootstrap: the two functions
# are extracted from the script's AST, the same way scripts/test-curl.ps1 works.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Set-ConfigLocalVar', 'Invoke-EnsureConfigLocal'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
function Write-Ok { param($m) }
function Write-Log { param($m) }
function Write-Warn { param($m) }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cfglocal-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # 1. Existing file (name/email/group + a [dotfiles] table): mode added, rest kept.
    $script:RepoPath = Join-Path $tmp 'a'; New-Item -ItemType Directory -Path $RepoPath | Out-Null
    $cfg = Join-Path $RepoPath 'config.local.toml'
    [System.IO.File]::WriteAllText($cfg, "[vars]`nname = `"N`"`nemail = `"e@x`"`ngroup = `"dev_machine`"`n`n[dotfiles]`n`"~/.x`" = { source = `"x`", mode = `"copy`", enabled = false }`n")
    $script:SkipToolInstall = $true
    Invoke-EnsureConfigLocal
    $text = [System.IO.File]::ReadAllText($cfg)
    Assert ($text -match '(?m)^mode = "owned"$') 'existing file: mode = "owned" not added'
    Assert ($text -match '(?m)^name = "N"$') 'existing file: name lost'
    Assert ($text -match '(?m)^\[dotfiles\]$') 'existing file: [dotfiles] lost'
    Assert (([regex]::Matches($text, '(?m)^mode = ')).Count -eq 1) 'existing file: mode duplicated'

    # 2. No file, non-interactive: file created with mode only.
    $script:RepoPath = Join-Path $tmp 'b'; New-Item -ItemType Directory -Path $RepoPath | Out-Null
    $cfg = Join-Path $RepoPath 'config.local.toml'
    Invoke-EnsureConfigLocal
    $text = [System.IO.File]::ReadAllText($cfg)
    Assert ($text -match '(?m)^\[vars\]$') 'new file: [vars] missing'
    Assert ($text -match '(?m)^mode = "owned"$') 'new file: mode missing'
    $bytes = [System.IO.File]::ReadAllBytes($cfg)
    Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'new file: written with a BOM'

    # 3. Set-ConfigLocalVar escapes quotes and replaces in place.
    Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'Q "q"'
    Set-ConfigLocalVar -Path $cfg -Key 'name' -Value 'R'
    $text = [System.IO.File]::ReadAllText($cfg)
    Assert (([regex]::Matches($text, '(?m)^name = ')).Count -eq 1) 'Set-ConfigLocalVar duplicated a key'
    Assert ($text -match '(?m)^name = "R"$') 'Set-ConfigLocalVar did not replace'
    Set-ConfigLocalVar -Path $cfg -Key 'email' -Value 'a\b"c'
    Assert ([System.IO.File]::ReadAllText($cfg) -match [regex]::Escape('email = "a\\b\"c"')) 'Set-ConfigLocalVar did not escape'

    Write-Host "config.local.toml writer checks passed on PowerShell $($PSVersionTable.PSVersion)"
} finally {
    Remove-Item -Recurse -Force $tmp
}
$global:LASTEXITCODE = 0
