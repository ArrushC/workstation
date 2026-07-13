# DBeaver CE in the Windows toolbelt: fourth installer-class app

**Date:** 2026-07-13
**Scope:** `bootstrap.ps1` (one `$InstallerTools` entry + an opt-in `TagPrefix` extension in the `-CheckForUpdates` installer loop + banner comment), `docs/windows/application_list.md`, `README.html`, `CLAUDE.md`, `docs/claude/invariants.md` / `docs/claude/file-care.md` (enumeration sweeps), `CLAUDE_CHANGELOG.md`.
**Status:** Design — pending user review.

## Goal

Add [DBeaver Community Edition](https://dbeaver.io) (GUI database client) to the
Windows toolbelt: auto-installed by `bootstrap.ps1` as the fourth
`$InstallerTools` app (the Obsidian/Zed/DevToys pattern) — latest GitHub
release, digest-verified, silent per-user install, no admin, no PATH changes,
Uninstall-registry idempotency.

**User decisions (2026-07-12):** Community Edition, Windows-only (the repo
installs no GUI apps on Linux — matches precedent); installer class
(approach A) over a pinned `$PortableTools` zip (B — ~130 MB pin churn on a
2-week release cadence, no self-update, pointless PATH entry) or docs-only
(C — doesn't install anything).

## Verified upstream facts (2026-07-12/13)

Researched from the GitHub API and the winget manifest
(`DBeaver.DBeaver.Community` 26.1.2).

- **Latest release: 26.1.2** (2026-07-05) at `dbeaver/dbeaver`.
  `/releases/latest` is honest (`prerelease: false` — no DevToys-style trap),
  so **no `IncludePrerelease`**. Release cadence is ~2 weeks.
- **Windows x64 installer asset:** `dbeaver-ce-26.1.2-windows-x86_64.exe`
  (~117 MB). Per-asset GitHub API sha256 `digest` present
  (`c1ec4978244ad1305c90a99e2b74741749066e105038c3621ad319de988ece74`, matches
  winget `InstallerSha256`) — the class's existing digest verification works
  unchanged. Sibling assets the match must avoid: `-windows-aarch64.exe`, the
  two `-windows-*.zip` archives (the `x86_64` token in the pattern excludes
  both).
- **NSIS, MultiUser-aware:** winget `InstallerType: nullsoft`; the user-scope
  variant passes `Custom: /currentuser` → **`/S /currentuser` gives a silent,
  per-user, no-admin/no-UAC install**. A machine scope (`/allusers`) exists;
  we never use it. The installer bundles its own JRE — no Java prerequisite.
- **Uninstall registry:** the per-user install registers key
  `DBeaver (current user)` (the winget `ProductCode`) under `HKCU\...\Uninstall`;
  DisplayName starts with "DBeaver" (exact string unverifiable from source —
  the NSIS script isn't in the public repo — so it gets confirmed on-host
  during the Windows test; the glob covers it regardless). `DetectName =
  "DBeaver*"` also matches the commercial editions (Lite/Enterprise/Ultimate)
  — **intended**: a licensed DBeaver already installed shouldn't get a CE
  forced alongside (the DevToys-Preview precedent).
- **Tags are BARE** (`26.1.2`, no `v`) — the first installer app like this.
  `Get-LatestGitTag` defaults `TagPrefix = "v"` and the `-CheckForUpdates`
  installer loop passes no override, so DBeaver's latest tag would resolve to
  `$null` and the row would silently degrade to the no-latest branch. Fixed by
  the opt-in `TagPrefix` extension below. The `-Doctor` installer loop never
  queries tags — unaffected.
- **Self-update: real.** On the new-version prompt, user consent downloads and
  launches the installer automatically
  ([dbeaver/dbeaver#3299](https://github.com/dbeaver/dbeaver/issues/3299),
  Chocolatey package notes) — unlike DevToys' notification-only check. The
  class's default "self-updates" hint is accurate → **no `UpdateHint`**.
- **MS-Store DBeaver exists** (MSIX) — invisible to the Uninstall-registry
  detect, so a Store-installed DBeaver would double-install (same known caveat
  as DevToys; carried as a code comment, not solved).

## Design

### 1. `$InstallerTools` entry (`bootstrap.ps1`)

Appended after DevToys:

```powershell
@{
    Name       = "DBeaver"
    Repo       = "dbeaver/dbeaver"                  # CE releases; /releases/latest is honest (unlike DevToys)
    AssetMatch = "dbeaver-ce-*-windows-x86_64.exe"  # NSIS installer (NOT -aarch64.exe, NOT the .zip archives)
    SilentArgs = "/S /currentuser"                  # NSIS silent + MultiUser per-user pin -> no admin
    DetectName = "DBeaver*"                         # HKCU ...\Uninstall\DBeaver (current user); glob also matches commercial editions (intended: don't force CE alongside a licensed install)
    TagPrefix  = ""                                 # bare tags (26.1.2) — see the -CheckForUpdates opt-in below
}
```

No `IncludePrerelease`, no `UpdateHint` — both defaults are correct for
DBeaver. `SilentArgs` is already a free-form string, so `/currentuser` needs
no class support.

### 2. Opt-in `TagPrefix` for installer apps (`-CheckForUpdates` loop)

The one mechanism change. In the installer-apps loop (`bootstrap.ps1` ~line
1712), honor an optional per-tool `TagPrefix`, defaulting to the current
behavior:

```powershell
$tagPrefix = if ($tool.ContainsKey('TagPrefix')) { $tool.TagPrefix } else { 'v' }
$latest    = Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tagPrefix
```

ContainsKey-guarded (StrictMode-safe, hashtable — the `IncludePrerelease`
precedent), so **Obsidian/Zed/DevToys are bit-for-bit unchanged**.
`Get-LatestGitTag` already handles an empty prefix correctly
(`refs/tags/*` glob; `Substring(0)` no-op; the `^\d+(\.\d+)*$` filter matches
`26.1.2`). The `$InstallerTools` banner comment gains `TagPrefix` as the third
documented opt-in field.

### 3. Docs (same commit)

- **`docs/windows/application_list.md`:** DBeaver joins the line-2
  parenthetical of bootstrap-auto-installed apps. (No standalone row exists to
  remove — DBeaver was never listed.)
- **`README.html`:** DBeaver added to the §setup-windows installer-class prose
  (silent per-user NSIS, self-updates) and to every "(Obsidian, Zed, DevToys)"
  enumeration — the DevToys sweep touched ≈ lines 2987 (comment), 3046
  (`-SkipToolInstall`), 4615 (troubleshooting); re-locate all instances at
  plan time.
- **`CLAUDE.md`:** the installer-class invariant bullet's example list gains
  DBeaver, and its opt-in-fields sentence gains `TagPrefix` (now three:
  `IncludePrerelease`, `UpdateHint`, `TagPrefix`).
- **`docs/claude/invariants.md` / `docs/claude/file-care.md`:** sweep for
  installer-app enumerations and the opt-in-field list; update where present.
- **`CLAUDE_CHANGELOG.md`:** one row (user-facing surface: a new
  auto-installed app).

### 4. Verification

Linux side (this machine):

```bash
make -C makefile ps-lint                 # PSScriptAnalyzer over bootstrap.ps1
make -C makefile lint MODE=prod          # check-invariants, shfmt, shellcheck, gitleaks (no new checks needed — no versions.mk pin)
# BOM retained on bootstrap.ps1 after edit (post-edit-guard auto-repairs; verify anyway)
```

No `versions.mk` change → no `check-invariants.sh` addition, no TOOLS-block
regeneration, no `cza` needed.

Windows side (post-merge, on the Windows host): re-run `bootstrap.ps1` —
DBeaver installs silently per-user (no UAC), Start-menu entry present, HKCU
`DBeaver (current user)` key exists (record the actual DisplayName);
immediate re-run skips it (registry detect); `bootstrap.ps1 -Doctor` shows a
green DBeaver row; `bootstrap.ps1 -CheckForUpdates` shows DBeaver with a
resolved latest version (proves the bare-tag `TagPrefix` fix);
Obsidian/Zed/DevToys lines unchanged in both.

## Out of scope (deliberate)

- DBeaver on Linux (`.rpm`/`.tar.gz` assets exist; the repo installs no GUI
  apps on Linux).
- arm64/x86 Windows assets (fleet is x64; Zed precedent).
- The portable `.zip` route; winget/Chocolatey/MS-Store install paths.
- Commercial editions (Lite/Enterprise/Ultimate — license + different
  download source).
- chezmoi-tracking DBeaver settings/drivers/connection config.
