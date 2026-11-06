#Requires -Version 5.1
# =============================================================================
# deepseek-harness.ps1 -- install DeepSeek's DeepSeek Harness desktop app when it is
# missing, for this user.
#
# Run by config.windows.toml's `deepseek-harness-win` task (the post-tools hook, so
# bootstrap.ps1 and wsu). It isn't a winget package: the winget entries are third-party
# repackages, and this is DeepSeek's own installer. DeepSeek publishes an electron-updater
# feed (nightly.yml) naming the current installer and its SHA-512. So:
#   1. stop there when "DeepSeek Harness" is already listed under the per-user Uninstall
#      key (the app updates itself; no network request is made);
#   2. else read the feed and refuse anything that isn't a usable one (Read-Feed: a
#      version, an installer URL under DeepSeek's download prefix, a base64 SHA-512);
#   3. download the installer and refuse it unless its SHA-512 matches the feed's
#      (Test-Sha512) and its Authenticode signature is Valid and names DeepSeek's
#      company (Test-Signer: the name, not a thumbprint, because the cert gets renewed);
#   4. run it with /S (per-user, no admin) for at most -TimeoutSec seconds.
# Every failure warns and exits 0: a failing hook would stop `mise bootstrap`.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.
# scripts/test-deepseek-harness.ps1 tests it; it never runs a real installer or touches
# the real Uninstall key.
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/deepseek-harness.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string]$FeedUrl = 'https://download.deepseek.com/dsh-desk/feeds/win-x64/nightly.yml',
    [string]$InstallerPrefix = 'https://download.deepseek.com/dsh-desk/bin/win-x64/',
    [string]$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
    [string]$WorkDir = [IO.Path]::GetTempPath(),
    [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'workstation\deepseek-harness'),
    [int]$TimeoutSec = 900
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 started from pwsh 7 inherits pwsh's PSModulePath, which puts
# pwsh's modules first; Microsoft.PowerShell.Security (Get-AuthenticodeSignature) then
# fails to load, and an unverifiable installer must never be run. Reset it to the
# machine value (the 5.1 and system module folders).
if ($PSVersionTable.PSEdition -ne 'Core') {
    $env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
}

function Write-Step([string]$Message) { Write-Host "  deepseek-harness: $Message" }

# The version, installer URL and SHA-512 (base64) of an electron-updater feed. Only
# top-level keys count (files[] entries are indented), and a value may be a one-line
# scalar (optionally quoted) or a folded/literal block. Throws a reason when the text
# isn't a usable feed.
function Read-Feed([string]$Text, [string]$Prefix) {
    $lines = $Text -split "\r?\n"
    $v = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -cmatch '^(version|path|sha512):\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()
            if ($val -match '^[>|]-?$') {
                $parts = @()
                while (($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '^\s+\S') {
                    $i++
                    $parts += $lines[$i].Trim()
                }
                $val = $parts -join ' '
            }
            if ($val -match '^(["''])(.*)\1$') { $val = $Matches[2] }
            $v[$key] = $val
        }
    }
    if (-not $v.ContainsKey('version') -or -not $v['version']) { throw 'no version' }
    if (-not $v.ContainsKey('path') -or -not $v['path']) { throw 'no path' }
    if (-not $v.ContainsKey('sha512') -or -not $v['sha512']) { throw 'no sha512' }
    $version = $v['version']
    $url = $v['path']
    $sha = $v['sha512']
    if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') { throw "bad version '$version'" }
    $inside = $url.StartsWith($Prefix, [StringComparison]::Ordinal)
    $rest = if ($inside) { $url.Substring($Prefix.Length) } else { '' }
    if (-not $inside -or $rest -cnotmatch '^[A-Za-z0-9._-]+\.exe$' -or $rest.Contains('..')) {
        throw "installer URL '$url' is outside $Prefix or isn't one .exe"
    }
    $ok = $false
    try { $ok = ([Convert]::FromBase64String($sha)).Length -eq 64 } catch { $ok = $false }
    if (-not $ok) { throw "sha512 isn't a base64 SHA-512" }
    return [pscustomobject]@{ Version = $version; Url = $url; Sha512 = $sha }
}

# True when the file's SHA-512 (base64, ordinal compare) is the expected one. Hashes a
# stream with .NET: Get-FileHash lives in a module that doesn't load when 5.1 inherits
# pwsh 7's PSModulePath.
function Test-Sha512([string]$Path, [string]$Expected) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $alg = [Security.Cryptography.SHA512]::Create()
        try { $actual = [Convert]::ToBase64String($alg.ComputeHash($stream)) } finally { $alg.Dispose() }
    } finally { $stream.Dispose() }
    return $actual -ceq $Expected
}

# The Authenticode status and signer (certificate SimpleName) of a file; Ok only for a
# Valid signature by exactly the expected company. Never throws.
function Test-Signer([string]$Path, [string]$Expected = 'Hangzhou DeepSeek Artificial Intelligence Co., Ltd.') {
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path
        $status = "$($s.Status)"
        $signer = ''
        if ($s.SignerCertificate) {
            $signer = $s.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        }
        return [pscustomobject]@{ Ok = ($status -eq 'Valid' -and $signer -ceq $Expected); Status = $status; Signer = $signer }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = "Error: $($_.Exception.Message)"; Signer = '' }
    }
}

