# TUI Phase C — Command Palette, Updates Table, Task History — Design

**Date:** 2026-08-11
**Status:** Approved (roadmap Phase C: command palette, parsed check-updates
table, task history browser)

## Goal

Three navigation/insight features for the shipped TUI, per the approved
roadmap in project memory. Engine choice (user-approved): Textual's
built-in command palette (`ctrl+p`, already bound) populated by custom
`Provider`s — the TUI never re-implements matching or the overlay.

## 1. Command palette

### Providers (`app/palette.py`, registered via `WorkstationApp.COMMANDS`)

- **`ActionsProvider`** — static: `go to <panel>` for each of the five
  panels; `refresh`; `toggle watch`; `check updates` (opens
  UpdatesScreen, §2); `task history` (opens HistoryScreen, §3); `help`;
  `quit`; plus the whole-panel actions phrased as commands — `provision
  all`, `apply all pending`, `push all hosts`, `run all health checks`,
  `distribute keys`. Every hit calls the EXISTING action method (panel
  or app) — the palette never re-implements behavior, so confirms, sudo
  gates, Linux-only gates, and inflight gates apply unchanged.
- **`EntitiesProvider`** — dynamic, read from the panels' already-loaded
  state (never re-shells): each provision tool → `run <tool>` /
  `clean <tool>`; each fleet host → `push <host>` / `ssh <host>` /
  `stats <host>`; each pending dotfile → `diff <path>` / `apply <path>`;
  each health check → `run check <name>`. Selecting a hit switches to
  the owning panel, moves the table cursor to that row, then invokes
  that panel's existing action — identical to keyboard use.
- **`HistoryProvider`** — the newest 20 re-runnable history entries
  (§3) as `re-run: <summary> (<age>, rc N)`.
- `discover()` (empty query) lists the ActionsProvider set; entities and
  history appear as the query is typed.

### Curation and chrome

- `get_system_commands` is overridden to yield ONLY `Quit` — Textual's
  `Theme` (would clobber the Mocha theme), `Keys`, `Screenshot`,
  `Minimize` are dropped.
- Palette CSS themed to Mocha in `APP_CSS` (mantle background, mauve
  highlight, overlay0 dim text).
- `("ctrl+p", "Palette")` joins GLOBAL_KEYS; HelpScreen global list
  updated. Hit display text is markup-inert (`Text`/escaped — host, file,
  and tool names are user- or file-derived).

## 2. Parsed check-updates table

- `core/makeiface.py::check_updates_command(repo_root, mode, *,
  porcelain: bool = True)` appends the make command-line variable
  `CHECK_UPDATES_PORCELAIN=1` (GNU make exports command-line variables
  to recipe environments, so `lib/check-updates.sh` takes its porcelain
  branch: exactly one `status|name|detail` line per registered tool, no
  banner, no ANSI). The runner is untouched.
- New `core/updates.py`:
  - `UpdateRow` dataclass: `status` (`ok|update|ahead|rolling|unknown`),
    `name`, `detail`, `pinned: str | None`, `latest: str | None` —
    `pinned`/`latest` parsed from an `update` row's `X → Y` detail
    (both None otherwise).
  - `parse_updates(text) -> list[UpdateRow]`: never-raise; lines not
    matching `status|name|detail` with a known status are skipped.
  - `UpdatesCache` (`checked_at: str` ISO-8601 UTC, `rows`), `load_cache(
    path)` / `save_cache(path, cache)` at
    `~/.cache/workstation-tui/updates.json` with the health-cache
    discipline (atomic replace; missing/corrupt → empty cache).
- `UpdatesScreen` (`app/widgets/updates_screen.py`, ModalScreen[None]),
  opened by `u` on Provision and by the palette's `check updates`:
  - DataTable columns `st` (glyph: `↑` yellow update / `✓` green ok /
    `!` yellow ahead / `·` dim rolling / `?` red unknown), `tool`,
    `pinned`, `latest`, `detail`; default order: `update` rows first,
    then `ahead`, `unknown`, `ok`, `rolling`, each group by name; `s`
    cycles sort (status-group → name → status-group); summary Static
    `N updates · N ok · N rolling · N unchecked · checked <age>` (`never`
    when no cache).
  - Shows the cache instantly on open, then starts a fresh check via
    `launch_task(check_updates_command(...), log_to=<tee>)` where the
    tee appends lines to a buffer AND to the provision log; on rc 0 the
    buffer is parsed, cached, and the table re-renders; on rc ≠ 0 the
    cached table stays with a `last check failed (rc=N)` banner.
    `R` re-checks; `esc` closes (a running check keeps running —
    launch_task owns it; its result still lands in the cache via
    `on_result`).
  - Read-only by design: pins are manual `versions.mk` edits (dual/
    triple-edit invariants). Every cell `Text()`-wrapped.
