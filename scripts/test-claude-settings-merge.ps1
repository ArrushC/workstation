# Tests scripts/claude-settings-merge.ps1, Windows' ~/.claude/settings.json merge, against
# this checkout's settings.seed.json and settings.enforced.json, writing a throwaway -Dest:
# a first run (the seed and the enforced keys), a live file (the enforced keys win; its own
# keys, hook types and plugins stay), non-ASCII text kept, a live file with a UTF-8 BOM
# (merged, and rewritten without it even when up to date), an up-to-date file left alone,
# a live file that isn't JSON and a PATH without jq (each a warning, the file as it was,
# exit 0), bootstrap.ps1's Invoke-ClaudeSettingsMerge running the script, and
# config.windows.toml running it from the post-tools hook, so wsu merges too.
# Windows PowerShell 5.1 and pwsh; ASCII only. Needs jq on PATH (mise's, or the runner's).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script = Join-Path $PSScriptRoot 'claude-settings-merge.ps1'
$shell = (Get-Process -Id $PID).Path
if (-not (Get-Command jq -CommandType Application -ErrorAction SilentlyContinue)) { throw 'jq is not on PATH; the merge needs it' }
$seed = Read-Text (Join-Path $repoRoot 'dotfiles\claude\settings.seed.json') | ConvertFrom-Json
$enforced = Read-Text (Join-Path $repoRoot 'dotfiles\claude\settings.enforced.json') | ConvertFrom-Json

$tmp = New-TestTempDir 'claude-settings-'
$dest = Join-Path $tmp '.claude\settings.json'

function Invoke-Merge {
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $script -Dest $dest 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
}
function Read-Settings { Read-Text $dest | ConvertFrom-Json }

