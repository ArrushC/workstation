# TUI Feedback Batch — Design

**Date:** 2026-08-07
**Status:** Approved (first live-usage feedback on the shipped TUI; precedes roadmap phases A–D)

## Goal

Fix three bugs found in real-terminal use and add two small features: the
chezmoi per-file diff "not managed" error, ragged health summary cells, and
non-working shell tab-completion; plus active-panel keys in the footer and a
fleet workstation-setup probe.

## 1. Chezmoi path fix (bug)

`chezmoi diff <path>` / `chezmoi re-add <path>` resolve relative target paths
against the CURRENT WORKING DIRECTORY, not the destDir — reproduced: from any
cwd outside `$HOME`, `chezmoi diff .claude/settings.json` fails rc=1
"not managed". `chezmoi status` emits destDir-relative paths, and the TUI
passes them verbatim.

- `core/chezmoi.py`: `target_diff(path)` and `re_add_command(path)` absolutize
  the argument — `str(Path.home() / path)` — before building argv.
- Regression tests pin the built argv; behavior verified from a non-home cwd.

## 2. Dynamic footer keys

The global `#key-bar` shows the ACTIVE panel's keys after the global set.

- A per-panel key registry (id → list of (key, label)) lives beside `PANELS`
  in `app.py`: dashboard `←→↑↓ Move · enter Open`, provision
  `r/c/u/R/x`, dotfiles `a/U/A/d`, fleet `s/p/P/a/e/x`, health `enter/R/o`.
- `switch_panel` re-renders the bar: global (`1-5 Panels · ctrl+←/→ Cycle ·
  g Refresh · q Quit · ? Help`) + ` │ ` + panel keys, via the theme `kb()`
  helper.
- The in-panel key-hint lines (`#provision-keys`, dotfiles/fleet/health
  equivalents) are REMOVED — keys live in one place; each panel gains a
  content row. HelpScreen remains the long-form reference (unchanged).

## 3. Fleet workstation-setup probe

Two-stage probing in `core/fleet.py`:

- Stage 1 (existing): TCP connect to port 22 → up/down.
- Stage 2 (new, reachable hosts only): `async probe_setup(entry, *, timeout=6.0)`
  runs `ssh -o BatchMode=yes -o ConnectTimeout=3 <user>@<addr> -- test -d
  .local/share/chezmoi` via `asyncio.create_subprocess_exec` (no shell):
  rc 0 → `"setup"`, rc 1 → `"missing"`, rc 255 (or any other rc/exception/
  timeout) → `"ssh-failed"`. BatchMode never prompts; unknown host keys fail
  closed as ssh-failed; nothing is written to `known_hosts`.
- `probe_all` composes both stages concurrently per host and returns
  name → `("up"|"down", setup_state|None)`; down hosts skip stage 2.
- Fleet table gains a `setup` column with themed glyphs: ✓ green setup /
  ○ yellow missing / ✗ red ssh-failed / — dim (down or not yet probed);
  `HOST_ICONS`-style vocabulary extends the theme.
- Tests inject fake probes end-to-end (no real ssh in the suite); the
  state-machine mapping is unit-tested against a fake subprocess.

**As-built (final-review fix wave, 2026-08-08):** argv hardened —
`"--"` precedes the destination (`["ssh", "-o", ..., "-o", ..., "--",
"<user>@<addr>", "test", "-d", ".local/share/chezmoi"]`) so a hostile
`hosts.conf` entry (bypasses the host-form's own validation) can't get a
`-`-leading user/address token option-parsed by ssh, matching app.py's
`ssh_to` established `["ssh", "--", dest]` pattern. `probe_setup` also now
kills AND reaps the ssh child on `asyncio.CancelledError` (routine under
exclusive-group worker cancellation) before re-raising, closing an
orphaned-child leak the timeout branch didn't have. `probe_all` gained
`include_setup: bool = True` so callers can skip stage 2 entirely (Fleet
panel gates it on `is_on_screen`, closing the every-refresh-from-any-panel
ssh storm); `FleetPanel._merge_probe_states` merges a skipped-stage-two
result into `probe_states` without regressing a previously-known setup
glyph back to unknown.

## 4. Health summary hygiene

- `_record_result` picks the last streamed line that is non-empty AND does not
  start with `"$ "` (the command echo), then `.strip()`s it before the 80-char
  truncation.
- The summary cell renders as single-line `Text(summary, overflow="ellipsis",
  no_wrap=True)`; existing fixed widths for state/check/age columns keep the
  table aligned. Existing cached summaries (pre-fix, unstripped) render
  stripped at display time too.

## 5. Tab completion

- Deploy: targeted `chezmoi apply ~/.config/zsh/completions/_workstation`
  during implementation (the file sits in ` A` pending state — an add, no
  overwrite prompt; the unrelated `MM .claude/settings.json` is untouched).
- Verify end-to-end in a scripted interactive zsh (fpath + compinit + the
  stub's eval path): completing `workstation <TAB>` must offer the subcommand
  list. If the eval-stub misbehaves in the real flow, fix the stub in-repo
  (it is first-party).
- README §tui troubleshooting gains: completion not working → check the file
  is APPLIED (`czs` shows it pending until `cza` runs).

## Error handling

Unchanged patterns throughout: never-raise core readers/probes; markup-inert
dynamic text; ssh probe failures degrade to a state, never an exception.

## Testing

Regression tests per item (argv pinning incl. non-home-cwd integration proof,
footer content per panel, setup-probe state machine + probe_all composition,
summary hygiene incl. `$`-echo skip, completion file deployment asserted in
the verify step not the suite). Suite stays green (enters at 177).

## Docs

README §tui: footer-keys behavior sentence, fleet setup-column sentence,
completion troubleshooting entry. CLAUDE_CHANGELOG row. (The roadmap phases
A–D are recorded in project memory, not this spec.)
