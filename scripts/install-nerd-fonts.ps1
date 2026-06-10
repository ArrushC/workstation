#Requires -Version 5.1
# =============================================================================
# install-nerd-fonts.ps1 — install JetBrainsMono Nerd Font Mono per-user.
#
# Invoked by bootstrap.ps1 (NOT directly). Downloads JetBrainsMono.zip from
# ryanoasis/nerd-fonts, verifies its SHA256 against the hard-coded pin below,
# extracts the six Mono variants, copies them to %LOCALAPPDATA%\Microsoft\Windows\Fonts\,
# and registers them in HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts
# (per-user — no admin needed for the registration even though bootstrap.ps1
# runs elevated), then ACTIVATES them in the current logon session via
# AddFontResourceW + a WM_FONTCHANGE broadcast (Invoke-FontActivation) so the
# font is usable immediately — without it, HKCU registration is honoured only at
# the next logon and the font stays invisible to every app until then. Honours
# $env:GITHUB_TOKEN (Authorization: Bearer header) to avoid the 60-req/hour
# unauthenticated GitHub rate limit.
#
# Idempotency: a no-op fast path returns early if a stamp file exists at
#   %LOCALAPPDATA%\workstation\nerd-fonts.<VERSION>.stamp
# AND all six TTFs are present AND all six HKCU registrations exist (it still
# re-runs the cheap session activation first, so a host provisioned by an older
# build — registered but never activated — goes live without a logout). Otherwise
# stale installs are swept (file + registry) before depositing the new set.
#
# Hard-fails on download or SHA256 issues (bootstrap.ps1 aborts). Soft-fails
# on registry-write failure (WezTerm still works via config.font_dirs;
# Zed/VS Code may not see the font until manual registration via Settings →
# Personalization → Fonts).
#
# Version + SHA256 are pinned in the script body — must mirror
# JETBRAINSMONO_NERD_VERSION in makefile/versions.mk + the per-version SHA in
# makefile/lib/font.sh (zip vs tar.xz hashes differ — see CLAUDE.md dual-edit
# invariant).
# =============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Version = '3.4.0'
$Sha256  = '76f05ff3ace48a464a6ca57977998784ff7bdbb65a6d915d7e401cd3927c493c'

$FontFamily = 'JetBrainsMonoNerdFontMono'
$FontDir    = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$StampDir   = Join-Path $env:LOCALAPPDATA 'workstation'
$StampFile  = Join-Path $StampDir "nerd-fonts.$Version.stamp"
$RegPath    = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

$Variants  = @('Regular', 'Italic', 'Bold', 'BoldItalic', 'Medium', 'MediumItalic')
$FontFiles = $Variants | ForEach-Object { "$FontFamily-$_.ttf" }

function Test-Installed {
    if (-not (Test-Path $StampFile)) { return $false }
    foreach ($f in $FontFiles) {
        if (-not (Test-Path (Join-Path $FontDir $f))) { return $false }
    }
    $reg = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if (-not $reg) { return $false }
    foreach ($f in $FontFiles) {
        $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($f)) (TrueType)"
        if (-not $reg.PSObject.Properties[$regName]) { return $false }
    }
    return $true
}

