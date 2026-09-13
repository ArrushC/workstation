# zellij: zjstatus tab bar + appearance flags (2026-09-13)

## Goal

Modernise the zellij chrome without touching what already works (rounded full
frames, powerline separators, the mauve theme, session resurrection): a
zjstatus tab bar with rounded Catppuccin pills, plus two config-only flags,
deployable to every fleet host through the existing provisioning paths.

## Decisions

1. **zjstatus lands via the bare `tab-bar` alias override**, not a custom
   layout. zellij's built-in default layout references the alias, so
   redefining it in `config.kdl`'s `plugins {}` block swaps the bar in every
   tab and every swap layout. Verified on 0.45.1 with `zellij action
   dump-layout` (headless session over `script -qfc`). A `layouts/default.kdl`
   would have replaced the built-in swap layouts — the exact loss the
   `default_layout` comment in `config.kdl` guards against.
2. **The built-in status-bar stays** in the bottom slot: it renders the key
   hints from this config (CTRL+S = Session, ALT+S = Scroll). zjstatus-hints
   shows zellij's stock hints, which are wrong here.
3. **Install = `USER_TOOL zjstatus`** in `tools.mk` → `lib/zellij-plugin.sh`
   → `~/.local/share/zellij/plugins/zjstatus.wasm` — zellij's DATA dir, the
   `[PLUGIN DIR]` that `zellij setup --check` prints and that the installer
   asks for. User-level (never sudo), WASM magic checked before install, 0644.
   Nothing under `~/.local/share` is chezmoi-managed.
4. **The alias stays the RELATIVE `file:zjstatus.wasm`.** zellij resolves it
   against `/usr/share/zellij/plugins`, then its data dir, and keeps the relative string as the
   plugin identity, including the `~/.cache/zellij/permissions.kdl` key.
   `file:~/…` expands to an absolute path at load (verified), which would make
   the one-time permission grant host-specific. `check_zellij_config` asserts
   the relative form.
5. **ABI coupling is a recorded floor**, not a fetched one. `ZJSTATUS_VERSION`
   sits next to `ZJSTATUS_ZELLIJ_FLOOR` in `versions.mk`; each zjstatus release
   states its floor in prose (v0.25.0: "zellij >= 0.45.0 required").
   `check_zjstatus_zellij_coupling` asserts `ZELLIJ_VERSION >= floor` offline.
   The pin joins `bump-versions.sh`'s EXCLUDE (gopls precedent) — a blind bump
   would silently raise the floor.
6. **Permission grant is interactive, once per host.** `zellij action
   write-chars` reaches terminal panes only, so it cannot be scripted; the
   README documents the click-or-focus + `y` step. Pre-seeding
   `permissions.kdl` is possible later (the key is host-independent) once the
   file format is captured from a granted host.
7. **`hide_session_name true`** (every session is `main`) and
   **`osc8_hyperlinks true`** (the eza `--hyperlink` aliases were dead inside
   zellij).
8. **`layouts/{dev,ops}.kdl`**: status-bar `size=2` → `1` (0.45's built-in
   size), bare `tab-bar`/`status-bar` aliases so the override applies, and
   the verbatim `zellij setup --dump-swap-layout default` block appended — a
   layout file replaces the built-in swap layouts, so `zellij -l dev` had lost
   ALT+[ / ALT+] cycling.

## Correction (2026-09-13, same day)

The first cut installed to `~/.config/zellij/plugins/`, which zellij never
searches (it tries `/usr/share/zellij/plugins`, then the data dir, then the
bare name). Every session showed "ERROR IN PLUGIN" while the headless probe
looked fine — `zellij action dump-layout` echoes the location string whether
or not the file was found. The probe now judges by the log (`Loaded plugin`
vs `No such file`), the installer asks zellij for `[PLUGIN DIR]`, and
`scripts/test-zellij-plugin.sh` (run by check-invariants) guards the
destination offline.

## Deferred, deliberately

- **`default_mode "locked"`.** Locked mode passes every key through except
  CTRL+G — including zellij's own ALT+N, ALT+H/J/K/L, ALT+F, ALT+[ ] defaults,
  which would need re-declaring in a `locked {}` block. ALT+F collides with
  Helix's insert-mode word motion and ALT+D with its delete-word, so the
  re-declaration needs per-key thought. Not a fleet-wide flip; a follow-up.
- zjstatus `datetime` (remote hosts run in assorted timezones) and
  `command_git_branch` (a shell command on the remote host every interval,
  plus a RunCommands grant).
- Pre-seeding `permissions.kdl` via chezmoi.

## Verification

- `make lint MODE=prod` (new checks: `zjstatus <-> zellij plugin-ABI floor`,
  `tab-bar alias -> file:zjstatus.wasm`).
- Sandbox install: `make zjstatus MODE=prod HOME=/tmp/zj-home STAMP=/tmp/zj-stamps DEST=/tmp/zj-bin`
  → `\0asm` magic at `/tmp/zj-home/.local/share/zellij/plugins/zjstatus.wasm`.
- Headless probes with the repo config (recipe in `docs/claude/verification.md`).
- On this box after merge: `cza`, `zellij kill-session main`, reattach, press
  `y` once.
