# Windows Terminal — Catppuccin Mocha (scheme + app theme)

**Date:** 2026-06-08
**Scope:** one new chezmoi-tracked Windows-only file (the Windows Terminal `settings.json`) plus the docs that describe it. No Make/`bootstrap.ps1`/install changes — Windows Terminal is a Store app the user already has; the bootstrap never touches it.
**Status:** Design — pending user review.

## Goal

Theme Windows Terminal on the single Windows host with **Catppuccin Mocha** — both the
terminal **color scheme** (per-profile `Appearance > Color scheme`) and the **app theme**
(window chrome: tab bar + title bar). Track the whole `settings.json` in chezmoi so the look
is reproducible on a re-provision of that host, using the exact same pattern already in place
for the Zed and VSCode `settings.json`.

## Motivation

The user has themed the rest of the Windows surface to Catppuccin Mocha (Zed dark theme,
Helix, dircolors, wezterm, etc. — see the recent `feat(zed): sync Windows dark theme to
Catppuccin Mocha` commits). Windows Terminal is the remaining un-themed Windows app. The
upstream `catppuccin/windows-terminal` repo ships the scheme + theme as JSON fragments; this
change bakes them into the tracked `settings.json` so they survive a fresh chezmoi apply.

## Facts established during research

- **This repo has exactly one Windows host** (CLAUDE.md: "Linux hosts + one Windows host").
  That removes the usual hazard of tracking WT's `settings.json` — per-machine dynamic-profile
  GUID drift — because the tracked file *is* that one host's file.
- **Established precedent:** `chezmoi/AppData/Roaming/Zed/settings.json` and
  `chezmoi/AppData/Roaming/Code/User/settings.json` are fully tracked and synced *from* the
  host (`chezmoi re-add` → commit). Windows Terminal becomes one more file in that pattern.
- **WT install is Store/MSIX** (confirmed on host). Settings path:
  `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json`.
  chezmoi maps source `AppData/Local/...` → `~/AppData/Local/...` = `%LOCALAPPDATA%\...` on
  Windows. So the source path is:
  `chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`.
- **The host's current file is reachable from WSL** at
  `/mnt/c/Users/arrush.chaturvedi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`
  and was read in full. So the tracked file can be authored exactly (current content + the
  Catppuccin injection) without the user pasting anything.
- **Current host file state:** `schemes: []`, `themes: []`, `profiles.defaults: {}` — all empty.
  Three profiles carry an explicit `"colorScheme": "Campbell"` override: `Windows PowerShell
  (Admin)`, `atc-cache-dev09`, `atc-cache-dev10`. No top-level `"theme"` key.
- **App theme is referenced by a top-level `"theme"` key** in `settings.json` (value = the
  theme object's `name`), distinct from the per-profile/`defaults` `colorScheme`.
- **Line endings:** the host file and the tracked Zed/VSCode JSON are all **LF-only**. No
  `.chezmoiattributes` exists, so chezmoi performs no line-ending transform. Track as LF,
  UTF-8, no BOM, mode `100644` — identical to Zed/VSCode. (Not a CRLF/BOM tripwire file.)
- **`.chezmoiignore.tmpl`:** the Linux branch ignores bare `AppData` (covers the whole
  subtree, including `AppData/Local/...`), so the new file deploys **only on Windows** with no
  ignore change. The dev/prod `group` block only ignores `.claude` + `.config/ccstatusline`,
  so the WT file is **not** group-gated — it deploys on the Windows host whether dev or prod
  (same as Zed/VSCode).
- **No template needed** — nothing in the file is host-variable, so it's a plain
  `settings.json`, not a `.tmpl` (unlike the helix `include`).
- **WT preserves user content across its own rewrites** — `schemes`, `themes`, the
  `defaults.colorScheme`, and the top-level `theme` all persist when WT rewrites the file; WT
  only reorders/regenerates *dynamic profiles*. So the Catppuccin entries are not lost on WT's
  automatic rewrites.

## Design

### The tracked file

New source file (Windows-only, plain static JSON):

```
chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json
```

Content = the host's current `settings.json` **verbatim**, with the five edits below applied.

### The five edits

1. **`schemes`** `[]` → array containing the Catppuccin Mocha scheme (from upstream `mocha.json`):

   ```json
   {
     "name": "Catppuccin Mocha",
     "cursorColor": "#F5E0DC",
     "selectionBackground": "#585B70",
     "background": "#1E1E2E",
     "foreground": "#CDD6F4",
     "black": "#45475A",
     "red": "#F38BA8",
     "green": "#A6E3A1",
     "yellow": "#F9E2AF",
     "blue": "#89B4FA",
     "purple": "#F5C2E7",
     "cyan": "#94E2D5",
     "white": "#BAC2DE",
     "brightBlack": "#585B70",
     "brightRed": "#F38BA8",
     "brightGreen": "#A6E3A1",
     "brightYellow": "#F9E2AF",
     "brightBlue": "#89B4FA",
     "brightPurple": "#F5C2E7",
     "brightCyan": "#94E2D5",
     "brightWhite": "#A6ADC8"
   }
   ```

2. **`themes`** `[]` → array containing the Catppuccin Mocha app theme (from upstream
   `mochaTheme.json`):

   ```json
   {
     "name": "Catppuccin Mocha",
     "tab": {
       "background": "#1E1E2EFF",
       "showCloseButton": "always",
       "unfocusedBackground": null
     },
     "tabRow": {
       "background": "#181825FF",
       "unfocusedBackground": "#11111BFF"
     },
     "window": {
       "applicationTheme": "dark"
     }
   }
   ```

3. **`profiles.defaults`** `{}` → `{ "colorScheme": "Catppuccin Mocha" }` — every profile
   inherits the scheme (the user's chosen "all profiles via defaults").

4. **Add top-level `"theme": "Catppuccin Mocha"`** — selects the app-chrome theme added in
   edit 2. (Placed among the top-level keys, e.g. after `"newTabMenu"`/near `"defaultProfile"`;
   WT will reorder on next write regardless.)

5. **Remove the three `"colorScheme": "Campbell"` lines** from `Windows PowerShell (Admin)`,
   `atc-cache-dev09`, and `atc-cache-dev10` so they inherit `defaults.colorScheme`. Without
   this, those three keep Campbell and "all profiles" would be false. *(Confirmed by user
   2026-06-08.)* Each profile keeps all its other keys unchanged.

Everything else in the file (actions, keybindings, the full profiles list with their GUIDs,
`defaultProfile`, etc.) is preserved exactly as on the host.

### How it lands on the host

1. Author the source file in the repo (this change), commit.
2. On the Windows host: `git pull` (or `cz`/chezmoi update flow), then `chezmoi diff` to
   preview, then `chezmoi apply`. chezmoi writes the file to the LocalState path; Windows
   Terminal picks it up live (or on next launch).
3. The Linux-side chezmoi cannot apply this — it manages the Linux `$HOME`; the Windows target
   is the native Windows chezmoi's responsibility. (Authoring the source from WSL is fine; only
   the *apply* must run on Windows.)

### Accepted tradeoff (documented, not engineered around)

WT rewrites `settings.json` on its own more often than Zed/VSCode do (reorders keys,
regenerates dynamic profiles). So `chezmoi status` on the Windows host will show this file
drifting periodically; the user re-syncs with `chezmoi re-add` — the identical workflow
already used for Zed. The Catppuccin entries themselves persist across WT rewrites. A
`modify_`/merge script that injects only the Catppuccin keys was considered and **rejected**:
it's a brand-new pattern for this repo, needs robust JSON-merge logic (PowerShell JSON
round-tripping mangles ordering; `jq` not guaranteed on Windows), and buys nothing on a single
host. YAGNI.