# Activate the installed fonts in the CURRENT logon session. HKCU registration
# alone is honoured only at the NEXT logon, so without this the font stays
# invisible to every app (Zed, VS Code, terminals) until the user logs out and
# back in. AddFontResourceW loads each face into the session font table; the
# WM_FONTCHANGE broadcast tells already-running apps to refresh. Idempotent
# (AddFontResourceW just bumps a refcount if a face is already loaded) and
# soft-fail — a failure here only costs the user one logout, since the persistent
# HKCU entry still activates the font at the next logon, so it must never abort.
function Invoke-FontActivation {
    try {
        if (-not ([System.Management.Automation.PSTypeName]'Workstation.FontActivator').Type) {
            Add-Type -Namespace Workstation -Name FontActivator -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
public static extern int AddFontResourceW(string lpszFilename);
[DllImport("user32.dll")]
public static extern int SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
'@
        }
        foreach ($f in $FontFiles) {
            $p = Join-Path $FontDir $f
            if (Test-Path $p) { [Workstation.FontActivator]::AddFontResourceW($p) | Out-Null }
        }
        # HWND_BROADCAST = 0xffff, WM_FONTCHANGE = 0x001D, SMTO_ABORTIFHUNG = 0x0002
        $res = [IntPtr]::Zero
        [Workstation.FontActivator]::SendMessageTimeout(
            [IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1000, [ref]$res) | Out-Null
    } catch {
        Write-Warning ("Font session-activation failed ($_). The font will still " +
            "activate at your next logon (HKCU registration is in place).")
    }
}

if (Test-Installed) {
    Invoke-FontActivation
    Write-Host "  nerd-fonts already installed (v$Version)"
    return
}

Write-Host "==> Installing JetBrainsMono Nerd Font Mono v$Version"

# Sweep stale install (files + HKCU entries) before depositing the new set.
# Guards against upstream renaming TTF files between releases.
if (Test-Path $FontDir) {
    Get-ChildItem -Path $FontDir -Filter "$FontFamily-*.ttf" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue }
}
$reg = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
if ($reg) {
    $reg.PSObject.Properties |
        Where-Object { $_.Name -like "$FontFamily-*" } |
        ForEach-Object {
            Remove-ItemProperty -Path $RegPath -Name $_.Name -ErrorAction SilentlyContinue
        }
}

# Download with optional GitHub auth.
$Url     = "https://github.com/ryanoasis/nerd-fonts/releases/download/v$Version/JetBrainsMono.zip"
$Headers = @{}
if ($env:GITHUB_TOKEN) {
    $Headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}

$TmpDir = Join-Path $env:TEMP "nerd-fonts-$Version"
if (Test-Path $TmpDir) { Remove-Item -Recurse -Force $TmpDir }
New-Item -ItemType Directory -Path $TmpDir | Out-Null

$Archive = Join-Path $TmpDir 'JetBrainsMono.zip'
Write-Host "  downloading $Url"
Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Archive -Headers $Headers

# Verify SHA256.
$Actual = (Get-FileHash -Algorithm SHA256 -Path $Archive).Hash.ToLower()
if ($Actual -ne $Sha256.ToLower()) {
    throw "SHA256 mismatch for v${Version}: expected $Sha256, got $Actual"
}

# Extract.
$Extract = Join-Path $TmpDir 'extract'
Expand-Archive -Path $Archive -DestinationPath $Extract -Force

# Ensure font + stamp dirs exist.
New-Item -ItemType Directory -Path $FontDir  -Force | Out-Null
New-Item -ItemType Directory -Path $StampDir -Force | Out-Null

# Copy the six Mono variants.
$Copied = 0
foreach ($f in $FontFiles) {
    $src = Get-ChildItem -Path $Extract -Filter $f -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $src) { throw "Expected $f not found in extracted archive" }
    Copy-Item -Path $src.FullName -Destination (Join-Path $FontDir $f) -Force
    $Copied++
}
if ($Copied -ne 6) { throw "Copied $Copied of 6 expected TTF files" }

# Register in HKCU (per-user). Soft-fail per-file: if any one registration is
# blocked, continue with the rest and flag at the end.
$RegistrationFailed = $false
foreach ($f in $FontFiles) {
    $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($f)) (TrueType)"
    try {
        New-ItemProperty -Path $RegPath -Name $regName -Value $f `
            -PropertyType String -Force | Out-Null
    } catch {
        Write-Warning "Failed to register $regName in HKCU: $_"
        $RegistrationFailed = $true
    }
}

# Cleanup temp.
Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue

# Stamp.
Set-Content -Path $StampFile -Value $Version -Encoding ASCII

# Activate the new faces in the current session (no logout needed — see the
# Invoke-FontActivation definition above).
Invoke-FontActivation

if ($RegistrationFailed) {
    Write-Warning ("Some HKCU registrations failed — WezTerm will work via " +
        "config.font_dirs, but Zed/VS Code may not see the font until manual " +
        "registration (Settings → Personalization → Fonts).")
} else {
    Write-Host "  installed + activated 6 Mono variants ($FontDir + HKCU)"
}
