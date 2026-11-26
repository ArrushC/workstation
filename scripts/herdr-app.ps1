#Requires -Version 5.1
# =============================================================================
# herdr-app.ps1 -- install the Herdr desktop app, and herdr-core (hc) beside it, when
# they are missing, for this user.
#
# Run by config.windows.toml's `herdr-app-win` task (the post-tools hook, so
# bootstrap.ps1 and wsu). Herdr is the window onto herdr-core's terminals: the ones on
# this PC, and each Linux host's kept shells (add a host in the app, or
# `hc machine add <ssh host>`; the WSL distro: `hc machine add --via 'wsl.exe -d
# <distro> -e sh -c' --name wsl`, typed in pwsh 7). The Linux hosts get herdr-core from
# mise (config.linux.toml's http:herdr-core); this script is only the Windows side.
#
# It does what Herdr's own installers do (releases.herdr.dev/app/install.ps1 and
# core/install.ps1), without piping a download into iex:
#   1. the app: stop there when <AppDir>\herdr-app.exe exists (the app updates itself;
#      no network request is made). Else read app/latest.json, refuse anything that isn't
#      a usable manifest (Read-Manifest: a version, a windows-x86_64 archive under the
#      release prefix, a SHA-256), download it, refuse it unless its SHA-256 matches,
#      unpack it with Windows' tar into <AppDir>, add a Start menu shortcut and put
#      <AppDir> on the user PATH;
#   2. herdr-core: skipped when <CoreDir>\herdr-core.exe exists or a herdr-core is on
#      PATH (the app keeps it current). Else the same from core/latest.json: the zip's
#      herdr-core.exe and conpty\ into <CoreDir>, hc.exe linked to it unless something
#      else answers to hc, <CoreDir> on the user PATH.
# Nothing downloaded is run here. The check is the manifest's SHA-256 over HTTPS, as in
# Herdr's installers: releases are not always Authenticode-signed (herdr-core's
# docs/security.md), so a signature is not required.
# Every failure warns and exits 0: a failing hook would stop `mise bootstrap`.
# ASCII only: Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.
# scripts/test-herdr-app.ps1 tests it on file:// fixtures in throwaway folders; it never
# touches the real install folders, Start menu or PATH.
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/herdr-app.ps1
# =============================================================================
[CmdletBinding()]
param(
    [string]$ReleasesUrl = 'https://releases.herdr.dev',
    [string]$AppDir = (Join-Path $env:LOCALAPPDATA 'Programs\herdr-app'),
    [string]$CoreDir = (Join-Path $env:LOCALAPPDATA 'Programs\herdr-core'),
    [string]$MenuDir = [Environment]::GetFolderPath('Programs'),
    [string]$WorkDir = [IO.Path]::GetTempPath(),
    [switch]$NoPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) { Write-Host "  herdr: $Message" }

