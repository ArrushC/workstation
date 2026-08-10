# TUI Phase B — Fleet Ops — Design

**Date:** 2026-08-10
**Status:** Approved (roadmap Phase B: parallel push dashboard, host drill-in
quick-stats, guided key distribution)

## Goal

Three fleet-ops features for the shipped TUI, per the approved roadmap in
project memory. Engine choice (user-approved): per-host multi-runner —
the dashboard spawns `update-hosts.sh --name <host>` once per selected
host; the script stays the ONLY push mutation path (no output parsing, no
native ssh pushes).

## 1. Push dashboard (multi-runner + screen)

### core/multirun.py — MultiRunner

- Asyncio-based, deliberately separate from the single-flight `core/runner`
  (which stays untouched for local make/sudo work).
- API: `MultiRunner(commands: dict[str, list[str]], *, limit: int = 4,
  exec_fn=asyncio.create_subprocess_exec)` — key = host name, value = argv.
  `await runner.run(on_update)` executes all commands under an
  `asyncio.Semaphore(limit)`; `runner.cancel()` kills AND reaps every live
  child (the `probe_setup` kill+reap discipline) and marks unstarted
  commands `cancelled`.
- Per-host state dataclass `HostRun`: `state` (`queued | running | done |
  failed | cancelled`), `rc: int | None`, `started/finished` monotonic
  stamps (→ elapsed), `lines: list[str]` (streamed stdout+stderr,
  interleaved, capped at 5000 — the panel MAX_LOG_LINES precedent).
- `on_update(name)` fires on every state change and appended line; the
  screen marshals it onto the UI loop. Env scrubbed like the existing
  runner (MAKEFLAGS/MFLAGS/MAKELEVEL). Never raises: spawn failure →
  `failed` with the exception text as the log line.

### PushScreen

- `p` (cursor host) and `P` (all hosts) on Fleet both open it — a
  single-host push is a one-row dashboard. Entry still passes
  `_linux_only_gate` and the existing ConfirmModal (`push N host(s)?`).
- One DataTable row per host: state glyph (themed vocabulary:
  queued `·` dim / running `●` blue / done `✓` green / failed `✗` red /
  cancelled `–` yellow), name, elapsed, last output line — every cell
  `Text()`-wrapped (remote-derived text). Summary Static beneath:
  `"N running · N done · N failed · N queued"`.