## Files to touch

1. **`chezmoi/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json`**
   — NEW. The host's current `settings.json` + the five edits. LF, UTF-8, no BOM, `100644`.
2. **`README.html`** — §setup-windows: add Windows Terminal to the list of configs chezmoi
   deploys on the Windows host (the sentence currently naming "Zed/VSCode settings"), noting it
   is themed Catppuccin Mocha (scheme + app theme) and that WT owns/re-rewrites the file so it
   re-syncs like Zed. (User-facing surface → README updated in the same change, per CLAUDE.md.)
3. **`docs/claude/file-care.md`** — new entry for the WT `settings.json`: WT-owned (expect
   drift, re-sync via `chezmoi re-add`); LF / no BOM / `100644`; the `defaults.colorScheme`
   vs per-profile-override gotcha (per-profile `colorScheme` wins over `defaults` — keep new
   profiles override-free to stay themed); Windows-only via the existing `AppData` Linux ignore.
4. **`CLAUDE_CHANGELOG.md`** — append a row.

No `CLAUDE.md` invariant: this adds no new cross-file dual-edit or build-time coupling beyond
what file-care.md covers. No `.chezmoiignore.tmpl` change (Linux already ignores `AppData`). No
`bootstrap.ps1` / `versions.mk` / Make change (WT is not installed by the repo).

## Out of scope

- Installing or updating Windows Terminal (Store app; not the repo's concern).
- A `modify_`/merge approach (rejected above).
- Reconciling WT's SSH profiles (`atc-cache-dev09/10`) with WezTerm's host auto-connect.
- Light-mode / other Catppuccin flavors (Mocha only).

## Risks / things to verify

- **Valid JSON after the five edits** — `chezmoi cat` / a JSON parse of the source must
  succeed; no trailing-comma or brace mistakes from removing the Campbell lines.
- **LF preserved** — `file <source>` must NOT say "CRLF"; no BOM. Matches Zed/VSCode.
- **Windows-only deploy** — on Linux, `chezmoi ignored` must list the WT target (it's under
  `AppData`); on Windows, `chezmoi managed` must include it and `chezmoi diff` must show only
  the intended changes against the live file before apply.
- **All profiles themed** — after apply + WT reload, confirm the three formerly-Campbell
  profiles now render Catppuccin Mocha (i.e. the override removal took).
- **App theme applied** — confirm the tab bar/title bar use the Catppuccin chrome (top-level
  `"theme"` resolved to the `themes[]` entry; `applicationTheme: dark`).
- **Drift expectation** — note (don't fix) that WT may immediately rewrite/reorder the file on
  first launch after apply; a follow-up `chezmoi re-add` re-captures WT's canonical ordering so
  future diffs are clean.

## Decisions (confirmed 2026-06-08)

1. **Track the whole `settings.json`** (sync-from-host, like Zed/VSCode) rather than a
   `modify_` merge script or manual fragments. ✅
2. **Scheme + app theme** (both `mocha.json` and `mochaTheme.json`), not scheme-only. ✅
3. **All profiles** via `profiles.defaults.colorScheme`. ✅
4. **WT install is Store/MSIX** → the `AppData/Local/Packages/...LocalState` source path. ✅
5. **Remove the three `Campbell` per-profile overrides** so all profiles inherit Catppuccin. ✅
6. **Commit the full file as-is**, including internal hostnames (`atc-cache-dev09/10`) and the
   domain login (`cbl\arrush.chaturvedi`) — the user accepts this in their dotfiles repo (no
   redaction/templating). ✅
