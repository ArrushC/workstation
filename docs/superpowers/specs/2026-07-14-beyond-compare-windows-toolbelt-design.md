# Beyond Compare in the Windows toolbelt: sixth installer-class app (winget-version-listing variant)

**Date:** 2026-07-14
**Scope:** `bootstrap.ps1` (one `$InstallerTools` entry + an opt-in
winget-version-listing resolver — new `Get-LatestWingetVersion` helper, a
version-source branch inside the existing `UrlTemplate` path, the same branch
in the `-CheckForUpdates` installer loop, banner comment),
`docs/windows/application_list.md` (Beyond Compare row moves to
auto-installed), `README.html`, `CLAUDE.md`, `docs/claude/invariants.md` /
`docs/claude/file-care.md` (enumeration sweeps), `CLAUDE_CHANGELOG.md`.
**Status:** Design — pending user review.

## Goal

Add [Beyond Compare](https://www.scootersoftware.com) (GUI file/folder
diff-merge tool) to the Windows toolbelt: auto-installed by `bootstrap.ps1` as
the sixth `$InstallerTools` app — latest release, sha256-verified, silent
**per-user** install, no admin, no PATH changes, Uninstall-registry
idempotency. Move Beyond Compare from the Manual installs section of
`application_list.md` to the Auto-installed section.

**User decisions (2026-07-14):**

- **Beyond Compare 5** (current major, v5.2.3 at design time), not the legacy
  BC4 line. BC is commercial trialware — the seed installs the 30-day trial;
  the user's license key unlocks it (Standard vs Pro is determined by the
  key). No license automation.
- **Method A** (winget-pkgs version listing) for version resolution, chosen
  after a live feasibility evaluation of all four candidates (see next
  section). Methods B–D rejected: B (scrape the download page) is fragile to
  a redesign and still hash-checks against winget — keeping the lag gap A
  eliminates; C (first-party update feed) is a dead end — `checkupdates.php`
  returns HTTP 400 without the app's undocumented parameters and
  `version5.xml` is an HTML fallback page, not a feed; D (hard pin à la
  `$PortableTools`) breaks the installer class's seed-latest model and adds a
  manual bump chore.
- **Installer class**, not a portable pin — GUI app, creates its own
  Start-menu shortcut, prompts to update in-app.

## Verified upstream facts (2026-07-14 — each tested live, not assumed)

Researched from scootersoftware.com/download, the GitHub contents API
(anonymous), and the winget manifest
(`ScooterSoftware.BeyondCompare.5` 5.2.3.32296).

- **No GitHub repo exists at all.** WinSCP at least had bare git tags for
  `Get-LatestGitTag`; Scooter Software has nothing on GitHub. This is the
  motivation for the new opt-in version source. The winget-pkgs repo is the
  best structured, machine-readable authority: the directory
  `manifests/s/ScooterSoftware/BeyondCompare/5` contains one subdirectory per
  published version, and the names ARE the 4-part versions
  (`5.0.2.30045` … `5.2.3.32296`, 17 at design time).
- **The 4-part version (with build number) is load-bearing:** the download
  URL embeds it — `BCompare-5.2.3.32296.exe` — so a 3-part version can't
  build a URL. Winget's directory names carry exactly the needed form.
- **Anonymous GitHub contents API works** (verified tokenless):
  `GET api.github.com/repos/microsoft/winget-pkgs/contents/manifests/s/ScooterSoftware/BeyondCompare/5`
  returns the version directories. Bootstrap already makes anonymous GitHub
  API calls for the other installer apps; `$env:GITHUB_TOKEN`, when present,
  lifts the rate limit the same way. The contents API caps a directory
  listing at 1000 entries — BC5 has 17 (BC4 accumulated ~40 over a decade);
  no pagination needed.
- **Winget currency:** the newest directory (`5.2.3.32296`) matches the
  version on scootersoftware.com/download exactly (the 2026-06-29 release is
  in) — winget tracks BC closely. A brand-new release can still lag
  hours–days; accepted trade-off (see Edge cases).
- **Stable first-party download URL** (verified: HTTP 200, 28.7 MB, plain
  Apache, no redirect, no user-agent blocking — simpler than WinSCP's
  SourceForge bounce):
  `https://www.scootersoftware.com/files/BCompare-{VERSION}.exe`.
- **End-to-end hash chain verified:** the installer was downloaded in full
  and its sha256 (`a74239803aa1a1373735dc092365cca85c726178625aa51821f35aaf42559621`)
  matches the winget manifest's `InstallerSha256` byte-for-byte.
