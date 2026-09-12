#Requires -Version 5.1
# Integration checks only: extract functions without executing provisioning.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-TestFunction {
    param([string]$Path, [string]$Name)
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $node = $ast.Find({
        param($item)
        $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $Name
    }, $true)
    if (-not $node) { throw "Missing function: $Name" }
    return $node.Extent.Text
}

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$bootstrapPath = Join-Path $repoRoot 'bootstrap.ps1'
$helper = Get-TestFunction $bootstrapPath 'Invoke-CurlRequest'
$fontHelper = Get-TestFunction (Join-Path $repoRoot 'scripts/install-nerd-fonts.ps1') 'Invoke-CurlRequest'
Assert-Test ($helper -ceq $fontHelper) 'Bootstrap/font HTTP helpers drifted'
. ([scriptblock]::Create($helper))
. ([scriptblock]::Create((Get-TestFunction $bootstrapPath 'Get-LatestWingetVersion')))

# Bind an ephemeral loopback port without HttpListener URL ACL requirements.
$server = Start-Job {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $listener.LocalEndpoint.Port
    $retried = $false
    try {
        while ($true) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 10; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = [System.IO.StreamReader]::new($stream)
                $request = $reader.ReadLine()
                $route = ($request -split ' ')[1]
                $headers = @()
                while ($line = $reader.ReadLine()) { $headers += $line }
                $status = '200 OK'
                $extra = ''
                $body = [System.Text.Encoding]::UTF8.GetBytes("line one`n$([char]0x2713) caf$([char]0xe9)`n")
                switch ($route) {
                    '/redirect' { $status = '302 Found'; $extra = "Location: /text`r`n" }
                    '/auth' {
                        if ($headers -notcontains 'Authorization: Bearer fixture-token') { $status = '401 Unauthorized' }
                    }
                    '/binary' { $body = [byte[]](0..255) }
                    '/object' { $body = [System.Text.Encoding]::UTF8.GetBytes('{"tag_name":"v1","assets":[]}') }
                    '/empty' { $body = [System.Text.Encoding]::UTF8.GetBytes('[]') }
                    '/single' { $body = [System.Text.Encoding]::UTF8.GetBytes('[{"draft":false,"tag_name":"v2"}]') }
                    '/multi' { $body = [System.Text.Encoding]::UTF8.GetBytes('[{"draft":true,"tag_name":"v3"},{"draft":false,"tag_name":"v2"}]') }
                    '/invalid' { $body = [System.Text.Encoding]::UTF8.GetBytes('{broken') }
                    '/missing' { $status = '404 Not Found' }
                    '/script-error' {
                        $status = '404 Not Found'
                        $body = [System.Text.Encoding]::UTF8.GetBytes('$script:downloadExecuted = $true')
                    }
                    '/retry' {
                        if (-not $retried) { $status = '503 Unavailable'; $retried = $true }
                    }
                }
                $length = $body.Length
                if ($route -eq '/partial') { $length += 100 }
                $head = [System.Text.Encoding]::ASCII.GetBytes(
                    "HTTP/1.1 $status`r`n${extra}Content-Length: $length`r`nConnection: close`r`n`r`n")
                $stream.Write($head, 0, $head.Length)
                $stream.Write($body, 0, $body.Length)
            } finally { $client.Dispose() }
        }
    } finally { $listener.Stop() }
}

