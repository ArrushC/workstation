# Tests bootstrap.ps1's SSH host launchers (Get-SshLauncherHosts, the Windows
# Terminal fragment and the Warp Tab Configs) without running the bootstrap:
# the functions are extracted from the script's AST, as scripts/test-curl.ps1
# does. USERPROFILE/LOCALAPPDATA/APPDATA point at a temp dir for the run.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Get-SshLauncherHosts', 'New-Uuid5', 'Invoke-WindowsTerminalFragments', 'Invoke-WarpTabConfigs'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$script:warnings = New-Object System.Collections.Generic.List[string]
function Write-Ok { param($m) }
function Write-Warn { param($m) $script:warnings.Add([string]$m) }
# Stand-ins for "Windows Terminal / Warp are installed".
function Get-AppxPackage { [CmdletBinding()] param([string]$Name) [pscustomobject]@{ Name = $Name } }
function Test-InstallerPresent { param($DisplayName) $DisplayName -ceq 'Warp*' }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

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
# A fresh fake profile per case; $Hosts (if given) becomes ~\.ssh\config.local.
function New-Profile([string]$Name, [string]$Hosts) {
    $root = Join-Path $tmp $Name
    foreach ($d in 'home\.ssh', 'local', 'roaming') { New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null }
    $env:USERPROFILE = Join-Path $root 'home'
    $env:LOCALAPPDATA = Join-Path $root 'local'
    $env:APPDATA = Join-Path $root 'roaming'
    if ($null -ne $Hosts) { [System.IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.ssh\config.local'), $Hosts) }
}
function Get-Fragment { Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\workstation\hosts.json' }
function Get-WarpDir { Join-Path $env:APPDATA 'warp\Warp\data\tab_configs' }

$saved = @{ USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA; APPDATA = $env:APPDATA }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("sshlaunch-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Test-Case 'concrete Host aliases only, in order, de-duplicated' {
        New-Profile 'parse' (@(
            '# Host commented-out',
            'Host alpha beta',
            'Host *',
            'Host !gamma delta',
            '  Host=eq-host',
            'host lower.case',
            'HostName not-a-host',
            'Host c*',
            'Host alpha',
            'Host bad;rm',
            'Host inline # trailing comment',
            'Match host foo',
            ''
        ) -join "`r`n")
        $script:warnings.Clear()
        $got = @(Get-SshLauncherHosts) -join ','
        Assert ($got -ceq 'alpha,beta,delta,eq-host,lower.case,inline') "got: $got"
        Assert (($script:warnings -join ' ') -like '*bad;rm*') "no warning for the unsafe alias: $($script:warnings -join ' | ')"
    }

    Test-Case 'no config.local -> no hosts' {
        New-Profile 'missing' $null
        Assert (@(Get-SshLauncherHosts).Count -eq 0) 'expected no hosts'
    }

    Test-Case 'Windows Terminal: one host is still a profiles array' {
        New-Profile 'wt-one' "Host alpha`n"
        Invoke-WindowsTerminalFragments
        $bytes = [System.IO.File]::ReadAllBytes((Get-Fragment))
        Assert (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'fragment written with a BOM'
        $text = [System.IO.File]::ReadAllText((Get-Fragment))
        Assert (-not $text.Contains("`r")) 'fragment has CR line endings'
        $p = @((ConvertFrom-Json $text).profiles)
        Assert ($p.Count -eq 1) "profiles: $($p.Count)"
        Assert ($p[0].name -ceq 'SSH: alpha') "name: $($p[0].name)"
        Assert ($p[0].commandline -ceq 'ssh -t alpha zellij attach --create main') "commandline: $($p[0].commandline)"
        Assert ($p[0].guid -match '^\{[0-9a-f-]{36}\}$') "guid: $($p[0].guid)"
    }

    Test-Case 'Windows Terminal: GUIDs are stable and distinct' {
        New-Profile 'wt-two' "Host alpha beta`n"
        Invoke-WindowsTerminalFragments
        $first = @((ConvertFrom-Json ([System.IO.File]::ReadAllText((Get-Fragment)))).profiles)
        Invoke-WindowsTerminalFragments
        $again = @((ConvertFrom-Json ([System.IO.File]::ReadAllText((Get-Fragment)))).profiles)
        Assert ($first.Count -eq 2) "profiles: $($first.Count)"
        Assert ($first[0].guid -ne $first[1].guid) 'two hosts share a GUID'
        Assert (($first[0].guid -eq $again[0].guid) -and ($first[1].guid -eq $again[1].guid)) 'GUIDs changed between runs'
    }

    Test-Case 'Windows Terminal: no hosts removes our fragment, keeps other apps fragments' {
        New-Profile 'wt-none' $null
        $ours = Get-Fragment
        $other = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\other\x.json'
        foreach ($f in $ours, $other) {
            New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
            [System.IO.File]::WriteAllText($f, '{}')
        }
        Invoke-WindowsTerminalFragments
        Assert (-not (Test-Path $ours)) 'stale workstation fragment left behind'
        Assert (Test-Path $other) "another app's fragment was removed"
    }

    Test-Case 'Warp: one entry per host; stale ones go, user configs stay' {
        New-Profile 'warp' "Host alpha Alpha`n"
        $dir = Get-WarpDir
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'mine.toml'), 'name = "mine"')
        [System.IO.File]::WriteAllText((Join-Path $dir 'workstation-ssh-old.toml'), 'name = "old"')
        Invoke-WarpTabConfigs
        $names = @(Get-ChildItem -Path $dir -File | ForEach-Object { $_.Name } | Sort-Object)
        Assert ('mine.toml' -in $names) 'user config removed'
        Assert ('workstation-ssh-old.toml' -notin $names) 'stale host entry left behind'
        Assert (('workstation-ssh-alpha.toml' -in $names) -and ('workstation-ssh-alpha-.toml' -in $names)) "case-colliding aliases: $($names -join ', ')"
        $body = [System.IO.File]::ReadAllText((Join-Path $dir 'workstation-ssh-alpha.toml'))
        Assert ($body.Contains("commands = ['ssh -t alpha zellij attach --create main']")) "body: $body"
        Assert (@($names | Where-Object { $_ -like 'workstation-*' }).Count -eq 5) "expected 3 local + 2 host entries: $($names -join ', ')"
    }
} finally {
    foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
    Remove-Item -Recurse -Force $tmp
}
if ($failures.Count -gt 0) { throw "SSH host launchers: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "SSH host launcher checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
