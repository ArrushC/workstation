# Helix on Windows — install + wire as the editor

**Date:** 2026-06-06
**Scope:** `bootstrap.ps1` (Windows install), `chezmoi/dot_gitconfig.tmpl` + `chezmoi/.chezmoi.toml.tmpl` (editor wiring), a new Windows-only helix config target, and the docs that describe them.
**Status:** Design — pending user review.

## Goal

Install Helix on the Windows client via the bootstrap (admin-free portable, same mechanism as
WezTerm/Starship) and make `hx` the editor on Windows — replacing the `zed --wait` editor
fallback added in the previous change. Deploy the existing helix config to Windows so the
editor experience matches Linux (catppuccin theme, keymaps, settings).

## Motivation

The prior change discovered that `[core] editor = hx` / chezmoi `[edit] command = "hx"` were
broken on Windows (helix not installed) and fell back to `zed --wait`. The user prefers Helix
everywhere. Helix ships official Windows builds, so installing it (rather than living with the
Zed fallback) gives a consistent cross-OS editor.

## Facts established during research

- **Bumping to Helix `25.07.1`** (latest; both Linux and Windows are bumped from the current
  `HELIX_VERSION = 24.03` in `makefile/versions.mk`).
- **Helix Windows release:**
  - URL: `https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip`
  - sha256: `5c8325ced8bacd8418d62706f669e96d9c3578a9237526e34d546900cbc049b6`
  - the archive wraps everything in a single top-level folder `helix-25.07.1-x86_64-windows/`
    containing `hx.exe` + a full `runtime/` (grammars, themes, queries). → a `tree`-layout
    portable install (verified against the actual release).
- **Helix Linux release (for the version bump):** `helix-25.07.1-x86_64-linux.tar.xz` unpacks to
  `helix-25.07.1-x86_64-linux/{hx,runtime/}` — exactly the layout `makefile/lib/helix.sh` expects
  (it builds the URL as `helix-${version}-x86_64-linux.tar.xz` and finds the `helix-*/` dir). The
  asset naming and layout are unchanged from 24.03, and `helix.sh` pins **no sha256**, so the Linux
  bump is a one-line `versions.mk` edit — no `helix.sh` change.
- **Runtime discovery:** Helix finds its runtime in `runtime/` adjacent to `hx.exe` for portable
  installs, so extracting the zip tree to one dir and putting it on PATH is sufficient — **no
  `HELIX_RUNTIME` env var is needed on Windows.** (The Linux `HELIX_RUNTIME` export in the rc is
  zsh/bash-only and those rc files are already ignored on Windows.)
- **Config location:** Helix on Windows reads `%APPDATA%\helix\config.toml` (Roaming), NOT
  `~/.config/helix`. chezmoi maps `AppData/Roaming/X` → `%APPDATA%\X` on Windows (same as the
  existing Zed/VSCode AppData configs), and the existing `.chezmoiignore.tmpl` Linux branch
  ignores `AppData`, so a Windows-only `AppData/Roaming/helix/...` source deploys only on Windows.