- **Existing HashManifest parser works unchanged:** the manifest lists ~48
  installer entries (12 locales × x86/x64 × user/machine scope), but the
  URL-basename match `*BCompare-5.2.3.32296.exe*` hits only the English
  entries — localized files are `BCompare-de-…`/`BCompare-fr-…` etc., which
  do not contain the plain basename as a substring — and the English entries
  come first in the document. First match = correct sha.
- **Inno Setup, per-user documented:** `InstallerType: inno`; the winget
  user-scope entries pass exactly `Custom: /CURRENTUSER` (machine scope =
  `/ALLUSERS`) → **`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER`
  gives a silent, per-user, no-admin/no-UAC install** (the WinSCP switch set
  verbatim). Single installer binary for both arches (winget lists x86 and
  x64 with the same URL + hash).
- **Uninstall registry:** Inno `ProductCode: BeyondCompare5_is1`; a per-user
  install registers `HKCU\...\Uninstall\BeyondCompare5_is1`.
  `DetectName = "Beyond Compare*"` also matches an existing BC4 install or a
  machine-wide HKLM BC5 — **intended**: never seed a trial alongside a
  licensed copy (the DBeaver-commercial-editions precedent). Exact
  DisplayName to be recorded during the on-host Windows test.
- **`-CheckForUpdates` version comparison should be exact:** the manifest has
  no `AppsAndFeaturesEntries` override, meaning the ARP `DisplayVersion`
  matches the 4-part `PackageVersion` — so `Get-InstalledAppVersion` output
  compares cleanly against the winget-resolved latest. Confirm on-host.
- **Update model: prompt-based, not silent.** BC's in-app check (Help →
  Check for Updates) notifies and, on consent, downloads + runs the
  installer. Carries an `UpdateHint` (WinSCP's wording fits verbatim).

## Design

### 1. `$InstallerTools` entry (`bootstrap.ps1`)

Appended after WinSCP — the first entry with **no `Repo` key at all**:

```powershell
@{
    Name           = "Beyond Compare"
    WingetVersions = "manifests/s/ScooterSoftware/BeyondCompare/5"  # version source: winget-pkgs dir names ARE the 4-part versions (no GitHub repo exists upstream)
    UrlTemplate    = "https://www.scootersoftware.com/files/BCompare-{VERSION}.exe"  # first-party, direct (no redirect); needs the 4-part version incl. build number
    HashManifest   = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/s/ScooterSoftware/BeyondCompare/5/{VERSION}/ScooterSoftware.BeyondCompare.5.installer.yaml"
    SilentArgs     = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER"  # Inno silent + documented per-user mode -> no admin/UAC
    DetectName     = "Beyond Compare*"  # HKCU ...\Uninstall\BeyondCompare5_is1; glob also matches BC4 or a machine-wide HKLM install (intended: never seed a trial alongside a licensed copy)
    UpdateHint     = "in-app update check prompts to install (not silent) — or re-run bootstrap with -ForceInstaller"
}
```

A comment on the entry notes the commercial-trialware model (seed = 30-day
trial; license key unlocks; Standard/Pro by key) and that the English
installer is deliberate (localized siblings exist but never match the hash
lookup).

### 2. Opt-in winget-version-listing resolver — the only new machinery

One new opt-in per-tool field (the sixth; absent = old behavior,
`ContainsKey`-guarded — **Obsidian/Zed/DevToys/DBeaver/WinSCP are
bit-for-bit unchanged**):

- **`WingetVersions`** — a `microsoft/winget-pkgs` directory path whose
  subdirectory names are the published versions. Its presence switches the
  version-resolution step *inside the existing `UrlTemplate` branch* of
  `Install-InstallerTool` from `Get-LatestGitTag` to the new helper; absent →
  `Get-LatestGitTag` exactly as today. Everything downstream — `{VERSION}`
  URL substitution, basename→`InstallerSha256` manifest pairing, hash
  hard-fail, warn+proceed on a missing manifest, download/install tail,
  idempotency, `-ForceInstaller`, `-SkipToolInstall` — is reused untouched.

New helper, `Get-LatestWingetVersion -Path <dir>`:

- `GET https://api.github.com/repos/microsoft/winget-pkgs/contents/<path>`
  with the same `User-Agent` + optional `$env:GITHUB_TOKEN` headers as the
  release resolver.
- Keep `type -eq 'dir'` entries; parse each name as `[System.Version]`
  (4-part parses natively; skip names that don't parse, e.g. a stray
  `.validation` file); return the **raw name string** of the highest —
  never a re-serialized form.
- Any failure (offline, rate-limited, empty, nothing parses) → `$null`,
  which flows into the existing "couldn't resolve the latest version …
  Skipping" warn path (class soft-fail posture; reword that warning so it
  names the actual source — tag lookup vs winget listing).

