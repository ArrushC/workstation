#Requires -Version 5.1
# =============================================================================
# install-nerd-fonts.ps1 — register JetBrainsMono Nerd Font Mono for this user.
#
# Invoked by bootstrap.ps1 (Invoke-InstallNerdFonts), NOT directly, with
# -SourceDir = `mise where github:ryanoasis/nerd-fonts`: mise downloads and
# checks the font, whose pin lives only in config.toml (tasks/fonts
# uses the same tool on Linux). This script copies the six Mono variants from
# there to %LOCALAPPDATA%\Microsoft\Windows\Fonts\ (only the ones that differ),
# and registers them (by FULL PATH — bare filenames resolve only against
# C:\Windows\Fonts, so an HKCU bare-name entry never loads at logon) in
# HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts
# (per-user — no admin needed; bootstrap.ps1 itself runs WITHOUT elevation), then
# ACTIVATES them in the current logon session via AddFontResourceW + a
# WM_FONTCHANGE broadcast (Invoke-FontActivation) so the font is usable
# immediately. Because Windows does NOT reliably load HKCU per-user fonts into the
# system font collection at logon (so the font can vanish after a reboot), it also
# registers a per-logon scheduled task (Register-FontLogonTask) that re-runs that
# activation at every sign-in — the durable, admin-free guarantee.
#
# Idempotency: a no-op fast path returns early if the stamp file
#   %LOCALAPPDATA%\workstation\nerd-fonts.stamp
# holds the SHA256s of the six source TTFs AND all six TTFs are present AND all
# six HKCU registrations exist with full-path values (it still re-runs the cheap
# session activation + re-registers the per-logon task first, so a host
# provisioned by an older build — registered but never activated, or registered
# by bare filename — goes live without a logout). Otherwise TTFs of this family
# with other names are swept, each changed TTF is deleted and copied anew, and
# only then are the HKCU entries rewritten (which also turns the bare-filename
# registrations left by older builds into full paths).
#
# Hard-fails when a source TTF is missing or a changed TTF can't be replaced,
# before HKCU or the stamp change (bootstrap.ps1 warns and goes on).
# Soft-fails on registry-write failure (Windows Terminal/Zed/VS Code may not see
# the font until manual registration via Settings → Personalization → Fonts).
#
# -NoRegister is for scripts/test-python-fonts.ps1 only: copy and stamp, with no
# HKCU read or write, no session activation and no logon task.
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDir,
    [switch]$NoRegister
)

$ErrorActionPreference = 'Stop'

$FontFamily = 'JetBrainsMonoNerdFontMono'
$FontDir    = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
$StampDir   = Join-Path $env:LOCALAPPDATA 'workstation'
$StampFile  = Join-Path $StampDir 'nerd-fonts.stamp'
$RegPath    = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

$Variants  = @('Regular', 'Italic', 'Bold', 'BoldItalic', 'Medium', 'MediumItalic')
$FontFiles = $Variants | ForEach-Object { "$FontFamily-$_.ttf" }

# The stamp key: the six source TTFs' SHA256s. A missing one fails here,
# before anything installed is touched.
$SrcHash = @{}
foreach ($f in $FontFiles) {
    $p = Join-Path $SourceDir $f
    if (-not (Test-Path -LiteralPath $p)) {
        throw "$f not found in $SourceDir (mise's github:ryanoasis/nerd-fonts install; try: mise install github:ryanoasis/nerd-fonts)"
    }
    $SrcHash[$f] = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower()
}
$Key = ($FontFiles | ForEach-Object { $SrcHash[$_] }) -join ' '

function Test-Installed {
    if (-not (Test-Path $StampFile)) { return $false }
    if ([System.IO.File]::ReadAllText($StampFile).Trim() -ne $Key) { return $false }
    foreach ($f in $FontFiles) {
        if (-not (Test-Path (Join-Path $FontDir $f))) { return $false }
    }
    if ($NoRegister) { return $true }
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
    if (-not $NoRegister) {
        Invoke-FontActivation
        Register-FontLogonTask
    }
    Write-Host "  JetBrainsMono Nerd Font Mono already installed"
    return
}

Write-Host "==> Installing JetBrainsMono Nerd Font Mono from $SourceDir"
New-Item -ItemType Directory -Path $FontDir  -Force | Out-Null
New-Item -ItemType Directory -Path $StampDir -Force | Out-Null

# Sweep TTFs of this family that are not the six (upstream renamed one between
# releases).
Get-ChildItem -Path $FontDir -Filter "$FontFamily-*.ttf" -ErrorAction SilentlyContinue |
    Where-Object { $FontFiles -notcontains $_.Name } |
    ForEach-Object { Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue }

# Replace each variant that differs: delete, then copy. A loaded font (GDI via
# the logon task, Windows Terminal, Zed) shares Delete, so the delete frees the
# name, but its mapping blocks an in-place overwrite. An identical variant stays
# untouched. A failure stops here, before HKCU and the stamp, so the installed
# registrations stay and the next run retries.
$Copied = 0
foreach ($f in $FontFiles) {
    $dest = Join-Path $FontDir $f
    if ((Test-Path -LiteralPath $dest) -and
        ((Get-FileHash -Algorithm SHA256 -LiteralPath $dest).Hash.ToLower() -eq $SrcHash[$f])) { continue }
    try {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
        Copy-Item -LiteralPath (Join-Path $SourceDir $f) -Destination $dest -Force
    } catch {
        throw ("could not replace $dest ($($_.Exception.Message)). The HKCU registrations " +
            "are untouched and no stamp was written: the next .\bootstrap.ps1 run retries " +
            "(close Windows Terminal/Zed/VS Code first if this repeats).")
    }
    $Copied++
}

# Register in HKCU (per-user), only now that the files are in place: entries of
# this family with other names go, the six are (re)written. Soft-fail per-file:
# if any one registration is blocked, continue with the rest and flag at the end.
$RegistrationFailed = $false
if (-not $NoRegister) {
    $RegNames = $FontFiles | ForEach-Object { "$([System.IO.Path]::GetFileNameWithoutExtension($_)) (TrueType)" }
    $reg = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    if ($reg) {
        $reg.PSObject.Properties |
            Where-Object { $_.Name -like "$FontFamily-*" -and $RegNames -notcontains $_.Name } |
            ForEach-Object {
                Remove-ItemProperty -Path $RegPath -Name $_.Name -ErrorAction SilentlyContinue
            }
    }
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
}

# Stamp (the older builds' nerd-fonts.<version>.stamp files go too).
Get-ChildItem -Path $StampDir -Filter 'nerd-fonts*.stamp' -ErrorAction SilentlyContinue | Remove-Item -Force
[System.IO.File]::WriteAllText($StampFile, $Key)

# Activate the new faces in the current session (no logout needed — see the
# Invoke-FontActivation definition above) and register the per-logon re-activation
# task so the font survives reboots.
if (-not $NoRegister) {
    Invoke-FontActivation
    Register-FontLogonTask
}

if ($RegistrationFailed) {
    Write-Warning ("Some HKCU registrations failed — Windows Terminal/Zed/VS Code may not " +
        "see the font until manual registration (Settings → Personalization " +
        "→ Fonts).")
} else {
    Write-Host "  installed + activated 6 Mono variants ($Copied copied; $FontDir + HKCU)"
}