$testDir = Join-Path ([System.IO.Path]::GetTempPath()) ('curl-test-' + [guid]::NewGuid())
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$shadowDir = $null
try {
    New-Item -ItemType Directory -Path $testDir | Out-Null
    $env:TEMP = $testDir
    $env:TMP = $testDir
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    do {
        $port = Receive-Job $server
        if ($port) { break }
        if ($server.State -eq 'Failed' -or [datetime]::UtcNow -gt $deadline) { throw 'Fixture server failed to start' }
        Start-Sleep -Milliseconds 100
    } while ($true)
    $base = "http://127.0.0.1:$port"
    $expected = "line one`n$([char]0x2713) caf$([char]0xe9)`n"
    Assert-Test ((Invoke-CurlRequest "$base/redirect") -ceq $expected) 'Redirect / UTF-8 / multiline failure'
    Assert-Test ((Invoke-CurlRequest "$base/auth" -Headers @{Authorization='Bearer fixture-token'}) -ceq $expected) 'Header forwarding failure'
    Assert-Test ((Invoke-CurlRequest "$base/retry") -ceq $expected) 'Retry failed'
    # Two curl.exe on PATH (System32 + Git's mingw64\bin is the everyday case, and
    # GitHub's windows runner): Get-Command returns BOTH, and the helper must still
    # resolve to exactly one executable.
    $systemCurl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $systemCurl)) { $systemCurl = (Get-Command curl.exe -CommandType Application | Select-Object -First 1).Source }
    $shadowDir = Join-Path $oldTemp ('curl-shadow-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $shadowDir | Out-Null
    Copy-Item -LiteralPath $systemCurl -Destination (Join-Path $shadowDir 'curl.exe')
    $oldPath = $env:PATH
    try {
        $env:PATH = "$shadowDir;$oldPath"
        Assert-Test (@(Get-Command curl.exe -CommandType Application).Count -ge 2) 'Fixture did not put two curl.exe on PATH'
        Assert-Test ((Invoke-CurlRequest "$base/redirect") -ceq $expected) 'Helper failed with two curl.exe on PATH'
    } finally { $env:PATH = $oldPath }
    $outFile = Join-Path $testDir 'binary with spaces.bin'
    $result = Invoke-CurlRequest "$base/binary" -OutFile $outFile
    Assert-Test ($null -eq $result) 'File download polluted the success pipeline'
    Assert-Test (([System.IO.File]::ReadAllBytes($outFile) -join ',') -ceq ((0..255) -join ',')) 'Binary bytes changed'
    $object = Invoke-CurlRequest "$base/object" | ConvertFrom-Json
    Assert-Test ($object.tag_name -eq 'v1') 'JSON object parsing failed'
    foreach ($route in @('empty', 'single', 'multi')) {
        $items = Invoke-CurlRequest "$base/$route" | ConvertFrom-Json
        $count = @($items | ForEach-Object { $_ }).Count
        $expectedCount = @{empty=0; single=1; multi=2}[$route]
        Assert-Test ($count -eq $expectedCount) "JSON array shape failed: $route"
        if ($count) {
            $release = $items | Where-Object { -not $_.draft } | Select-Object -First 1
            Assert-Test ($release.tag_name -eq 'v2') 'Prerelease selection regressed'
        }
    }
    foreach ($route in @('missing', 'auth', 'partial', 'invalid')) {
        $failed = $false
        try {
            $null = Invoke-CurlRequest "$base/$route" | ConvertFrom-Json -ErrorAction Stop
        } catch { $failed = $true }
        Assert-Test $failed "Failure did not throw: $route"
    }
    $message = ''
    try { $null = Invoke-CurlRequest "$base/missing" } catch { $message = $_.Exception.Message }
    Assert-Test ($message -like '*404*') 'HTTP status missing from failure message'
    $failed = $false
    try { Invoke-CurlRequest "$base/partial" -OutFile $outFile } catch { $failed = $true }
    Assert-Test $failed 'Partial binary download did not throw'
    Assert-Test (([System.IO.File]::ReadAllBytes($outFile)).Length -eq 256) 'Failed download replaced existing destination'
    Assert-Test (@(Get-ChildItem -LiteralPath $testDir).Count -eq 1) 'Temporary downloads leaked'
    $script:downloadExecuted = $false
    $failed = $false
    try {
        $download = Invoke-CurlRequest "$base/script-error"
        & ([scriptblock]::Create($download))
    } catch { $failed = $true }
    Assert-Test ($failed -and -not $script:downloadExecuted) 'Failed script download reached execution'

    # Exercise the real winget resolver with fixture JSON and no network.
    function Invoke-CurlRequest {
        '[{"type":"dir","name":"1.2.3"},{"type":"file","name":"9.9.9"},{"type":"dir","name":"2.0.0"},{"type":"dir","name":"invalid"}]'
    }
    Assert-Test ((Get-LatestWingetVersion 'fixture') -eq '2.0.0') 'Winget version selection regressed'
    . ([scriptblock]::Create($helper))
    Stop-Job $server
    $failed = $false
    try { $null = Invoke-CurlRequest "$base/text" } catch { $failed = $true }
    Assert-Test $failed 'Connection failure did not throw'
    Assert-Test (@(Get-ChildItem -LiteralPath $testDir).Count -eq 1) 'Connection failure leaked temp files'
    $oldPath = $env:PATH
    try {
        $env:PATH = $testDir
        $failed = $false
        try { $null = Invoke-CurlRequest "$base/text" } catch {
            $failed = $_.Exception.Message -like 'curl.exe is required*'
        }
        Assert-Test $failed 'Missing curl.exe did not produce prerequisite guidance'
    } finally { $env:PATH = $oldPath }
    Write-Host "curl integration checks passed on PowerShell $($PSVersionTable.PSVersion)"
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    Stop-Job $server -ErrorAction SilentlyContinue
    Remove-Job $server -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($shadowDir) { Remove-Item -LiteralPath $shadowDir -Recurse -Force -ErrorAction SilentlyContinue }
}
# The GitHub runner appends `exit $LASTEXITCODE` to every pwsh/powershell step,
# and the last native call above is the deliberate connection-refused fixture
# (curl exit 7). Reaching this line means every assertion passed.
$global:LASTEXITCODE = 0
