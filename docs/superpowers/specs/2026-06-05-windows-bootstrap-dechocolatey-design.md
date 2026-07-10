# Windows bootstrap: remove Chocolatey, switch to binary/portable installs

**Date:** 2026-06-05
**Scope:** `bootstrap.ps1` (Windows client entry point) + the user-facing docs and Claude-internal notes that describe it.
**Status:** Design — pending user review.

## Goal

Remove Chocolatey and all admin/elevation requirements from the Windows bootstrap. The
Windows host should provision with **no package manager and no admin rights**, installing
only what's needed from first-party binaries/portable archives into a single per-user
location. Git becomes a hard prerequisite the user installs themselves.

## Motivation

The current `bootstrap.ps1` bootstraps Chocolatey itself, requires an elevated PowerShell,
and installs seven tools (chezmoi, git, starship, zoxide, wezterm, zed, vscode) through it.
The user wants to drop Chocolatey entirely in favor of admin-free, self-contained installs,
keeping only the genuinely-automatic essentials and letting the GUI editors be installed by
hand.

## Install model (the core decision)

Everything provisioned by the script lands under a single root:

```
$Root = "$env:LOCALAPPDATA\workstation"
  $Root\bin\        # single-exe tools: chezmoi, starship   (added to User PATH)
  $Root\wezterm\    # WezTerm portable tree (multi-file)     (added to User PATH)
  $Root\stamps\     # per-tool "<tool>.<version>.stamp" idempotency markers
```

| Tool | Handling | Location | Pinned? |
|---|---|---|---|
| **Git** | User-installed. **Hard-fail** with install instructions if not on PATH. No install attempt. | — | — |
| **chezmoi** | Auto-install via the official `get.chezmoi.io` PowerShell installer pointed at `$Root\bin` via `-BinDir`. First-party, self-verifying, admin-free, tracks latest (security updates). | `$Root\bin` | latest (installer self-verifies) |
| **WezTerm** | Auto-download portable `.zip` from GitHub releases → sha256-verify → extract the whole tree. | `$Root\wezterm` | **version + sha256 in `bootstrap.ps1`** |
| **Starship** | Auto-download portable `.zip` from GitHub releases → sha256-verify → place `starship.exe`. | `$Root\bin` | **version + sha256 in `bootstrap.ps1`** |
| **zoxide** | **Dropped entirely**, no mention. The PowerShell profile's `zoxide init` is already `Get-Command`-guarded and no-ops cleanly when absent. | — | — |
| **Zed** | Manual-install. **Soft-warn** (never fail) if not on PATH. Its chezmoi config still deploys. | — | — |
| **VSCode** | Manual-install. **Soft-warn** (never fail) if `code` not on PATH. Its chezmoi config still deploys. | — | — |
| **BurntToast** | Kept as-is (PSGallery, CurrentUser scope — not Chocolatey). | — | — |
| **Nerd Fonts** | Kept as-is (`scripts\install-nerd-fonts.ps1`, per-user HKCU). | — | — |
| **SSH key** | Kept as-is (prompt-driven `ssh-keygen`). | — | — |

**Why chezmoi via the official installer rather than the pinned portable helper:** it is
first-party, self-verifies its own checksum, and tracks the latest release (so security
fixes arrive without a manual bump). WezTerm and Starship are pinned because the user
explicitly chose reproducible pinned installs for the auto-downloaded portable binaries.
*(This split is a confirmable — see "Decisions to confirm before implementation".)*

## Admin / elevation

**Removed entirely.** Every remaining step is admin-free:
- chezmoi installer → user `$Root\bin`
- portable downloads → user `$Root`
- PATH edits → `[Environment]::SetEnvironmentVariable(..., 'User')` (no machine scope)
- BurntToast → `-Scope CurrentUser`
- Nerd Fonts → HKCU registration
- ssh-keygen → user `~/.ssh`

So `Test-IsAdmin`, the admin gate in `Invoke-Preflight`, and the "RUN FROM AN ELEVATED
PowerShell" guidance all go away.

## Script structure changes

### Remove
- **All legacy handling** (clean sweep):
  - `Invoke-LegacyPathMigrate` (the `C:\Git\workstation` → home-dir move) — function, its
    MAIN call, the `0a` header-comment block, and the `-Yes` doc mention of legacy auto-move.
  - The WezTerm legacy-hardlink cleanup inside `Invoke-WeztermConfigEnv` (the block that
    deletes a stale `%USERPROFILE%\.config\wezterm\wezterm.lua`) and the header-comment
    sentence that documents it. `Invoke-WeztermConfigEnv` is reduced to just setting the
    `WEZTERM_CONFIG_FILE` env var.
- `Test-IsAdmin`.
- `Install-Chocolatey`.
- `$ChocoTools` array and the choco orphan-detection / `choco list --force` logic.
- `Invoke-ChocoInstall` (replaced — see below).
- The "WHY CHOCOLATEY (not winget)" comment block and the elevated-shell one-liner framing.

