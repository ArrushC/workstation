# WinSCP in the Windows toolbelt: fifth installer-class app (direct-URL variant)

**Date:** 2026-07-14
**Scope:** `bootstrap.ps1` (one `$InstallerTools` entry + an opt-in direct-URL
resolver path in `Install-InstallerTool` + banner comment),
`docs/windows/application_list.md` (WinSCP row moves to auto-installed;
FileZilla dropped), `README.html`, `CLAUDE.md`, `docs/claude/invariants.md` /
`docs/claude/file-care.md` (enumeration sweeps), `CLAUDE_CHANGELOG.md`.
**Status:** Design — pending user review.

## Goal

Add [WinSCP](https://winscp.net) (GUI SFTP/SCP/FTP/S3 client) to the Windows
toolbelt: auto-installed by `bootstrap.ps1` as the fifth `$InstallerTools` app
— latest release, sha256-verified, silent **per-user** install, no admin, no
PATH changes, Uninstall-registry idempotency. Move WinSCP from the Manual
installs section of `application_list.md` to the Auto-installed section and
remove the FileZilla entry.

**User decisions (2026-07-14):**

- **GUI only** — `winscp.com` (scripting CLI) does NOT go on PATH; sftp
  scripting is already covered by OpenSSH/SSHFS-Win.
- **Per-user install required** — `/CURRENTUSER`, never `/ALLUSERS`/machine
  scope.
- **Approach A** (installer class + opt-in direct-URL resolver) over B (pinned
  `$PortableTools` zip — wrong class for a GUI-only app: PATH entry, bespoke
  Start-menu shortcut step, manual pin bumps, INI config drift) and C (winget
  user-scope — winget may be absent, manifest says `elevatesSelf` → UAC risk,
  breaks the installer class's no-winget rule).
- **FileZilla is removed entirely**, not kept as a manual-list alternative.
  This deliberately deviates from `application_list.md`'s line-2 convention
  ("where they had in-row alternatives, those alternatives are kept") — the
  user doesn't want FileZilla suggested at all.

## Verified upstream facts (2026-07-14)

Researched from the GitHub API, `git ls-remote`, winscp.net docs, and the
winget manifest (`WinSCP.WinSCP` 6.5.6).

- **No GitHub release assets.** `winscp/winscp` has tags but ZERO releases
  (`/releases` returns `[]`) — the class's GitHub-release resolver + per-asset
  API digest CANNOT work for WinSCP. This is the first installer app like
  this and the motivation for the opt-in direct-URL resolver.
- **Tags are BARE with beta noise:** latest stable `6.5.6`; `6.6-beta` /
  `6.6.1-beta` also exist. `Get-LatestGitTag`'s default filter
  (`^\d+(\.\d+)*$`) already drops the `-beta` tags, and `TagPrefix ""` is the
  DBeaver precedent — **no new filtering code**.
- **Stable first-party download URL:**
  `https://winscp.net/download/WinSCP-{VERSION}-Setup.exe/download` → HTTP 200
  via a vendor-controlled redirect to a SourceForge mirror (verified with
  curl; `Invoke-WebRequest` follows redirects by default). The winget manifest
  uses the equivalent
  `sourceforge.net/projects/winscp/files/WinSCP/<ver>/...` URL — same file.
- **Inno Setup, per-user documented:** winscp.net/eng/docs/installation
  documents `/SILENT`, `/VERYSILENT`, `/NORESTART`, and `/CURRENTUSER`
  ("non administrative install mode") / `/ALLUSERS`. The winget user-scope
  variant passes exactly `Custom: /CURRENTUSER` → **`/VERYSILENT
  /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER` gives a silent, per-user,
  no-admin/no-UAC install** (Zed/DevToys switch set + the scope pin). The
  manifest carries `ElevationRequirement: elevatesSelf` on BOTH scope entries;
  with `/CURRENTUSER` passed explicitly no elevation occurs per the official
  docs — confirmed on-host during the Windows test.
- **Sha256 source = the official winget manifest** (per-version raw YAML at
  `microsoft/winget-pkgs` — `manifests/w/WinSCP/WinSCP/<ver>/WinSCP.WinSCP.installer.yaml`,
  `InstallerSha256: 4488C493...` for 6.5.6). Precedent: SSHFS-Win's
  `Sha256Pin` already sources from a winget manifest. The manifest for a
  brand-new WinSCP release can LAG (hours–days) → that path warns+proceeds,
  mirroring the class's existing "GitHub published no digest" posture. The
  manifest also lists an MSI hash — extraction must pair `InstallerSha256`
  with the `InstallerUrl` entry matching `*-Setup.exe`, not take first-match.
- **Uninstall registry:** Inno AppId `winscp3_is1`; per-user install registers
  `HKCU\...\Uninstall\winscp3_is1` with version-suffixed DisplayName
  ("WinSCP 6.5.6" — the DevToys shape) and a `DisplayVersion` for
  `Get-InstalledAppVersion`. `DetectName = "WinSCP*"` also matches an existing
  MACHINE-wide WinSCP in HKLM — **intended**: never double-install alongside
  an admin install (the DBeaver-commercial-editions precedent).
- **Update model: prompt-based, not silent.** WinSCP's in-app update check
  notifies and, on user consent, downloads + runs the installer. Not the
  Obsidian silent-self-update story → carries an `UpdateHint`.
- **x86-only installer** — WinSCP ships a single 32-bit installer that runs on
  x64; no arch-picking needed (nothing to exclude).
- **MS-Store WinSCP exists** (MSIX) — invisible to the Uninstall-registry
  detect, so a Store-installed WinSCP would double-install (same known class
  caveat as DevToys/DBeaver; carried as a code comment, not solved).

## Design

### 1. `$InstallerTools` entry (`bootstrap.ps1`)

Appended after DBeaver:

```powershell
@{
    Name         = "WinSCP"
    Repo         = "winscp/winscp"      # tags only — no release assets; version source for UrlTemplate + -CheckForUpdates
    TagPrefix    = ""                    # bare tags (6.5.6); default Get-LatestGitTag filter drops 6.6-beta et al.
    UrlTemplate  = "https://winscp.net/download/WinSCP-{VERSION}-Setup.exe/download"  # first-party; redirects to a SourceForge mirror
    HashManifest = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/w/WinSCP/WinSCP/{VERSION}/WinSCP.WinSCP.installer.yaml"
    SilentArgs   = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER"  # Inno silent + documented per-user mode -> no admin/UAC
    DetectName   = "WinSCP*"             # HKCU ...\Uninstall\winscp3_is1, DisplayName version-suffixed ("WinSCP 6.5.6"); glob also matches a machine-wide HKLM install (intended: never double-install); MS-Store MSIX invisible here (known class caveat)
    UpdateHint   = "in-app update check prompts to install (not silent) — or re-run bootstrap with -ForceInstaller"
}
```

### 2. Opt-in direct-URL resolver (`Install-InstallerTool`)

The one mechanism change. Two new opt-in per-tool fields (fields four and
five; absent = old behavior, `ContainsKey`-guarded like `IncludePrerelease` —
**Obsidian/Zed/DevToys/DBeaver are bit-for-bit unchanged**):

- **`UrlTemplate`** — its presence routes the tool through the tag-based
  resolver: version = `Get-LatestGitTag -Repo $Tool.Repo -TagPrefix
  $Tool.TagPrefix` (the function `-CheckForUpdates` already uses; `$null` →
  warn + skip, the class's soft-fail posture), download URL = `{VERSION}`
  substitution. Skips the GitHub releases API and `AssetMatch` entirely
  (WinSCP has no `AssetMatch` — the two resolver paths are mutually
  exclusive by construction).
- **`HashManifest`** — `{VERSION}`-templated URL of the official winget
  installer manifest. Fetch the YAML text, extract the `InstallerSha256`
  paired with the `InstallerUrl` whose filename matches the downloaded
  `*-Setup.exe` (NOT first-match — the manifest also hashes the MSI).
  Hash mismatch → **hard fail** (`Write-Fail`, temp file removed first —
  the class's existing tamper posture). Manifest fetch/parse failure (404 =
  winget lag on a brand-new release) → **warn + proceed** (the existing
  "no digest published" posture, same wording style).

Download and install reuse the existing code path (`Invoke-WebRequest` →
temp exe → `Start-Process -Wait` with `SilentArgs` → exit-code warn →
`finally` cleanup); the success line reports the resolved version instead of
`$release.tag_name`. The `$InstallerTools` banner comment documents both new
fields (now five opt-ins).

### 3. `-Doctor` / `-CheckForUpdates` — zero changes

Both installer loops already honor `TagPrefix` (DBeaver) and `UpdateHint`
(DevToys); WinSCP slots in with no mechanism edits.

### 4. Docs (same commit)

- **`docs/windows/application_list.md`:** delete the `- WinSCP / FileZilla`
  row from Manual installs (FileZilla dropped entirely — see user decisions);
  add `- WinSCP` to the Auto-installed section after DBeaver.
- **`README.html`:** WinSCP added to the §setup-windows installer-class prose
  (silent per-user Inno, prompt-based updates, no-GitHub-releases direct-URL
  + winget-manifest-hash variant) and to every installer-app enumeration
  (the DBeaver sweep touched ≈ lines 2987, 3046, 4615; re-locate all
  instances at plan time).
- **`CLAUDE.md`:** the installer-class invariant bullet's example list gains
  WinSCP, and its opt-in-fields sentence gains `UrlTemplate` + `HashManifest`
  (now five: `IncludePrerelease`, `UpdateHint`, `TagPrefix`, `UrlTemplate`,
  `HashManifest`).
- **`docs/claude/invariants.md` / `docs/claude/file-care.md`:** sweep for
  installer-app enumerations and the opt-in-field list; update where present.
- **`CLAUDE_CHANGELOG.md`:** one row (user-facing surface: a new
  auto-installed app + manual-list change).

### 5. Verification

Linux side (this machine):

```bash
make -C makefile ps-lint                 # PSScriptAnalyzer over bootstrap.ps1
make -C makefile lint MODE=prod          # check-invariants, shfmt, shellcheck, gitleaks (no new checks — no versions.mk pin)
# BOM retained on bootstrap.ps1 after edit (post-edit-guard auto-repairs; verify anyway)
```

No `versions.mk` change → no `check-invariants.sh` addition, no TOOLS-block
regeneration, no `cza` needed. No new bootstrap flags → no completion-parity
edits.

Windows side (post-merge, on the Windows host): re-run `bootstrap.ps1` —
WinSCP installs silently per-user with **no UAC prompt** (the load-bearing
per-user requirement), Start-menu entry present, HKCU `winscp3_is1` key
exists (record the actual DisplayName/DisplayVersion); immediate re-run skips
it (registry detect); `bootstrap.ps1 -Doctor` shows a green WinSCP row with
the UpdateHint; `bootstrap.ps1 -CheckForUpdates` resolves the latest bare tag
(≥ 6.5.6, proving beta tags are filtered); `-ForceInstaller` reinstalls;
Obsidian/Zed/DevToys/DBeaver lines unchanged in both.

## Out of scope (deliberate)

- FileZilla in any form (removed from docs; never installed).
- WinSCP on Linux (Windows-only app; the repo installs no GUI apps on Linux).
- The portable `.zip` route; `winscp.com` CLI on PATH; winget/Chocolatey/
  MS-Store install paths.
- chezmoi-tracking WinSCP configuration (registry-based sessions/settings).
- Auto-solving the MS-Store MSIX double-install caveat (carried as a code
  comment, same as DevToys/DBeaver).
