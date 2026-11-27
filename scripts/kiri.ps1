#Requires -Version 5.1
# =============================================================================
# kiri.ps1 -- install Kiri, the container engine and its window, when it is missing, for
# this user, on a Windows host that has WSL.
#
# Run by config.windows.toml's `kiri-win` task (the post-tools hook, so bootstrap.ps1 and
# wsu). Kiri (https://runkiri.com) runs containers in a WSL distro of its own (`kiri`) and
# serves the Docker API on the named pipe \\.\pipe\kiri: `docker`, `docker compose` and
# `docker buildx` from %LOCALAPPDATA%\Kiri\bin on the `kiri` context. In the WSL distro,
# ~/.local/bin/kiri-docker runs that same CLI through interop and tasks/kiri makes it
# `docker` there; this script is only the Windows side.
#
#   1. Stop when <AppDir>\kiri-win.exe exists: Kiri updates itself (its own feed check),
#      and no network request is made here.
#   2. Stop when no WSL distro is registered: Kiri's setup would ask for administrator
#      rights to install WSL, and this hook never raises UAC.
#   3. Read the release feed (<FeedBase>/latest-windows-<arch>.json: version, url, sha256)
#      and refuse anything that isn't a usable one (Read-Feed: a version, the URL exactly
#      <FeedBase>/Kiri-<version>-<arch>.msi, a SHA-256). Download the MSI, refuse it unless
#      its SHA-256 is the feed's, then `msiexec /i <msi> /qn /norestart`: Kiri's installer
#      is per-user and needs no administrator rights. 0 and 3010 (restart wanted) count as
#      installed, and only when kiri-win.exe is then there.
#   4. Say what is left: Kiri's first-run setup is a window and has no command line, so
#      the person opens Kiri once and chooses "Kiri Linux" (its own small distro; never a
#      development distro: Kiri's engine would then share it). <AppDir>\setup.json says
#      whether that is done.
# Unlike herdr-app.ps1 this runs what it downloads: an MSI can't be unpacked into place.
# Kiri's installers aren't code-signed yet (its docs), so the check is the feed's SHA-256
# over HTTPS, the one Kiri's own updater uses.
# It never enables Kiri's Kubernetes or sharing, never touches the docker context (Kiri's
# setup creates `kiri`), and never moves containers from another engine: that is the
# person's (README: Kiri).
# Every failure warns and exits 0: a failing hook would stop `mise bootstrap`.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.
# scripts/test-kiri.ps1 tests it on file:// fixtures with a stand-in for msiexec; it never
# reaches the real %LOCALAPPDATA%\Kiri or the real installer.
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/kiri.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string]$FeedBase = 'https://download.runkiri.com',
    [string]$AppDir = (Join-Path $env:LOCALAPPDATA 'Kiri'),
    [string]$WorkDir = [IO.Path]::GetTempPath(),
    [string]$Msiexec = (Join-Path $env:SystemRoot 'System32\msiexec.exe'),
    [string]$LxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss',
    [string]$Arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' })
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "  kiri: $Message" }

# The version, MSI URL and SHA-256 (hex) in a release feed. The URL must be exactly
# <Base>/Kiri-<version>-<Arch>.msi. Throws a reason when the text isn't a usable feed.
function Read-Feed([string]$Text, [string]$Base, [string]$Arch) {
    try { $f = $Text | ConvertFrom-Json } catch { throw 'not JSON' }
    if ($null -eq $f -or $f.GetType().Name -cne 'PSCustomObject') { throw 'not a JSON object' }
    $names = @($f.PSObject.Properties.Name)
    foreach ($key in 'version', 'url', 'sha256') { if (-not ($names -contains $key)) { throw "no $key" } }
    $version = "$($f.version)"
    if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') { throw "bad version '$version'" }
    $url = "$($f.url)"
    $want = "$Base/Kiri-$version-$Arch.msi"
    if ($url -cne $want) { throw "installer URL '$url' isn't $want" }
    $sha = "$($f.sha256)"
    if ($sha -cnotmatch '^[0-9a-f]{64}$') { throw "sha256 isn't a SHA-256" }
    return [pscustomobject]@{ Version = $version; Url = $url; Sha256 = $sha }
}

