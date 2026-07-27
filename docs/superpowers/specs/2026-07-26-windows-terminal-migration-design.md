# Windows Terminal migration — retire Warp, elevate Windows Terminal to the managed primary terminal

**Date:** 2026-07-26
**Scope:** `bootstrap.ps1` (Warp removal + retire step, WT seed + fragment generator + doctor), the tracked WT `settings.json`, a new generated JSON fragment, `chezmoi/.chezmoiremove`, rc-file guard removal, `manage-hosts.{sh,ps1}` note retarget, README/CLAUDE.md/docs-claude/changelog sweep. No Make/Linux install changes.
**Status:** Design — pending user review.
**Prior actions:** stale PR #101 (`automation/wezterm-nightly` snapshot) closed and its branch deleted — the wezterm-nightly workflow was already removed by #102, so nothing regenerates it.

## Goal

Windows Terminal becomes the single managed Windows terminal. Warp is retired the same
way WezTerm was retired in #102 (config removal + self-healing retire step + doc/invariant
sweep), and Windows Terminal is elevated from "passively tracked `settings.json`"
(the 2026-06-08 Catppuccin design) to the primary terminal: seeded by `bootstrap.ps1`,
its per-host SSH+Zellij launch surface regenerated from `hosts.conf`, and the durable
terminal behaviors from the WezTerm/Warp eras carried over.

## Context: what already exists

- **WT `settings.json` is already chezmoi-tracked** at
  `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`
  (Store/MSIX install on the one Windows host; 251 lines; static, sync-from-host via
  `chezmoi re-add`, per `docs/claude/file-care.md`). It already carries Catppuccin Mocha
  (scheme + app theme), `defaultProfile` = the fixed-UUID5 **Nushell** profile
  (`{a1337c9f-08c3-5ee9-ad61-dcc130796eb6}` → portable `%LOCALAPPDATA%\workstation\nu\nu.exe`),
  `copyOnSelect: true`, and an `alt+shift+d` splitPane binding.
- **Warp surface to retire:** `$WarpTool`/`Install-Warp` (winget `Warp.Warp`, best-effort,
  user scope), `Invoke-WarpTabConfigs` (regenerates `%APPDATA%\warp\Warp\data\tab_configs\workstation-*.toml`
  from `hosts.conf`), three chezmoi-tracked config files
  (`AppData/Local/warp/Warp/config/{settings.toml,keybindings.yaml}`,
  `AppData/Roaming/warp/Warp/data/themes/catppuccin-mocha.yaml`), Doctor/CheckForUpdates
  entries, epilogue text, README §setup-warp + ~15 other README touchpoints,
  CLAUDE.md invariants (lines 92–94 area), `docs/claude/{invariants,file-care,verification}.md`
  rows, `docs/windows/application_list.md:21`, and shell-side
  `TERM_PROGRAM != WarpTerminal` guards (5 in `dot_zshrc.tmpl`, 2 in `dot_bashrc.tmpl`).
- **The durable terminal values** (from WezTerm/Warp archaeology): Catppuccin Mocha +
  JetBrainsMono NFM + bar cursor; Zellij-mnemonic pane keys (`alt+shift+d`=down,
  `alt+shift+r`=right, `alt+shift+arrows` navigate, zoom); per-host launch entries running
  `ssh -t <user>@<ip> zellij attach --create main` generated from `hosts.conf`
  (green=dev / cyan=prod accents); AlmaLinux-9-WSL sessions one keypress away; 100k
  scrollback parity with Zellij's `scroll_buffer_size`; copy-on-select; session restore
  (Warp `restore_session = true`); no telemetry/AI/auto-launch; **no per-host GPU tuning**
  (twice A/B-reverted in the WezTerm era — carry the restraint).

## Facts established during research (2026-07-26)

- **WT stable is 1.24.x** (2026-07). Inbox + default terminal on Windows 11 since 22H2;
  MSIX installs (Store, winget, GitHub bundle) are per-user by design (no admin) and
  auto-update through the Store. Portable/unpackaged modes exist but forfeit
  default-terminal registration and Store servicing — wrong trade for an evergreen app.
