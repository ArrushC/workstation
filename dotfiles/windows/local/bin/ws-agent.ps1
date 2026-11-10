# ws-agent on Windows, for PowerShell (5.1 and 7) and, through ws-agent.cmd, cmd. Jobs run in WSL,
# where the sandbox is, so this forwards to the ws-agent of the distribution the directory lives in:
#   \\wsl.localhost\<distro>\home\me\src\foo  ->  wsl.exe -d <distro> --cd /home/me/src/foo -- ws-agent ...
# - Outside a WSL directory `context` prints nothing; other commands go to the default distribution.
# - A repository on a Windows drive is refused: its working copy has to live in WSL.
# - CLAUDECODE crosses over, so `allow` and the source settings still refuse from a session.
# Git Bash (Claude Code's Bash tool and hooks) uses the `ws-agent` script beside this file: same
# rules. WS_AGENT_WSL names the program to run instead of wsl.exe (tests). ASCII only.
$ErrorActionPreference = 'Stop'
$unc = '^[\\/]{2}(wsl\.localhost|wsl\$)[\\/]([^\\/]+)(.*)$'
function Convert-WslPath([string]$Path) {
    if ($Path -match $unc) {
        $rest = ($Matches[3] -replace '\\', '/')
        if (-not $rest) { $rest = '/' }
        return @{ Distro = $Matches[2]; Path = $rest }
    }
    return $null
}
$distro = ''
$dir = ''
$here = Convert-WslPath ((Get-Location).ProviderPath)
if ($here) { $distro = $here.Distro; $dir = $here.Path }
$rest = New-Object System.Collections.Generic.List[string]
$prev = ''
foreach ($a in $args) {
    $a = [string]$a
    $w = Convert-WslPath $a
    if ($w) {
        if (-not $distro) { $distro = $w.Distro }
        $a = $w.Path
    } elseif ($a -match '^[A-Za-z]:[\\/]' -and @('--repo', 'allow', 'disallow', 'watch', 'unwatch', 'github', 'ungithub') -contains $prev) {
        [Console]::Error.WriteLine("ws-agent: $a is on a Windows drive; a repository for queued jobs has to live in WSL (\\wsl.localhost\<distro>\...)")
        exit 3
    }
    $rest.Add($a)
    $prev = $a
}
$first = if ($args.Count) { [string]$args[0] } else { '' }
if ($first -eq 'context' -and -not $distro) { exit 0 }
$wsl = if ($env:WS_AGENT_WSL) { $env:WS_AGENT_WSL } else { 'wsl.exe' }
if (-not (Get-Command $wsl -ErrorAction SilentlyContinue)) {
    if ($first -eq 'context') { exit 0 }
    [Console]::Error.WriteLine("ws-agent: wsl.exe isn't on PATH; queued jobs run in WSL")
    exit 1
}
$session = @()
if ($env:CLAUDECODE -eq '1') { $session = @('env', 'CLAUDECODE=1') }
if ($env:WSLENV) { $env:WSLENV = "$($env:WSLENV):CLAUDECODE/u" } else { $env:WSLENV = 'CLAUDECODE/u' }
$where = @()
if ($distro) { $where += @('-d', $distro) }
if ($dir) { $where += @('--cd', $dir) }
# `wsl.exe --` hands its words to the distribution's login shell (so PATH has ~/.local/bin and
# mise's shims), which would parse a prompt's quotes and metacharacters again, and PowerShell 5.1
# drops quotes on the way to a native program. The arguments cross as one base64 word (each
# NUL-ended) that ws-agent decodes; a session's marker crosses as plain words too.
$bytes = New-Object System.Collections.Generic.List[byte]
foreach ($a in $rest) { $bytes.AddRange([Text.Encoding]::UTF8.GetBytes($a)); $bytes.Add(0) }
$packed = [Convert]::ToBase64String($bytes.ToArray())
& $wsl @where '--' @session 'ws-agent' '--argv-b64' $packed
exit $LASTEXITCODE
