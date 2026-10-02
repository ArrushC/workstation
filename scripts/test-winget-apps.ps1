# Tests bootstrap.ps1's GUI-app step without running the bootstrap: Install-WingetApps
# (mise bootstrap --only packages: config.windows.toml's winget list) and
# Install-SshfsWin (the one UAC install). Both are extracted from the script's AST,
# as scripts/test-ssh-launchers.ps1 does.
#
# Nothing is installed: `mise` and `winget` are function stubs that record their
# arguments (functions win over mise.exe/winget.exe on PATH), and the script stops
# unless both resolve to the stubs.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$failures = New-Object System.Collections.Generic.List[string]
$wanted = 'Install-WingetApps', 'Install-SshfsWin'
$found = @()
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
    $found += $f.Name
}
foreach ($w in $wanted) { if ($found -notcontains $w) { $failures.Add("bootstrap.ps1 has no function $w") } }
if ($ast.Find({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq 'WingetApps' }, $true)) {
    $failures.Add('bootstrap.ps1 still references $WingetApps (the apps live in config.windows.toml)')
}
if ($failures.Count -gt 0) { throw "winget apps: $($failures -join '; ')" }

# Every mise/winget call and log line, in order.
$script:events = New-Object System.Collections.Generic.List[string]
$script:miseExit = 0
$script:miseThrows = $false
$script:listExit = 0
$script:installExit = 0
$script:wingetThrows = $false
$script:installThrows = $false
# The ErrorActionPreference winget runs under, and the one the warnings run under afterwards.
$script:wingetEap = New-Object System.Collections.Generic.List[string]
$script:warnEap = New-Object System.Collections.Generic.List[string]
function mise {
    $script:events.Add("mise $($args -join ' ')")
    if ($script:miseThrows) { throw [System.Management.Automation.ApplicationFailedException]::new('mise could not start') }
    $global:LASTEXITCODE = $script:miseExit
}
function winget {
    $script:events.Add("winget $($args -join ' ')")
    $script:wingetEap.Add("$ErrorActionPreference")
    if ($script:wingetThrows) { throw [System.Management.Automation.ApplicationFailedException]::new('The file cannot be accessed by the system.') }
    if ($script:installThrows -and $args[0] -eq 'install') { throw [System.Management.Automation.ApplicationFailedException]::new('The file cannot be accessed by the system.') }
    if ($args[0] -eq 'list') { $global:LASTEXITCODE = $script:listExit } else { $global:LASTEXITCODE = $script:installExit }
}
foreach ($c in 'mise', 'winget') {
    if ((Get-Command $c).CommandType -ne 'Function') { throw "refusing to run: $c does not resolve to the test stub" }
}
function Write-Log { param($m) $script:events.Add("log: $m") }
function Write-Ok { param($m) $script:events.Add("ok: $m") }
function Write-Warn { param($m) $script:events.Add("warn: $m"); $script:warnEap.Add("$ErrorActionPreference") }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }
function Get-Code([string]$Hex) { [Convert]::ToInt32($Hex, 16) }
# The leading comma keeps an empty or one-item result an array (StrictMode: $null has no .Count).
function Get-Events([string]$Like) { , @($script:events | Where-Object { $_ -like $Like }) }
function Show { $script:events -join ' | ' }

# One GUI-app run with the given stub behaviour.
function Invoke-Apps([switch]$SkipTools, [switch]$SkipElev, [int]$MiseExit = 0, [switch]$MiseThrows,
                     [int]$ListExit = 0, [int]$InstallExit = 0, [switch]$WingetThrows, [switch]$InstallThrows) {
    $script:SkipToolInstall = [bool]$SkipTools
    $script:SkipElevated = [bool]$SkipElev
    $script:miseExit = $MiseExit
    $script:miseThrows = [bool]$MiseThrows
    $script:listExit = $ListExit
    $script:installExit = $InstallExit
    $script:wingetThrows = [bool]$WingetThrows
    $script:installThrows = [bool]$InstallThrows
    $script:events.Clear()
    $script:wingetEap.Clear()
    $script:warnEap.Clear()
    Install-WingetApps
}

$miseCall = "mise -C $env:USERPROFILE bootstrap --only packages --yes"
$listCall = 'winget list --id SSHFS-Win.SSHFS-Win --exact --disable-interactivity --accept-source-agreements'
$installCall = 'winget install --id SSHFS-Win.SSHFS-Win --exact --scope machine --disable-interactivity --accept-package-agreements --accept-source-agreements'
$notFound = Get-Code '8A150014'

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}

Test-Case '-SkipToolInstall: neither mise nor winget runs' {
    Invoke-Apps -SkipTools
    Assert ((Get-Events 'mise *').Count -eq 0 -and (Get-Events 'winget *').Count -eq 0) "calls: $(Show)"
    Assert ((Get-Events 'log: GUI apps skipped (-SkipToolInstall)').Count -eq 1) "log: $(Show)"
}

Test-Case 'the apps come from mise (pinned with -C), then SSHFS-Win is checked with winget list; present -> no install' {
    Invoke-Apps -ListExit 0
    Assert ((Get-Events 'mise *').Count -eq 1 -and (Get-Events 'mise *')[0] -ceq $miseCall) "mise calls: $(Show)"
    Assert ((Get-Events 'winget *').Count -eq 1 -and (Get-Events 'winget *')[0] -ceq $listCall) "winget calls: $(Show)"
    Assert ($script:events.IndexOf($miseCall) -lt $script:events.IndexOf($listCall)) "order: $(Show)"
    Assert ((Get-Events 'ok: SSHFS-Win present').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'warn: *').Count -eq 0) "warned: $(Show)"
}

