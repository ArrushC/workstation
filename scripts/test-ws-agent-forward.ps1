# Tests dotfiles/windows/local/bin/ws-agent.ps1 (ws-agent on Windows forwards to WSL) with a
# stand-in for wsl.exe (WS_AGENT_WSL) that prints its arguments: a WSL directory gives -d/--cd,
# arguments cross as one base64 word (quotes, spaces and shell metacharacters intact), a WSL path
# argument is translated, a Windows-drive repository is refused (exit 3), `context` outside WSL
# prints nothing, and a session's CLAUDECODE crosses as `env CLAUDECODE=1`.
# Windows PowerShell 5.1 and pwsh; ASCII only.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\test-helpers.ps1')
$script = Join-Path $PSScriptRoot '..\dotfiles\windows\local\bin\ws-agent.ps1'
$shell = (Get-Process -Id $PID).Path
$tmp = New-TestTempDir 'ws-agent-forward-'
$fake = Join-Path $tmp 'fake-wsl.cmd'
[IO.File]::WriteAllText($fake, "@echo off`r`necho %*`r`nexit /b 5`r`n")
$savedWsl = $env:WS_AGENT_WSL; $savedCc = $env:CLAUDECODE; $savedWslenv = $env:WSLENV
function Invoke-Forward([string[]]$ForwardArgs) {
    # From a drive directory (cmd, which runs the stand-in, has no UNC working directory), and with
    # the child's stderr as text: under 'Stop' PowerShell would turn its first line into an exception.
    Push-Location $tmp
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $script @ForwardArgs 2>&1 | ForEach-Object { "$_" })
        return @{ Out = ($out -join "`n"); Code = $LASTEXITCODE }
    } finally { Pop-Location }
}
function Unpack([string]$Line) {
    $word = ($Line.Trim() -split ' ')[-1]
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($word))
    return ,@($text.TrimEnd([char]0) -split [char]0)
}
try {
    $env:WS_AGENT_WSL = $fake
    Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
    Test-Case 'arguments cross as one base64 word, untouched' {
        # No double quote here: this test starts the script as a child process, and PowerShell 5.1
        # drops them at that boundary (typed at a prompt the script runs in-process and keeps them).
        $nasty = 'fix it; rm -rf ~ $(id) `id` two  spaces & more'
        $r = Invoke-Forward @('run', '--title', 't', '--prompt', $nasty)
        Assert ($r.Code -eq 5) "exit code $($r.Code), want the forwarded program's 5"
        Assert ($r.Out -match '(^| )-- ws-agent --argv-b64 [A-Za-z0-9+/=]+$') "sent: $($r.Out)"
        $got = Unpack $r.Out
        Assert ($got[-1] -ceq $nasty) "prompt arrived as: $($got[-1])"
        Assert (($got -join '|') -ceq "run|--title|t|--prompt|$nasty") "args: $($got -join '|')"
    }
    Test-Case 'a WSL path argument is translated and names the distribution' {
        $r = Invoke-Forward @('ls', '--repo', '\\wsl.localhost\AlmaLinux-9\home\me\src\foo')
        Assert ($r.Out -match '^-d AlmaLinux-9 ') "sent: $($r.Out)"
        Assert (((Unpack $r.Out) -join '|') -ceq 'ls|--repo|/home/me/src/foo') "args: $((Unpack $r.Out) -join '|')"
    }
    Test-Case 'a repository on a Windows drive is refused' {
        $r = Invoke-Forward @('allow', 'C:\src\foo')
        Assert ($r.Code -eq 3) "exit code $($r.Code), want 3"
        Assert ($r.Out -match 'has to live in WSL') "message: $($r.Out)"
    }
    Test-Case 'context outside a WSL directory prints nothing' {
        $r = Invoke-Forward @('context')
        Assert ($r.Code -eq 0 -and $r.Out -eq '') "code $($r.Code), out: $($r.Out)"
    }
    Test-Case 'a session marker crosses as plain words' {
        $env:CLAUDECODE = '1'
        try { $r = Invoke-Forward @('inbox') } finally { Remove-Item Env:CLAUDECODE }
        Assert ($r.Out -match '-- env CLAUDECODE=1 ws-agent --argv-b64 ') "sent: $($r.Out)"
    }
} finally {
    $env:WS_AGENT_WSL = $savedWsl; $env:CLAUDECODE = $savedCc; $env:WSLENV = $savedWslenv
    Remove-Item -Recurse -Force $tmp
}
Complete-Test 'ws-agent forwarder'
