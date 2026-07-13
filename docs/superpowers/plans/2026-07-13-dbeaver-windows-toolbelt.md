# DBeaver CE Windows Toolbelt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-install DBeaver Community Edition on the Windows host as the fourth `$InstallerTools` app in `bootstrap.ps1`, with a new opt-in `TagPrefix` field so `-CheckForUpdates` can resolve DBeaver's bare (un-`v`-prefixed) git tags.

**Architecture:** One data entry in the existing `$InstallerTools` manifest (latest-GitHub-release, digest-verified, NSIS silent per-user via `/S /currentuser`, Uninstall-registry idempotency) + a two-line ContainsKey-guarded extension in the `-CheckForUpdates` installer loop + a docs sweep. No new files, no version pins, no Linux half.

**Tech Stack:** PowerShell 5.1-compatible script edits (`bootstrap.ps1`), HTML/Markdown docs.

**Spec:** `docs/superpowers/specs/2026-07-13-dbeaver-windows-toolbelt-design.md` (approved 2026-07-13).

## Global Constraints

- Work on the existing `feat/dbeaver` branch (spec already committed there as `e7a238c`).
- `bootstrap.ps1` MUST keep its **UTF-8 BOM** and **LF** line endings after every edit (PS 5.1 mis-decodes glyphs without the BOM). The repo's `post-edit-guard` hook auto-repairs both and tells you to re-read — obey it. Verify manually anyway (commands in Task 1 Step 5).
- All PowerShell must be **5.1-compatible**: no `??`, no ternary, hashtable key probes via `.ContainsKey()` (StrictMode-safe).
- Installer-class rules: **no admin/UAC anywhere, nothing added to PATH**, existing entries (Obsidian/Zed/DevToys) bit-for-bit unchanged.
- **No `versions.mk` change** → no `check-invariants.sh` addition, no TOOLS-block regeneration, no `cza` needed.
- README/CLAUDE.md/changelog land in the same PR as the code (squash-merge satisfies the "same commit" doc rule).
- Windows-host runtime verification is **post-merge, manual, by the user** (no Windows here); this plan's verification is lint + premise proofs.

---

### Task 1: `bootstrap.ps1` — DBeaver entry + opt-in `TagPrefix`

**Files:**
- Modify: `bootstrap.ps1:317` (banner comment — opt-in fields list)
- Modify: `bootstrap.ps1:340-349` (append DBeaver entry to `$InstallerTools`)
- Modify: `bootstrap.ps1:1710-1713` (`-CheckForUpdates` installer loop)

**Interfaces:**
- Consumes: existing `Install-InstallerTool` (no changes — `SilentArgs` is passed through as a free-form string), `Get-LatestGitTag -TagPrefix` parameter (already exists, default `"v"`), `$tool.ContainsKey()` hashtable probing precedent (`IncludePrerelease`).
- Produces: `$InstallerTools` entry `Name = "DBeaver"` with new optional key `TagPrefix` (string, may be `""`); the `-CheckForUpdates` loop honors `TagPrefix` on any installer tool. Task 2's docs describe exactly these.

- [ ] **Step 1: Prove the premise (bare tags) so a future engineer trusts the mechanism change**

Run:

```bash
GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs https://github.com/dbeaver/dbeaver.git "refs/tags/v*" | wc -l
GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs https://github.com/dbeaver/dbeaver.git "refs/tags/26.*" | tail -2
```

Expected: first command prints `0` (zero `v`-prefixed tags — the default `TagPrefix "v"` would resolve `$null`); second prints bare-numeric tag refs (e.g. `refs/tags/26.1.2`). Verified 2026-07-13; if the first command is non-zero upstream changed their tagging — stop and re-check the spec.

- [ ] **Step 2: Update the `$InstallerTools` banner comment (opt-in fields: two → three)**

In `bootstrap.ps1`, replace:

```powershell
# Two OPT-IN per-tool fields (absent = old behavior, Obsidian/Zed untouched):
#   IncludePrerelease  resolve the newest NON-DRAFT release from /releases
#                      instead of /releases/latest — DevToys flags EVERY 2.x
#                      release prerelease:true, so "latest" returns 2023's
#                      v1.0.13.0 (an MSIX-only release with no .exe asset).
#   UpdateHint         status text for -Doctor/-CheckForUpdates when the
#                      default "self-updates" story is wrong — DevToys' in-app
#                      update check is notification-only (it never installs).
```

