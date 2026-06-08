# Windows installer-layout tools — auto-install Obsidian via its NSIS installer

**Date:** 2026-06-08
**Scope:** `bootstrap.ps1` (a new installer-tool install path + `-ForceInstaller` flag), `docs/windows/application_list.md`, and the docs that describe the Windows install surface (`README.html`, `CLAUDE.md`, `docs/claude/file-care.md`, `CLAUDE_CHANGELOG.md`).
**Status:** Design — pending user review.

## Goal

Add a third Windows tool-install class to `bootstrap.ps1` — **installer-layout** tools — for apps
that publish a silent-capable, admin-free installer (rather than a portable zip), and use it to
auto-install **Obsidian** on the Windows client. Today Obsidian is a manual entry in
`docs/windows/application_list.md`; after this change the bootstrap installs it unattended.

## Motivation

The existing `$PortableTools` mechanism only handles portable zips (download → verify sha256 →
extract → PATH). Obsidian does not ship a portable zip for Windows — its only Windows release asset
is an NSIS installer `.exe`. But that installer is per-user and silent-capable, so it still fits the
repo's hard "no elevation anywhere" rule. Rather than leave Obsidian as a manual install, we
generalize the bootstrap with an installer class so Obsidian (and future installer-only apps) come
up automatically.

## Facts established during research

- **Obsidian Windows release asset (via the GitHub API,
  `obsidianmd/obsidian-releases` → `releases/latest`, v1.12.7 at research time):** the *only* Windows
  asset is `Obsidian-1.12.7.exe` (~295 MB), an NSIS (electron-builder) installer. macOS gets `.dmg`,
  Linux gets AppImage/`.tar.gz`/`.deb`. **There is no portable `.zip` for Windows** — so it cannot
  use the `$PortableTools` "extract a zip" path.
- **Silent, admin-free install:** `Obsidian-<ver>.exe /S` performs a silent **per-user** install
  (verified: `/S` is the documented NSIS silent switch; the `/S /allusers` variant is machine-wide and
  needs admin — we deliberately use plain `/S`, no `/allusers`, to stay elevation-free).
- **GitHub API exposes a per-asset sha256 `digest`:** `releases/latest` returns each asset's
  `digest` as `sha256:<hex>` (verified: `Obsidian-1.12.7.exe` →
  `sha256:f35d2a35061098400a3fafc1bfd38d8bd33f1ad76df8b78b62ccdf20b0a30d26`). This lets us verify a
  **LATEST** download against GitHub's reported hash — no hand-pinned literal, but still a real
  sha256 check.
- **Install path is ambiguous / undocumented:** sources disagree between
  `%LOCALAPPDATA%\Programs\obsidian\Obsidian.exe` (electron-builder NSIS per-user default) and the
  older `%LOCALAPPDATA%\Obsidian`. A wrong hard-coded path would silently re-download ~295 MB on
  every bootstrap run. → presence is detected via the **uninstall registry**, not a filesystem path
  (see Design §3).
- **electron-builder NSIS per-user installs register an uninstall key** under
  `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*` with a `DisplayName` (Obsidian's
  `productName`). This is the canonical, path-independent "is it installed" signal, and a
  Control-Panel uninstall removes it.
- **Obsidian self-updates** after first install. So the bootstrap is an **initial seed only**;
  pinning a version is pointless — we install LATEST and let Obsidian's own updater take over.
- **Existing `bootstrap.ps1` shape (to mirror / not disturb):**
  - `param()` block has `-Skip*`, `-Reinstall`, `-Yes` switches.
  - `$PortableTools` = pinned (`Version` + `Sha256`) entries with `Layout` `single`/`tree`.
  - `Install-PortableTool` does: stamp gate (`<exe>.<version>.stamp` + `Get-Command`), TLS-1.2 line
    (`SecurityProtocol -bor 3072`), `Invoke-WebRequest`, sha256 hard-fail, extract, `Add-ToUserPath`.
  - `Invoke-ToolInstall` pre-creates dirs then loops `$PortableTools` (after `Install-Chezmoi`).
  - `Add-ToUserPath` appends a dir to the User PATH.

## Design

### 1. New `$InstallerTools` list + `Install-InstallerTool` function (separate from portable)

Add a new manifest array and a dedicated function rather than branching inside
`Install-PortableTool`. The installer flow diverges from portable on nearly every axis — LATEST
resolution (no version pin), digest from the API (no literal pin), registry presence check (no
version stamp), silent-run (no extract), and **no PATH entry** — so a shared function would be mostly
conditionals. Keeping the portable path untouched also respects CLAUDE.md's "don't destabilize the
working Windows install path" posture.