`-CheckForUpdates` installer loop: today it calls
`Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tagPrefix` unconditionally,
which cannot work for a Repo-less entry — branch on
`ContainsKey('WingetVersions')` to call the same helper. `-Doctor` needs
**zero changes** (it reads only `DetectName`/`UpdateHint`).

The `$InstallerTools` banner comment: "Five OPT-IN per-tool fields" → six,
with a `WingetVersions` description and the BC rationale (no GitHub presence
at all; version + hash from the same authority).

Since version and hash now come from the **same authority**, WinSCP's
"manifest lags a brand-new release → warn + proceed unverified" gap
structurally disappears for BC: if winget is behind, the resolver simply
returns the previous version, whose manifest exists — a fully verified
install of a slightly older seed. The warn+proceed path stays as a safety
net (e.g. manifest tree reorganized).

### 3. Docs (same commit)

- **`docs/windows/application_list.md`:** delete `- Beyond Compare` from
  Manual installs; add it to the Auto-installed section after WinSCP.
- **`README.html`:** Beyond Compare card next to WinSCP's in the
  §setup-windows installer-class prose (silent per-user Inno, trialware note,
  prompt-based updates, the no-GitHub-at-all winget-listing variant); add to
  every installer-app enumeration (the WinSCP sweep touched ≈ lines 3055,
  3113–3116, 4694–4699; re-locate all instances at plan time).
- **`CLAUDE.md`:** the installer-class invariant bullet's example list gains
  Beyond Compare; its opt-in-fields sentence goes five → six with a one-line
  `WingetVersions` description (version source when upstream has no GitHub
  presence; BC as the precedent).
- **`docs/claude/invariants.md` / `docs/claude/file-care.md`:** sweep for
  installer-app enumerations and the opt-in-field count; update where
  present.
- **`CLAUDE_CHANGELOG.md`:** one row (user-facing surface: a new
  auto-installed app + manual-list change).

No `versions.mk` change (latest-release model — nothing pinned), no
completion-parity edits (no new bootstrap flags), no `check-invariants.sh`
additions (nothing mechanically checkable added), no chezmoi/TOOLS-block
regeneration.

## Edge cases & error handling

- **Offline / API failure / rate-limited:** helper returns `$null` → warn +
  skip this tool, bootstrap continues (class posture).
- **Hash mismatch:** hard fail for this tool, temp file removed first
  (existing class tamper posture; `Write-Fail` is allowed in this class).
- **Existing BC4 / machine-wide BC5 / licensed copy:** `DetectName` glob
  skips the install.
- **Winget lag:** installs the newest winget-known version, fully
  hash-verified; BC's in-app check covers the gap (see Design §2).
- **MSIX/Store copies:** no Beyond Compare MSIX is known in the MS Store; the
  known class caveat (Store installs invisible to the registry detect) is
  noted in the entry comment only if observed — not carried speculatively.

## Verification

Linux side (this machine):

```bash
make -C makefile ps-lint                 # PSScriptAnalyzer over bootstrap.ps1
make -C makefile lint MODE=prod          # check-invariants, shfmt, shellcheck, gitleaks
# BOM retained on bootstrap.ps1 after edit (post-edit-guard auto-repairs; verify anyway)
```

Resolver logic is additionally provable from Linux with plain curl/jq (the
listing + manifest fetch + hash pairing were all verified that way during
design).

Windows side (post-merge, on the Windows host — same deferred posture as
DBeaver/WinSCP): re-run `bootstrap.ps1` — Beyond Compare installs silently
per-user with **no UAC prompt**, Start-menu entry present, HKCU
`BeyondCompare5_is1` key exists (record the actual
DisplayName/DisplayVersion); immediate re-run skips it (registry detect);
`bootstrap.ps1 -Doctor` shows a green Beyond Compare row with the
UpdateHint; `bootstrap.ps1 -CheckForUpdates` resolves the latest winget
version (4-part, ≥ 5.2.3.32296) and compares it against the registry
DisplayVersion; `-ForceInstaller` reinstalls; the five existing installer
apps' lines are unchanged in both.

## Out of scope (deliberate)

- Beyond Compare 4 in any form.
- Beyond Compare on Linux (Scooter ships Linux packages, but this repo
  installs no GUI apps on Linux).
- License-key registration/automation; the alternate MSI/zip installers;
  localized installers; winget/Chocolatey install paths.
- chezmoi-tracking Beyond Compare settings.
- Generalizing `WingetVersions` beyond version listing (e.g. replacing the
  GitHub-release resolver) — it exists solely for upstreams with no GitHub
  presence.