with:

```powershell
# Three OPT-IN per-tool fields (absent = old behavior, Obsidian/Zed untouched):
#   IncludePrerelease  resolve the newest NON-DRAFT release from /releases
#                      instead of /releases/latest — DevToys flags EVERY 2.x
#                      release prerelease:true, so "latest" returns 2023's
#                      v1.0.13.0 (an MSIX-only release with no .exe asset).
#   UpdateHint         status text for -Doctor/-CheckForUpdates when the
#                      default "self-updates" story is wrong — DevToys' in-app
#                      update check is notification-only (it never installs).
#   TagPrefix          git-tag prefix for the -CheckForUpdates version lookup
#                      (default "v") — DBeaver's tags are bare (26.1.2), so it
#                      overrides with "" or the update scan resolves nothing.
```

- [ ] **Step 3: Append the DBeaver entry to `$InstallerTools`**

Replace (the DevToys entry tail + array close — unique in the file):

```powershell
        IncludePrerelease = $true                     # see banner: /releases/latest lies for this repo
        UpdateHint        = "update-checks in-app only (no self-update); re-run bootstrap with -ForceInstaller to update"
    }
)
```

with:

```powershell
        IncludePrerelease = $true                     # see banner: /releases/latest lies for this repo
        UpdateHint        = "update-checks in-app only (no self-update); re-run bootstrap with -ForceInstaller to update"
    },
    @{
        Name       = "DBeaver"
        Repo       = "dbeaver/dbeaver"                 # CE; /releases/latest is honest here (unlike DevToys)
        AssetMatch = "dbeaver-ce-*-windows-x86_64.exe" # NSIS installer (NOT -aarch64.exe, NOT the .zip archives)
        SilentArgs = "/S /currentuser"                 # NSIS silent + MultiUser per-user pin -> no admin/UAC
        DetectName = "DBeaver*"                        # HKCU ...\Uninstall\"DBeaver (current user)"; glob also matches commercial editions (intended: never force CE alongside a licensed install); MS-Store MSIX copies are invisible here and would double-install (known class caveat, same as DevToys)
        TagPrefix  = ""                                # tags are bare (26.1.2, no v) — read by the -CheckForUpdates lookup only
    }
)
```