Each `$InstallerTools` entry:

```powershell
@{
    Name        = "Obsidian"
    Repo        = "obsidianmd/obsidian-releases"   # GitHub owner/repo for LATEST resolution
    AssetMatch  = "Obsidian-*.exe"                 # glob selecting the Windows installer asset
    SilentArgs  = "/S"                             # NSIS per-user silent (NO /allusers → no admin)
    DetectName  = "Obsidian*"                       # HKCU Uninstall DisplayName glob (presence check)
}
```

### 2. `Install-InstallerTool` — LATEST resolve, digest-verify, silent run

Flow inside the function:

1. **Presence gate:** unless `$ForceInstaller`, if `Test-InstallerPresent -DisplayName $Tool.DetectName`
   returns true → `Write-Ok "<Name> already installed"`, return. (Detection helper in §3.)
2. **Resolve LATEST:** set the TLS-1.2 line (reuse the existing pattern), then
   `Invoke-RestMethod "https://api.github.com/repos/$($Tool.Repo)/releases/latest"`. If
   `$env:GITHUB_TOKEN` is set, send it as an `Authorization` header (raises the 60/hr anon API limit;
   the curl-pipe bootstrap form already uses this token to clone the private repo). Pick the asset
   whose `name` matches `AssetMatch` (first match; warn if >1). Capture `browser_download_url` and
   `digest`.
3. **Download** the asset to `%TEMP%\ws-<name>-installer.exe` via `Invoke-WebRequest`.
4. **Verify:** if the asset has a `digest` (`sha256:<hex>`), compare to `Get-FileHash -Algorithm
   SHA256`; **mismatch → hard-fail** (`Write-Fail`, same as portable). If the API returns no digest,
   `Write-Warn` ("no published digest — skipping hash verification") and proceed (HTTPS + GitHub).
5. **Install silently:** `Start-Process -FilePath <exe> -ArgumentList $Tool.SilentArgs -Wait`.
6. **Cleanup** the temp `.exe` in a `finally`.
7. **No `Add-ToUserPath`** — Obsidian is a GUI app that creates its own Start-menu shortcut and
   self-updates; it is not meant to be on PATH.