Test-Case 'SSHFS-Win missing (0x8A150014): machine scope, no --silent, the UAC warning (two prompts without WinFsp) before the install' {
    Invoke-Apps -ListExit $notFound
    $installs = Get-Events 'winget install *'
    Assert ($installs.Count -eq 1 -and $installs[0] -ceq $installCall) "install calls: $(Show)"
    Assert (($installs[0] -split ' ') -notcontains '--silent') "--silent in: $($installs[0])"
    $warn = Get-Events 'warn: SSHFS-Win installs machine-wide*expect a UAC prompt*'
    Assert ($warn.Count -eq 1 -and $warn[0] -like '*without WinFsp*two*one for WinFsp*one for SSHFS-Win*') "UAC warning: $(Show)"
    Assert ($script:events.IndexOf($warn[0]) -lt $script:events.IndexOf($installs[0])) "warning after the install: $(Show)"
    Assert ((Get-Events 'ok: SSHFS-Win installed').Count -eq 1) "log: $(Show)"
}

Test-Case '-SkipElevated: the mise apps still install; SSHFS-Win is neither checked nor installed' {
    Invoke-Apps -SkipElev -ListExit $notFound
    Assert ((Get-Events 'mise *').Count -eq 1) "mise calls: $(Show)"
    Assert ((Get-Events 'winget *').Count -eq 0) "winget calls: $(Show)"
    Assert ((Get-Events 'log: SSHFS-Win skipped (-SkipElevated)').Count -eq 1) "log: $(Show)"
}

Test-Case 'mise packages fails: a warning with the retry command, and SSHFS-Win still runs' {
    Invoke-Apps -MiseExit 1 -ListExit 0
    Assert ((Get-Events 'warn: mise bootstrap --only packages exited 1*mise bootstrap packages apply --manager winget*').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'winget list *').Count -eq 1) "SSHFS-Win skipped: $(Show)"
}

Test-Case 'mise cannot start: a warning, and SSHFS-Win still runs' {
    Invoke-Apps -MiseThrows -ListExit 0
    Assert ((Get-Events 'warn: mise bootstrap --only packages could not start*').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'winget list *').Count -eq 1) "SSHFS-Win skipped: $(Show)"
}

Test-Case 'winget list errors (not 0x8A150014): a warning and NO install, so no surprise UAC prompt' {
    Invoke-Apps -ListExit (Get-Code '8A15000F')
    Assert ((Get-Events 'winget install *').Count -eq 0) "installed anyway: $(Show)"
    Assert ((Get-Events 'warn: SSHFS-Win: could not check it (winget list 0x8A15000F)*').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events '*expect a UAC prompt*').Count -eq 0) "UAC warning without an install: $(Show)"
}

Test-Case 'an install failure warns with the hex code and the manual command' {
    Invoke-Apps -ListExit $notFound -InstallExit (Get-Code '8A150014')
    Assert ((Get-Events 'warn: SSHFS-Win: winget exited 0x8A150014*winget install --id SSHFS-Win.SSHFS-Win').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'ok: SSHFS-Win installed').Count -eq 0) "reported success: $(Show)"
}

Test-Case 'winget "already installed" codes (0x8A15002B, 0x8A150061, 0x8A15010D) count as present' {
    foreach ($hex in '8A15002B', '8A150061', '8A15010D') {
        Invoke-Apps -ListExit $notFound -InstallExit (Get-Code $hex)
        Assert ((Get-Events 'ok: SSHFS-Win present (winget)').Count -eq 1) "0x${hex}: $(Show)"
        Assert ((Get-Events 'warn: SSHFS-Win:*').Count -eq 0) "0x${hex} warned: $(Show)"
    }
}

Test-Case 'a winget that cannot start: a warning, no install, winget ran under Continue and the warning under Stop' {
    Invoke-Apps -WingetThrows
    Assert ((Get-Events 'winget install *').Count -eq 0) "installed: $(Show)"
    Assert ((Get-Events 'warn: SSHFS-Win: could not check it (winget list error*').Count -eq 1) "log: $(Show)"
    Assert ((@($script:wingetEap | Where-Object { $_ -ne 'Continue' }).Count -eq 0) -and ($script:wingetEap.Count -eq 1)) "EAP inside winget: $($script:wingetEap -join ', ')"
    Assert ((@($script:warnEap | Where-Object { $_ -ne 'Stop' }).Count -eq 0) -and ($script:warnEap.Count -ge 1)) "EAP at the warning: $($script:warnEap -join ', ')"
}

Test-Case 'winget install cannot start: a warning with the manual command, no success, install under Continue and the warning under Stop' {
    Invoke-Apps -ListExit $notFound -InstallThrows
    Assert ((Get-Events 'warn: SSHFS-Win: winget could not start*winget install --id SSHFS-Win.SSHFS-Win').Count -eq 1) "log: $(Show)"
    Assert ((Get-Events 'ok: SSHFS-Win installed').Count -eq 0) "reported success: $(Show)"
    $installEap = @($script:wingetEap)[-1]
    Assert ($installEap -eq 'Continue') "EAP inside winget install: $installEap"
    Assert ((@($script:warnEap | Where-Object { $_ -ne 'Stop' }).Count -eq 0) -and ($script:warnEap.Count -ge 1)) "EAP at the warning: $($script:warnEap -join ', ')"
}

if ($failures.Count -gt 0) { throw "winget apps: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "winget app checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
