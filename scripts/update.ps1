# Windows update task: mise owns the bootstrap, just as tasks/update does on Linux.
param([switch]$Pulled, [Parameter(ValueFromRemainingArguments=$true)][string[]]$BootstrapArgs)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Pulled) {
    git -C $repo pull --ff-only --prune
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    # Read the newly pulled script before running the bootstrap, in this same PowerShell
    # (powershell.exe from the task, pwsh.exe when run by hand).
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Pulled @BootstrapArgs
    exit $LASTEXITCODE
}
mise -C $env:USERPROFILE bootstrap --only 'dotfiles,tools' --yes @BootstrapArgs
exit $LASTEXITCODE