### Add
- **`$Root` / path constants** and a **`$PortableTools`** pinned manifest (one hashtable per
  pinned portable tool: `Name`, `Version`, `Url` (with version interpolated), `Sha256`,
  `Exe` (PATH command to verify), `Layout` = `single` | `tree`, `Dest`).
- **`Install-PortableTool`** — the reusable installer (see next section).
- **`Add-ToUserPath $dir`** — idempotent User-PATH append + current-session refresh
  (only appends if the dir isn't already present).
- **`Install-Chezmoi`** — fetch `get.chezmoi.io/ps1`, invoke it with `-BinDir "$Root\bin"`;
  skip if `chezmoi` already on PATH; ensure `$Root\bin` is on PATH.
- **`Invoke-ToolInstall`** — orchestrates: ensure `$Root` dirs → `Install-Chezmoi` →
  `Install-PortableTool` for each `$PortableTools` entry → soft-warn checks for Zed + VSCode.
  Replaces `Invoke-ChocoInstall` in MAIN.

### Modify
- **Header comment block** — rewrite the flow narrative (no choco, no admin, new install
  model, Git-as-prerequisite, dropped legacy migration).
- **`Invoke-Preflight`** — becomes: **Git present?** (hard-fail with a clear "install Git for
  Windows from https://git-scm.com/download/win and re-run" message if missing) →
  **chezmoi** handled by the install step (no admin classification) → **ssh-keygen** soft-warn
  (unchanged). Drop all admin/choco bucketing and `$script:NeedsChocoInstall`.
- **`-SkipToolInstall`** — repurposed: "skip the chezmoi/WezTerm/Starship auto-installs;
  assume they're already on PATH." Git is still required (hard-fail) because the clone needs
  it; chezmoi still required if the chezmoi-apply step will run (mirrors current `-SkipToolInstall`
  semantics for chezmoi).
- **`Invoke-Reinstall`** help text — replace the `choco uninstall ...` line with the new
  cleanup hint (`Remove-Item -Recurse -Force "$env:LOCALAPPDATA\workstation"` to drop the
  portable tools; chezmoi/starship/wezterm re-download on the next run).
- **MAIN** — new order: `Invoke-Preflight → Invoke-ToolInstall → Invoke-CloneRepo →
  Invoke-Chezmoi → Invoke-WeztermConfigEnv → Invoke-InstallBurntToast → Invoke-InstallNerdFonts
  → Invoke-EnsureSshKey`. (No `Invoke-LegacyPathMigrate`.)

## `Install-PortableTool` design

A single function that turns a pinned manifest entry into an installed, on-PATH tool, modeled
on the existing `scripts\install-nerd-fonts.ps1` (download + Get-FileHash verify + stamp gate).

Behavior:
1. **Idempotency gate:** if `$Root\stamps\<exe>.<version>.stamp` exists *and* `Get-Command <exe>`
   resolves, log "already installed" and return. (A version bump changes the stamp name → reinstall.)
2. **Download:** TLS-1.2 bump, `Invoke-WebRequest -Uri $Url -OutFile <temp.zip>`. Hard-fail on
   download error.
3. **Verify:** `Get-FileHash -Algorithm SHA256`. If it doesn't equal the pinned `Sha256`,
   **hard-fail** (do not install an unverified binary).
4. **Extract + place:**
   - `Layout = single`: `Expand-Archive` to temp, copy `<exe>.exe` into `$Root\bin`.
   - `Layout = tree`: clear `$Dest`, `Expand-Archive` and move the tree into `$Dest` (handle the
     single-top-level-folder case WezTerm zips use).
5. **PATH:** `Add-ToUserPath $Dest` (for `tree`) / `Add-ToUserPath $Root\bin` (for `single`).
6. **Stamp:** write `$Root\stamps\<exe>.<version>.stamp`.
7. **Failure policy:** WezTerm/Starship download or extract failures are **warn-not-fail** (the
   bootstrap still completes; dotfiles apply; the user can re-run). A **sha256 mismatch is the one
   hard-fail** inside the helper — that's a tamper/corruption signal, not a transient miss.

## Version pinning

Pins (version + sha256) live **in `bootstrap.ps1`** in the `$PortableTools` manifest — the same
self-contained pattern `scripts\install-nerd-fonts.ps1` already uses (`$Version` + `$Sha256` in
the script body). **Not** `makefile/versions.mk` — Make never runs on Windows, and the existing
Nerd Fonts precedent keeps Windows pins in their `.ps1`. No template/Make bridge to keep in sync.

At implementation time the pins must be sourced for real:
- **Starship:** download URL `https://github.com/starship/starship/releases/download/<v>/starship-x86_64-pc-windows-msvc.zip`; sha256 from the release's published checksums (or compute from the downloaded asset).
- **WezTerm:** date-stamped tags (e.g. `20240203-110809-5046fc22`); asset `WezTerm-windows-<tag>.zip`; sha256 from the release. Asset naming and the inner folder name need verifying against the actual release.

If network access to the releases is unavailable during implementation, leave clearly-marked
`<<PIN-ME>>` placeholders + a TODO; the sha256 verify step will hard-fail loudly rather than
install something wrong.

## Files to touch

1. **`bootstrap.ps1`** — all of the above. **Must retain its UTF-8 BOM** (PS 5.1 dependency).
   Verify after editing: `file bootstrap.ps1` → "UTF-8 Unicode (with BOM) text". Restore via the
   `[System.IO.File]::WriteAllText(..., UTF8Encoding::new($true))` one-liner if the BOM is lost.
2. **`README.html`** (+ `docs/README/README.css`/`.js` only if needed) — heavy edits to:
   - §intro / layout: the "choco + chezmoi apply, elevated" entry-point descriptions.
   - §setup-windows: "Run from elevated PowerShell", "Tools installed (via Chocolatey)", the
     WHY-choco note, the one-liner (drop "elevated"), the step diagram's "admin check / Bootstrap
     Choco + tools" nodes, and the admin-required prose. Replace with: Git-as-prerequisite,
     binary/portable installs under `%LOCALAPPDATA%\workstation`, no admin, manual Zed/VSCode.
   - §troubleshooting: the choco-specific entries ("Admin required to install", "registered with
     choco", "Chocolatey install completed but `choco`", "choco install says...") — replace with
     the new failure modes (Git missing → hard-fail; sha256 mismatch; PATH not refreshed →
     open a new shell).
   - The journal-filter placeholder example that lists `choco` as a sample filter term.
3. **`CLAUDE_CHANGELOG.md`** — append a row (user-facing change → README updated: Yes).
4. **`docs/claude/file-care.md`** — extend the `bootstrap.ps1` entry: besides the BOM, it now
   carries **pinned `version` + `sha256` for WezTerm and Starship** in `$PortableTools` (bump =
   edit version + refresh sha256, same discipline as `install-nerd-fonts.ps1`).
5. **`.claude/memory/feedback-windows-chezmoi-check-before-apply.md`** — update the stale chezmoi
   location (`C:\ProgramData\chocoportable\bin\chezmoi.exe` → `%LOCALAPPDATA%\workstation\bin\chezmoi.exe`)
   and the reinstall hint (`choco install -y chezmoi` → re-run `bootstrap.ps1`, which reinstalls
   chezmoi via the official binary installer). Update `.claude/memory/MEMORY.md` pointer if its
   hook text references choco.
6. **`CLAUDE.md`** — optionally add a one-line invariant: "Windows tool installs are admin-free
   binary/portable downloads under `%LOCALAPPDATA%\workstation` (no Chocolatey); WezTerm/Starship
   pins live in `bootstrap.ps1`." *(Claude-internal; no README/changelog needed for this file.)*

## Out of scope

- `bootstrap.sh` and the Linux/Make provisioning — untouched.
- Removing already-Chocolatey-installed tools from existing hosts — left to the user; the script
  just stops managing them. Existing choco installs keep working (Get-Command finds them and the
  new flow skips re-installing).
- Auto-installing Zed/VSCode — explicitly user-manual now.
- WezTerm config delivery — unchanged in mechanism (`WEZTERM_CONFIG_FILE` env var still points
  at the chezmoi source). Only the legacy-hardlink cleanup is removed.

## Risks / things to verify

- **BOM preservation** on `bootstrap.ps1` after editing (PS 5.1 will fail to parse the glyphs
  without it). Verify with `file`.
- **sha256 sourcing** for the pins (network-dependent at implementation time).
- **WezTerm asset/folder naming** — date-stamped tags and the inner directory layout of the zip
  must be checked against a real release, not assumed.
- **PATH propagation** — new PATH entries won't be visible in the *current* shell unless we also
  refresh `$env:PATH` in-session; the script does this, but the closing message should still tell
  the user to open a new shell for good measure.
- **`get.chezmoi.io/ps1` `-BinDir` invocation** — the scriptblock-from-downloaded-text call must
  be validated (the documented one-liner's escaping is finicky).
- **Zed on Windows** — newer/preview-grade; soft-warn (never fail) is the safe choice and is what
  we do.

## Decisions (confirmed 2026-06-05)

1. **chezmoi = official `get.chezmoi.io` installer** (latest, self-verified) into `$Root\bin` —
   not pinned. ✅ confirmed.
2. **Drop all legacy handling**, including the WezTerm legacy-hardlink cleanup —
   `Invoke-WeztermConfigEnv` only sets the env var. ✅ confirmed (clean sweep).
3. **`-SkipToolInstall` repurposed** ("skip chezmoi/WezTerm/Starship auto-installs"), name kept.
   ✅ confirmed.