# True when the file's SHA-256 (lower-case hex) is the expected one. Hashes a stream with
# .NET: Get-FileHash lives in a module that doesn't load when 5.1 inherits pwsh 7's
# PSModulePath.
function Test-Sha256([string]$Path, [string]$Expected) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $alg = [Security.Cryptography.SHA256]::Create()
        try { $actual = -join ($alg.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) } finally { $alg.Dispose() }
    } finally { $stream.Dispose() }
    return $actual -ceq $Expected
}

# curl.exe with bootstrap.ps1's Invoke-CurlRequest flags: retries, and a stalled transfer
# aborts instead of hanging; redirects over https only.
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

# The WSL distros registered for this user (HKCU Lxss; `wsl.exe -l` prints UTF-16).
function Get-WslDistro([string]$Key) {
    if (-not (Test-Path -LiteralPath $Key)) { return @() }
    $names = foreach ($sub in @(Get-ChildItem -LiteralPath $Key)) {
        $n = $sub.GetValue('DistributionName')
        if ($null -ne $n -and "$n") { "$n" }
    }
    return @($names)
}

# 'done' when Kiri's first-run setup finished (<AppDir>\setup.json's "done": true), else
# 'pending' (no file, not JSON, or not done).
function Get-SetupState([string]$AppDir) {
    $path = Join-Path $AppDir 'setup.json'
    if (-not (Test-Path -LiteralPath $path)) { return 'pending' }
    try { $s = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return 'pending' }
    if ($null -ne $s -and $s.GetType().Name -ceq 'PSCustomObject' -and
        ($s.PSObject.Properties.Name -contains 'done') -and $s.done -eq $true) { return 'done' }
    return 'pending'
}

# Kiri. State is 'present' (nothing fetched), 'no-wsl' (nothing fetched) or 'installed'.
# Throws a reason. The download folder is always removed.
function Install-Kiri([string]$FeedBase, [string]$Arch, [string]$AppDir, [string]$WorkDir, [string]$Msiexec, [string[]]$Distros) {
    $exe = Join-Path $AppDir 'kiri-win.exe'
    if (Test-Path -LiteralPath $exe) { return [pscustomobject]@{ State = 'present'; Version = '' } }
    if (-not ($Distros | Where-Object { $_ })) { return [pscustomobject]@{ State = 'no-wsl'; Version = '' } }
    $dir = Join-Path $WorkDir ('kiri-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        $feedUrl = "$FeedBase/latest-windows-$Arch.json"
        try {
            $file = Join-Path $dir 'latest.json'
            Get-Url $feedUrl $file
            $f = Read-Feed ([IO.File]::ReadAllText($file)) $FeedBase $Arch
        } catch {
            throw "the release feed $feedUrl isn't usable: $($_.Exception.Message)"
        }
        Write-Step "downloading Kiri $($f.Version)"
        $msi = Join-Path $dir "Kiri-$($f.Version)-$Arch.msi"
        Get-Url $f.Url $msi
        if (-not (Test-Sha256 $msi $f.Sha256)) { throw "the download's SHA-256 doesn't match the feed's" }
        $p = Start-Process -FilePath $Msiexec -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "the installer exited $($p.ExitCode)" }
        if (-not (Test-Path -LiteralPath $exe)) { throw "the installer finished but $exe isn't there" }
        return [pscustomobject]@{ State = 'installed'; Version = $f.Version }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $r = Install-Kiri -FeedBase $FeedBase.TrimEnd('/') -Arch $Arch -AppDir $AppDir -WorkDir $WorkDir -Msiexec $Msiexec -Distros (Get-WslDistro $LxssKey)
    if ($r.State -eq 'no-wsl') {
        Write-Step 'no WSL distro is registered: Kiri not installed (it runs its engine in WSL)'
    } else {
        if ($r.State -eq 'installed') { Write-Step "installed Kiri $($r.Version) (Start menu: Kiri); it updates itself from now on" }
        if ((Get-SetupState $AppDir) -eq 'done') {
            if ($r.State -eq 'present') { Write-Step 'Kiri is installed and set up; it updates itself' }
        } else {
            Write-Step 'open Kiri once to finish its setup, and choose "Kiri Linux" as its distro; then ws update in the WSL distro makes docker there Kiri''s'
        }
    }
} catch {
    Write-Step "Kiri was not installed: $($_.Exception.Message)"
}
exit 0
