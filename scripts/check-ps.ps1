#!/usr/bin/env pwsh
# check-ps.ps1 -- run PSScriptAnalyzer over the repo's PowerShell scripts.
# Single source for `make ps-lint` and the CI `powershell` job. Exits non-zero
# if any finding at Warning or Error remains after PSScriptAnalyzerSettings.psd1.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot   # scripts/ -> repo root
$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

$targets = @(
    'bootstrap.ps1',
    'scripts/manage-hosts.ps1',
    'scripts/install-nerd-fonts.ps1',
    'scripts/check-ps.ps1'
) | ForEach-Object { Join-Path $repoRoot $_ }

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Error 'PSScriptAnalyzer not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 2
}

$results = foreach ($t in $targets) {
    Invoke-ScriptAnalyzer -Path $t -Settings $settings
}

if ($results) {
    $results |
        Sort-Object ScriptName, Line |
        Format-Table -AutoSize Severity, ScriptName, Line, RuleName, Message |
        Out-String -Width 200 |
        Write-Host
    $n = ($results | Measure-Object).Count
    Write-Host "PSScriptAnalyzer: $n finding(s) at Warning+ (see above)" -ForegroundColor Red
    exit 1
}

Write-Host "PSScriptAnalyzer: clean (Warning+) over $($targets.Count) files" -ForegroundColor Green
exit 0
