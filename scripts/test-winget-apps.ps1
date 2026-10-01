# Tests bootstrap.ps1's GUI-app step ($WingetApps + Install-WingetApps)
# without running the bootstrap: the table and the functions are extracted
# from the script's AST, as scripts/test-ssh-launchers.ps1 does.
#
# Nothing is installed:
#  - `winget` is a function stub that records its arguments (functions win
#    over winget.exe on PATH), and the script stops unless it resolves to it
#  - Get-AppxPackage and the Uninstall registry (Get-ItemProperty) are
#    stubbed to a fake inventory; the real Test-InstallerPresent matches it
#
# -HostCheck first runs the REAL Test-InstallerPresent and Get-AppxPackage
# (read-only) for every table entry on this machine, prints the table and
# fails when an app is not detected. Use it on a provisioned host, not in CI.
[CmdletBinding()]
param([switch]$HostCheck)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Test-InstallerPresent', 'Install-WingetApps'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$failures = New-Object System.Collections.Generic.List[string]
# The table is bootstrap.ps1's top-level `$WingetApps = @(...)` assignment.
$WingetApps = @()
$tableAst = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $n.Left.VariablePath.UserPath -eq 'WingetApps'
}, $false)
if ($tableAst) { . ([scriptblock]::Create($tableAst.Extent.Text)) } else { $failures.Add('bootstrap.ps1 has no top-level $WingetApps table') }

if ($HostCheck) {
    # Read-only: what the real registry and Appx store say on this machine.
    function Get-HostDisplayName([string]$Glob) {
        foreach ($root in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $Glob } |
                ForEach-Object { "$($root.Substring(0, 4)) '$($_.DisplayName)'" }
        }
    }
    Write-Host "Real host, read-only ($(@($WingetApps).Count) apps):"
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($app in $WingetApps) {
        if ($app.ContainsKey('Appx')) {
            $pkg = @(Get-AppxPackage -Name $app.Appx -ErrorAction SilentlyContinue)
            $present = $pkg.Count -gt 0
            $seen = "Appx $($app.Appx) -> $(@($pkg | ForEach-Object { $_.PackageFullName }) -join ', ')"
        } else {
            $present = Test-InstallerPresent $app.Detect
            $seen = "'$($app.Detect)' -> $(@(Get-HostDisplayName $app.Detect) -join ', ')"
        }
        if (-not $present) { $missing.Add($app.Name) }
        $state = if ($present) { 'present' } else { 'MISSING' }
        Write-Host ('  {0,-8} {1,-17} {2,-8} {3}' -f $state, $app.Name, $app.Scope, $seen)
    }
    if (@($WingetApps).Count -eq 0) { $failures.Add('host check: no $WingetApps entries to check') }
    elseif ($missing.Count -gt 0) { $failures.Add("host check: not detected on this host: $($missing -join ', ')") }
}

# The fake inventory. $hostArp/$hostAppx are the DisplayNames and Appx names
# this workstation reported (DevToys is the pre-winget "DevToys Preview").
$hostArp = @('Obsidian', 'Beyond Compare 5', 'DBeaver 26.2.1 (current user)', 'DevToys Preview version 2.0-preview.9',
    'Warp', 'WinSCP 6.5.6', 'Zed', 'SSHFS-Win 2021 (x64)', 'WinFsp 2025')
$hostAppx = @('Microsoft.WindowsTerminal')
$script:arp = @()
$script:appx = @()
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$Path)
    if ($Path -like 'HKCU:*') {
        [pscustomobject]@{ SystemComponent = 1 }   # an Uninstall key with no DisplayName
        foreach ($n in $script:arp) { [pscustomobject]@{ DisplayName = $n } }
    }
}
function Get-AppxPackage {
    [CmdletBinding()]
    param([string]$Name)
    if ($script:appx -contains $Name) { [pscustomobject]@{ Name = $Name; PackageFullName = "${Name}_fake" } }
}
$script:calls = New-Object System.Collections.Generic.List[string]
$script:wingetExit = 0
function winget {
    $script:calls.Add($args -join ' ')
    $global:LASTEXITCODE = $script:wingetExit
}
if ((Get-Command winget).CommandType -ne 'Function') { throw 'refusing to run: winget does not resolve to the test stub' }
$script:log = New-Object System.Collections.Generic.List[string]
function Write-Log { param($m) $script:log.Add("log: $m") }
function Write-Ok { param($m) $script:log.Add("ok: $m") }
function Write-Warn { param($m) $script:log.Add("warn: $m") }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

# One Install-WingetApps run against an inventory; returns the ids winget installed.
function Invoke-Apps([string[]]$Arp, [string[]]$Appx, [bool]$Skip, [int]$ExitCode = 0) {
    $script:arp = @($Arp)
    $script:appx = @($Appx)
    $script:SkipElevated = $Skip
    $script:wingetExit = $ExitCode
    $script:calls.Clear()
    $script:log.Clear()
    Install-WingetApps
    foreach ($c in $script:calls) {
        $words = $c -split ' '
        $at = [array]::IndexOf($words, '--id')
        if ($at -ge 0) { $words[$at + 1] }
    }
}
function Get-Id([string]$Name) { @($WingetApps | Where-Object { $_.Name -eq $Name } | ForEach-Object { $_.Id }) }
$userIds = @($WingetApps | Where-Object { $_.Scope -eq 'user' } | ForEach-Object { $_.Id })
$machineIds = @($WingetApps | Where-Object { $_.Scope -eq 'machine' } | ForEach-Object { $_.Id })

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}

