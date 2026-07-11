# Windows bootstrap: SSHFS-Win via a best-effort elevated install class

**Date:** 2026-07-10
**Scope:** `bootstrap.ps1` (new install class + flag + Doctor/CheckForUpdates coverage), `README.html` §setup-windows + §troubleshooting, `CLAUDE.md` Windows-installs invariant, `CLAUDE_CHANGELOG.md`.
**Status:** Design — pending user review.

## Goal

Add [SSHFS-Win](https://github.com/winfsp/sshfs-win) to the Windows bootstrap toolbelt so
Unix filesystems can be mounted over SSH (`\\sshfs\user@host` UNC paths / `net use`
drive letters). Primary install path is `winget install SSHFS-Win.SSHFS-Win`, with an
automated fallback when winget is absent, and a clean soft-fail everywhere else.

## The elevation problem (why this needs a new class)

SSHFS-Win depends on **WinFsp, a kernel-mode file-system driver**. Both MSIs are
machine-scope (`Scope: machine` in the winget manifest) — there is no per-user install
path for a kernel driver, and a UAC elevation prompt is unavoidable.

`bootstrap.ps1`'s load-bearing invariant since the 2026-06-05 de-chocolatey redesign is
**NO ADMIN REQUIRED**. Neither existing class fits:

- `$PortableTools` — pinned per-user zips/exes. A driver can't be portable.
- `$InstallerTools` — latest-release **admin-free** per-user silent installers. These MSIs
  require elevation.

**Decision (user-approved):** a third, clearly-marked class — `$ElevatedTools` — that is
**best-effort**: it may pop UAC, it soft-fails on every failure mode, and the bootstrap
remains fully runnable end-to-end with zero elevation (the step just skips). This is the
single sanctioned exception to the no-admin rule, and it is skippable via a new flag.

## Verified upstream facts (2026-07-10)

- winget ID `SSHFS-Win.SSHFS-Win` (v3.5.20357) declares `WinFsp.WinFsp` as a
  `PackageDependencies` entry — one winget command installs both.
- `winfsp/sshfs-win` latest release `v3.5.20357` (2020): assets
  `sshfs-win-3.5.20357-{x64,x86}.msi`, GitHub API `digest` is **null** (pre-digest-era
  release). The winget manifest publishes the official x64 sha256:
  `1657e397f8dce1c2d2e3220007f9c9f882631882b9bec4608f7835e87dcd096c`.
- `winfsp/winfsp` latest release `v2.1`: asset `winfsp-2.1.25156.msi`, digest **present**.
- A silent `msiexec /i <msi> /qn` from a non-elevated shell does **not** trigger UAC for a
  machine-scope MSI — it fails (MSI error 1925). The fallback must launch msiexec via
  `Start-Process -Verb RunAs`, which throws a catchable exception when UAC is declined.

## Design

### 1. `$ElevatedTools` list (after `$InstallerTools`)

One entry today. Shape:

```powershell
$ElevatedTools = @(
    @{
        Name       = "SSHFS-Win"
        WingetId   = "SSHFS-Win.SSHFS-Win"   # manifest pulls WinFsp.WinFsp as a dependency
        DetectName = "SSHFS-Win*"            # Uninstall-registry DisplayName glob (HKLM)
        # MSI fallback chain, installed IN ORDER when winget is absent:
        Msi        = @(
            @{ Name = "WinFsp";    Repo = "winfsp/winfsp";    AssetMatch = "winfsp-*.msi";
               DetectName = "WinFsp*" }
            @{ Name = "SSHFS-Win"; Repo = "winfsp/sshfs-win"; AssetMatch = "sshfs-win-*-x64.msi";
               DetectName = "SSHFS-Win*"
               # 2020-era release has no API digest; official sha256 from the winget manifest:
               Sha256Pin  = "1657e397f8dce1c2d2e3220007f9c9f882631882b9bec4608f7835e87dcd096c" }
        )
    }
)
```

### 2. `Install-ElevatedTool` flow

1. **Detect first, never re-elevate:** `Test-InstallerPresent -DisplayName $Tool.DetectName`
   (existing helper; these MSIs register machine-wide under HKLM) → already installed →
   `Write-Ok` + return. **No UAC on an already-provisioned machine.** `-ForceInstaller`
   forces a reinstall, consistent with `$InstallerTools` (it bypasses this registry check
   and, on the winget path, adds `--force` — winget otherwise no-ops on an
   already-installed package).
2. **Heads-up banner** before any prompt: machine-wide install (WinFsp kernel driver),
   expect a UAC prompt, skip with `-SkipElevated`.
3. **winget path** (when `Get-Command winget` resolves):
   `winget install --id SSHFS-Win.SSHFS-Win --exact --accept-source-agreements
   --accept-package-agreements`. Exit 0 → `Write-Ok`. Non-zero (UAC declined, network,
   store agreement issues) → **soft-fail** with the manual one-liner. Deliberately **no
   MSI retry after a winget failure** — the failure cause (declined UAC, no network) would
   just recur and pop a second UAC prompt.
4. **MSI fallback** (winget absent): for each entry in `Msi`, in order:
   - Skip if its own `DetectName` is already registered (WinFsp may pre-exist for other
     tools, e.g. rclone mounts).
   - Resolve `releases/latest` via the GitHub API (same headers/`$env:GITHUB_TOKEN`
     pattern as `Install-InstallerTool`), match `AssetMatch`, download to `$env:TEMP`.
   - **Verify:** API `digest` if present → else `Sha256Pin` if present → else warn+proceed
     (same escalation as `$InstallerTools`). **Mismatch = refuse this tool** (delete file,
     loud `Write-Bad`) **but continue the bootstrap** — unlike the portable/installer
     classes this class must never hard-exit, so no `Write-Fail` here.
   - Install: `Start-Process msiexec -ArgumentList "/i <msi> /qn /norestart" -Verb RunAs
     -Wait -PassThru`. Declined UAC throws → catch → soft-fail. Exit 0 → ok; exit 3010 →
     ok + "reboot may be required"; other → warn.
   - Temp MSI removed in `finally`.
5. **Every failure mode** (no winget, API lookup failure, download failure, hash mismatch,
   UAC declined, non-interactive session) lands on warn-and-continue with manual
   instructions (`winget install SSHFS-Win.SSHFS-Win` or the two GitHub release URLs).

### 3. New flag: `-SkipElevated`

Skips the `$ElevatedTools` loop only. `-SkipToolInstall` already skips all of
`Invoke-ToolInstall` including this. Header comment updates: flow narrative, flags list,
and the "NO ADMIN REQUIRED" paragraph amended to document the one sanctioned,
skippable, soft-failing exception.

### 4. `-Doctor` and `-CheckForUpdates`

- **Doctor** ("Installer apps + extras" section): presence lines for SSHFS-Win and WinFsp
  via `Test-InstallerPresent` + `Get-InstalledAppVersion`; absent → warn with the
  re-run/manual hint (not `Write-Bad` — the tool is best-effort/optional).
- **CheckForUpdates**: new "Elevated tools" stanza — installed registry version vs
  `Get-LatestGitTag` for `winfsp/sshfs-win` and `winfsp/winfsp`, hint
  `winget upgrade SSHFS-Win.SSHFS-Win`.

### 5. Docs + invariants

- **README.html §setup-windows:** add SSHFS-Win to the tool table (marked "elevated —
  UAC prompt, best-effort"), describe the winget → MSI → manual chain, the
  `-SkipElevated` flag, and a one-line usage pointer (`\\sshfs\user@host`).
- **README.html §troubleshooting:** one entry — "bootstrap popped a UAC prompt /
  SSHFS-Win skipped": why (kernel driver), how to skip, how to install manually.
- **CLAUDE.md:** amend the "Windows tool installs are admin-free" invariant bullet to
  name the `$ElevatedTools` exception (best-effort, UAC-prompting, soft-fail,
  `-SkipElevated`; SSHFS-Win pulls the WinFsp kernel driver, hence machine-scope).
- **CLAUDE_CHANGELOG.md:** append a row (README updated: yes).
- **`docs/windows/application_list.md`:** no entry — the list omits apps auto-installed
  by `bootstrap.ps1`.

## Error handling summary

| Failure | Behavior |
|---|---|
| Already installed | Skip silently-ok; no UAC |
| winget present, install fails (UAC declined / network) | Warn + manual one-liner; continue |
| winget absent | MSI fallback chain |
| GitHub API / download failure | Warn + manual one-liner; continue |
| Hash mismatch (digest or pin) | Delete download, loud warn, refuse tool, continue |
| UAC declined on msiexec (`-Verb RunAs` throws) | Catch, warn + manual one-liner, continue |
| msiexec exit 3010 | Success + "reboot may be required" |

## Testing

- `make -C makefile ps-lint` (PSScriptAnalyzer) passes; `bootstrap.ps1` retains its UTF-8 BOM.
- On the Windows host: `-Doctor` before/after; a fresh run installs via winget (UAC
  accepted); `-SkipElevated` run shows the skip line; already-installed rerun shows no UAC.
- Mount smoke test: `net use X: \\sshfs\<user>@<linux-host>` then `dir X:`.

## Out of scope

- SSHFS-Win Manager (GUI) — the core `\\sshfs` UNC provider is enough.
- A generic winget-backed class for future tools (rejected: re-opens the
  package-manager door the de-chocolatey redesign deliberately closed).
- Pinning WinFsp/SSHFS-Win versions in `$PortableTools`/`versions.mk` — this class
  follows the `$InstallerTools` latest-release model (winget installs latest anyway).
