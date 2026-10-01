# Tests bootstrap.ps1's GUI-app step ($WingetApps + Install-WingetApps +
# Test-WindowsTerminalPresent) without running the bootstrap: the table and
# the functions are extracted from the script's AST, as
# scripts/test-ssh-launchers.ps1 does.
#
# Nothing is installed:
#  - `winget` is a function stub that records its arguments (functions win
#    over winget.exe on PATH), and the script stops unless it resolves to it
#  - Get-AppxPackage and the Uninstall registry (Get-ItemProperty) are
#    stubbed to a fake inventory; the real Test-InstallerPresent matches it
#  - PATH points at a temp dir that has an empty wt.exe or nothing
#
# -HostCheck first runs the REAL presence checks (read-only) for every table
# entry on this machine, prints the table and fails when an app is not
# detected. Use it on a provisioned host, not in CI.
[CmdletBinding()]
param([switch]$HostCheck)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Test-InstallerPresent', 'Test-WindowsTerminalPresent', 'Install-WingetApps'
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
$wtId = 'Microsoft.WindowsTerminal'

if ($HostCheck) {
    # Read-only: what the real registry, Appx store and PATH say on this machine.
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
        if ($app.Id -eq $wtId) {
            $present = Test-WindowsTerminalPresent
            $pkg = @(Get-AppxPackage -Name $wtId -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageFullName })
            $wt = @(Get-Command wt.exe -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
            $seen = "Appx -> $($pkg -join ', '); wt.exe -> $($wt -join ', ')"
        } else {
            $present = Test-InstallerPresent $app.Detect
            $seen = "'$($app.Detect)' -> $(@(Get-HostDisplayName $app.Detect) -join ', ')"
        }
        if (-not $present) { $missing.Add($app.Name) }
        $state = if ($present) { 'present' } else { 'MISSING' }
        $kind = if ($app.ContainsKey('Uac')) { "$($app.Scope)+uac" } else { $app.Scope }
        Write-Host ('  {0,-8} {1,-17} {2,-12} {3}' -f $state, $app.Name, $kind, $seen)
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
$script:wingetThrows = $false
function winget {
    $script:calls.Add($args -join ' ')
    if ($script:wingetThrows) { throw [System.Management.Automation.ApplicationFailedException]::new('The file cannot be accessed by the system.') }
    $global:LASTEXITCODE = $script:wingetExit
}
if ((Get-Command winget).CommandType -ne 'Function') { throw 'refusing to run: winget does not resolve to the test stub' }
$script:log = New-Object System.Collections.Generic.List[string]
function Write-Log { param($m) $script:log.Add("log: $m") }
function Write-Ok { param($m) $script:log.Add("ok: $m") }
function Write-Warn { param($m) $script:log.Add("warn: $m") }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

# PATH for the cases: a temp dir with an empty wt.exe, or one without it.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wingetapps-" + [guid]::NewGuid())
$wtBin = Join-Path $tmp 'wt'
$noWt = Join-Path $tmp 'none'
foreach ($d in $wtBin, $noWt) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
[System.IO.File]::WriteAllBytes((Join-Path $wtBin 'wt.exe'), [byte[]]@())
$savedPath = $env:PATH

# One Install-WingetApps run against an inventory; returns the ids winget was called for.
function Invoke-Apps([string[]]$Arp, [string[]]$Appx, [bool]$Skip, [int]$ExitCode = 0, [switch]$WtOnPath, [switch]$Throws) {
    $script:arp = @($Arp)
    $script:appx = @($Appx)
    $script:SkipElevated = $Skip
    $script:wingetExit = $ExitCode
    $script:wingetThrows = [bool]$Throws
    $env:PATH = if ($WtOnPath) { $wtBin } else { $noWt }
    $script:calls.Clear()
    $script:log.Clear()
    Install-WingetApps
    foreach ($c in $script:calls) {
        $words = $c -split ' '
        $at = [array]::IndexOf($words, '--id')
        if ($at -ge 0) { $words[$at + 1] }
    }
}
# These write to the pipeline (one match comes back as a scalar): wrap calls in @().
function Get-Id([string]$Name) { $WingetApps | Where-Object { $_.Name -eq $Name } | ForEach-Object { $_.Id } }
function Get-Call([string]$Id) { $script:calls | Where-Object { ($_ -split ' ') -contains $Id } }
function Get-Log([string]$Like) { $script:log | Where-Object { $_ -like $Like } }
function Get-Code([string]$Hex) { [Convert]::ToInt32($Hex, 16) }
$allIds = @($WingetApps | ForEach-Object { $_.Id })
$userIds = @($WingetApps | Where-Object { $_.Scope -eq 'user' } | ForEach-Object { $_.Id })
$uacIds = @($WingetApps | Where-Object { $_.ContainsKey('Uac') -and $_.Uac } | ForEach-Object { $_.Id })
$noUacIds = @($allIds | Where-Object { $_ -notin $uacIds })

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}