Test-Case 'table: Id, Name, Scope and one of Detect/Appx per entry; Zed and SSHFS-Win are the machine-scope ones' {
    Assert (@($WingetApps).Count -eq 9) "entries: $(@($WingetApps).Count)"
    foreach ($app in $WingetApps) {
        Assert ($app.Id -and $app.Name) "entry without Id/Name: $($app.Keys -join ',')"
        Assert ($app.Scope -in 'user', 'machine') "$($app.Name): Scope '$($app.Scope)'"
        Assert ($app.ContainsKey('Detect') -xor $app.ContainsKey('Appx')) "$($app.Name): needs exactly one of Detect/Appx"
    }
    $machine = @($WingetApps | Where-Object { $_.Scope -eq 'machine' } | ForEach-Object { $_.Name }) -join ','
    Assert ($machine -ceq 'Zed,SSHFS-Win') "machine scope: $machine"
}

Test-Case 'present apps (this host''s DisplayNames, "DevToys Preview" included) are not installed' {
    $ids = @(Invoke-Apps -Arp $hostArp -Appx $hostAppx -Skip $false)
    Assert ($ids.Count -eq 0) "winget ran for: $($ids -join ', ')"
    Assert (@($script:log | Where-Object { $_ -like 'ok: * present' }).Count -eq 9) "log: $($script:log -join ' | ')"
}

Test-Case 'missing user-scope apps are installed with --scope user, silently, agreements accepted' {
    $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $true)
    Assert (($ids -join ',') -ceq ($userIds -join ',')) "installed: $($ids -join ', ')"
    foreach ($c in $script:calls) {
        Assert ($c -like 'install --id * --exact --scope user *') "call: $c"
        foreach ($flag in '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements') {
            Assert (($c -split ' ') -contains $flag) "no $flag in: $c"
        }
    }
}

Test-Case 'Windows Terminal is an Appx check: no Appx package -> installed, an Appx package -> not' {
    $ids = @(Invoke-Apps -Arp $hostArp -Appx @() -Skip $false)
    Assert (($ids -join ',') -ceq ((Get-Id 'Windows Terminal') -join ',')) "installed: $($ids -join ', ')"
    $ids = @(Invoke-Apps -Arp @() -Appx $hostAppx -Skip $true)
    Assert ((Get-Id 'Windows Terminal')[0] -notin $ids) "installed: $($ids -join ', ')"
}

Test-Case '-SkipElevated: Zed and SSHFS-Win are skipped, not checked or installed' {
    $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $true)
    foreach ($id in $machineIds) { Assert ($id -notin $ids) "installed $id" }
    Assert (@($script:calls | Where-Object { $_ -like '*--scope machine*' }).Count -eq 0) "machine-scope call: $($script:calls -join ' | ')"
    foreach ($n in 'Zed', 'SSHFS-Win') {
        Assert (@($script:log | Where-Object { $_ -eq "log: $n skipped (-SkipElevated)" }).Count -eq 1) "no skip line for ${n}: $($script:log -join ' | ')"
    }
}

Test-Case 'without -SkipElevated, missing machine-scope apps install with --scope machine' {
    $arp = @($hostArp | Where-Object { $_ -notlike 'Zed*' -and $_ -notlike 'SSHFS-Win*' })
    $ids = @(Invoke-Apps -Arp $arp -Appx $hostAppx -Skip $false)
    Assert (($ids -join ',') -ceq ($machineIds -join ',')) "installed: $($ids -join ', ')"
    foreach ($c in $script:calls) { Assert ($c -like 'install --id * --exact --scope machine *') "call: $c" }
}

Test-Case 'Zed: "Zed Preview" / "Zed Nightly" do not count as Zed' {
    $arp = @($hostArp | Where-Object { $_ -ne 'Zed' }) + @('Zed Preview', 'Zed Nightly')
    $ids = @(Invoke-Apps -Arp $arp -Appx $hostAppx -Skip $false)
    Assert (($ids -join ',') -ceq ((Get-Id 'Zed') -join ',')) "installed: $($ids -join ', ')"
}

Test-Case 'a failed winget install warns with the manual command, and the rest still run' {
    $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $true -ExitCode 1)
    Assert ($ids.Count -eq $userIds.Count) "attempted: $($ids -join ', ')"
    foreach ($id in $userIds) {
        Assert (@($script:log | Where-Object { $_ -like "warn: *winget install --id $id" }).Count -eq 1) "no manual hint for ${id}: $($script:log -join ' | ')"
    }
    Assert (@($script:log | Where-Object { $_ -like 'ok: * installed' }).Count -eq 0) "reported success: $($script:log -join ' | ')"
}

if ($failures.Count -gt 0) { throw "winget apps: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "winget app checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