- **Existing helix config:** `chezmoi/dot_config/helix/config.toml` — `theme = "catppuccin_mocha"`
  (bundled in Helix's runtime, so it works on Windows with no extra files), relative line numbers,
  cursorline, custom statusline, `C-s` save keymaps, etc. Currently ignored on Windows (correct —
  `~/.config/helix` isn't read by Windows Helix).
- **`$PortableTools`** in `bootstrap.ps1` already drives WezTerm (`tree`) + Starship (`single`)
  with pinned version + sha256; `Install-PortableTool`'s `tree` branch flattens a single
  top-level folder and `Add-ToUserPath $Dest`. Adding Helix is one manifest entry + one path const.

## Design

### 1. Install Helix in `bootstrap.ps1`

- Add a path constant next to the others:
  ```powershell
  $WsHelix = Join-Path $WsRoot "helix"
  ```
- Add a `$PortableTools` entry:
  ```powershell
  @{
      Name    = "Helix"
      Exe     = "hx"
      Version = "25.07.1"
      Url     = "https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip"
      Sha256  = "5c8325ced8bacd8418d62706f669e96d9c3578a9237526e34d546900cbc049b6"
      Layout  = "tree"
      Dest    = $WsHelix
  }
  ```
  No changes to `Install-PortableTool` — the `tree` branch already handles the single-top-level-folder
  flatten (→ `hx.exe` + `runtime/` land directly in `$WsHelix`), the sha256 verify, the stamp gate,
  and `Add-ToUserPath $WsHelix`. The reinstall `Remove-Item $Dest` is already commented for the
  running-process-lock case (relevant if Helix is open).
- Ensure `$WsHelix` is created alongside `$WsBin`/`$WsStamps` if `Invoke-ToolInstall` pre-creates
  dirs (it currently creates `$WsRoot`/`$WsBin`/`$WsStamps`; `tree` installs create `$Dest`
  themselves, so no change strictly required — but creating it is harmless/consistent).
- Update the header comment (install model + flow step) and any "what's installed" summary to
  include Helix.

### 2. Revert the editor to `hx` (keep merge on Zed)

- `chezmoi/dot_gitconfig.tmpl` — `[core] editor` back to unconditional `hx` (remove the
  `{{ if eq .chezmoi.os "windows" }}zed --wait{{ else }}hx{{ end }}` and the Windows comment).
  `hx` is now on PATH on both OSes.
- `chezmoi/.chezmoi.toml.tmpl` — `[edit] command` back to unconditional `"hx"` (remove the
  conditional + the Windows `args = ["--wait"]` block).
- `chezmoi/.chezmoi.toml.tmpl` — `[merge]` **unchanged** (keep `vimdiff` on Linux, `zed` +
  `["--wait", Destination, Source, Target]` on Windows). Helix has no 3-way merge; Zed stays the
  Windows merge tool. The `[diff] pager` (empty on Windows) also stays as-is.

### 3. Deploy the helix config to Windows

- New source file `chezmoi/AppData/Roaming/helix/config.toml.tmpl` with body:
  ```
  {{ include "dot_config/helix/config.toml" }}
  ```
  `include` reads the raw file relative to the source root (`chezmoi/`), so the Windows target
  `%APPDATA%\helix\config.toml` gets the exact Linux config content. **Single source of truth** —
  editing `dot_config/helix/config.toml` automatically updates Windows on next apply. NOT a
  parity-pair (no duplicated content).
- No `.chezmoiignore.tmpl` change: `AppData` is already ignored on Linux (so this file is
  Windows-only), and `.config/helix` stays ignored on Windows (Windows Helix doesn't read it).
- The included config's header comment (`# ~/.config/helix/config.toml — managed by chezmoi`) is
  slightly inaccurate on Windows (the real path is `%APPDATA%\helix`) but harmless — it's a comment.
  Left as-is to keep the single source.

### 4. Version bump (24.03 → 25.07.1) + new dual-edit tripwire

Bump Helix on **both** platforms as part of this change:
- **Linux:** `HELIX_VERSION := 24.03` → `25.07.1` in `makefile/versions.mk`. `helix.sh` needs no
  change (verified: same asset naming + layout, no sha pin). Next `make provision` re-installs
  Helix 25.07.1 + its runtime to `$HELIX_RUNTIME_DEST/runtime` (the version is baked into the TOOL
  stamp, so the bump auto-triggers reinstall). The rc `HELIX_RUNTIME` export is unchanged (same path).
- **Windows:** the `$PortableTools` pin (`25.07.1` + sha256) in `bootstrap.ps1`.

Going forward, the Windows pin must track `HELIX_VERSION` — a new dual-edit tripwire
(`makefile/versions.mk` ↔ `bootstrap.ps1`), joining the existing Windows-pin family
(WezTerm/Starship in `bootstrap.ps1`, the JetBrainsMono triple-edit). No template var bridges
Make ↔ ps1 (Make never runs on Windows).

## Files to touch

1. **`makefile/versions.mk`** — `HELIX_VERSION := 24.03` → `25.07.1` (Linux bump). No `helix.sh`
   change (asset naming/layout unchanged; no sha pin there).
2. **`bootstrap.ps1`** — `$WsHelix` const, the Helix `$PortableTools` entry (pinned `25.07.1` +
   sha256), header/flow comment updates. **Retain UTF-8 BOM.**
3. **`chezmoi/dot_gitconfig.tmpl`** — `[core] editor` → `hx`.
4. **`chezmoi/.chezmoi.toml.tmpl`** — `[edit] command` → `hx` (drop Windows args); `[merge]`
   unchanged.
5. **`chezmoi/AppData/Roaming/helix/config.toml.tmpl`** — NEW, one-line `include`.
6. **`README.html`** — §setup-windows: the install list becomes four tools (chezmoi, WezTerm,
   Starship, **Helix**); the flow diagram step 2 label gains Helix; a note that the helix config
   deploys to `%APPDATA%\helix` on Windows. (User-facing → README updated in the same change.)
7. **`CLAUDE.md`** — extend the "Windows tool installs are admin-free binary/portable downloads"
   invariant to include Helix; note the Windows helix runtime is the bundled portable `runtime/`
   (no `HELIX_RUNTIME` env var — distinct from the Linux dev runtime invariant); add the
   `HELIX_VERSION` (`versions.mk`) ↔ `bootstrap.ps1` dual-edit to the pin-tripwire list.
8. **`docs/claude/file-care.md`** — extend the `bootstrap.ps1` pinned-tools entry to list Helix;
   note the new `AppData/Roaming/helix/config.toml.tmpl` `include` (single-source, not a duplicate).
9. **`CLAUDE_CHANGELOG.md`** — append a row.

## Out of scope

- Auto-installing Helix on Linux differently (already handled by `makefile/lib/helix.sh`; this
  change only bumps its version pin).
- Changing the merge tool design (Zed-on-Windows stays; Helix can't merge).
- Zed/VSCode (still hand-installed).

## Risks / things to verify

- **BOM** on `bootstrap.ps1` after editing (`file` must say "with BOM", not CRLF).
- **Runtime discovery on Windows** — confirm `hx --health` (or `hx --version` + a syntax-highlight
  smoke test) finds the bundled `runtime/` with no `HELIX_RUNTIME` set. The portable layout should
  make this automatic; verify on the host.
- **`include` path** — `{{ include "dot_config/helix/config.toml" }}` must resolve against the
  source root (post-`.chezmoiroot`). Verify the Windows render via `chezmoi cat` of the AppData
  target (or `chezmoi execute-template`).
- **Stale `HELIX_RUNTIME`** — ensure no leftover `HELIX_RUNTIME` env var on the Windows host points
  somewhere wrong (it would override the bundled runtime). The rc files don't set it on Windows;
  confirm the User/Machine env doesn't either.
- **`AppData/Roaming/helix` target mapping** — confirm chezmoi deploys it to `%APPDATA%\helix\config.toml`
  on Windows and ignores it on Linux (mirror of the Zed/VSCode AppData precedent).
- **Editor-on-PATH ordering** — `hx` resolves from `%LOCALAPPDATA%\workstation\helix`; confirm a new
  shell picks it up and `git config core.editor` = `hx`.
- **Config compatibility with 25.07.1** — the tracked `config.toml` uses stable options
  (`theme`, `line-number`, `cursor-shape`, `statusline`, `indent-guides`, `keys.*`, `auto-save`).
  Helix warns-not-fails on any deprecated/renamed key, so a stale option won't break startup; still,
  smoke-test `hx --health` / open a file on both OSes after the bump to confirm no config error.
- **Linux reinstall on bump** — bumping `HELIX_VERSION` re-triggers the `helix` TOOL on the next
  `make provision` (version is in the stamp). Verify `make -n provision` shows the helix target
  firing and that a real install lands 25.07.1's `hx` + runtime. WSL hosts are unaffected (helix is
  not installed under WSL per the existing scope rules).

## Decisions (confirmed 2026-06-06)

1. **Deploy the helix config to Windows** (`%APPDATA%\helix\config.toml`) via the `include` of the
   existing Linux config — single source of truth. ✅
2. **Keep `zed --wait` as the Windows merge tool** (editor reverts to `hx`; Helix can't 3-way merge). ✅
3. **Bump both Linux + Windows to Helix `25.07.1`** (latest; from 24.03) — Linux via
   `versions.mk`, Windows via the `bootstrap.ps1` pin + sha256. ✅