No `IncludePrerelease` (DBeaver's `/releases/latest` is honest, `prerelease: false`) and no `UpdateHint` (DBeaver genuinely self-updates: on the new-version prompt, consent downloads and launches the installer — dbeaver/dbeaver#3299).

- [ ] **Step 4: Honor `TagPrefix` in the `-CheckForUpdates` installer loop**

Replace (unique — the elevated-tools loop below it has no `$hasHint` line; include it to disambiguate):

```powershell
    foreach ($tool in $InstallerTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $latest    = Get-LatestGitTag -Repo $tool.Repo
        $hasHint   = $tool.ContainsKey('UpdateHint')
```

with:

```powershell
    foreach ($tool in $InstallerTools) {
        $installed = Get-InstalledAppVersion -DisplayName $tool.DetectName
        $tagPrefix = if ($tool.ContainsKey('TagPrefix')) { $tool.TagPrefix } else { 'v' }
        $latest    = Get-LatestGitTag -Repo $tool.Repo -TagPrefix $tagPrefix
        $hasHint   = $tool.ContainsKey('UpdateHint')
```

`Get-LatestGitTag` already handles `""` correctly: `refs/tags/*` glob, `StartsWith("")` always true, `Substring(0)` no-op, and the `^\d+(\.\d+)*$` filter admits `26.1.2` (`[version]` sort picks the numeric max). The `-Doctor` installer loop never queries tags — do NOT touch it. The elevated-tools loop keeps the default (SSHFS-Win tags are `v`-prefixed).

- [ ] **Step 5: Verify encoding invariants survived the edits**

Run:

```bash
file bootstrap.ps1
git ls-files --eol bootstrap.ps1
```

Expected: `UTF-8 Unicode (with BOM) text` and `i/lf w/lf`. If the `post-edit-guard` hook reported an auto-repair, re-read the touched regions before continuing.

- [ ] **Step 6: Lint**

Run:

```bash
make -C makefile ps-lint MODE=prod
make -C makefile lint MODE=prod
```

Expected: `ps-lint` passes (or soft-skips with a "pwsh not found" note — CI's `lint.yml` enforces PSScriptAnalyzer regardless); `lint` all-green (the BOM check covers `bootstrap.ps1`; no new invariant checks apply).

- [ ] **Step 7: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): DBeaver CE as fourth installer-class app + opt-in TagPrefix for -CheckForUpdates"
```

---

### Task 2: Docs sweep (README, app list, CLAUDE.md, changelog)

**Files:**
- Modify: `README.html:2888-2889` (new DBeaver `<li>` after DevToys), `README.html:3023`, `README.html:3082-3084`, `README.html:4651-4652`
- Modify: `docs/windows/application_list.md:2`
- Modify: `CLAUDE.md:91` (installer-class invariant bullet — three micro-edits)
- Modify: `CLAUDE_CHANGELOG.md` (append one row)

**Interfaces:**
- Consumes: Task 1's exact behavior — entry fields (`AssetMatch "dbeaver-ce-*-windows-x86_64.exe"`, `SilentArgs "/S /currentuser"`, `DetectName "DBeaver*"`, `TagPrefix ""`), the three-opt-in-field class model.
- Produces: nothing consumed downstream (terminal docs task).

- [ ] **Step 1: README — insert the DBeaver `<li>` between DevToys and SSHFS-Win**

In `README.html`, replace:

```html
                        <li>
                            <strong>SSHFS-Win</strong> &mdash; mounts remote
```

with:

```html
                        <li>
                            <strong>DBeaver</strong> &mdash; same
                            installer-class path: silent, per-user install of
                            its NSIS <code>.exe</code>
                            (<code>/S /currentuser</code> &mdash; no admin),
                            verified against the GitHub API&rsquo;s sha256
                            digest and detected via the Uninstall registry.
                            Community Edition; bundles its own JRE; genuinely
                            self-updates after the seed
                            (<code>-ForceInstaller</code> to reseed manually).
                        </li>
                        <li>
                            <strong>SSHFS-Win</strong> &mdash; mounts remote
```

- [ ] **Step 2: README — extend the `-ForceInstaller` flag comment**

Replace:

```html
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian, Zed, DevToys) even if present
```

with:

```html
.\bootstrap.ps1 -ForceInstaller                  # re-install installer tools (Obsidian, Zed, DevToys, DBeaver) even if present
```

- [ ] **Step 3: README — extend the `-SkipToolInstall` prose (two spots in one paragraph)**

Replace:

```html
                        (Obsidian, Zed, DevToys) and the native
```

with:

```html
                        (Obsidian, Zed, DevToys, DBeaver) and the native
```

then replace:

```html
                        (assumes they&rsquo;re already present). Obsidian, Zed, and DevToys install
```

with:

```html
                        (assumes they&rsquo;re already present). Obsidian, Zed, DevToys, and DBeaver install
```

- [ ] **Step 4: README — extend the troubleshooting sha256 entry's enumeration**

Replace:

```html
                                (<code>$InstallerTools</code>, e.g. Obsidian,
                                Zed, DevToys) are
```

with:

```html
                                (<code>$InstallerTools</code>, e.g. Obsidian,
                                Zed, DevToys, DBeaver) are
