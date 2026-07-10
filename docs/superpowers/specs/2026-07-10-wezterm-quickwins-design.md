# WezTerm quick-wins bundle + shift-click link opening — design

**Date:** 2026-07-10
**Status:** approved (research → brainstorm → design conversation, this session)
**Scope:** `chezmoi/dot_config/wezterm/wezterm.lua` (single PR) + README keybind
table + changelog row. No rc/parity files, no render block, no HOSTS sentinel.

## Context

A web-research sweep (awesome-wezterm, plugin ecosystem, changelog, community
articles) produced a ~30-item candidate list; the user selected the "quick wins"
bundle and added one item of their own: **shift-click on a detected hyperlink
must actually open it in the browser**. Everything below is verified to work on
the pinned stable build 20240203-110809-5046fc22 (no stable release has shipped
since, so the plugin/recipe ecosystem matured on this exact build).

Explicitly out of scope (unchanged no-gos): per-host render tuning
(`max_fps` caps / OpenGL — `project-wezterm-render-webgpu-120fps`),
`wezterm.gui.*` at config load (`project-wezterm-no-gui-calls-at-config-load`),
Acrylic/translucency, nightly-only features (OSC 9;4 progress, `wezterm.serde`),
SSHMUX domains, tab-bar plugin replacements, workspace/resurrect plugins
(deferred, not rejected).

**Supersession note:** the 2026-07-09 UX-sweep spec listed
`check_for_updates=false` as declined. The user re-approved it explicitly in
this session's design review (2026-07-10) as part of this bundle.

## Feature 1 — Shift-click opens hyperlinks (root-caused)

**Root cause** (verified against `wezterm-gui/src/inputmap.rs` at tag
20240203-110809-5046fc22): the default `SHIFT+Down streak=1` binding is
`ExtendSelectionToMouseCursor(Cell)`, so by the time the default `SHIFT+Up`
composite `CompleteSelectionOrOpenLinkAtMouseCursor` fires, a non-empty
selection exists and the composite always takes the complete-selection branch —
the link-open branch is unreachable. Shift-click therefore "does nothing"
visible today.

**Fix** — two mouse-binding overrides:

- `Down streak=1 Left, mods=SHIFT` → `act.SelectTextAtMouseCursor 'Cell'`
  (start a fresh, empty selection instead of extending).
- `Up streak=1 Left, mods=SHIFT` → `act.Multiple {
  act.CompleteSelectionOrOpenLinkAtMouseCursor 'ClipboardAndPrimarySelection',
  copy_and_announce }`. On a plain click the selection is empty → the composite
  opens the link; after a shift+drag the selection is non-empty → it completes
  + copies, and `copy_and_announce` fires the existing "Copied!" badge
  (its re-copy of the same selection is harmless; it no-ops when empty).

**Why SHIFT specifically matters:** SHIFT is the (default, unchanged)
`bypass_mouse_reporting_modifier`, so this is the one modifier that reaches
WezTerm's own mouse handling *inside mouse-reporting panes* (Zellij, Helix).
The existing CTRL+click link-open never fires there — the app consumes the
event. Result: shift-click opens links everywhere, including remote Zellij
sessions; `https://` links go to the browser via the OS default; `file://`
links keep the existing open-uri → Helix same-domain routing.

**Accepted loss:** shift-click-to-*extend* an existing selection (the default
`ExtendSelectionToMouseCursor` behavior). Shift+drag selection — the way text
is actually selected over Zellij — still works: Down anchors, Drag (default
binding, untouched) extends, Up completes + copies.

## Feature 2 — Hyperlink rule: `#NN` → workstation PR/issue

`config.hyperlink_rules = wezterm.default_hyperlink_rules()` + one appended
rule:

```lua
{ regex = [[\B#(\d+)\b]], format = 'https://github.com/ArrushC/workstation/issues/$1' }
```

- GitHub auto-redirects `/issues/NN` to `/pull/NN` when NN is a PR.
- `\B#` avoids matching `word#12`; `\b` after digits avoids color hexes
  (`#1e1e2e` has no digit→boundary transition).
- Pairs with Feature 1: shift-click `#71` in any pane (incl. Zellij) → PR in
  browser. The existing `#\d+` quick-select atom stays for keyboard flow.
- Deliberately NOT adding the popular bare `owner/repo` rule: in path-heavy
  output `makefile/versions.mk` would light up as a GitHub link.

## Feature 3 — QuickSelect action bindings (three new keys)

All three use `act.QuickSelectArgs` with a restricted pattern set and an
`action` callback consuming `window:get_selection_text_for_pane(pane)`;
each sets a `label` so the overlay says what Enter will do.