- **WT rewrites `settings.json`** when the Settings UI saves (full re-serialize; comments
  and ordering lost — microsoft/terminal#9167, #8991 still open) and stamps dynamic-profile
  stubs at startup. Hot-reloads external edits. This is the known, accepted drift model —
  identical to today (`chezmoi re-add`, `docs/claude/file-care.md` entry).
- **JSON fragment extensions** (`%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\<app>\*.json`,
  works for Store installs, admin-free) can **add profiles and color schemes** and modify
  existing profiles via `"updates"`, but **cannot** set `defaultProfile`, globals, themes,
  `newTabMenu`, or (reliably) keybindings. All `.json` files in the app dir are read;
  WT 1.24 has an Extensions page listing them. Fragments are read at WT launch (restart to
  pick up regeneration).
- **Deterministic profile GUIDs are documented UUID5**: fragment namespace
  `{f65ddb7e-706b-4499-8a50-40313caf510a}` → `appNs = uuid5(ns, "workstation" as UTF-16LE)`
  → `profileGuid = uuid5(appNs, profileName as UTF-16LE)`. So generated profiles have
  stable GUIDs across regenerations, and `newTabMenu`/`defaultProfile` can reference them.
- **WT 1.24 ships an SSH dynamic-profile generator** (`source: "Windows.Terminal.SSH"`,
  reads `ssh_config`). It would duplicate our hosts **without** the `zellij attach` suffix —
  disable via `"disabledProfileSources"`.
- **`newTabMenu`** supports `folder` entries with `matchProfiles` (regex since 1.24) —
  an "SSH hosts" folder can collect the generated profiles by name pattern without the
  static file ever referencing generated GUIDs.
- **Multiplexer landscape:** zellij gained **native Windows support in 0.44.0 (2026-03)** —
  the same minor version the fleet pins (`ZELLIJ_VERSION := 0.44.3`), with msvc zip +
  sha256 release assets that fit `$PortableTools`. The port is ~4 months old with an active
  umbrella issue (zellij#4745), including a Nushell-specific paste bug inside zellij on
  Windows. **psmux** (native ConPTY tmux-clone, Nushell-aware) is real and active but
  8 months old total, pseudonymous single lead, unverifiable adoption claims, and stale
  package-manager channels — exactly the abandonment-risk profile the pinned-portable
  philosophy exists to avoid. tmux under MSYS2 can't host native shells properly; WSL-side
  mux wrapping Windows shells degrades over interop pipes; WT panes +
  `firstWindowPreference: "persistedWindowLayout"` restore layout/profiles/CWD (via OSC 9;9)
  but have **no detach/attach** and don't restore buffer contents.

## Approaches considered

1. **Whole-file `settings.json` + generated fragment (RECOMMENDED).** Keep the existing
   static sync-from-host model for `settings.json` (globals, defaults, schemes, themes,
   actions/keybindings, `newTabMenu`, `defaultProfile`) and move ALL `hosts.conf`-generated
   content into a bootstrap-regenerated fragment file. Clean separation: the generator never
   touches the user-editable file (the Warp `workstation-*.toml` prefix rule maps 1:1 to
   "only files under `Fragments\workstation\` are wiped"), no JSON-merge machinery, and the
   2026-06-08 decision ("no modify_ script — one host") stays intact.
2. **modify-template deep-merge for `settings.json`** (the `modify_private_settings.json`
   pattern): enforced keys + passthrough of WT's stamps. Strictly more robust against WT's
   re-serialization, but it's real new machinery (PS-free JSON merge on Windows chezmoi,
   ordering churn, template testing), duplicates what fragments already solve for the
   generated part, and re-litigates a decision the repo already made. Rejected — YAGNI on
   one host; revisit only if `chezmoi re-add` drift becomes a chronic annoyance.
3. **Portable/unpackaged WT pinned in `$PortableTools`.** Pin-determinism consistency with
   Helix/Nushell, but loses default-terminal registration, Store servicing, and fights the
   inbox copy. Rejected.

## Design

### 1. Install: best-effort evergreen seed (`Install-WindowsTerminal`)

Mirrors `Install-Warp`'s model (best-effort, self-updating, never `Write-Fail`), with
MSIX-appropriate detection:

- Detect via `Get-AppxPackage -Name Microsoft.WindowsTerminal` (per-user, no admin) with a
  `Get-Command wt.exe` fallback (App Execution Alias). Present → `Write-Ok`, skip.
- Absent → `winget install --id Microsoft.WindowsTerminal --exact --silent
  --accept-source-agreements --accept-package-agreements` (MSIX is inherently user-scope);
  winget absent → `Write-Warn` pointing at the Store. `-ForceInstaller` adds `--force`.
- No `versions.mk` pin (Store-serviced evergreen — the Warp/`$InstallerTools` precedent).
- `-SkipToolInstall` skips it. Doctor + CheckForUpdates report presence/version
  ("self-updates via Store").

On this host WT is already installed — the seed exists for fresh-host reproducibility.

### 2. `settings.json` elevation (tracked file edits)

The file stays **static, whole-file, sync-from-host** (`chezmoi re-add` after UI edits;
LF, UTF-8, no BOM, `100644`; preserve WT's trailing-space and final-newline quirks).
Edits, all carrying WezTerm/Warp-era values over:

- **`profiles.defaults`** gains: `"font": { "face": "JetBrainsMono NFM", "size": 10.5 }`,
  `"cursorShape": "bar"`, `"historySize": 100000` (fleet parity with Zellij's
  `scroll_buffer_size 100000`; WT clamps large values internally — verify the effective
  ceiling on-machine and keep whatever it accepts), `"bellStyle": ["audible", "taskbar"]`
  (audible BEL for `notify.sh` + taskbar flash when unfocused), `"padding": "8, 8, 8, 8"`,
  `"antialiasingMode": "grayscale"`, `"useAcrylic": false`. Per-profile duplicates of these
  keys (currently on the Nushell profile) are removed so defaults rule. Font size stays the
  WT-tuned 10.5 — Warp's 13.0 was Warp-metric (its own zoom/DPI scale), not transferable.
- **Prune stale profiles:** delete the two hand-added SSH profiles (`atc-cache-dev09/10` —
  wrong shape: domain-prefixed user, hostname not IP, no `-t`/zellij; superseded by the
  generated fragment) and dedupe the doubled `AlmaLinux-9` WSL entries (keep the live
  `source: "Microsoft.WSL"` one; `defaultProfile` unaffected — it points at Nushell).
- **`"disabledProfileSources": ["Windows.Terminal.SSH"]`** — keep WT's 1.24 ssh_config
  generator from duplicating hosts without the zellij suffix. (Leave WSL + PowerShell
  generators enabled.)
- **`firstWindowPreference: "persistedWindowLayout"`** — Warp `restore_session = true`
  parity. (WezTerm's same-day session-persistence revert in May was a WezTerm
  implementation problem; Warp-era restore was kept deliberately.) Note: WT restores
  layout/profiles/CWD, not buffer contents; long-lived state lives in remote/WSL zellij.
- **`newTabMenu`**: `folder` "SSH hosts" with `matchProfiles` on the generated-name pattern
  (`"SSH: *"` — regex form; exact `source` string of fragment profiles verified on-machine
  during implementation as the preferred match key), then `remainingProfiles`. The static
  file never references generated GUIDs.
- **`actions` + `keybindings`** (new-style split arrays, `User.*` ids) — the Zellij
  mnemonics carried through three terminals now: `alt+shift+d` split down (retarget the
  existing binding from `split: auto` to `down`), `alt+shift+r` split right,
  `alt+shift+left/right/up/down` moveFocus, `ctrl+shift+z` togglePaneZoom, `ctrl+=` /
  `ctrl+-` / `ctrl+0` adjust/resetFontSize. Existing copy/paste/find bindings stay.
  Warp's Blocks/bookmarks/workflows/command-search bindings have no WT target — dropped
  (documented as the loss surface, README migration note).
- **Unchanged:** `defaultProfile` = Nushell (the CLAUDE.md Nushell-default invariant now
  applies unconditionally — Warp's AlmaLinux-9 exception dies with Warp; AlmaLinux-9
  remains one dropdown/`wsl.exe` away and is the recommended place for long-lived work),
  Catppuccin scheme/theme, `copyOnSelect: true`.

### 3. Generated fragment: `Invoke-WindowsTerminalFragments`

New `bootstrap.ps1` step, the direct successor of `Invoke-WarpTabConfigs` (same MAIN slot,
same every-run self-heal, same warn-and-continue posture):

- Target dir: `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\workstation\` (works for
  the Store install, admin-free). Wipe rule: delete **only** `*.json` inside that
  `workstation` app dir, then regenerate — the namespace directory IS the managed prefix;
  user fragments (other app names) and user profiles (settings.json) are untouchable by
  construction.
- Emits `hosts.json`: one profile per `hosts.conf` row (same parser as Warp's: skip
  blank/`#`, `-split '\s+'`, warn+skip malformed <4-field rows):
  `name = "SSH: <name>"`, `commandline = "ssh -t <user>@<ip> zellij attach --create main"`
  (the load-bearing string, verbatim from Warp), `tabColor` green `#a6e3a1` (dev_machine) /
  cyan `#94e2d5` (prod) — Mocha values of Warp's green/cyan accents, `icon` (Nerd-Font
  ssh glyph or emoji), `tabTitle = <name>`, `guid` = documented UUID5 chain
  (`{f65ddb7e-706b-4499-8a50-40313caf510a}` → app "workstation" → profile name, UTF-16LE) via
  a small SHA-1-based `New-Uuid5` helper (PS 5.1-safe, ~20 lines). Stable GUIDs mean
  re-generation is invisible to WT state.
- No local-shell fragment entries: Nushell/PowerShell/WSL profiles already live in
  `settings.json` (Warp needed local Tab Configs because its + menu was the launch surface;
  WT's profile list already is one).
- UTF-8 **no BOM**, LF, trailing newline. Skip-with-warn when WT is not detected;
  `hosts.conf` missing → warn, remove managed fragments (no stale hosts).
- Epilogue + docs note: **restart WT** after bootstrap regenerates fragments (read at
  launch), and new fragment profiles may need enabling on WT's Extensions page once.
- Doctor: count profiles in the fragment vs `hosts.conf` rows; warn on mismatch or missing
  fragment dir.

### 4. Warp retirement (mirror of #102's WezTerm pattern)

- **Delete** the three tracked Warp config sources; no `.chezmoiignore` change needed
  (blanket `AppData` non-Windows ignore covers both old and new files).
- **`chezmoi/.chezmoiremove`** gains the three Warp **target** paths
  (`AppData/Local/warp/Warp/config/settings.toml`, `.../keybindings.yaml`,
  `AppData/Roaming/warp/Warp/data/themes/catppuccin-mocha.yaml`) — Windows chezmoi removes
  the deployed copies; Linux no-ops (no `$HOME/AppData`).
- **`bootstrap.ps1` removals:** `$WarpTool`, `Install-Warp` (+ its `Invoke-ToolInstall`
  call and `-SkipToolInstall` message text), `Invoke-WarpTabConfigs` (+ MAIN call),
  Doctor Warp-presence + tab-config checks, CheckForUpdates entry, header/flow-comment and
  epilogue rewrites (steps 2/4/5c, next-steps text).
- **New `Invoke-WarpRetire`** (same shape as `Invoke-WeztermRetire`: every-run, independent
  existence-guarded try/catch blocks, silent no-op when clean, wired next to
  `Invoke-WeztermRetire` in MAIN):
  1. Managed Tab Configs: delete `%APPDATA%\warp\Warp\data\tab_configs\workstation-*.toml`
     (prefix-scoped — user-created Tab Configs are still never touched).
  2. App uninstall, best-effort: registry-detected → `winget uninstall --id Warp.Warp
     --silent`; failure or winget absent → `Write-Warn` with the manual uninstall hint,
     never `Write-Fail`. **[flagged decision — see Open decisions]**
  3. Deliberately does NOT delete `%LOCALAPPDATA%\warp` / `%APPDATA%\warp` wholesale —
     user-created themes/Tab Configs/history are user data; the uninstaller owns its own
     cleanup.
  - Paired **Doctor leftover check** (`$warpLeftovers`: app still registry-present /
    managed `workstation-*.toml` still present) mirroring the WezTerm one.
- **rc guards:** remove the five `TERM_PROGRAM != WarpTerminal` guards in `dot_zshrc.tmpl`
  (fzf, atuin, starship, zsh-shift-select, fzf-tab zstyles) and two in `dot_bashrc.tmpl`
  (fzf, starship) — parity pair, same commit. **Deliberate behavior change:** those five
  re-enable under WT in WSL/SSH sessions (that's the point — WT is a normal terminal;
  starship/atuin/fzf are wanted again). Comment sweep: `dot_dircolors:23`,
  `dot_config/starship.toml:52`, `AppData/Roaming/nushell/config.nu.tmpl:7`,
  `bootstrap.sh` Warp comments/output (~4 sites), `.chezmoiremove:9` comment.
- **`manage-hosts` parity pair:** rename/retarget `note_warp_refresh()` (sh) /
  `Show-WarpRefreshNote` (ps1) → "Windows Terminal SSH profiles (fragment) regenerate on
  the next `bootstrap.ps1` run" — 4 call sites each, headers too, both files in the same
  commit. **No flag changes** → no completion-parity edits (`check-invariants.sh` stays
  green untouched).

### 5. Multiplexer strategy (the investigation's answer)

- **Remote (the real workhorse): zellij over SSH — unchanged.** Generated WT profiles run
  `ssh -t … zellij attach --create main`, preserving detach/reattach and the
  broken-pipe recovery path.
- **WSL AlmaLinux-9: zellij — unchanged** (already provisioned by the makefiles).
- **Local Windows shells (Nushell/pwsh): WT panes + persisted window layout, now.** Zero
  new dependencies, native Nushell, the Zellij-mnemonic keybindings from §2. Accepted gap:
  no local detach/attach — long-lived work already lives in remote/WSL zellij.
- **Deferred follow-up (own PR, not this migration): native Windows zellij** — 0.44.0
  added Windows support; the msvc zip + sha256sum fits `$PortableTools` and would dual-edit
  with `ZELLIJ_VERSION := 0.44.3` (the Helix/gh precedent). Adopt once zellij#4745 quiets
  and the Windows Nushell paste bug is fixed — one config and one muscle memory across
  local/WSL/remote. **psmux: rejected** — technically credible (native ConPTY, tmux
  language, documented Nushell support) but 8 months old, single pseudonymous maintainer,
  unverifiable adoption claims, lagging package channels. Revisit in ~12 months if zellij's
  Windows port stalls.

### 6. Docs / invariants / changelog sweep

- **CLAUDE.md:** rewrite the Warp invariant (line ~93) into a Windows Terminal invariant
  (evergreen Store seed, fragment generator + wipe rule, settings.json static re-add model,
  `disabledProfileSources`, restart-to-pick-up-fragments); delete the "Warp's Nushell
  exception" (line ~94) — Nushell default becomes unconditional; update the Nushell-default
  bullet (line ~92), doc-map row 38 ("Windows + Warp" → "Windows + Windows Terminal"),
  verification pointer line ~142.
- **`docs/claude/invariants.md`:** add the Warp-retired sibling next to the WezTerm-retired
  entry; add the WT invariant detail (fragment namespace = managed prefix; UUID5 chain;
  never touch other app dirs / settings.json from the generator).
- **`docs/claude/file-care.md`:** delete the Warp entry (line ~62); expand the WT
  settings.json entry (line ~35) with the new keys and the fragment-file care rules.
- **`docs/claude/verification.md`:** replace the Warp recipe with a WT one (theme/font/
  cursor render check; `CTRL+T` lands in Nushell; SSH folder in the dropdown; fragment
  count = hosts.conf rows + a foreign-named fragment file and a user Tab-Config-analog
  profile survive a re-run; `alt+shift+d/r` splits; `echo $env:WT_SESSION` non-empty).
- **README.html** (+ TOC/`README.js` anchors): hero tagline (135), Terminal card (309–311),
  §setup-windows install card + flow step 5c + "Warp config model" note → "Windows Terminal
  config model", §setup-wsl phrasing, **§setup-warp (3325–3416) → §setup-windows-terminal**
  (launch flow = dropdown/SSH-hosts folder + `wt` CLI examples; new keybind table; note the
  fzf/atuin/starship-now-active change), §hosts single-generated-output sentence (3591),
  §adding (4246), troubleshooting entries 4442/4464–4490/4735/4820–4840 (retitle "Warp
  shows old settings" → WT settings/fragment staleness incl. the restart-to-reload-fragments
  and Extensions-page notes), doctor roster text (2647). Keep the "(25 entries)" count in
  CLAUDE.md accurate if entries merge/split.
- **`docs/windows/application_list.md`:** Warp line → Windows Terminal line (auto-installed,
  evergreen seed).
- **`CLAUDE_CHANGELOG.md`:** one row for the migration (README-impact column filled), plus
  a row noting PR #101 closure if convention asks for PR hygiene rows (it doesn't — skip).
- **Memory:** no Warp memory files exist; nothing to clean (verified).

## Open decisions (flagged for user review)

1. **`Invoke-WarpRetire` uninstalls the app** (recommended, mirrors WezTerm's full
   removal; best-effort, warn-and-continue) — vs leaving Warp installed and only removing
   managed state. Say the word and step 2 becomes a Doctor-note-only.
2. **Font size 10.5** (current WT-tuned value) — bump if you want the Warp-era visual size;
   Warp's `13.0` is not metric-compatible.
3. **`defaultProfile` stays Nushell** per the standing invariant — flag if you'd rather
   carry Warp's AlmaLinux-9-first behavior into WT.

## Out of scope

- Native Windows zellij adoption (deferred follow-up PR with explicit criteria, §5).
- psmux (rejected, §5).
- A `modify_`/merge script for settings.json (re-rejected, Approaches §2).
- Warp user-data deletion beyond managed files; WT portable mode; preview/canary channels;
  Terminal Chat (Canary-only); per-host GPU/rendering tuning (standing prohibition).
- Linux/WSL terminal behavior changes beyond the rc-guard removals.

## Risks / verification hooks

- **WT re-serializes settings.json** on Settings-UI saves — unchanged risk, unchanged
  answer (`chezmoi re-add`); the fragment file is outside the blast radius.
- **Fragment profiles need a WT restart** and may need one-time enabling on the Extensions
  page — documented in README troubleshooting + bootstrap epilogue.
- **`historySize` 100000 may clamp** — verify effective value on-machine; record the real
  ceiling in file-care if lower.
- **Guard removal re-enables starship/atuin/fzf in WSL/SSH** — verify prompt/keybinds in a
  WT WSL tab and an SSH+zellij tab; watch for double-OSC-133 emission (the old Warp
  verification's concern) now that starship runs again.
- **`check-templates.sh`/`check-invariants.sh`/`ps-lint` must stay green** — rc templates
  change (both groups render), bootstrap.ps1 must keep its BOM, no flag changes so
  completion parity is untouched.
- The fragment `source` string for `matchProfiles`/`newTabMenu` grouping is verified
  on-machine during implementation (research could not confirm the exact value).