Error handling matches the portable helper's tone: API/download/asset-missing → `Write-Warn` + skip
(don't sink the whole bootstrap); only a **digest mismatch** hard-fails.

### 3. Presence detection — uninstall registry (concretizes "check real install path")

A helper:

```powershell
function Test-InstallerPresent {
    param([string]$DisplayName)
    $roots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($r in $roots) {
        $hit = Get-ItemProperty $r -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like $DisplayName }
        if ($hit) { return $true }
    }
    return $false
}
```

This is the canonical Windows "is this app installed" check, path-independent (sidesteps the
`Programs\obsidian` vs `Obsidian` ambiguity), and honors the user's intent better than a stamp: a
manual Control-Panel uninstall removes the key, so the next bootstrap reinstalls. HKCU is the
relevant root for per-user installs; HKLM/WOW6432Node are included so a pre-existing machine-wide
Obsidian (installed some other way) is also detected and not duplicated.

### 4. New `-ForceInstaller` flag

Add `[switch]$ForceInstaller` to `param()`. When set, installer tools re-download + re-run their
silent installer even when detected present; **portable tools are untouched** (they keep their
existing version-stamp reinstall logic). Documented in the header comment block beside the other
flags.

### 5. Wire into `Invoke-ToolInstall`

After the existing `$PortableTools` loop, add:

```powershell
foreach ($t in $InstallerTools) { Install-InstallerTool -Tool $t }
```

Honor `-SkipToolInstall` the same way the portable loop already does (the early return at the top of
`Invoke-ToolInstall` already covers this).

### 6. Repo-convention follow-through (same commit)

- **`bootstrap.ps1` re-saved with UTF-8 BOM preserved** (PS 5.1 tripwire — CLAUDE.md).
- **`docs/windows/application_list.md`** — drop Obsidian from the manual list (now auto-installed),
  or annotate it as "auto-installed by bootstrap.ps1" so the list stays an accurate inventory.
- **`README.html`** — §setup-windows: document the new installer-tool class, that Obsidian now
  installs automatically, and the `-ForceInstaller` flag; §adding: how to add an installer-layout
  tool (`$InstallerTools` entry: `Repo`/`AssetMatch`/`SilentArgs`/`DetectName`). Touch
  `docs/README/README.css`/`.js` only if a new section/control needs it.
- **`CLAUDE.md`** — extend the Windows-installs invariant: it's no longer *only* portable downloads;
  there is now an installer class (LATEST via GitHub API, verified against the API `digest`, presence
  via HKCU/HKLM Uninstall registry, **no PATH**, `-ForceInstaller` to force). Note installer tools
  carry **no `versions.mk`/pin** (intentional — LATEST seed + self-update).
- **`docs/claude/file-care.md`** — extend the `bootstrap.ps1` entry to describe `$InstallerTools`
  (unpinned/LATEST, digest-verified, registry-detected) alongside the pinned `$PortableTools`.
- **`CLAUDE_CHANGELOG.md`** — append a row.

## Files to touch

1. **`bootstrap.ps1`** — `[switch]$ForceInstaller` in `param()`; `$InstallerTools` array (Obsidian
   entry); `Install-InstallerTool` + `Test-InstallerPresent` functions; the loop in
   `Invoke-ToolInstall`; header comment updates (flag + installer model). **Retain UTF-8 BOM.**
2. **`docs/windows/application_list.md`** — remove/annotate Obsidian (now auto-installed).
3. **`README.html`** — §setup-windows (installer class, Obsidian auto-install, `-ForceInstaller`),
   §adding (add-an-installer-tool walkthrough). `README.css`/`.js` only if needed.
4. **`CLAUDE.md`** — extend the Windows-installs invariant (installer class; LATEST + digest-verify;
   registry detection; no PATH; no version pin; `-ForceInstaller`).
5. **`docs/claude/file-care.md`** — extend the `bootstrap.ps1` entry for `$InstallerTools`.
6. **`CLAUDE_CHANGELOG.md`** — append a row.

## Out of scope

- **Other apps in `application_list.md`** — the installer framework is generic, but only Obsidian is
  wired up now. Adding others is a later, per-app change.
- **Linux Obsidian** — Linux has AppImage/`.deb`; this change is Windows-only and does not touch the
  Linux/Make install path.
- **Pinning an Obsidian version** — explicitly LATEST per the user; Obsidian self-updates afterward.
- **Auto-update management** — Obsidian's own updater owns updates after the seed; the bootstrap does
  not re-run installs on a schedule (only on `-ForceInstaller` or when uninstalled).

## Risks / things to verify (on a Windows host)

- **BOM** on `bootstrap.ps1` after editing (`file` must report a BOM, parse under PS 5.1).
- **Registry DisplayName** — confirm the installed Obsidian's uninstall `DisplayName` actually
  matches `Obsidian*` (electron-builder uses `productName`):
  `Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' | ? DisplayName -like 'Obsidian*'`.
- **`/S` per-user, no admin** — confirm a plain `/S` install completes without an elevation prompt
  and lands a working Obsidian for the current user.
- **Auto-launch after silent install** — confirm `/S` does **not** pop Obsidian open during the
  bootstrap (electron-builder oneClick may run-after-finish; if it does, it's a cosmetic annoyance,
  not a failure — note it if so).
- **Digest field present** — verified today on v1.12.7; the code must still behave (warn + proceed)
  if a future release omits `digest`.
- **AssetMatch uniqueness** — `Obsidian-*.exe` matches exactly one Windows asset in the current
  release; guard against >1 match (pick first + warn) in case a future release adds another `.exe`.
- **API rate limit** — anon GitHub API is 60/hr; confirm the optional `$env:GITHUB_TOKEN` header is
  sent when present and that the no-token path still works for a normal single run.
- **`-ForceInstaller`** — confirm it re-installs Obsidian when already present, and leaves portable
  tools (Starship/WezTerm/Helix) alone.
- **`-SkipToolInstall`** — confirm it still skips the new installer loop.

## Decisions (confirmed 2026-06-08)

1. **Installer-layout as a separate `$InstallerTools` list + `Install-InstallerTool` function**, not a
   branch in `Install-PortableTool`. ✅
2. **LATEST version resolution** via the GitHub `releases/latest` API (no version pin; Obsidian
   self-updates after the seed). ✅
3. **Verify the download against the GitHub API's per-asset `digest`** (sha256) — no hand-pinned
   literal, but still a real hash check; mismatch hard-fails; missing digest → warn + proceed. ✅
4. **Presence detection via the HKCU/HKLM Uninstall registry `DisplayName`** (concretizes the
   "check real install path" choice; path-independent, uninstall-aware). ✅
5. **`-ForceInstaller` flag** (this exact name) forces re-install of installer tools only; portable
   tools untouched. ✅
6. **No PATH entry** for installer tools (GUI app with its own shortcut). ✅
