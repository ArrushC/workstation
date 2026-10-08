# Tests bootstrap.ps1's mise plumbing without running the bootstrap: the
# miserc.toml writer (Initialize-MiseEnv), the mise install / update
# (Install-Mise), the mise bootstrap step's guard, ordering and
# -C pinning (Invoke-MiseBootstrap), its free-space check
# (Assert-ToolsDiskSpace), the Claude Code step's PATH entry
# (Invoke-InstallClaudeCode), and the run sequence's hand-over to the pulled
# bootstrap.ps1. The functions are extracted from the script's AST
# (scripts/lib/test-helpers.ps1, which also has the mise stub).
#
# Nothing real is touched:
#  - the User environment is never written: a function that calls
#    [Environment]::SetEnvironmentVariable itself is refused, not loaded
#    (PowerShell can't stub a static .NET method)
#  - `mise` is the helper's function stub (functions win over mise.exe on
#    PATH), and the script stops unless it resolves to that stub
#  - Invoke-CurlRequest, Add-ToUserPath and Update-SessionPath are stubbed, and so
#    are Get-FreeSpaceMB and Get-DirSizeMB (the disk is whatever a case says)
#  - every path points at a temp dir
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = Read-ScriptAst (Join-Path $repoRoot 'bootstrap.ps1')
$refused = New-Object System.Collections.Generic.List[string]
foreach ($f in (Get-AstFunction $ast 'Initialize-MiseEnv', 'Install-Mise', 'Invoke-MiseBootstrap', 'Assert-ToolsDiskSpace', 'Invoke-InstallClaudeCode')) {
    if ($f.Extent.Text -match 'Environment\]::SetEnvironmentVariable') { $refused.Add($f.Name); continue }
    . ([scriptblock]::Create($f.Extent.Text))
}
$script:addedPaths = New-Object System.Collections.Generic.List[string]
function Add-ToUserPath { param([string]$Dir) $script:addedPaths.Add($Dir) }
function Update-SessionPath { }
# The disk: 100 GB free and nothing installed unless a case says otherwise.
$script:freeMB = 102400
$script:usedMB = 0
function Get-FreeSpaceMB { param([string]$Path) $script:freeMB }
function Get-DirSizeMB { param([string]$Path) $script:usedMB }
function Invoke-EnsureConfigLocal { }
function Invoke-WslConfigReminder { }
# The download: a copy of $script:curlZip, or a failure when it's $null.
$script:curlZip = $null
function Invoke-CurlRequest {
    param([string]$Uri, [hashtable]$Headers, [string]$OutFile)
    if (-not $script:curlZip) { throw 'curl.exe request failed (exit 6)' }
    Copy-Item -LiteralPath $script:curlZip -Destination $OutFile -Force
}
Assert-Stub 'mise'
foreach ($name in $refused) { $failures.Add("$name writes the User environment directly (the tests would touch the real one)") }

# A zip laid out like mise's release: mise\bin\{mise,mise-shim}.exe + mise\extra.txt,
# plus mise\<$Extra> when given.
function New-MiseZip([string]$Name, [string]$Extra) {
    $src = Join-Path $tmp "zipsrc-$Name\mise"
    New-TestFile (Join-Path $src 'bin\mise.exe') "mise-$Name"
    New-TestFile (Join-Path $src 'bin\mise-shim.exe') "shim-$Name"
    New-TestFile (Join-Path $src 'extra.txt') "extra-$Name"
    if ($Extra) { New-TestFile (Join-Path $src $Extra) "extra-$Name" }
    $zip = Join-Path $tmp "$Name.zip"
    Compress-Archive -Path $src -DestinationPath $zip
    return $zip
}
function Use-MiseZip([string]$Version, [string]$Zip) {
    $script:MiseVersion = $Version
    $script:MiseUrl = "https://example.invalid/mise-$Version.zip"
    $script:curlZip = $Zip
    $script:MiseSha256 = if ($Zip) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip).Hash.ToLower() } else { 'none' }
}

