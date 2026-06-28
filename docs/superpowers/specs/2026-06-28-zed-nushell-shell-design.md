# Zed integrated-terminal default shell → Nushell (Windows)

**Date:** 2026-06-28
**Status:** Approved (design)
**Scope:** One tracked dotfile edit + two doc updates. Windows-only effect.

## Problem

Zed's integrated terminal on Windows defaults to the **system shell**
(PowerShell / `cmd.exe`) because the chezmoi-tracked Zed config
(`chezmoi/AppData/Roaming/Zed/settings.json`) has a `terminal` block but **no
`shell` key**. The rest of the Windows environment already standardizes on
**Nushell** as the default local shell (WezTerm `default_prog`, Windows Terminal
`defaultProfile`). Zed's integrated terminal is the odd one out.

Goal: make Zed's integrated terminal launch Nushell, consistent with the rest of
the Windows setup.

## Approach

Add a `shell` key to the existing `terminal` block in
`chezmoi/AppData/Roaming/Zed/settings.json`:

```jsonc
"terminal": {
  "shell": { "program": "nu" },
  "font_size": 13.0,
  ... (existing keys unchanged)
},
```

### Why bare `nu` (PATH resolution)

- `bootstrap.ps1` installs Nushell as a pinned portable tool to
  `%LOCALAPPDATA%\workstation\nu` and adds that directory to the **User PATH**.
- Zed spawns its integrated terminal as a child process that inherits the user
  environment (including the User PATH), so `nu` resolves by name.
- This mirrors the established pattern: WezTerm's `nu_prog()` resolver
  (`chezmoi/dot_config/wezterm/wezterm.lua`) prefers the absolute portable path
  but **falls back to bare `nu` on PATH**. The Zed setting is a single string
  field with no existence-check / fallback expressiveness, so the bare-`nu`
  fallback form is the right fit.
- The Zed discussion (zed-industries/zed#11091) confirms users set Nushell via
  `terminal.shell.program` with a bare binary name.

### Why not an absolute path

An absolute path (`C:\Users\<user>\AppData\Local\workstation\nu\nu.exe`) would
hardcode the username. Zed's `settings.json` does **not** expand environment
variables, so making it host-agnostic would require converting the plain JSON
file into a chezmoi `.tmpl` and injecting `{{ .chezmoi.homeDir }}` — a heavier
change for marginal robustness, since PATH is fully settled by the time the user
launches Zed. Rejected in favor of bare `nu`.

## Scope & constraints

- **Windows-only.** The file is under `AppData/`, which is ignored on Linux via
  `chezmoi/.chezmoiignore.tmpl` (blanket `AppData` entry). No `.chezmoiignore`
  change is needed, and applying on Linux/WSL does not touch this file.
- **JSONC, not strict JSON.** The file uses `//` comments and trailing commas
  (e.g. `"enabled": false,` inside objects). Preserve that style: 2-space indent,
  trailing comma after the new key, no reflowing of existing keys.
- **File mechanics unchanged.** Plain `.json` (deployed verbatim, not a
  template), LF line endings, mode 0644. No CRLF/BOM/mode concerns.
- **Placement.** Add `shell` as the first key in the `terminal` block for
  prominence; existing `terminal` keys are otherwise untouched.

## Documentation updates

Per the repo rule "changing user-facing surface → update `README.html` + append a
`CLAUDE_CHANGELOG.md` row":

1. **README.html** — the *"Nushell is the default local shell"* paragraph
   (around line 2757) currently enumerates exactly two surfaces (WezTerm
   `default_prog`, Windows Terminal `defaultProfile`). Extend it to add **Zed's
   integrated terminal (`terminal.shell.program`)** as a third surface where
   Nushell is the default. In-place edit to the existing sentence; no new
   section, CSS, or JS.
2. **CLAUDE_CHANGELOG.md** — append one row: the Zed `terminal.shell.program`
   change + the README paragraph update (README column = **Yes**).

### Explicitly NOT changed

- **CLAUDE.md** — the load-bearing invariant *"Nushell is the default LOCAL
  Windows shell … Two places set the default and must agree"* stays as-is. Zed's
  integrated terminal is a per-app embedded terminal, **not** the OS-level
  default shell; it does not *need* to agree with WezTerm / Windows Terminal
  (divergence causes no breakage). Folding Zed into that invariant would imply a
  coupling that does not exist and would bloat the lean, every-session CLAUDE.md.

## Verification

- **Local (best-effort, Linux):** confirm the edited file parses as JSONC and
  braces/commas balance (strip `//` comments + trailing commas, then parse; or
  careful manual review of the minimal diff). The real target is Windows, which
  can't be exercised here.
- **Windows (real check, manual / future host):** `chezmoi apply` on the Windows
  host → open Zed's integrated terminal → confirm the Nushell prompt/banner, e.g.
  run `$nu.current-exe` and see the `…\workstation\nu\nu.exe` path.

## Risks & mitigations

- **PATH not yet propagated** → bare `nu` fails to launch. Low risk: PATH is
  settled long before Zed launch (the same assumption WezTerm's fallback relies
  on). Mitigation if it ever bites: switch to the templated absolute-path
  approach (documented above).
- **Zed rewrites `settings.json`** (it owns the file) → the key persists because
  Zed preserves unknown/known settings on rewrite; if Zed ever drops it,
  re-capture via `chezmoi re-add` (same drift pattern already documented for Zed
  in the README).
