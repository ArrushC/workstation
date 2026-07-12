# DevToys in the toolbelt: GUI installer-class on Windows, CLI portable on Windows + Linux dev

**Date:** 2026-07-11
**Scope:** `bootstrap.ps1` (one `$InstallerTools` entry + `IncludePrerelease`/`UpdateHint` mechanism extensions, one `$PortableTools` entry + Dest var), `makefile/versions.mk` (`DEVTOYS_CLI_VERSION`), new `makefile/lib/devtoys-cli.sh`, `makefile/Makefile` (dev-only bespoke target), `scripts/check-invariants.sh` (dual-edit pin check), `docs/windows/application_list.md`, `README.html`, `CLAUDE.md`, `docs/claude/invariants.md`, `docs/claude/file-care.md`, `CLAUDE_CHANGELOG.md`.
**Status:** Design — pending user review.

## Goal

Add [DevToys](https://devtoys.app) ("Swiss Army knife for developers") to the toolbelt:

- **DevToys GUI** — auto-installed on the Windows host by `bootstrap.ps1`, installer
  class (the Obsidian/Zed pattern), and removed from the manual
  `docs/windows/application_list.md` list (the Zed precedent: named in the header
  line of auto-installed apps instead).
- **DevToys CLI** (`DevToys.CLI`) — the command-line version of its tools, installed
  as a pinned portable tool on Windows AND a dev-only bespoke install on Linux
  (the OpenCode/omp cross-platform precedent, but tree-shaped, not eget-able).

**User decisions (2026-07-11):** GUI + CLI (not GUI-only); CLI on Windows + Linux
dev (not Windows-only); GUI via installer class + prerelease-aware resolver
(approach A — over a pinned portable GUI zip or winget).

## Verified upstream facts (2026-07-11)

Researched from the GitHub API, the `DevToys-app/Publish` build source, and the
winget manifest (full citations in the research notes; key facts below).

- **Latest release: v2.0.9.0** (2026-01-08). Tag format `vX.Y.Z.0`.
- **THE PRERELEASE TRAP:** every 2.x release is flagged `prerelease: true`
  (branded "2.0 Preview"), so `GET /releases/latest` returns **v1.0.13.0
  (2023)** — an MSIX-only release with no `.exe`/`.zip` assets. A stock
  `$InstallerTools` entry would match no asset and skip forever. Any "latest"
  resolver must take the first non-draft entry of `/releases` (or pin a tag).
  `Get-LatestGitTag` is UNAFFECTED — it reads git tags via `git ls-remote`
  (v2.0.9.0 sorts correctly under `[version]`), so `-CheckForUpdates`
  comparisons work without changes.
- **GUI installer** (`devtoys_win_x64.exe`, also arm64/x86): **Inno Setup**,
  generated at build time (`GuiPackingWindows.cs` in `DevToys-app/Publish`), with
  `PrivilegesRequired(Lowest)` → **per-user, no admin/UAC**, default dir
  `{userpf}\DevToys` (= `%LOCALAPPDATA%\Programs\DevToys`). Silent flags:
  `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` (winget manifest confirms
  `InstallerType: inno`, `Scope: user`). The `[Run]` post-install launch carries
  `SkipIfSilent` — silent installs don't pop the app.
- **Uninstall registry:** `HKCU\...\Uninstall\DevToys_is1`, DisplayName defaults
  to **"DevToys <version>"** (version-suffixed — Inno AppName+AppVersion default),
  so detection must prefix-glob `DevToys*`. Preview builds use app name
  "DevToys Preview", which the glob also matches — acceptable: a user already
  running Preview shouldn't get a stable seed forced alongside.
- **No self-update:** the in-app check (`AppHelper.CheckForUpdateAsync`) is
  **notification-only** — it never downloads or installs. The installer class's
  "self-updates after" rationale doesn't hold; the update path is the in-app
  notice + re-running bootstrap with `-ForceInstaller`.
- **Digests:** all v2.0.9.0 assets expose the GitHub API per-asset sha256
  `digest` (e.g. `devtoys_win_x64.exe` →
  `e099d9fc6771110c3371bb8adc778312d34ec0963a2f86dee4f7c1661b7e7c0f`, matching
  the winget `InstallerSha256`). Existing digest verification works unchanged.
  CLI zips, verified this session (API digest AND `sha256sum` of the downloaded
  asset agree): `devtoys.cli_win_x64_portable.zip` →
  `27327ad18c06d5bba4356f039c76203b0099f864d10f6de0d833225077dd310a`
  (33,983,972 B); `devtoys.cli_linux_x64_portable.zip` →
  `08ea1db86f0e9bfd8e591cbeb2102a16e7213b4512de378ba1c06449cbd225af`
  (33,628,605 B — informational; the Linux install is version-pinned, not
  hash-pinned, like every other Linux tool).
- **GUI runtime:** self-contained .NET 8 (no runtime prereq); Blazor-hybrid on
  WebView2 Evergreen (preinstalled on Win10/11; winget floor 10.0.17763).
- **CLI zips** (per-arch): `devtoys.cli_win_x64_portable.zip` (~33 MB,
  **self-contained**) vs `devtoys.cli_win_x64.zip` (~5 MB, framework-dependent —
  **requires a .NET 8 runtime**; not acceptable as a bootstrap dependency).
  The portable zip is **NOT a lone binary**: single-file `DevToys.CLI.exe` at the
  zip root **plus a required `Plugins/DevToys.Tools/` multi-file tree** (+ .pdbs,
  LICENSE). Linux: `devtoys.cli_linux_x64_portable.zip`, executable named
  **`DevToys.CLI`** (no extension) + the same Plugins tree; zip extraction loses
  the +x bit → `chmod` needed. Not eget-able (eget installs single binaries;
  the exe is useless without its sibling Plugins tree).
- **winget/Store (context only):** `DevToys-app.DevToys` / Store `9NBN8W1DS547`.
  Not used — the repo reserves winget for the elevated class and prefers
  GitHub-direct + digest verification.

## Design

### 1. GUI — `$InstallerTools` entry + two opt-in mechanism extensions (`bootstrap.ps1`)

New entry (Zed-shaped):

```powershell
@{
    Name              = "DevToys"
    Repo              = "DevToys-app/DevToys"
    AssetMatch        = "devtoys_win_x64.exe"   # Inno Setup installer (x64 only — Zed precedent)
    SilentArgs        = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"  # Inno; PrivilegesRequired=lowest -> per-user, no admin
    DetectName        = "DevToys*"              # HKCU ...\Uninstall\DevToys_is1 -> DisplayName "DevToys <ver>" (version-suffixed; also matches Preview — intended)
    IncludePrerelease = $true                   # ALL DevToys 2.x releases are prerelease:true -> /releases/latest returns 2023's v1.0.13.0
    UpdateHint        = "update-checks in-app only (no self-update); re-run bootstrap with -ForceInstaller to update"
}
```

Mechanism extensions — both **opt-in fields** absent from Obsidian/Zed, whose
behavior is bit-for-bit unchanged:

- **`IncludePrerelease`** — in `Install-InstallerTool`, when the key is present
  and true, resolve the release via `GET /repos/<repo>/releases?per_page=10` and
  take the **first non-draft entry** (prereleases allowed; the releases list is
  newest-first) instead of `GET /releases/latest`. Everything downstream (asset
  match, digest verification, silent install, temp cleanup, warn-and-skip
  failure modes) is unchanged. Key probing is StrictMode-safe: `$Tool` is a
  hashtable, so use `$Tool['IncludePrerelease']` / `ContainsKey` (mirror the
  existing `$asset.PSObject.Properties['digest']` caution).
- **`UpdateHint`** — the `-CheckForUpdates` "Installer apps" loop currently
  hardcodes `'self-updates in-app; -ForceInstaller reseeds'`, which is false for
  DevToys. Honor an optional per-tool `UpdateHint`, falling back to the current
  literal when absent. The section banner ("install LATEST + self-update —
  nothing to pin") gets a one-word softening ("most self-update").

The `$InstallerTools` block comment gains the two DevToys nuances (prerelease
resolver; notification-only updates).

### 2. CLI on Windows — pinned `$PortableTools` entry (`bootstrap.ps1`)

New Dest var next to the others: `$WsDevToysCli = Join-Path $WsRoot "devtoys-cli"`.

```powershell
@{
    # DevToys CLI — command-line versions of the DevToys tools; the Windows
    # half of the Linux dev-only devtoys-cli target (see makefile/versions.mk).
    # Self-contained .NET single-file exe + REQUIRED sibling Plugins/ tree ->
    # Layout 'tree' (the exe is useless without Plugins/DevToys.Tools).
    Name       = "DevToys CLI"
    Exe        = "DevToys.CLI"
    Version    = "2.0.9.0"
    Url        = "https://github.com/DevToys-app/DevToys/releases/download/v2.0.9.0/devtoys.cli_win_x64_portable.zip"
    Sha256     = "27327ad18c06d5bba4356f039c76203b0099f864d10f6de0d833225077dd310a"
    Layout     = "tree"
    Dest       = $WsDevToysCli
    Repo       = "DevToys-app/DevToys"
    TagPrefix  = "v"
    UpdateHint = "dual-edit: `$PortableTools here AND DEVTOYS_CLI_VERSION in makefile/versions.mk"
}
```

`Dest` joins the User PATH via the existing tree-layout path handling; the
command is `devtoys.cli` (Windows case-insensitivity over `DevToys.CLI.exe`).
The `Sha256` above is the GitHub API per-asset digest, cross-verified this
session by hashing the downloaded zip (see Verified upstream facts).

### 3. CLI on Linux — dev-only bespoke target (pwndbg/vcpkg shape)

- **`makefile/versions.mk`:** `DEVTOYS_CLI_VERSION := 2.0.9.0` in the dev-only
  neighborhood, comment carrying: what it is, the asset name + tag shape, the
  prerelease trap (why nothing here can use "latest"), the tree-not-binary
  shape (why not `EGET_TOOL`), and the **Windows dual-edit** pointer
  (`$PortableTools` in `bootstrap.ps1`).
- **New `makefile/lib/devtoys-cli.sh`** (LF, 0755, `shfmt -i 2` + shellcheck
  clean, `set -euo pipefail`): takes version + DEST env (same contract style as
  the other lib scripts); downloads
  `devtoys.cli_linux_x64_portable.zip` at the pinned tag; extracts the WHOLE
  tree to `/usr/local/lib/devtoys-cli` (zip handling mirrors `archive.sh`);
  `chmod 0755` the `DevToys.CLI` ELF (zip loses the bit); runs
  `verify-binary.sh` against it (ELF/arch/ldd/glibc-floor — it's a dynamic ELF)
  BEFORE declaring success; symlinks **`$(DEST)/devtoys.cli`** → the tree
  executable (exact command-name parity with Windows).
- **`makefile/Makefile`:** bespoke `devtoys-cli` target — dev-only (joins
  `PROVISION_FANOUT` under `MODE=dev` only, like pwndbg/vcpkg), `$(SUDO)`
  threaded, stamp filename bakes `$(DEVTOYS_CLI_VERSION)` so pin bumps
  auto-reinstall. Prod: no-op phony (herdr/opencode/omp precedent).
- The `sync-tool-memory.sh` hook regenerates the machine-memory TOOLS block on
  the `versions.mk`/`Makefile` edit (then `cza`).

### 4. Enforcement + docs

- **`scripts/check-invariants.sh`:** `DEVTOYS_CLI_VERSION` dual-edit check
  (`versions.mk` ↔ the version literal in `bootstrap.ps1`'s `$PortableTools`),
  cloned from the `OPENCODE_VERSION`/`OMP_VERSION` checks.
- **`docs/windows/application_list.md`:** drop the standalone `- DevToys` line
  (currently an uncommitted working-tree edit); add DevToys to the header
  parenthetical of bootstrap-installed apps (the Zed pattern).
- **`README.html`:** DevToys card in the §setup-windows installer-class block
  (per-user Inno, the prerelease resolver, notification-only updates →
  `-ForceInstaller` update path); DevToys CLI in the portable-tools text; the
  "(Obsidian, Zed)" enumerations (≈ lines 2987 comment, 3046 `-SkipToolInstall`,
  4615 troubleshooting) become "(Obsidian, Zed, DevToys)"; DevToys CLI added
  wherever the Linux dev-only agent tools (opencode/omp) are surfaced.
- **`CLAUDE_CHANGELOG.md`:** one row (user-facing surface changed: new
  auto-installed apps + new CLI on both OSes).
- **`CLAUDE.md`:** installer-class invariant bullet gains the DevToys nuances
  (opt-in prerelease resolver; notification-only updates — the class is no
  longer uniformly "self-updates after"); `DEVTOYS_CLI_VERSION` joins the
  version-pin dual-edit list; `devtoys-cli` joins the dev-only bespoke-target
  bullet (pwndbg/vcpkg one). Matching detail rows in
  `docs/claude/invariants.md` and `docs/claude/file-care.md` (new lib script in
  the LF+0755 set — covered by the existing `makefile/lib/*.sh` glob, called
  out only if those docs enumerate files by name).

### 5. Verification

Linux side (this machine):

```bash
make -C makefile lint MODE=prod          # check-invariants (new dual-edit check green), shfmt, shellcheck, gitleaks
make -C makefile ps-lint                 # PSScriptAnalyzer over bootstrap.ps1
bash .claude/hooks/test-hooks.sh         # unchanged hooks still green (belt-and-suspenders)
make -C makefile devtoys-cli MODE=dev    # sandbox/dev install per docs/claude/verification.md
devtoys.cli --version                    # runs; also smoke: echo '{"a":1}' | devtoys.cli jsonformat ... (exact subcommand per --help)
file (git ls-files --stage) checks on makefile/lib/devtoys-cli.sh  # LF + 100755
```

Risk to check at install: self-contained .NET on Linux can still want ICU at
runtime (globalization); the `devtoys.cli --version` smoke run catches it —
if it trips, `libicu` is already in EL9 base repos (add to
`LINUX_OPTIONAL_PACKAGES` only if actually needed).

Windows side (post-merge, on the Windows host): re-run `bootstrap.ps1` —
DevToys installs silently per-user (HKCU `DevToys_is1` key exists, Start-menu
entry present, no UAC), `devtoys.cli --version` works from a fresh shell,
`bootstrap.ps1 -CheckForUpdates` shows DevToys with the custom hint and
DevToys CLI pinned-vs-latest, `bootstrap.ps1 -Doctor` green.

## Out of scope (deliberate)

- DevToys GUI on Linux (`devtoys_linux_*` assets exist; nobody asked).
- arm64/x86 Windows assets (fleet is x64; Zed precedent).
- chezmoi-tracking DevToys settings/config.
- MS Store / winget / Chocolatey install paths.
- ~~A Linux `devtoys` convenience alias (parity name `devtoys.cli` only — add
  later if wanted).~~ ADDED 2026-07-12 at user request, post-implementation: a
  `devtoys` shell alias in the zsh+bash tools-alias sections (user chose the
  rc-alias shape over an installer symlink; kept everywhere-for-parity per the
  web-admin-alias precedent, no template gate).