- Keys: `enter` → full per-host log in the existing TextViewScreen;
  `x` → confirm, then `runner.cancel()`; `esc` → close only when nothing
  is `queued`/`running`, else a ConfirmModal ("push still running —
  cancel and close?").
- Commands: `update-hosts.sh --name <host>` per host via the existing
  `core/fleet.py::push_command`, whose signature TIGHTENS to
  `push_command(repo_root, name: str)` — the `name=None` bare/all form is
  removed (nothing else uses it: the fleet panel is being rewired and the
  headless CLI never consumed it; verified 2026-08-10).
- Mutual exclusion: app gains `_push_inflight: bool`. PushScreen refuses
  to start while `_task_inflight` (toast); `launch_task` /
  `run_task_sequence` refuse to start while `_push_inflight` (toast);
  `_watch_tick` also skips while `_push_inflight`.
- On close: per-host outcomes land in FleetPanel
  `last_push: dict[str, tuple[str, float]]` (state, `time.time()`),
  rendered as a new narrow `push` column in the fleet table — glyph +
  relative age (`✓ 2m`), dim `–` when never pushed this session
  (session-only state, not persisted). Fleet re-probes.
- Notification (Phase A seam): ONE notify per push session, message
  built from COUNTS AND DURATION ONLY — e.g. `"push — 4 ok, 1 failed
  (73s)"` — never host names (hosts.conf-derived text stays out of
  notify.sh until its WSL quote-interpolation hardening lands; see the
  parked-minors memory). Failure rule: any failed host → always notify;
  all-ok → threshold rule (≥ `notify_threshold_secs`).

## 2. Host drill-in quick-stats

- `enter` on a fleet row opens `HostStatsScreen` (read-only). Route via
  `on_data_table_row_selected` (the health/dotfiles precedent — DataTable
  consumes enter); PANEL_KEYS fleet gains `("enter", "Stats")` and the
  footer drift-test carve-out extends to fleet.
- New `core/hoststats.py`:
  - `stats_command(entry) -> list[str]`: ONE BatchMode ssh argv
    (`-o BatchMode=yes -o ConnectTimeout=3 --` before destination, the
    `probe_setup` hardening) whose remote command is a single POSIX-sh
    block emitting delimited sections `===vitals===`, `===workstation===`,
    `===session===`, `===tools===`:
    - vitals: `uptime`; `free -m` total/used; `df -P /` size/used/pct;
      `uname -sr`; `/etc/os-release` PRETTY_NAME
    - workstation: repo dir exists; `git -C ~/.local/share/chezmoi
      log -1 --format='%h %cr'` + `rev-parse --abbrev-ref HEAD` +
      `status --porcelain | wc -l`; newest stamp mtime under the stamp
      dir (age); `chezmoi status | wc -l` (pending drift)
    - session: `who | wc -l` + usernames
    - tools: `chezmoi --version | head -1`, `git --version`,
      `make --version | head -1`
    - every probe `|| echo missing` — a partial host still returns the
      sections it can.
  - `parse_stats(text) -> HostStats`: never-raise parser; `HostStats` is
    a dataclass of optionals — absent/garbled sections render `–`, never
    crash. Latency is NOT remote: the screen reports the TCP probe
    round-trip time measured TUI-side.
- The screen runs the ssh as an on-loop async worker (group
  `host-stats`, kill+reap on cancel, timeout → an "unreachable" state
  rendered in the screen, never an exception). Themed key/value card
  stack; all remote-derived strings markup-inert. `R` re-runs; `esc`
  closes; no caching — closing discards.

## 3. Guided key distribution

- `k` on Fleet (behind `_linux_only_gate`) opens `KeyDistModal`:
  a SelectionList of all hosts (name + net/repo glyphs); hosts whose
  CURRENT repo-probe state is `ssh-failed` come PRE-checked (BatchMode
  auth failure = exactly "needs a key"). Header reports the local key:
  `~/.ssh/id_ed25519.pub` present/missing (native read, never-raise) —
  when missing, a warning line notes the script will offer to generate
  one. Keys: `space` toggle, `a` toggle all, `enter` confirm, `esc`
  cancel. Confirm with zero selected → notify, stay open.
- On confirm the TUI SUSPENDS (the `s`/ssh pattern) and runs
  `manage-hosts.sh --copy-id --name <host>` SEQUENTIALLY per selected
  host in the real terminal — password prompts and `ensure_ssh_key`'s
  generate prompt work exactly as today; a per-host banner line
  (`=== <name> (i/N) ===`) separates them. No new script flags, no
  parity-pair edits — the flow composes the script's existing modes.
- Injectable seam: app gains `copy_id_fn(entries: list[HostEntry]) ->
  list[tuple[str, int]]` (name, rc per host) defaulting to the
  suspend+sequential-subprocess implementation; tests inject a capture
  (no real suspend/ssh in the suite).
- On resume: FleetPanel logs one rc-based line per host (`ok`/`failed
  (rc=N)`), re-probes (a fixed host's `ssh-failed` glyph visibly heals),
  and ONE summary toast fires — counts only, no host names (same
  notify.sh rule as §1).

## Error handling

Established patterns throughout: MultiRunner and `parse_stats` are
never-raise seams; ssh children are killed AND reaped on cancellation
(probe_setup discipline); all remote/user-derived text is markup-inert
(`Text()` cells, `markup=False` logs/statics, `escape()` for exception
text); worker groups `push` and `host-stats` join the existing
vocabulary; `_push_inflight` and `_task_inflight` are mutually exclusive
gates.

## Testing

No real ssh/subprocess/suspend in the suite (injected exec_fn /
copy_id_fn / probe fakes). Per feature: MultiRunner (cap respected, state
transitions, cancel kills+reaps+marks, spawn-failure → failed, line cap);
PushScreen (rows render, summary counts, esc-guard while running, cancel
flow, last_push column + relative age, mutual-exclusion toasts both
directions, count-only notification); stats (argv hardening incl. `--`,
parser per section + garbled/partial input, unreachable state, enter
routing); key-dist (preselect from ssh-failed, toggles, zero-selected
guard, sequential argv order, per-host rc log lines, re-probe on resume,
count-only toast). Suite enters at 221.

## Docs

README §tui: push-dashboard behavior (p/P now open the dashboard, keys
inside it), fleet `push` column, `enter` quick-stats, `k` key
distribution; key rows for all three. HelpScreen + PANEL_KEYS updated
together. CLAUDE_CHANGELOG row.