- Dashboard: the provision card gains the line `N updates available ·
  checked <age>` from the cache (`updates: never checked` when empty).
  The rollup reads the cache file once per refresh cycle.

## 3. Task history browser

- New `core/history.py`:
  - `HistoryEntry` (pydantic, like TaskResult): `id` (`YYYYmmdd-HHMMSS-
    <4 hex>`), `started_at` (ISO-8601 UTC), `kind` (`task|sequence|
    push|keydist`), `command: list[str] | None` (argv for re-run; None
    for push/keydist), `summary` (Phase A `_command_summary` text for
    local kinds; the counts message for push/keydist), `returncode:
    int | None`, `duration_secs`, `cancelled`, `outcome` (`ok|failed|
    cancelled`), `needs_sudo: bool` (so re-run re-applies the gate).
  - `HistoryStore(root: Path)` (default `~/.cache/workstation-tui/
    history/`): `append(entry, log_lines)` writes one JSON line to
    `index.jsonl` and `<id>.log`; `load(limit=200) -> list[HistoryEntry]`
    newest first (corrupt lines skipped); `read_log(id) -> str` (missing
    → `""`); `prune(keep=200)` drops the oldest entries and their log
    files. Every method never raises (failures return empty/False; the
    app logs a warning line).
- Recording hooks: `_task_flow` and `_sequence_flow` tee `log_to` into a
  bounded list (5000 lines) and append one entry per command (a
  sequence yields `kind=sequence` entries, one per command); PushScreen
  completion appends one `push` entry (log = per-host sections joined);
  `distribute_keys` appends one `keydist` entry (log = per-host rc
  lines). Recording runs off-loop (`asyncio.to_thread`), fire-and-forget,
  followed by `prune(keep=200)`.
- `HistoryScreen` (`app/widgets/history_screen.py`, ModalScreen[None]),
  opened by global `H` and the palette's `task history`: DataTable
  (`when` relative age, outcome glyph — `✓` green / `✗` red / `–` yellow
  cancelled — `kind`, `summary`, `rc`, `time` `m:ss`), newest first;
  `enter` → the entry's log in TextViewScreen; `r` → re-run: `task`/
  `sequence` kinds relaunch `command` via `launch_task(needs_sudo=
  entry.needs_sudo)` after a ConfirmModal (`re-run <summary>?`) and
  close the screen; `push`/`keydist` rows toast `re-run from the Fleet
  panel`; `esc` closes. `("H", "History")` joins GLOBAL_KEYS +
  HelpScreen. All cells `Text()`-wrapped.

## Error handling

Established patterns: never-raise stores/parsers/providers (a provider
exception would break the palette — providers catch and yield nothing);
markup-inert dynamic text everywhere; recording and caching are
fire-and-forget and never block or fail a task; `_task_inflight` /
`_push_inflight` gates apply to palette-launched actions exactly as to
keyboard-launched ones (the palette calls the same methods).

## Testing

No real make/ssh/subprocess in the suite; caches and stores use
`tmp_path`. Per feature: palette (providers yield the expected hits for
injected panel state; selecting an entity hit switches panel + moves
cursor + invokes the action; system commands curated to Quit only;
`ctrl+p` opens the palette); updates (argv carries the porcelain var;
parser per status + `X → Y` split + garbage; cache round-trip + corrupt
file; screen shows cache then re-renders on rc 0; failure banner on
rc ≠ 0; sort cycling; dashboard line); history (store append/load/prune/
read_log + never-raise on unwritable root; task/sequence/push/keydist
entries recorded with logs; screen rows + log view + re-run through the
sudo gate + non-re-runnable toast). Suite enters at 264.

## Docs

README §tui: palette paragraph (`ctrl+p`, what's searchable), updates
table paragraph (`u`, porcelain, cache + dashboard line), history
paragraph (`H`, re-run, retention, cache location); key rows. HelpScreen
+ GLOBAL_KEYS updated together. CLAUDE_CHANGELOG row.