```

- [ ] **Step 5: application list — DBeaver joins the auto-installed parenthetical**

In `docs/windows/application_list.md` line 2, replace:

```
Apps auto-installed by bootstrap.ps1 (WezTerm, Starship, Obsidian, Zed, DevToys, Claude Code — plus chezmoi, Helix, and the JetBrainsMono Nerd Font, which were never listed here) are omitted; where they had in-row alternatives, those alternatives are kept.
```

with:

```
Apps auto-installed by bootstrap.ps1 (WezTerm, Starship, Obsidian, Zed, DevToys, DBeaver, Claude Code — plus chezmoi, Helix, and the JetBrainsMono Nerd Font, which were never listed here) are omitted; where they had in-row alternatives, those alternatives are kept.
```

(DBeaver never had a standalone row — nothing to remove.)

- [ ] **Step 6: CLAUDE.md — three micro-edits inside the installer-class bullet (line 91)**

Edit 6a — example list + the "only a silent .exe" claim (DBeaver *does* ship a portable zip; we deliberately don't pin it). Replace:

```
(`$InstallerTools` in `bootstrap.ps1`, e.g. Obsidian + Zed + DevToys)** for apps that ship only a silent `.exe` (no portable zip):
```

with:

```
(`$InstallerTools` in `bootstrap.ps1`, e.g. Obsidian + Zed + DevToys + DBeaver)** for apps installed via a silent `.exe` (no portable zip worth pinning):
```

Edit 6b — `SilentArgs` examples. Replace:

```
(Obsidian = NSIS `/S`; Zed = Inno Setup `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, `PrivilegesRequired=lowest`)
```

with:

```
(Obsidian = NSIS `/S`; Zed = Inno Setup `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, `PrivilegesRequired=lowest`; DBeaver = NSIS MultiUser `/S /currentuser`)
```

Edit 6c — the opt-in fields sentence (two → three). Replace:

```
DevToys carries the class's two OPT-IN fields: `IncludePrerelease` (all its 2.x releases are `prerelease:true`, so `/releases/latest` returns 2023's v1.0.13.0 — the resolver takes the newest non-draft of `/releases` instead) and `UpdateHint` (DevToys does NOT self-update — its in-app check is notification-only; Doctor/CheckForUpdates print the hint instead of "self-updates").
```

with:

```
The class has three OPT-IN per-tool fields (absent = old behavior): DevToys carries `IncludePrerelease` (all its 2.x releases are `prerelease:true`, so `/releases/latest` returns 2023's v1.0.13.0 — the resolver takes the newest non-draft of `/releases` instead) and `UpdateHint` (DevToys does NOT self-update — its in-app check is notification-only; Doctor/CheckForUpdates print the hint instead of "self-updates"); DBeaver carries `TagPrefix` (its git tags are bare — `26.1.2`, no `v` — so the `-CheckForUpdates` tag lookup overrides the default `v` with `""`).
```

- [ ] **Step 7: Confirm the two Claude reference docs need no edits (verified at plan time — re-confirm cheaply)**

Run:

```bash
rg -n "InstallerTools|Obsidian" docs/claude/invariants.md docs/claude/file-care.md
```

Expected: `invariants.md` has NO installer-class content (no matches) — nothing to update. `file-care.md` matches only its generic "`$InstallerTools` manifest (installer-layout class, e.g. Obsidian)" sentence — left as-is (the DevToys PR set this precedent; "e.g." is non-exhaustive). If you see anything else enumerate Obsidian/Zed/DevToys, extend it with DBeaver.

- [ ] **Step 8: CLAUDE_CHANGELOG.md — append one row at the end of the table**

```markdown
| Added DBeaver CE as the fourth installer-class app in `bootstrap.ps1` (`$InstallerTools`: latest GitHub release, digest-verified, NSIS `/S /currentuser` silent per-user — no admin; Uninstall-registry detect; bundles its own JRE; real self-update so no `UpdateHint`), plus a third opt-in class field `TagPrefix` — DBeaver's git tags are bare (`26.1.2`, no `v`), so the `-CheckForUpdates` lookup needed a ContainsKey-guarded prefix override (default `'v'`; Obsidian/Zed/DevToys untouched). MS-Store MSIX copies stay invisible to the registry detect (known class caveat, carried as a code comment). | **Yes** | §setup-windows: DBeaver installer-class entry after DevToys; `-ForceInstaller` flag-line and `-SkipToolInstall` prose enumerations gain DBeaver; §troubleshooting sha256-mismatch entry's installer-class enumeration gains DBeaver. |
```

- [ ] **Step 9: Lint**

Run:

```bash
make -C makefile lint MODE=prod
```

Expected: all-green (docs edits can't break invariants, but the pre-commit hook runs this anyway — fail here, not there).

- [ ] **Step 10: Commit**

```bash
git add README.html docs/windows/application_list.md CLAUDE.md CLAUDE_CHANGELOG.md
git commit -m "docs: DBeaver in Windows setup, app list, installer-class invariant + changelog"
```

---

## Post-merge (user, Windows host — NOT part of this plan)

From the spec §4: re-run `bootstrap.ps1` → DBeaver installs silently per-user (no UAC), Start-menu entry present, HKCU `DBeaver (current user)` key exists (record the actual DisplayName); immediate re-run skips it; `-Doctor` shows a green DBeaver row; `-CheckForUpdates` shows DBeaver with a resolved latest version (proves the bare-tag fix); Obsidian/Zed/DevToys lines unchanged in both.
