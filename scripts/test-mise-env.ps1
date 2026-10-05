# Tests bootstrap.ps1's mise plumbing without running the bootstrap: the
# miserc.toml writer (Initialize-MiseEnv), the one-time cleanup of the
# pre-mise portable installs (Invoke-LegacyToolCleanup), the mise install /
# update (Install-Mise), the mise bootstrap step's guard, ordering and
# -C pinning (Invoke-MiseBootstrap), and the Claude Code step's PATH entry
# (Invoke-InstallClaudeCode). The functions are extracted from the
# script's AST, as scripts/test-config-local.ps1 does.
#
# Nothing real is touched:
#  - the User environment only through Get-UserEnv/Set-UserEnv, stubbed here
#    (PowerShell can't stub a static .NET method); a function that calls
#    [Environment]::SetEnvironmentVariable itself is refused, not loaded
#  - `mise` is a function stub (functions win over mise.exe on PATH), and
#    the script stops unless it resolves to that stub
#  - Invoke-CurlRequest, Add-ToUserPath and Update-SessionPath are stubbed
#  - every path points at a temp dir
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'bootstrap.ps1'), [ref]$null, [ref]$null)
$wanted = 'Initialize-MiseEnv', 'Invoke-LegacyToolCleanup', 'Install-Mise', 'Invoke-MiseBootstrap', 'Invoke-InstallClaudeCode'
$refused = New-Object System.Collections.Generic.List[string]
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) {
    if ($f.Extent.Text -match 'Environment\]::SetEnvironmentVariable') { $refused.Add($f.Name); continue }
    . ([scriptblock]::Create($f.Extent.Text))
}
$script:warnings = New-Object System.Collections.Generic.List[string]
function Write-Ok { param($m) }
function Write-Log { param($m) }
function Write-Warn { param($m) $script:warnings.Add([string]$m) }
# Write-Fail exits bootstrap.ps1; here it throws so a case can assert on it.
function Write-Fail { param($m) throw "WRITE-FAIL: $m" }
# The fake User environment: a case-insensitive name -> value table.
$script:userEnv = @{}
$script:userWrites = New-Object System.Collections.Generic.List[string]
function Get-UserEnv { param([string]$Name) if ($script:userEnv.ContainsKey($Name)) { $script:userEnv[$Name] } }
function Set-UserEnv {
    param([string]$Name, $Value)
    $script:userWrites.Add($Name)
    if ($null -eq $Value) { $script:userEnv.Remove($Name) } else { $script:userEnv[$Name] = $Value }
}
$script:addedPaths = New-Object System.Collections.Generic.List[string]
function Add-ToUserPath { param([string]$Dir) $script:addedPaths.Add($Dir) }
function Update-SessionPath { }
function Invoke-EnsureConfigLocal { }
function Invoke-WslConfigReminder { }
# The download: a copy of $script:curlZip, or a failure when it's $null.
$script:curlZip = $null
function Invoke-CurlRequest {
    param([string]$Uri, [hashtable]$Headers, [string]$OutFile)
    if (-not $script:curlZip) { throw 'curl.exe request failed (exit 6)' }
    Copy-Item -LiteralPath $script:curlZip -Destination $OutFile -Force
}
# The mise stub: records each call (args joined) in $script:events and
# answers from $script:miseReply (first key found in the call -> Out/Exit).
$script:events = New-Object System.Collections.Generic.List[string]
$script:miseReply = @{}
function mise {
    $line = $args -join ' '
    $script:events.Add("mise $line")
    $exit = 0
    foreach ($k in $script:miseReply.Keys) {
        if ($line.Contains($k)) {
            $r = $script:miseReply[$k]
            if ($r.ContainsKey('Out')) { $r.Out }
            $exit = $r.Exit
            break
        }
    }
    $global:LASTEXITCODE = $exit
}
if ((Get-Command mise).CommandType -ne 'Function') { throw 'refusing to run: mise does not resolve to the test stub' }
function Assert([bool]$cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

$failures = New-Object System.Collections.Generic.List[string]
foreach ($name in $refused) { $failures.Add("$name writes the User environment directly (use Set-UserEnv)") }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        $script:warnings.Clear()
        & $Body
        Write-Host "  ok    $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "  FAIL  $Name -- $($_.Exception.Message)"
    }
}
function New-TestFile([string]$Path, [string]$Content = 'x') {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content)
}
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
function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path) }