try {
    Test-Case 'no settings.json: the seed and the enforced keys, no temp file left' {
        $r = Invoke-Merge
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -match 'merged') "no merge line: $($r.Out)"
        $s = Read-Settings
        Assert ($s.theme -eq $enforced.theme) "theme is $($s.theme)"
        Assert ($s.model -eq $seed.model) "model is $($s.model)"
        Assert ($s.enabledPlugins.'code-review@claude-plugins-official' -eq $true) 'code review is not on'
        $left = @(Get-ChildItem -Force -LiteralPath (Split-Path $dest) | Where-Object { $_.Name -ne 'settings.json' } | ForEach-Object { $_.Name })
        Assert ($left.Count -eq 0) "left behind: $($left -join ', ')"
    }

    Test-Case 'a live file: the enforced keys win; its own keys, hook types and plugins stay' {
        New-TestFile $dest '{"theme":"auto","model":"sonnet","mine":1,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo stop"}]}]},"enabledPlugins":{"mine@market":true}}'
        $r = Invoke-Merge
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        $s = Read-Settings
        Assert ($s.theme -eq $enforced.theme) "theme is $($s.theme)"
        Assert ($s.model -eq 'sonnet') "the seed overwrote model: $($s.model)"
        Assert ($s.mine -eq 1) 'a live-only key was dropped'
        Assert ($s.hooks.Stop[0].hooks[0].command -eq 'echo stop') 'the live Stop hook was dropped'
        foreach ($k in $enforced.hooks.PSObject.Properties.Name) {
            Assert ($s.hooks.PSObject.Properties.Name -contains $k) "the enforced $k hook is missing"
        }
        Assert ($s.enabledPlugins.'mine@market' -eq $true) 'a live plugin was dropped'
        Assert ($s.enabledPlugins.'clangd-lsp@claude-plugins-official' -eq $false) 'clangd-lsp is not off'
    }

    Test-Case 'non-ASCII text in the live file comes through' {
        $text = 'caf' + [char]0x00e9 + ' ' + [char]0x2014 + ' ' + [char]0x2713
        [IO.File]::WriteAllText($dest, '{"note":"' + $text + '"}', [Text.UTF8Encoding]::new($false))
        $r = Invoke-Merge
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        $note = (Read-Settings).note
        Assert ($note -ceq $text) "note is now '$note'"
    }

    Test-Case 'a live file with a UTF-8 BOM: merged and rewritten without it, no temp file left' {
        [IO.File]::WriteAllText($dest, '{"theme":"auto","mine":1}', [Text.UTF8Encoding]::new($true))
        $r = Invoke-Merge
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -match 'merged') "no merge line: $($r.Out)"
        Assert ([IO.File]::ReadAllBytes($dest)[0] -ne 0xEF) 'the BOM is still there'
        $s = Read-Settings
        Assert ($s.mine -eq 1) 'a live-only key was dropped'
        Assert ($s.theme -eq $enforced.theme) "theme is $($s.theme)"
        $left = @(Get-ChildItem -Force -LiteralPath (Split-Path $dest) | Where-Object { $_.Name -ne 'settings.json' } | ForEach-Object { $_.Name })
        Assert ($left.Count -eq 0) "left behind: $($left -join ', ')"
    }

    Test-Case 'an up-to-date file with a BOM: still rewritten without it' {
        Invoke-Merge | Out-Null
        [IO.File]::WriteAllText($dest, [IO.File]::ReadAllText($dest), [Text.UTF8Encoding]::new($true))
        $r = Invoke-Merge
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert ([IO.File]::ReadAllBytes($dest)[0] -ne 0xEF) 'the BOM is still there'
    }

    Test-Case 'an up-to-date file: not rewritten, nothing said' {
        Invoke-Merge | Out-Null
        $old = (Get-Date).AddDays(-1)
        (Get-Item -LiteralPath $dest).LastWriteTime = $old
        $r = Invoke-Merge
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert ($r.Out.Trim() -eq '') "it said: $($r.Out)"
        Assert ((Get-Item -LiteralPath $dest).LastWriteTime -eq $old) 'the file was rewritten'
    }

    Test-Case 'a live file that is not JSON: a warning, exit 0, the file as it was' {
        $bad = '{"theme": "auto",'
        New-TestFile $dest $bad
        $r = Invoke-Merge
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -match 'not valid JSON') "no warning: $($r.Out)"
        Assert ((Read-Text $dest) -ceq $bad) 'the file changed'
    }

    Test-Case 'no jq on PATH: a warning, exit 0, the file as it was' {
        New-TestFile $dest '{"theme":"auto"}'
        $path = $env:PATH
        try {
            $env:PATH = Join-Path $env:SystemRoot 'System32'
            $r = Invoke-Merge
        } finally {
            $env:PATH = $path
        }
        Assert ($r.Code -eq 0) "exit $($r.Code): $($r.Out)"
        Assert ($r.Out -match 'jq') "no warning: $($r.Out)"
        Assert ((Read-Text $dest) -ceq '{"theme":"auto"}') 'the file changed'
    }

    Test-Case 'bootstrap.ps1''s Invoke-ClaudeSettingsMerge runs the script (-SkipToolInstall runs no hook)' {
        $ast = Read-ScriptAst (Join-Path $repoRoot 'bootstrap.ps1')
        . (Import-AstFunction $ast 'Invoke-ClaudeSettingsMerge')
        $RepoPath = Join-Path $tmp 'repo'
        $marker = Join-Path $tmp 'ran'
        New-TestFile (Join-Path $RepoPath 'scripts\claude-settings-merge.ps1') "Set-Content -LiteralPath '$marker' -Value ran"
        Invoke-ClaudeSettingsMerge
        Assert (Test-Path -LiteralPath $marker) 'the script did not run'
    }

    Test-Case 'config.windows.toml runs it from the post-tools hook, so wsu merges too' {
        $toml = Read-Text (Join-Path $repoRoot 'config.windows.toml')
        Assert ($toml -match '(?m)^post-tools = "mise run [^"]*\bclaude-settings-win\b') 'the post-tools hook does not run claude-settings-win'
        Assert ($toml -match '(?s)\[tasks\.claude-settings-win\][^\[]*scripts/claude-settings-merge\.ps1') 'claude-settings-win does not run scripts/claude-settings-merge.ps1'
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Test 'claude-settings-merge'
