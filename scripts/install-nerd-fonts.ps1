#Requires -Version 5.1
# =============================================================================
# install-nerd-fonts.ps1 — install JetBrainsMono Nerd Font Mono per-user.
#
# Invoked by bootstrap.ps1 (NOT directly). Downloads JetBrainsMono.zip from
# ryanoasis/nerd-fonts, verifies its SHA256 against the hard-coded pin below,
# extracts the six Mono variants, copies them to %LOCALAPPDATA%\Microsoft\Windows\Fonts\,
# and registers them (by FULL PATH — bare filenames resolve only against
# C:\Windows\Fonts, so an HKCU bare-name entry never loads at logon) in
# HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts
# (per-user — no admin needed; bootstrap.ps1 itself runs WITHOUT elevation), then
# ACTIVATES them in the current logon session via AddFontResourceW + a
# WM_FONTCHANGE broadcast (Invoke-FontActivation) so the font is usable
# immediately. Because Windows does NOT reliably load HKCU per-user fonts into the
# system font collection at logon (so the font can vanish after a reboot), it also
# registers a per-logon scheduled task (Register-FontLogonTask) that re-runs that
# activation at every sign-in — the durable, admin-free guarantee. Honours
# $env:GITHUB_TOKEN (Authorization: Bearer header) to avoid the 60-req/hour
# unauthenticated GitHub rate limit.
#
# Idempotency: a no-op fast path returns early if a stamp file exists at
#   %LOCALAPPDATA%\workstation\nerd-fonts.<VERSION>.stamp
# AND all six TTFs are present AND all six HKCU registrations exist with
# full-path values (it still re-runs the cheap session activation + re-registers
# the per-logon task first, so a host provisioned by an older build — registered
# but never activated, or registered by bare filename — goes live without a
# logout). Otherwise stale installs are swept
# (file + registry) before depositing the new set, which also rewrites the
# bare-filename registrations left by older builds of this script as full paths.
#
# Hard-fails on download or SHA256 issues (bootstrap.ps1 aborts). Soft-fails
# on registry-write failure (Windows Terminal/Zed/VS Code may not see the font until
# manual registration via Settings → Personalization → Fonts).
#
# Version + SHA256 are pinned in the script body — must mirror
# JETBRAINSMONO_NERD_VERSION in makefile/versions.mk + the per-version SHA in
# makefile/lib/font.sh (zip vs tar.xz hashes differ — see CLAUDE.md dual-edit
# invariant).
# =============================================================================

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Version = '3.5.1'
$Sha256  = 'fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e'

$FontFamily = 'JetBrainsMonoNerdFontMono'
$FontDir    = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$StampDir   = Join-Path $env:LOCALAPPDATA 'workstation'
$StampFile  = Join-Path $StampDir "nerd-fonts.$Version.stamp"
$RegPath    = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

$Variants  = @('Regular', 'Italic', 'Bold', 'BoldItalic', 'Medium', 'MediumItalic')
$FontFiles = $Variants | ForEach-Object { "$FontFamily-$_.ttf" }

# Kept self-contained: bootstrap also runs from memory before the repo exists.
# The font script carries the same helper for its independent execution context.
function Invoke-CurlRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{},
        [string]$OutFile
    )

    # Get-Command lists EVERY curl.exe on PATH (System32 + Git's mingw64\bin is
    # the everyday case) - take the first, i.e. the one a bare `curl.exe` runs.
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl) {
        throw 'curl.exe is required on PATH. Restore the Windows system curl or install it from https://curl.se/windows/ and reopen your shell.'
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    $headerFile = $null
    try {
        # --speed-limit/--speed-time: a connected-but-stalled transfer aborts
        # (exit 28, which --retry treats as transient) instead of hanging forever.
        $curlArgs = @('--disable', '--fail', '--silent', '--show-error', '--location',
            '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30',
            '--speed-limit', '1', '--speed-time', '60',
            '--output', $tempFile)
        if ($Headers.Count -gt 0) {
            # Headers travel via a file, never argv: a PAT on a command line is
            # visible to process auditing. One header per line; no BOM, or curl
            # would send it as part of the first header name.
            $headerFile = [System.IO.Path]::GetTempFileName()
            $headerLines = @(foreach ($key in $Headers.Keys) { '{0}: {1}' -f $key, $Headers[$key] })
            [System.IO.File]::WriteAllLines($headerFile, [string[]]$headerLines, [System.Text.UTF8Encoding]::new($false))
            $curlArgs += @('--header', "@$headerFile")
        }
        $curlArgs += @('--url', $Uri)
        # PS 5.1 can turn redirected native stderr into PowerShell errors;
        # PS 7 can optionally throw on native exit codes. Handle both ourselves.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $curlOutput = & $curl.Source @curlArgs 2>&1
        $curlExitCode = $LASTEXITCODE
        if ($curlExitCode -ne 0) {
            # --silent --show-error leaves only curl's own diagnostic on stderr
            # (e.g. "curl: (22) The requested URL returned error: 404"); surface it.
            $detail = ((@($curlOutput) | ForEach-Object { "$_".Trim() }) -join ' ').Trim()
            throw "curl.exe request failed (exit $curlExitCode): $Uri [$detail]"
        }
        if ($OutFile) {
            Move-Item -LiteralPath $tempFile -Destination $OutFile -Force -ErrorAction Stop
        } else {
            [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8)
        }
    } finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        if ($headerFile) { Remove-Item -LiteralPath $headerFile -Force -ErrorAction SilentlyContinue }
    }
}

