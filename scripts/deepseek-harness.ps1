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
    [int]$TimeoutSec = 900
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "  deepseek-harness: $Message" }

# The version, installer URL and SHA-512 (base64) of an electron-updater feed. Only
# top-level keys count (files[] entries are indented), and a value may be a one-line
# scalar (optionally quoted) or a folded/literal block. Throws a reason when the text
# isn't a usable feed.
function Read-Feed([string]$Text, [string]$Prefix) {
    $lines = $Text -split "\r?\n"
    $v = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(version|path|sha512):\s*(.*)$') {
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