# The version, archive URL and SHA-256 (hex) for $Target in a release manifest
# (latest.json). The URL must be <Prefix><version>/<one file name ending in $Ext>.
# Throws a reason when the text isn't a usable manifest.
function Read-Manifest([string]$Text, [string]$Prefix, [string]$Ext, [string]$Target = 'windows-x86_64') {
    try { $m = $Text | ConvertFrom-Json } catch { throw 'not JSON' }
    if ($null -eq $m -or $m -is [string] -or -not ($m.PSObject.Properties.Name -contains 'version')) { throw 'no version' }
    $version = "$($m.version)"
    if ($version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') { throw "bad version '$version'" }
    if (-not ($m.PSObject.Properties.Name -contains 'targets') -or $null -eq $m.targets -or
        -not ($m.targets.PSObject.Properties.Name -contains $Target)) { throw "no $Target build" }
    $t = $m.targets.$Target
    $names = @($t.PSObject.Properties.Name)
    if (-not ($names -contains 'url') -or -not ($names -contains 'sha256')) { throw "no url or sha256 for $Target" }
    $url = "$($t.url)"
    $sha = "$($t.sha256)"
    $base = "$Prefix$version/"
    $inside = $url.StartsWith($base, [StringComparison]::Ordinal)
    $rest = if ($inside) { $url.Substring($base.Length) } else { '' }
    if (-not $inside -or $rest -cnotmatch '^[A-Za-z0-9._-]+$' -or $rest.Contains('..') -or
        -not $rest.EndsWith($Ext, [StringComparison]::Ordinal)) {
        throw "archive URL '$url' isn't one $Ext under $base"
    }
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

# Unpacks a .tar.gz or .zip with Windows' own tar (bsdtar reads both; Git Bash's tar,
# often first on PATH, takes C:\ for a remote host).
function Expand-Release([string]$Archive, [string]$Into) {
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { throw 'no System32\tar.exe (Windows 10 1803 or newer has one)' }
    New-Item -ItemType Directory -Force -Path $Into | Out-Null
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & $tar -xf $Archive -C $Into 2>&1
    if ($LASTEXITCODE -ne 0) { throw "tar could not unpack $(Split-Path -Leaf $Archive): $((@($out) | ForEach-Object { "$_".Trim() }) -join ' ')" }
}

# Appends $Dir to the user PATH unless it is listed. Reads and writes the raw registry
# value, so %VARIABLES% in it stay unexpanded and it keeps its type. Returns $true when
# it added it.
function Add-UserPath([string]$Dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $want = $Dir.TrimEnd('\')
        foreach ($p in ($raw -split ';')) { if ($p.Trim().TrimEnd('\') -ieq $want) { return $false } }
        $kind = if (@($key.GetValueNames()) -contains 'Path') { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $new = if ($raw) { "$($raw.TrimEnd(';'));$Dir" } else { $Dir }
        $key.SetValue('Path', $new, $kind)
    } finally { $key.Close() }
    # Setting any user variable tells running programs the environment changed.
    [Environment]::SetEnvironmentVariable('HERDR_INSTALLING', '1', 'User')
    [Environment]::SetEnvironmentVariable('HERDR_INSTALLING', $null, 'User')
    return $true
}

# Downloads the manifest's build into a new folder under $WorkDir, checks it, and hands
# the unpacked folder to $Place. The folder is always removed.
function Install-Release([string]$What, [string]$ManifestUrl, [string]$Prefix, [string]$Ext, [string]$WorkDir, [scriptblock]$Place) {
    $dir = Join-Path $WorkDir ('herdr-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        try {
            $file = Join-Path $dir 'latest.json'
            Get-Url $ManifestUrl $file
            $m = Read-Manifest ([IO.File]::ReadAllText($file)) $Prefix $Ext
        } catch {
            throw "the release manifest $ManifestUrl isn't usable: $($_.Exception.Message)"
        }
        Write-Step "downloading $What $($m.Version)"
        $archive = Join-Path $dir ($m.Url.Substring($m.Url.LastIndexOf('/') + 1))
        Get-Url $m.Url $archive
        if (-not (Test-Sha256 $archive $m.Sha256)) { throw "the download's SHA-256 doesn't match the manifest's" }
        $out = Join-Path $dir 'out'
        Expand-Release $archive $out
        & $Place $out
        return $m.Version
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The app. State is 'present' (nothing fetched) or 'installed'. Throws a reason.
function Install-App([string]$ReleasesUrl, [string]$AppDir, [string]$MenuDir, [string]$WorkDir, [bool]$SetPath = $true) {
    $exe = Join-Path $AppDir 'herdr-app.exe'
    if (Test-Path -LiteralPath $exe) { return [pscustomobject]@{ State = 'present'; Version = '' } }
    $version = Install-Release 'the Herdr app' "$ReleasesUrl/app/latest.json" "$ReleasesUrl/app/" '.tar.gz' $WorkDir {
        param($out)
        $new = Join-Path $out 'herdr-app'
        if (-not (Test-Path -LiteralPath (Join-Path $new 'herdr-app.exe'))) { throw 'the download holds no herdr-app\herdr-app.exe' }
        New-Item -ItemType Directory -Force -Path (Split-Path $AppDir) | Out-Null
        # A folder without the exe is a broken leftover: nothing runs from it.
        if (Test-Path -LiteralPath $AppDir) { Remove-Item -LiteralPath $AppDir -Recurse -Force }
        Move-Item -LiteralPath $new -Destination $AppDir
    }
    New-Item -ItemType Directory -Force -Path $MenuDir | Out-Null
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $MenuDir 'Herdr.lnk'))
    $link.TargetPath = $exe
    $link.WorkingDirectory = $env:USERPROFILE
    $link.Description = 'Terminals and coding agents that keep running'
    $link.Save()
    if ($SetPath) { $null = Add-UserPath $AppDir }
    return [pscustomobject]@{ State = 'installed'; Version = $version }
}

# herdr-core. State is 'present' (in $CoreDir, or another one on PATH) or 'installed'.
function Install-Core([string]$ReleasesUrl, [string]$CoreDir, [string]$WorkDir, [bool]$SetPath = $true) {
    $exe = Join-Path $CoreDir 'herdr-core.exe'
    if (Test-Path -LiteralPath $exe) { return [pscustomobject]@{ State = 'present'; Version = ''; Where = $exe } }
    $other = Get-Command herdr-core -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($other) { return [pscustomobject]@{ State = 'present'; Version = ''; Where = $other.Source } }
    $version = Install-Release 'herdr-core' "$ReleasesUrl/core/latest.json" "$ReleasesUrl/core/" '.zip' $WorkDir {
        param($out)
        if (-not (Test-Path -LiteralPath (Join-Path $out 'herdr-core.exe')) -or
            -not (Test-Path -LiteralPath (Join-Path $out 'conpty\conpty.dll'))) { throw 'the download holds no complete hc (herdr-core.exe and conpty\conpty.dll)' }
        New-Item -ItemType Directory -Force -Path $CoreDir | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $out 'conpty') -Destination $CoreDir
        Copy-Item -Force -Path (Join-Path $out 'THIRD-PARTY-NOTICES') -Destination $CoreDir -ErrorAction SilentlyContinue
        # The exe last: its presence is what marks the install complete.
        Copy-Item -Force -LiteralPath (Join-Path $out 'herdr-core.exe') -Destination $exe
    }
    $hc = Join-Path $CoreDir 'hc.exe'
    if (-not (Test-Path -LiteralPath $hc) -and -not (Get-Command hc -CommandType Application -ErrorAction SilentlyContinue)) {
        New-Item -ItemType HardLink -Path $hc -Target $exe | Out-Null
    }
    if ($SetPath) { $null = Add-UserPath $CoreDir }
    return [pscustomobject]@{ State = 'installed'; Version = $version; Where = $exe }
}

$base = $ReleasesUrl.TrimEnd('/')
try {
    $r = Install-App -ReleasesUrl $base -AppDir $AppDir -MenuDir $MenuDir -WorkDir $WorkDir -SetPath (-not $NoPath)
    if ($r.State -eq 'present') { Write-Step 'the Herdr app is installed; it updates itself' }
    else { Write-Step "installed the Herdr app $($r.Version) (Start menu: Herdr); it updates itself from now on" }
} catch {
    Write-Step "the Herdr app was not installed: $($_.Exception.Message)"
}
try {
    $r = Install-Core -ReleasesUrl $base -CoreDir $CoreDir -WorkDir $WorkDir -SetPath (-not $NoPath)
    if ($r.State -eq 'present') { Write-Step "herdr-core is installed ($($r.Where)); the app keeps it current" }
    else { Write-Step "installed herdr-core $($r.Version) (hc in new terminals); the app keeps it current" }
} catch {
    Write-Step "herdr-core was not installed: $($_.Exception.Message)"
}
exit 0