# The Uninstall subkey whose DisplayName is exactly $Name, or $null. Name is the subkey
# name (the guid). Values come from RegistryKey.GetValue: under StrictMode, property
# access throws for a subkey with no DisplayName, and real Uninstall keys have those.
function Get-InstalledHarness([string]$Key, [string]$Name = 'DeepSeek Harness') {
    if (-not (Test-Path -LiteralPath $Key)) { return $null }
    foreach ($sub in @(Get-ChildItem -LiteralPath $Key)) {
        $display = $sub.GetValue('DisplayName')
        if ($null -ne $display -and "$display" -ceq $Name) {
            $ver = $sub.GetValue('DisplayVersion')
            return [pscustomobject]@{ Version = $(if ($null -ne $ver) { "$ver" } else { '' }); Name = $sub.PSChildName }
        }
    }
    return $null
}

# curl.exe with bootstrap.ps1's Invoke-CurlRequest flags: retries, and a stalled
# transfer aborts instead of hanging. Unlike wezterm-nightly.ps1's Get-Url it also
# follows redirects over https only (--proto-redir =https).
function Get-Url([string]$Uri, [string]$OutFile) {
    $curlArgs = @('--disable', '--fail', '--silent', '--show-error', '--location', '--proto-redir', '=https',
        '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30',
        '--speed-limit', '1', '--speed-time', '60', '--output', $OutFile, '--url', $Uri)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & curl.exe @curlArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe exit ${LASTEXITCODE} for ${Uri}: $((@($out) | ForEach-Object { "$_".Trim() }) -join ' ')"
    }
}

# Runs the installer and returns its exit code. On timeout it throws and leaves the
# process running (killing an installer half-way would leave a broken install).
function Invoke-Installer([string]$Path, [string[]]$ArgumentList = @('/S'), [int]$TimeoutSec = 900) {
    $p = Start-Process -FilePath $Path -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
    $null = $p.Handle   # without it, 5.1's ExitCode is $null after WaitForExit
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        throw "the installer didn't finish within $TimeoutSec s (it may still be running)"
    }
    return $p.ExitCode
}

# Installs the app when it isn't listed. State is 'present' (nothing fetched) or
# 'installed'. Throws a reason on any refusal; the downloaded folder is always removed.
# A complete, SHA-512-verified build the signer check or the install then refuses is
# recorded in <StateDir>\rejected.sha512 (line 1: its feed SHA-512, line 2: the reason),
# and isn't downloaded again until the feed names another build. A mismatch, a download
# or a feed problem is never recorded: those can be transient.
function Install-Harness([string]$FeedUrl, [string]$Prefix, [string]$UninstallKey, [string]$WorkDir, [string]$StateDir, [int]$TimeoutSec = 900) {
    $have = Get-InstalledHarness $UninstallKey
    if ($have) { return [pscustomobject]@{ State = 'present'; Version = $have.Version } }
    $dir = Join-Path $WorkDir ('deepseek-harness-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        try {
            $feedFile = Join-Path $dir 'nightly.yml'
            Get-Url $FeedUrl $feedFile
            $feed = Read-Feed ([IO.File]::ReadAllText($feedFile)) $Prefix
        } catch {
            throw "the update feed $FeedUrl isn't usable: $($_.Exception.Message)"
        }
        $rejectFile = Join-Path $StateDir 'rejected.sha512'
        if (Test-Path -LiteralPath $rejectFile) {
            $prev = @([IO.File]::ReadAllLines($rejectFile))
            if ($prev.Count -ge 1 -and $prev[0] -ceq $feed.Sha512) {
                $why = if ($prev.Count -ge 2) { $prev[1] } else { 'no reason recorded' }
                throw "DeepSeek Harness $($feed.Version) failed to install before ($why); skipping it until DeepSeek publishes a new build. Delete $rejectFile to retry"
            }
        }
        Write-Step "downloading DeepSeek Harness $($feed.Version) (about 290 MB)"
        $installer = Join-Path $dir ($feed.Url.Substring($feed.Url.LastIndexOf('/') + 1))
        Get-Url $feed.Url $installer
        if (-not (Test-Sha512 $installer $feed.Sha512)) { throw "the installer's SHA-512 doesn't match the feed's" }
        try {
            $sig = Test-Signer $installer
            if (-not $sig.Ok) {
                throw "the installer isn't signed by Hangzhou DeepSeek Artificial Intelligence Co., Ltd. (status $($sig.Status), signer '$($sig.Signer)')"
            }
            Write-Step "installing DeepSeek Harness $($feed.Version) (this can take a few minutes)"
            $code = Invoke-Installer -Path $installer -TimeoutSec $TimeoutSec
            if ($code -eq 2) {
                throw "the installer exited 2 (DeepSeek's installer refuses when the app is running, the install folder isn't empty or isn't writable, or the disk is full)"
            }
            if ($code -ne 0) { throw "the installer exited $code" }
            if (-not (Get-InstalledHarness $UninstallKey)) { throw 'the installer exited 0 but Windows lists no DeepSeek Harness' }
        } catch {
            $reason = ($_.Exception.Message -split "\r?\n")[0]
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
            [IO.File]::WriteAllText($rejectFile, "$($feed.Sha512)`n$reason`n")
            throw "$reason (skipping this build until DeepSeek publishes a new one; delete $rejectFile to retry)"
        }
        Remove-Item -LiteralPath $rejectFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ State = 'installed'; Version = $feed.Version }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $r = Install-Harness -FeedUrl $FeedUrl -Prefix $InstallerPrefix -UninstallKey $UninstallKey -WorkDir $WorkDir -StateDir $StateDir -TimeoutSec $TimeoutSec
    if ($r.State -eq 'present') { Write-Step "DeepSeek Harness $($r.Version) is installed; it updates itself" }
    else { Write-Step "installed DeepSeek Harness $($r.Version); it updates itself from now on" }
} catch {
    Write-Step "not installed: $($_.Exception.Message)"
}
exit 0