$savedMiseEnv = $env:MISE_ENV
$tmp = New-TestTempDir 'miseenv-'
try {
    Test-Case 'miserc.toml: windows, no BOM, LF; the session MISE_ENV goes' {
        $script:RepoPath = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
        $env:MISE_ENV = 'windows'
        Initialize-MiseEnv
        $rc = Join-Path $script:RepoPath 'miserc.toml'
        $bytes = [System.IO.File]::ReadAllBytes($rc)
        Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'written with a BOM'
        $text = Read-Text $rc
        Assert (-not $text.Contains("`r")) 'CR line endings'
        $lines = @($text -split "`n")
        Assert ($lines -ccontains 'env = ["windows"]') "no env line: $text"
        Assert ($lines -ccontains 'auto_env = false') "no auto_env line: $text"
        Assert (@($lines | Where-Object { $_ -and $_ -notmatch '^#' }).Count -eq 2) "unexpected lines: $text"
        Assert (-not (Test-Path Env:MISE_ENV)) "session MISE_ENV still set: $env:MISE_ENV"
    }

    Test-Case 'miserc.toml: an existing file is rewritten' {
        $script:RepoPath = Join-Path $tmp 'repo2'
        New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:RepoPath 'miserc.toml'), "env = [`"linux`"]`n")
        Initialize-MiseEnv
        Assert ((Read-Text (Join-Path $script:RepoPath 'miserc.toml')).Contains('env = ["windows"]')) 'old miserc.toml kept'
    }

    $script:WsRoot = Join-Path $tmp 'ws'
    $script:WsStamps = Join-Path $script:WsRoot 'stamps'
    $script:WsMise = Join-Path $tmp 'ws\mise'
    $miseExe = Join-Path $script:WsMise 'bin\mise.exe'
    Test-Case 'Install-Mise: fresh install from the verified zip' {
        Use-MiseZip 't1' (New-MiseZip 't1')
        Install-Mise
        Assert ((Read-Text $miseExe) -ceq 'mise-t1') "mise.exe: $(Read-Text $miseExe)"
        Assert (Test-Path (Join-Path $script:WsStamps 'mise.t1.stamp')) 'no stamp'
    }

    Test-Case 'Install-Mise: a running mise.exe is renamed to *.old, not deleted' {
        Use-MiseZip 't2' (New-MiseZip 't2')
        # Read+Delete share: rename allowed, overwrite refused -- like a running image.
        $h = [System.IO.File]::Open($miseExe, 'Open', 'Read', 'Read, Delete')
        try { Install-Mise } finally { $h.Dispose() }
        Assert ((Read-Text $miseExe) -ceq 'mise-t2') "mise.exe: $(Read-Text $miseExe)"
        Assert ((Read-Text (Join-Path $script:WsMise 'bin\mise-shim.exe')) -ceq 'shim-t2') 'mise-shim.exe not updated'
        Assert (@(Get-ChildItem (Join-Path $script:WsMise 'bin') -Filter '*.old').Count -eq 2) 'old exes not kept as *.old'
        Assert (Test-Path (Join-Path $script:WsStamps 'mise.t2.stamp')) 'no stamp'
    }

    Test-Case 'Install-Mise: a later run removes the *.old leftovers' {
        Install-Mise
        Assert (@(Get-ChildItem (Join-Path $script:WsMise 'bin') -Filter '*.old').Count -eq 0) '*.old left behind'
        Assert ((Read-Text $miseExe) -ceq 'mise-t2') 'mise.exe changed'
    }

    Test-Case 'Install-Mise: download fails with a mise installed -> warn, keep it' {
        Use-MiseZip 't3' $null
        Install-Mise
        Assert (($script:warnings -join ' ') -like '*continuing on the installed mise*min_version*refuse until a re-run*') "warnings: $($script:warnings -join ' | ')"
        Assert ((Read-Text $miseExe) -ceq 'mise-t2') 'mise.exe changed'
        Assert (-not (Test-Path (Join-Path $script:WsStamps 'mise.t3.stamp'))) 'stamp written without an install'
    }

    Test-Case 'Install-Mise: sha256 mismatch with a mise installed -> warn, keep it' {
        Use-MiseZip 't4' (New-MiseZip 't4')
        $script:MiseSha256 = '0' * 64
        Install-Mise
        Assert (($script:warnings -join ' ') -like '*sha256 mismatch*min_version*') "warnings: $($script:warnings -join ' | ')"
        Assert ((Read-Text $miseExe) -ceq 'mise-t2') 'unverified mise installed'
    }

    Test-Case 'Install-Mise: download fails with no mise -> Write-Fail' {
        $saved = $script:WsMise
        $script:WsMise = Join-Path $tmp 'ws-empty\mise'
        Use-MiseZip 't5' $null
        $msg = ''
        try { Install-Mise } catch { $msg = $_.Exception.Message } finally { $script:WsMise = $saved }
        Assert ($msg -like 'WRITE-FAIL:*no mise is installed*network*') "got: $msg"
    }

    Test-Case 'Install-Mise: sha256 mismatch with no mise -> Write-Fail names the pinned checksum, not the network' {
        $saved = $script:WsMise
        $script:WsMise = Join-Path $tmp 'ws-empty-sha\mise'
        Use-MiseZip 't5s' (New-MiseZip 't5s')
        $script:MiseSha256 = '0' * 64
        $msg = ''
        try { Install-Mise } catch { $msg = $_.Exception.Message } finally { $script:WsMise = $saved }
        Assert ($msg -like 'WRITE-FAIL:*did not match the pinned checksum*re-run*$MiseSha256 in bootstrap.ps1 is wrong for $MiseVersion*') "got: $msg"
        Assert ($msg -notlike '*network*') "network advice for a checksum mismatch: $msg"
        Assert (-not (Test-Path (Join-Path $tmp 'ws-empty-sha\mise\bin\mise.exe'))) 'unverified mise installed'
    }

    Test-Case 'Install-Mise: copy fails -> Write-Fail names the fix; a mise.exe stays' {
        Use-MiseZip 't6' (New-MiseZip 't6')
        $extra = Join-Path $script:WsMise 'extra.txt'
        $h = [System.IO.File]::Open($extra, 'Open', 'Read', 'Read')   # blocks the overwrite
        $msg = ''
        try { Install-Mise } catch { $msg = $_.Exception.Message } finally { $h.Dispose() }
        Assert ($msg -like 'WRITE-FAIL:*close Nushell tabs and editors started through mise shims*Windows PowerShell window*') "got: $msg"
        Assert (Test-Path $miseExe) 'no mise.exe left'
        Assert (-not (Test-Path (Join-Path $script:WsStamps 'mise.t6.stamp'))) 'stamp written for a failed update'
    }

    Test-Case 'Install-Mise: a copy that fails before bin\ puts the renamed mise.exe and mise-shim.exe back' {
        $saved = $script:WsMise
        $script:WsMise = Join-Path $tmp 'ws-restore\mise'
        $bin = Join-Path $script:WsMise 'bin'
        New-TestFile (Join-Path $bin 'mise.exe') 'mise-orig'
        New-TestFile (Join-Path $bin 'mise-shim.exe') 'shim-orig'
        # A held file under a directory that sorts before bin\: the copy fails after the renames.
        $heldPath = Join-Path $script:WsMise 'aa-held\held.txt'
        New-TestFile $heldPath 'held'
        Use-MiseZip 't7' (New-MiseZip 't7' 'aa-held\held.txt')
        $h = [System.IO.File]::Open($heldPath, 'Open', 'Read', 'Read')   # blocks the overwrite
        $msg = ''
        try { Install-Mise } catch { $msg = $_.Exception.Message } finally { $h.Dispose(); $script:WsMise = $saved }
        Assert ($msg -like 'WRITE-FAIL:*Could not update mise*') "got: $msg"
        $names = @(Get-ChildItem -LiteralPath $bin | ForEach-Object { $_.Name })
        Assert (($names.Count -eq 2) -and ($names -contains 'mise.exe') -and ($names -contains 'mise-shim.exe')) "bin holds: $($names -join ', ')"
        Assert ((Read-Text (Join-Path $bin 'mise.exe')) -ceq 'mise-orig') "mise.exe: $(Read-Text (Join-Path $bin 'mise.exe'))"
        Assert ((Read-Text (Join-Path $bin 'mise-shim.exe')) -ceq 'shim-orig') "mise-shim.exe: $(Read-Text (Join-Path $bin 'mise-shim.exe'))"
        Assert (-not (Test-Path (Join-Path $script:WsStamps 'mise.t7.stamp'))) 'stamp written for a failed update'
    }

    # Invoke-MiseBootstrap with the stubbed mise.
    $script:RepoPath = Join-Path $tmp 'mb-repo'
    New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
    # A fixed budget (the real disk-budget.toml changes weekly).
    $budgetFile = Join-Path $script:RepoPath 'disk-budget.toml'
    Set-Content -LiteralPath $budgetFile -Value 'windows = 3000'
    $script:SkipDotfiles = $false
    $script:SkipToolInstall = $false
    $script:FirstApplyMarker = Join-Path $tmp 'ws\dotfiles-first-apply-done'
    $script:MiseShims = Join-Path $tmp 'mise\shims'
    $winLs = '[{"path": "C:\\Users\\u\\.config\\mise\\config.toml"}, {"path": "C:\\Users\\u\\.config\\mise\\config.windows.toml"}]'
    function Invoke-Bootstrap {
        $script:miseCalls.Clear()
        $msg = ''
        try { Invoke-MiseBootstrap } catch { $msg = $_.Exception.Message }
        return $msg
    }
    function Get-MiseCall([string]$Part) { @($script:miseCalls | Where-Object { $_ -like "mise *$Part*" }) }

    Test-Case 'mise bootstrap: stops before bootstrap/prune when config.windows.toml is not loaded' {
        $script:miseReply = @{ 'config ls' = @{ Out = '[{"path": "C:\\Users\\u\\.config\\mise\\config.toml"}]'; Exit = 0 } }
        $msg = Invoke-Bootstrap
        Assert ($msg -like 'WRITE-FAIL:*config.windows.toml*miserc.toml*') "got: $msg"
        Assert ($msg -notlike '*min_version*') "min_version hint for an exit-0 config ls: $msg"
        Assert (@(Get-MiseCall 'bootstrap').Count -eq 0) 'mise bootstrap ran'
        Assert (@(Get-MiseCall 'prune').Count -eq 0) 'mise prune ran'
    }

    Test-Case 'mise bootstrap: a failing `mise config ls` stops with its first lines and the min_version hint, not the miserc message' {
        $lsErr = @('mise ERROR mise version 2026.9.1 is below min_version 2026.9.9 in C:\Users\u\.config\mise\config.toml') +
            @(2..8 | ForEach-Object { "mise ERROR detail line $_" })
        $script:miseReply = @{ 'config ls' = @{ Out = $lsErr; Exit = 1 } }
        $msg = Invoke-Bootstrap
        Assert ($msg -like "WRITE-FAIL:*exit 1*$($lsErr[0])*") "got: $msg"
        Assert ($msg -like "*an older mise than config.toml's min_version? re-run .\bootstrap.ps1 after a download succeeds*") "no hint: $msg"
        Assert ($msg -notlike '*detail line 8*') "output not trimmed: $msg"
        Assert ($msg -notlike '*was not honoured*') "miserc message for a failing config ls: $msg"
        Assert (@(Get-MiseCall 'bootstrap').Count -eq 0) 'mise bootstrap ran'
        Assert (@(Get-MiseCall 'prune').Count -eq 0) 'mise prune ran'
    }

    Test-Case 'mise bootstrap: a failing `mise config ls` stops even when its error names config.windows.toml' {
        $script:miseReply = @{ 'config ls' = @{ Out = @('mise ERROR failed to parse C:\Users\u\.config\mise\config.windows.toml', 'TOML parse error at line 3, column 1'); Exit = 1 } }
        $msg = Invoke-Bootstrap
        Assert ($msg -like 'WRITE-FAIL:*min_version*failed to parse*config.windows.toml*TOML parse error*') "got: $msg"
        Assert (@(Get-MiseCall 'bootstrap').Count -eq 0) 'mise bootstrap ran'
    }

    Test-Case 'mise bootstrap: a failed bootstrap stops before the tool steps (no prune)' {
        $script:miseReply = @{ 'config ls' = @{ Out = $winLs; Exit = 0 }; ' bootstrap ' = @{ Exit = 1 } }
        $msg = Invoke-Bootstrap
        Assert ($msg -like 'WRITE-FAIL:*mise bootstrap*failed*') "got: $msg"
        Assert (@(Get-MiseCall 'prune').Count -eq 0) 'mise prune ran after a failed bootstrap'
        Assert (@(Get-MiseCall 'reshim').Count -eq 0) 'mise reshim ran after a failed bootstrap'
    }

    Test-Case 'mise bootstrap: tool steps after a good bootstrap; every call pinned with -C; node marker' {
        $script:miseReply = @{
            'config ls'  = @{ Out = $winLs; Exit = 0 }
            'where node' = @{ Out = 'C:\node'; Exit = 0 }
            'config get' = @{ Out = 'version = "26.10.0"'; Exit = 0 }
        }
        Get-ChildItem $script:WsStamps -Filter 'node-postinstall.*.stamp' | Remove-Item -Force
        $msg = Invoke-Bootstrap
        Assert ($msg -eq '') "failed: $msg"
        $calls = @($script:miseCalls | Where-Object { $_ -like 'mise *' })
        $pin = "mise -C $env:USERPROFILE "
        foreach ($c in $calls) { Assert ($c.StartsWith($pin)) "not pinned to %USERPROFILE%: $c" }
        $boot = $script:miseCalls.IndexOf(@(Get-MiseCall 'bootstrap --only dotfiles,tools --yes')[0])
        $prune = $script:miseCalls.IndexOf(@(Get-MiseCall 'prune --yes')[0])
        Assert (($boot -ge 0) -and ($prune -gt $boot)) "order: $($script:miseCalls -join ' | ')"
        Assert (@(Get-MiseCall 'install --yes --force node').Count -eq 1) 'node not force-reinstalled'
        Assert (@(Get-ChildItem $script:WsStamps -Filter 'node-postinstall.*.stamp').Count -eq 1) 'no node marker'
        Assert (@(Get-MiseCall 'prune --yes').Count -eq 1 -and @(Get-MiseCall 'reshim').Count -eq 1) 'prune/reshim missing'
    }

    Test-Case 'mise bootstrap: unchanged node declaration -> no reinstall' {
        $msg = Invoke-Bootstrap
        Assert ($msg -eq '') "failed: $msg"
        Assert (@(Get-MiseCall 'install --yes --force node').Count -eq 0) 'node reinstalled again'
    }

    Test-Case 'mise bootstrap: node in use -> warning, no marker' {
        Get-ChildItem $script:WsStamps -Filter 'node-postinstall.*.stamp' | Remove-Item -Force
        $script:miseReply['install --yes --force node'] = @{ Out = 'Error: failed to remove node (os error 32)'; Exit = 1 }
        $msg = Invoke-Bootstrap
        Assert ($msg -eq '') "failed: $msg"
        Assert (($script:warnings -join ' ') -like '*close running node processes*') "warnings: $($script:warnings -join ' | ')"
        Assert (@(Get-ChildItem $script:WsStamps -Filter 'node-postinstall.*.stamp').Count -eq 0) 'marker written after a failed reinstall'
    }

    $script:miseReply = @{ 'config ls' = @{ Out = $winLs; Exit = 0 } }
    Test-Case 'disk: too little room stops before mise bootstrap installs anything' {
        $script:freeMB = 1024; $script:usedMB = 0
        $msg = Invoke-Bootstrap
        Assert ($msg -like 'WRITE-FAIL:*Not enough disk space*1.0 GB free*about 3.9 GB needed*Nothing was installed*WORKSTATION_SKIP_DISK_CHECK*') "got: $msg"
        Assert (@(Get-MiseCall 'bootstrap').Count -eq 0) 'mise bootstrap ran'
    }

    Test-Case 'disk: what is already installed lowers the need (2.8 GB installed, 2 GB free)' {
        $script:freeMB = 2048; $script:usedMB = 2800
        $msg = Invoke-Bootstrap
        Assert ($msg -eq '') "failed: $msg"
        Assert (@(Get-MiseCall 'bootstrap --only').Count -eq 1) 'mise bootstrap did not run'
    }

    Test-Case 'disk: WORKSTATION_SKIP_DISK_CHECK=1 goes ahead with a warning' {
        $script:freeMB = 1024; $script:usedMB = 0
        $env:WORKSTATION_SKIP_DISK_CHECK = '1'
        try { $msg = Invoke-Bootstrap } finally { Remove-Item Env:WORKSTATION_SKIP_DISK_CHECK }
        Assert ($msg -eq '') "failed: $msg"
        Assert (($script:warnings -join ' ') -like '*Low disk space*going ahead*') "warnings: $($script:warnings -join ' | ')"
        Assert (@(Get-MiseCall 'bootstrap --only').Count -eq 1) 'mise bootstrap did not run'
    }

    Test-Case 'disk: an unreadable drive skips the check; -SkipToolInstall never checks' {
        $script:freeMB = $null
        Assert ((Invoke-Bootstrap) -eq '') 'an unreadable drive stopped the bootstrap'
        $script:freeMB = 1024; $script:SkipToolInstall = $true
        try { $msg = Invoke-Bootstrap } finally { $script:SkipToolInstall = $false; $script:freeMB = 102400 }
        Assert ($msg -eq '') "-SkipToolInstall ran the check: $msg"
    }

    Test-Case 'disk: no windows figure in disk-budget.toml skips the check, with a warning' {
        Set-Content -LiteralPath $budgetFile -Value 'linux = 5000'
        $script:freeMB = 1024
        try { $msg = Invoke-Bootstrap } finally { Set-Content -LiteralPath $budgetFile -Value 'windows = 3000'; $script:freeMB = 102400 }
        Assert ($msg -eq '') "a missing budget stopped the bootstrap: $msg"
        Assert (($script:warnings -join ' ') -like '*disk check skipped: no windows figure*') "warnings: $($script:warnings -join ' | ')"
        Assert (@(Get-MiseCall 'bootstrap --only').Count -ge 1) 'mise bootstrap did not run'
    }

    Test-Case 'disk: the real Get-FreeSpaceMB reads a drive, and $null for a missing drive or a UNC path' {
        $src = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FreeSpaceMB' }, $true))[0]
        . ([scriptblock]::Create(($src.Extent.Text -replace '^function Get-FreeSpaceMB', 'function Get-RealFreeSpaceMB')))
        $free = Get-RealFreeSpaceMB $env:TEMP
        Assert (($null -ne $free) -and ($free -gt 0)) "TEMP's drive: [$free]"
        $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpper() })
        $letter = [char[]](68..90) | Where-Object { "$_" -notin $used } | Select-Object -Last 1
        $none = Get-RealFreeSpaceMB "${letter}:\nope"
        Assert ($null -eq $none) "missing drive ${letter}: got [$none], want `$null (not 0)"
        Assert ($null -eq (Get-RealFreeSpaceMB '\\server\share\x')) 'a UNC path should read as $null'
    }

    Test-Case 'Claude Code: an installed ~\.local\bin\claude.exe puts that folder on the User PATH' {
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = Join-Path $tmp 'claude-home'
            $bin = Join-Path $env:USERPROFILE '.local\bin'
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            Set-Content -LiteralPath (Join-Path $bin 'claude.exe') -Value ''
            $script:SkipToolInstall = $false
            $script:addedPaths.Clear()
            Invoke-InstallClaudeCode
            Assert (@($script:addedPaths) -contains $bin) "Add-ToUserPath calls: $($script:addedPaths -join ', ')"
        } finally { $env:USERPROFILE = $saved }
    }

    Test-Case 'Claude Code: claude found elsewhere, no ~\.local\bin\claude.exe -> PATH untouched, nothing installed' {
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = Join-Path $tmp 'claude-none'
            New-Item -ItemType Directory -Force -Path $env:USERPROFILE | Out-Null
            function claude { }
            $script:SkipToolInstall = $false
            $script:addedPaths.Clear()
            $script:curlZip = $null
            Invoke-InstallClaudeCode
            Assert ($script:addedPaths.Count -eq 0) "Add-ToUserPath calls: $($script:addedPaths -join ', ')"
        } finally { $env:USERPROFILE = $saved }
    }

    # The run sequence's hand-over after the pull: the if-block is taken from the AST and
    # run in a child PowerShell with the clone steps stubbed and a fake checkout script.
    Test-Case 'run sequence: after the pull the checkout''s bootstrap.ps1 runs the rest (without -Reinstall/-Yes), once' {
        $ifAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -like '*WORKSTATION_BOOTSTRAP_PULLED*' }, $true))[0]
        Assert ($null -ne $ifAst) 'no WORKSTATION_BOOTSTRAP_PULLED block in bootstrap.ps1'
        $repo = Join-Path $tmp 'reexec-repo'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'bootstrap.ps1') -Value 'param([switch]$SkipKeyGen, [switch]$Reinstall, [switch]$Yes) "CHILD pulled=$env:WORKSTATION_BOOTSTRAP_PULLED SkipKeyGen=$SkipKeyGen Reinstall=$Reinstall Yes=$Yes"; exit 7'
        $harness = Join-Path $tmp 'reexec-harness.ps1'
        $head = "param([switch]`$SkipKeyGen, [switch]`$Reinstall, [switch]`$Yes)`n`$RepoPath = '$repo'`n" +
            "function Invoke-Reinstall { 'WIPED' }`nfunction Invoke-Preflight { }`nfunction Invoke-CloneRepo { 'PULLED' }`n"
        Set-Content -LiteralPath $harness -Value ($head + $ifAst.Extent.Text + "`n'PARENT-CONTINUED'")
        $savedPulled = $env:WORKSTATION_BOOTSTRAP_PULLED
        Remove-Item Env:WORKSTATION_BOOTSTRAP_PULLED -ErrorAction SilentlyContinue
        try {
            $out = @(& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $harness -SkipKeyGen -Reinstall -Yes)
            $code = $LASTEXITCODE
        } finally { if ($savedPulled) { $env:WORKSTATION_BOOTSTRAP_PULLED = $savedPulled } }
        Assert (($out -join '|') -ceq 'WIPED|PULLED|CHILD pulled=1 SkipKeyGen=True Reinstall=False Yes=False') "output: $($out -join '|')"
        Assert ($code -eq 7) "exit code $code, want the checkout script's 7"
    }
} finally {
    if ($null -eq $savedMiseEnv) { Remove-Item Env:MISE_ENV -ErrorAction SilentlyContinue } else { $env:MISE_ENV = $savedMiseEnv }
    Remove-Item -Recurse -Force $tmp
}
Complete-Test 'mise plumbing'