$savedMiseEnv = $env:MISE_ENV
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("miseenv-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Test-Case 'miserc.toml: windows,owned, no BOM, LF; the User and session MISE_ENV go' {
        $script:RepoPath = Join-Path $tmp 'repo'
        New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
        $script:MiseEnvTokens = @('windows', 'owned')
        $script:userEnv = @{ MISE_ENV = 'windows,owned'; Path = 'C:\x' }
        $script:userWrites.Clear()
        $env:MISE_ENV = 'windows,owned'
        Initialize-MiseEnv
        $rc = Join-Path $script:RepoPath 'miserc.toml'
        $bytes = [System.IO.File]::ReadAllBytes($rc)
        Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'written with a BOM'
        $text = Read-Text $rc
        Assert (-not $text.Contains("`r")) 'CR line endings'
        $lines = @($text -split "`n")
        Assert ($lines -ccontains 'env = ["windows", "owned"]') "no env line: $text"
        Assert ($lines -ccontains 'auto_env = false') "no auto_env line: $text"
        Assert (@($lines | Where-Object { $_ -and $_ -notmatch '^#' }).Count -eq 2) "unexpected lines: $text"
        Assert (-not (Test-Path Env:MISE_ENV)) "session MISE_ENV still set: $env:MISE_ENV"
        Assert (-not $script:userEnv.ContainsKey('MISE_ENV')) 'User MISE_ENV not removed'
        Assert ($script:userEnv['Path'] -ceq 'C:\x') 'User Path touched'
    }

    Test-Case 'miserc.toml rewritten; no User MISE_ENV means no User write' {
        $script:RepoPath = Join-Path $tmp 'repo2'
        New-Item -ItemType Directory -Path $script:RepoPath | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:RepoPath 'miserc.toml'), "env = [`"linux`"]`n")
        $script:MiseEnvTokens = @('windows', 'owned')
        $script:userEnv = @{ Path = 'C:\x' }
        $script:userWrites.Clear()
        Initialize-MiseEnv
        Assert ((Read-Text (Join-Path $script:RepoPath 'miserc.toml')).Contains('env = ["windows", "owned"]')) 'old miserc.toml kept'
        Assert ($script:userWrites.Count -eq 0) "User environment written: $($script:userWrites -join ', ')"
    }

    Test-Case 'legacy cleanup: old dirs, exes, stamps and PATH entries go; the rest stays' {
        $script:WsRoot = Join-Path $tmp 'ws'
        $script:WsBin = Join-Path $script:WsRoot 'bin'
        $script:WsStamps = Join-Path $script:WsRoot 'stamps'
        $oldDirs = 'helix', 'nu', 'devtoys-cli', 'dngrep', 'logexpert'
        foreach ($d in $oldDirs) { New-TestFile (Join-Path $script:WsRoot "$d\tool.exe") }
        $oldExes = 'starship', 'gh', 'jq', 'omp', 'opencode', 'chezmoi'
        foreach ($e in $oldExes) { New-TestFile (Join-Path $script:WsBin "$e.exe") }
        $keepFiles = @(
            (Join-Path $script:WsBin 'wpy.cmd'),
            (Join-Path $script:WsBin 'textual.cmd'),
            (Join-Path $script:WsRoot 'mise\bin\mise.exe'),
            (Join-Path $script:WsStamps 'mise.2026.9.9.stamp'),
            (Join-Path $script:WsStamps 'python-env.stamp'),
            (Join-Path $script:WsStamps 'wslconfig.abcd1234.stamp'),
            (Join-Path $script:WsStamps 'node-postinstall.0123456789abcdef.stamp')
        )
        foreach ($k in $keepFiles) { New-TestFile $k }
        $oldStamps = 'starship.1.25.1.stamp', 'nu.0.113.1.stamp', 'DevToys.CLI.2.0.9.0.stamp', 'dnGREP.5.0.30.0.stamp', 'mise-runtimes.abcd1234.stamp'
        foreach ($s in $oldStamps) { New-TestFile (Join-Path $script:WsStamps $s) }
        $script:userEnv = @{ Path = (@(
            'C:\Windows',
            $script:WsBin,
            (Join-Path $script:WsRoot 'helix'),
            ((Join-Path $script:WsRoot 'nu') + '\'),
            (Join-Path $script:WsRoot 'DevToys-CLI'),
            (Join-Path $script:WsRoot 'dngrep'),
            (Join-Path $script:WsRoot 'logexpert'),
            (Join-Path $script:WsRoot 'mise\bin'),
            'C:\Users\u\AppData\Local\mise\shims'
        ) -join ';') }
        $script:userWrites.Clear()
        Invoke-LegacyToolCleanup
        foreach ($d in $oldDirs) { Assert (-not (Test-Path (Join-Path $script:WsRoot $d))) "$d dir left behind" }
        foreach ($e in $oldExes) { Assert (-not (Test-Path (Join-Path $script:WsBin "$e.exe"))) "$e.exe left behind" }
        foreach ($s in $oldStamps) { Assert (-not (Test-Path (Join-Path $script:WsStamps $s))) "$s left behind" }
        foreach ($k in $keepFiles) { Assert (Test-Path $k) "$k removed" }
        $want = @('C:\Windows', $script:WsBin, (Join-Path $script:WsRoot 'mise\bin'), 'C:\Users\u\AppData\Local\mise\shims') -join ';'
        Assert ($script:userEnv['Path'] -ceq $want) "User Path: $($script:userEnv['Path'])"
        Assert ($script:warnings.Count -eq 0) "unexpected warning: $($script:warnings -join ' | ')"
    }

    Test-Case 'legacy cleanup: a second run changes nothing' {
        $before = $script:userEnv['Path']
        $script:userWrites.Clear()
        Invoke-LegacyToolCleanup
        Assert ($script:userWrites.Count -eq 0) "User environment written: $($script:userWrites -join ', ')"
        Assert ($script:userEnv['Path'] -ceq $before) 'User Path changed'
        Assert (Test-Path (Join-Path $script:WsStamps 'mise.2026.9.9.stamp')) 'mise stamp removed'
    }

    Test-Case 'legacy cleanup: an in-use old exe is named in a warning, not fatal' {
        $gh = Join-Path $script:WsBin 'gh.exe'
        New-TestFile $gh
        $h = [System.IO.File]::Open($gh, 'Open', 'Read', 'Read')   # no Delete share: like a running gh
        try { Invoke-LegacyToolCleanup } finally { $h.Dispose() }
        Assert (($script:warnings -join ' ') -like "*gh.exe*close it and re-run*") "warnings: $($script:warnings -join ' | ')"
        $script:warnings.Clear()
        Invoke-LegacyToolCleanup
        Assert (-not (Test-Path $gh)) 'gh.exe left behind once released'
        Assert ($script:warnings.Count -eq 0) "warned again: $($script:warnings -join ' | ')"
    }

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
    $script:MiseEnvTokens = @('windows', 'owned')
    $script:SkipDotfiles = $false
    $script:SkipToolInstall = $false
    $script:MigratedMarker = Join-Path $tmp 'ws\dotfiles-migrated'
    $script:MiseShims = Join-Path $tmp 'mise\shims'
    $ownedLs = '[{"path": "C:\\Users\\u\\.config\\mise\\config.toml"}, {"path": "C:\\Users\\u\\.config\\mise\\config.owned.toml"}]'
    function Invoke-Bootstrap {
        $script:events.Clear()
        $script:userEnv = @{}
        # Recorded in the same log as the mise calls, to check the order.
        function Invoke-LegacyToolCleanup { $script:events.Add('cleanup') }
        $msg = ''
        try { Invoke-MiseBootstrap } catch { $msg = $_.Exception.Message }
        return $msg
    }
    function Get-MiseCall([string]$Part) { @($script:events | Where-Object { $_ -like "mise *$Part*" }) }

    Test-Case 'mise bootstrap: stops before bootstrap/prune when config.owned.toml is not loaded' {
        $script:miseReply = @{ 'config ls' = @{ Out = '[{"path": "C:\\Users\\u\\.config\\mise\\config.toml"}]'; Exit = 0 } }
        $msg = Invoke-Bootstrap
        Assert ($msg -like 'WRITE-FAIL:*config.owned.toml*miserc.toml*') "got: $msg"
        Assert ($msg -notlike '*min_version*') "min_version hint for an exit-0 config ls: $msg"
        Assert (@(Get-MiseCall 'bootstrap').Count -eq 0) 'mise bootstrap ran'
        Assert (@(Get-MiseCall 'prune').Count -eq 0) 'mise prune ran'
        Assert ($script:events -notcontains 'cleanup') 'legacy cleanup ran'
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

    Test-Case 'mise bootstrap: a failing `mise config ls` stops even when its error names config.owned.toml' {
        $script:miseReply = @{ 'config ls' = @{ Out = @('mise ERROR failed to parse C:\Users\u\.config\mise\config.owned.toml', 'TOML parse error at line 3, column 1'); Exit = 1 } }
        $msg = Invoke-Bootstrap
        Assert ($msg -like 'WRITE-FAIL:*min_version*failed to parse*config.owned.toml*TOML parse error*') "got: $msg"
        Assert (@(Get-MiseCall 'bootstrap').Count -eq 0) 'mise bootstrap ran'
        Assert ($script:events -notcontains 'cleanup') 'legacy cleanup ran'
    }

    Test-Case 'mise bootstrap: a failed bootstrap keeps the old tools (no cleanup)' {
        $script:miseReply = @{ 'config ls' = @{ Out = $ownedLs; Exit = 0 }; ' bootstrap ' = @{ Exit = 1 } }
        $msg = Invoke-Bootstrap
        Assert ($msg -like 'WRITE-FAIL:*mise bootstrap*failed*') "got: $msg"
        Assert ($script:events -notcontains 'cleanup') 'legacy cleanup ran after a failed bootstrap'
    }

    Test-Case 'mise bootstrap: cleanup after a good bootstrap; every call pinned with -C; node marker' {
        $script:miseReply = @{
            'config ls'  = @{ Out = $ownedLs; Exit = 0 }
            'where node' = @{ Out = 'C:\node'; Exit = 0 }
            'config get' = @{ Out = 'version = "26.10.0"'; Exit = 0 }
        }
        Get-ChildItem $script:WsStamps -Filter 'node-postinstall.*.stamp' | Remove-Item -Force
        $msg = Invoke-Bootstrap
        Assert ($msg -eq '') "failed: $msg"
        $calls = @($script:events | Where-Object { $_ -like 'mise *' })
        $pin = "mise -C $env:USERPROFILE "
        foreach ($c in $calls) { Assert ($c.StartsWith($pin)) "not pinned to %USERPROFILE%: $c" }
        $boot = $script:events.IndexOf(@(Get-MiseCall 'bootstrap --only dotfiles,tools --yes')[0])
        $clean = $script:events.IndexOf('cleanup')
        Assert (($boot -ge 0) -and ($clean -gt $boot)) "order: $($script:events -join ' | ')"
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
} finally {
    if ($null -eq $savedMiseEnv) { Remove-Item Env:MISE_ENV -ErrorAction SilentlyContinue } else { $env:MISE_ENV = $savedMiseEnv }
    Remove-Item -Recurse -Force $tmp
}
if ($failures.Count -gt 0) { throw "mise plumbing: $($failures.Count) case(s) failed: $($failures -join '; ')" }
Write-Host "mise plumbing checks passed on PowerShell $($PSVersionTable.PSVersion)"
$global:LASTEXITCODE = 0
