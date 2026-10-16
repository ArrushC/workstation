#Requires -Version 5.1
# =============================================================================
# claude-settings-merge.ps1 -- Windows' three-layer ~/.claude/settings.json merge, with
# scripts/lib/claude-settings-merge.sh's jq filter (that file explains the layers):
# settings.seed.json (only where a key is absent) -> the live file -> settings.enforced.json
# (always wins).
#
# Run by config.windows.toml's `claude-settings-win` task (the post-tools hook), so wsu
# applies a settings.enforced.json change as Linux's full bootstrap does, and by
# bootstrap.ps1's Invoke-ClaudeSettingsMerge (-SkipToolInstall runs no hook). The file is
# rewritten, through a temp file and a rename, only when the merge changes it, and a run
# that changes nothing prints nothing. Every failure (no jq, a missing source, a live file
# that isn't JSON) warns, leaves the file as it was and exits 0: a failing hook would stop
# `mise bootstrap`.
# jq -a writes non-ASCII as \u escapes, so its output reads the same whatever the
# console's code page. ASCII only: Windows PowerShell 5.1 reads a BOM-less script in the
# ANSI code page. scripts/test-claude-settings-merge.ps1 tests it with -Dest.
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/claude-settings-merge.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string]$Dest = (Join-Path $env:USERPROFILE '.claude\settings.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$seed = Join-Path $repo 'dotfiles\claude\settings.seed.json'
$enforced = Join-Path $repo 'dotfiles\claude\settings.enforced.json'

function Write-Step([string]$Message) { Write-Host "  claude settings: $Message" }

# jq's output lines; $LASTEXITCODE is jq's. 'Continue', local to the call: PS 5.1 turns
# a native command's redirected stderr into error records, which 'Stop' makes terminating.
function Invoke-Jq {
    $ErrorActionPreference = 'Continue'
    & jq @args 2>$null
}

function Merge-Settings {
    if (-not (Get-Command jq -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Step "! jq is not on PATH -- $Dest left as it is"
        return
    }
    foreach ($f in $seed, $enforced) {
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Step "! missing $f -- $Dest left as it is"
            return
        }
    }
    $dir = Split-Path -Parent $Dest
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $empty = Join-Path $dir ".settings.json.empty.$PID.tmp"
    $tmp = Join-Path $dir ".settings.json.$PID.tmp"
    try {
        $live = $Dest
        if (Test-Path -LiteralPath $Dest) {
            Invoke-Jq empty $Dest | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Step "! $Dest is not valid JSON -- left as it is"
                return
            }
        } else {
            [IO.File]::WriteAllText($empty, '{}')
            $live = $empty
        }
        $merged = @(Invoke-Jq -a -s '.[0] * .[1] * .[2]' $seed $live $enforced)
        if ($LASTEXITCODE -ne 0 -or $merged.Count -eq 0) {
            Write-Step "! the jq merge failed -- $Dest left as it is"
            return
        }
        $text = ($merged -join "`n") + "`n"
        if ((Test-Path -LiteralPath $Dest) -and [IO.File]::ReadAllText($Dest) -ceq $text) { return }
        [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
        Move-Item -Force -LiteralPath $tmp -Destination $Dest
        Write-Step "merged seed + live + enforced -> $Dest"
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $empty, $tmp
    }
}

try {
    Merge-Settings
} catch {
    Write-Step "! merge failed: $_ -- $Dest left as it is"
}
exit 0