try {
    Test-Case 'table: Id, Name, Scope; a Detect for all but Windows Terminal; Zed + SSHFS-Win machine scope; only SSHFS-Win is Uac' {
        Assert (@($WingetApps).Count -eq 9) "entries: $(@($WingetApps).Count)"
        foreach ($app in $WingetApps) {
            Assert ($app.Id -and $app.Name) "entry without Id/Name: $($app.Keys -join ',')"
            Assert ($app.Scope -in 'user', 'machine') "$($app.Name): Scope '$($app.Scope)'"
            Assert ($app.ContainsKey('Detect') -xor ($app.Id -eq $wtId)) "$($app.Name): Detect is for every app but Windows Terminal"
        }
        $machine = @($WingetApps | Where-Object { $_.Scope -eq 'machine' } | ForEach-Object { $_.Name }) -join ','
        Assert ($machine -ceq 'Zed,SSHFS-Win') "machine scope: $machine"
        Assert (($uacIds -join ',') -ceq 'SSHFS-Win.SSHFS-Win') "Uac: $($uacIds -join ',')"
        Assert ($allIds[-1] -ceq 'SSHFS-Win.SSHFS-Win') 'the UAC entry is not last'
    }

    Test-Case 'present apps (this host''s DisplayNames, "DevToys Preview" included) are not installed' {
        $ids = @(Invoke-Apps -Arp $hostArp -Appx $hostAppx -Skip $false)
        Assert ($ids.Count -eq 0) "winget ran for: $($ids -join ', ')"
        Assert (@(Get-Log 'ok: * present').Count -eq 9) "log: $($script:log -join ' | ')"
    }

    Test-Case 'missing user-scope apps install with --scope user, --silent, agreements accepted' {
        $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $false)
        Assert (($ids -join ',') -ceq ($allIds -join ',')) "installed: $($ids -join ', ')"
        foreach ($id in $userIds) {
            $c = @(Get-Call $id)
            Assert ($c.Count -eq 1) "calls for ${id}: $($c.Count)"
            Assert ($c[0] -like "install --id $id --exact --scope user *") "call: $($c[0])"
            foreach ($flag in '--silent', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements') {
                Assert (($c[0] -split ' ') -contains $flag) "no $flag in: $($c[0])"
            }
        }
    }

    Test-Case 'Windows Terminal: an Appx package or wt.exe on PATH counts; neither -> installed' {
        $ids = @(Invoke-Apps -Arp $hostArp -Appx @() -Skip $false)
        Assert (($ids -join ',') -ceq $wtId) "neither: installed $($ids -join ', ')"
        $ids = @(Invoke-Apps -Arp $hostArp -Appx @() -Skip $false -WtOnPath)
        Assert ($ids.Count -eq 0) "wt.exe on PATH: installed $($ids -join ', ')"
        $ids = @(Invoke-Apps -Arp $hostArp -Appx $hostAppx -Skip $false)
        Assert ($ids.Count -eq 0) "Appx package: installed $($ids -join ', ')"
    }

    Test-Case '-SkipElevated skips only SSHFS-Win; Zed still installs with --scope machine, silently' {
        $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $true)
        Assert (($ids -join ',') -ceq ($noUacIds -join ',')) "installed: $($ids -join ', ')"
        $zed = @(Get-Call 'ZedIndustries.Zed')
        Assert ($zed.Count -eq 1 -and $zed[0] -like 'install --id ZedIndustries.Zed --exact --scope machine *') "Zed call: $($zed -join ' | ')"
        Assert (($zed[0] -split ' ') -contains '--silent') "Zed call without --silent: $($zed[0])"
        $skips = @(Get-Log 'log: * skipped (-SkipElevated)')
        Assert (($skips -join '|') -ceq 'log: SSHFS-Win skipped (-SkipElevated)') "skip lines: $($skips -join ' | ')"
        Assert (@(Get-Log '*UAC*').Count -eq 0) "UAC warning without a UAC install: $($script:log -join ' | ')"
    }

    Test-Case 'SSHFS-Win (Uac): --scope machine, no --silent, a UAC warning first; every other call keeps --silent' {
        $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $false)
        Assert ($ids[-1] -ceq 'SSHFS-Win.SSHFS-Win') "order: $($ids -join ', ')"
        $c = @(Get-Call 'SSHFS-Win.SSHFS-Win')
        Assert ($c.Count -eq 1 -and $c[0] -like 'install --id SSHFS-Win.SSHFS-Win --exact --scope machine *') "call: $($c -join ' | ')"
        $words = $c[0] -split ' '
        Assert ($words -notcontains '--silent') "--silent in: $($c[0])"
        foreach ($flag in '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements') {
            Assert ($words -contains $flag) "no $flag in: $($c[0])"
        }
        foreach ($id in $noUacIds) { Assert ((@(Get-Call $id)[0] -split ' ') -contains '--silent') "no --silent for $id" }
        $warn = @(Get-Log 'warn: *expect a UAC prompt*')
        Assert ($warn.Count -eq 1 -and $warn[0] -like 'warn: SSHFS-Win *') "UAC warnings: $($warn -join ' | ')"
    }

    Test-Case 'Zed: "Zed Preview" / "Zed Nightly" do not count as Zed' {
        $arp = @($hostArp | Where-Object { $_ -ne 'Zed' }) + @('Zed Preview', 'Zed Nightly')
        $ids = @(Invoke-Apps -Arp $arp -Appx $hostAppx -Skip $false)
        Assert (($ids -join ',') -ceq (@(Get-Id 'Zed') -join ',')) "installed: $($ids -join ', ')"
    }

    Test-Case 'a failed winget install warns with the hex exit code and the manual command; the rest still run' {
        $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $true -ExitCode (Get-Code '8A150014'))
        Assert ($ids.Count -eq $noUacIds.Count) "attempted: $($ids -join ', ')"
        foreach ($app in @($WingetApps | Where-Object { $_.Id -in $noUacIds })) {
            $hit = @(Get-Log "warn: $($app.Name): winget exited 0x8A150014 * winget install --id $($app.Id)")
            Assert ($hit.Count -eq 1) "no hex/manual hint for $($app.Name): $($script:log -join ' | ')"
        }
        Assert (@(Get-Log 'ok: * installed').Count -eq 0) "reported success: $($script:log -join ' | ')"
    }

    Test-Case 'winget "already installed" codes (0x8A15002B, 0x8A150061, 0x8A15010D) count as present' {
        foreach ($hex in '8A15002B', '8A150061', '8A15010D') {
            $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $true -ExitCode (Get-Code $hex))
            Assert ($ids.Count -eq $noUacIds.Count) "0x${hex}: attempted $($ids -join ', ')"
            Assert (@(Get-Log 'ok: * present (winget)').Count -eq $ids.Count) "0x${hex}: $($script:log -join ' | ')"
            Assert (@(Get-Log 'warn: *').Count -eq 0) "0x${hex} warned: $($script:log -join ' | ')"
        }
    }

    Test-Case 'a winget that cannot start warns for each app, and the run goes on' {
        $ids = @(Invoke-Apps -Arp @() -Appx @() -Skip $true -Throws)
        Assert ($ids.Count -eq $noUacIds.Count) "attempted: $($ids -join ', ')"
        Assert (@(Get-Log 'warn: *: winget could not start (The file cannot be accessed by the system.) * winget install --id *').Count -eq $ids.Count) "log: $($script:log -join ' | ')"
        Assert ($ErrorActionPreference -eq 'Stop') "ErrorActionPreference left at $ErrorActionPreference"
    }
} finally {
    $env:PATH = $savedPath
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) { throw "winget apps: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "winget app checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