function Test-Installed {
    if (-not (Test-Path $StampFile)) { return $false }
    foreach ($f in $FontFiles) {
        if (-not (Test-Path (Join-Path $FontDir $f))) { return $false }
    }
    $reg = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if (-not $reg) { return $false }
    foreach ($f in $FontFiles) {
        $regName = "$([System.IO.Path]::GetFileNameWithoutExtension($f)) (TrueType)"
        $prop = $reg.PSObject.Properties[$regName]
        if (-not $prop) { return $false }
        # Per-user font registrations MUST store the FULL PATH, not a bare filename:
        # a bare name resolves only against C:\Windows\Fonts (the implicit base for
        # HKLM/machine fonts), so an HKCU bare-name entry silently fails to load at
        # logon and the font stays invisible to DirectWrite apps (Windows Terminal,
        # Zed, VS Code) — even though the .ttf is present + the entry exists. Treat a
        # stale bare-name registration (from an older build of this script) as
        # not-installed so the fresh-install path below rewrites it with full paths.
        if ($prop.Value -ne (Join-Path $FontDir $f)) { return $false }
    }
    return $true
}

# Activate the installed fonts in the CURRENT logon session. HKCU registration
# alone does NOT reliably load per-user fonts into the system font collection at
# logon (the per-user fonts dir "has no special powers" — it is deliberately
# excluded from the KnownFolder API), so without this the font stays invisible to
# every app (Zed, VS Code, terminals) in this session. AddFontResourceW loads each
# face into the session font table; the WM_FONTCHANGE broadcast tells
# already-running apps to refresh. Idempotent (AddFontResourceW just bumps a
# refcount if a face is already loaded) and soft-fail — it must never abort; the
# per-logon task (Register-FontLogonTask) re-runs this at every future sign-in, so
# a transient failure here self-corrects next logon.
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
        Write-Warning ("Font session-activation failed ($_). The per-logon task " +
            "re-activates it at your next sign-in.")
    }
}

# Register a per-user, no-admin scheduled task that re-runs the AddFontResourceW
# activation at EVERY logon. This is the durability guarantee: Windows does not
# reliably load HKCU-registered per-user fonts into the DirectWrite/GDI system
# font collection at logon, so without this the font can silently disappear from
# Windows Terminal / Zed / VS Code after a reboot even though it is installed and
# registered. AddFontResourceW (run in the user's interactive session) IS proven
# to make the font visible to apps launched afterwards, so a task that runs it
# AtLogOn closes the gap. The task runs a self-contained activation script
# deposited next to the stamp (no dependency on the repo checkout, which may move),
# hidden, as the current user with their interactive token (LogonType Interactive
# → it affects the live session; RunLevel Limited → no elevation). Idempotent
# (-Force replaces in place) and soft-fail; re-registered every run so a deleted
# task or a host seeded by an older build self-heals on the next bootstrap.
function Register-FontLogonTask {
    try {
        New-Item -ItemType Directory -Path $StampDir -Force | Out-Null
        $activateScript = Join-Path $StampDir 'activate-nerd-fonts.ps1'
        # Self-contained: globs the per-user fonts dir for our faces and loads each
        # via AddFontResourceW + a WM_FONTCHANGE broadcast. Matches by filename
        # prefix so a font-version bump needs no change to the task or this script.
        $body = @'
$ErrorActionPreference = "SilentlyContinue"
$fdir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
Add-Type -Namespace Workstation -Name FontLogon -MemberDefinition @"
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)] public static extern int AddFontResourceW(string lpszFilename);
[DllImport("user32.dll")] public static extern int SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
"@
Get-ChildItem $fdir -Filter "JetBrainsMonoNerdFontMono-*.ttf" -ErrorAction SilentlyContinue |
    ForEach-Object { [Workstation.FontLogon]::AddFontResourceW($_.FullName) | Out-Null }
$res = [IntPtr]::Zero
[Workstation.FontLogon]::SendMessageTimeout([IntPtr]0xffff, 0x001D, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1000, [ref]$res) | Out-Null
'@
        Set-Content -Path $activateScript -Value $body -Encoding UTF8

        $taskName  = 'WorkstationNerdFontActivate'
        $whoami    = "$env:USERDOMAIN\$env:USERNAME"
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$activateScript`""
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $whoami
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        $principal = New-ScheduledTaskPrincipal -UserId $whoami -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Write-Host "  registered per-logon font-activation task ($taskName)"
    } catch {
        Write-Warning ("Could not register the per-logon font-activation task ($_). " +
            "The font is active now, but to survive a reboot it may need a re-run of " +
            "bootstrap.ps1 (or a manual sign-out) afterwards.")
    }
}

if (Test-Installed) {
    Invoke-FontActivation
    Register-FontLogonTask
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
Invoke-CurlRequest -Uri $Url -OutFile $Archive -Headers $Headers

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
        # FULL PATH, not the bare filename — see Test-Installed for why HKCU
        # per-user fonts won't load at logon when registered by bare name.
        New-ItemProperty -Path $RegPath -Name $regName -Value (Join-Path $FontDir $f) `
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
# Invoke-FontActivation definition above) and register the per-logon re-activation
# task so the font survives reboots.
Invoke-FontActivation
Register-FontLogonTask

if ($RegistrationFailed) {
    Write-Warning ("Some HKCU registrations failed — Windows Terminal/Zed/VS Code may not " +
        "see the font until manual registration (Settings → Personalization " +
        "→ Fonts).")
} else {
    Write-Host "  installed + activated 6 Mono variants ($FontDir + HKCU)"
}