| Key | Patterns | Action on select |
|---|---|---|
| `CTRL+SHIFT+I` | IPv4 `\b\d{1,3}(\.\d{1,3}){3}\b` | If the IP equals a managed host's `remote_address` → `SpawnTab { DomainName = <host> }` (Zellij attaches via per-domain `default_prog`); else `SpawnCommandInNewTab { domain = 'CurrentPaneDomain', args = { 'ssh', ip } }` |
| `CTRL+SHIFT+G` | `file:line[:col]` — `[[[\w./~_-]+:\d+(?::\d+)?]]` | Open in Helix at that position: `SpawnCommandInNewTab { domain = same-domain, args = { 'hx', sel } }`, mirroring the open-uri routing (works for WSL, SSH domains — one-shot editor tab; local Windows panes get `hx.exe` from the portable install) |
| `CTRL+SHIFT+Y` | git SHA `\b[0-9a-f]{7,40}\b` | `pane:send_text(sel)` — "yank" the SHA straight into the prompt, no clipboard round-trip |

Key-choice notes: I/G/Y are unbound in the current config and not load-bearing
defaults on 20240203. G = goto, I = IP, Y = yank.

## Feature 4 — Local pane story

Zellij owns panes inside SSH tabs; local/WSL panes currently have no ergonomic
bindings at all. Additions (all `domain = 'CurrentPaneDomain'`):

- `ALT+SHIFT+D` → `SplitVertical` (new pane **d**own) — matches Zellij's
  pane-mode `d` mnemonic.
- `ALT+SHIFT+R` → `SplitHorizontal` (new pane **r**ight) — matches Zellij's `r`.
- `CTRL+SHIFT+Z` → `TogglePaneZoomState`.
- `CTRL+SHIFT+Q` → `PaneSelect {}` (letter overlay; default alphabet).
- `config.unzoom_on_switch_pane = true`.
- **Amendment (2026-07-10, user-approved "shell wins"):** plan-time
  verification against `commands.rs` at the pinned tag showed the default
  `CTRL+SHIFT+Left/Right` = `ActivatePaneDirection` bindings CONSUME the
  chord even with a single pane — which has silently shadowed the zsh
  shift-select word-extend (README §prompt-keys) inside every WezTerm pane
  since that feature landed. Resolution: `DisableDefaultAssignment` on
  `CTRL+SHIFT+Left/Right` (the chord now reaches the shell, making the
  documented word-extend true), and pane navigation moves to
  `ALT+SHIFT+arrows` — consistent with the `ALT+SHIFT+D/R` split layer.
  This replaces the original "existing default Left/Right pane nav stays"
  line. (`CTRL+SHIFT+Z` also turned out to already be the built-in zoom
  default — the explicit binding just documents it.)
- Avoided `CTRL+SHIFT+K` (default ClearScrollback) and `CTRL+SHIFT+D`
  (adjacent to existing bindings users may chord).

## Feature 5 — One-liner flags

- `config.enable_kitty_graphics = true` — yazi/imgcat image previews in
  local/WSL/raw-ssh panes (off by default on 20240203). Known limit: not
  through Zellij (no kitty-graphics passthrough).
- `config.check_for_updates = false` — the build is pinned deliberately;
  kill the update toast. (Supersession note above.)
- `config.quote_dropped_files = 'WindowsAlwaysQuoted'` — drag-and-drop of
  files onto the terminal pastes a quoted path (double quotes are valid in
  POSIX shells too; dropped paths are Windows-side paths regardless).

## Cross-cutting

- **Cheatsheet (`help_choices`)**: rows for shift-click link-open, the three
  QuickSelect keys, splits/zoom/PaneSelect, and the pre-existing
  `CTRL+SHIFT+Left/Right` pane nav.
- **Command palette (`augment-command-palette`)**: entries for the three
  QuickSelect actions + PaneSelect + splits, reusing the SAME action values as
  `config.keys` (no drift).
- **README.html**: keybind-table rows + a mouse-behavior line for shift-click;
  same commit. **CLAUDE_CHANGELOG.md**: one row.
- **Verification**: luaparse syntax harness
  (`node /tmp/lua-syntax-check/check.js` — recreate if gone, per
  `feedback-lua-syntax-use-luaparse-not-lsp`); `make lint MODE=prod`;
  live smoke on the Windows clone after merge (config reload toast confirms
  parse; shift-click a URL inside a Zellij pane; `#NN` click; QuickSelect trio;
  split/zoom in a WSL tab; yazi image preview).
- **Deployment**: Windows reads `wezterm.lua` from its clone via
  `WEZTERM_CONFIG_FILE` → needs a `git pull` on the Windows clone (or chezmoi
  update via interop) after merge; Linux hosts pick it up via normal
  `czu && cza`.

## Delivery

One PR: `feat(wezterm): quick-wins bundle — shift-click links, #NN hyperlinks,
QuickSelect actions, pane bindings, kitty graphics`.
