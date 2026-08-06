# Workstation TUI (`workstation`) — Design

**Date:** 2026-08-05
**Status:** Approved (brainstorming session, layout/approach validated via visual companion)

## Goal

A Textual + Click control panel for the workstation provisioning system, intended to
become the **primary daily interface** — the scripts, make targets, and `cz*` aliases
remain the underlying plumbing and fallback. One command: `workstation`. Bare
invocation launches the TUI; subcommands run a starter set of headless actions.

## Decisions (from requirements dialogue)

| Question | Decision |
|---|---|
| Purpose | Full control panel: provisioning, dotfiles/chezmoi, hosts/fleet, health/doctor — all four panels in v1 |
| Platforms | Linux full (dev **and** prod); Windows reduced (chezmoi, hosts.conf, bootstrap-related) |
| Python supply on prod | Promote `python-env` from dev-only to both scopes (user-level, no sudo — prod-safe; `uv` is already both-scopes) |
| Privileged commands | In-TUI password overlay feeding `sudo` (any Linux mode, shown whenever a command needs it); native UAC popup on Windows |
| CLI shape | One Click entry point; bare → TUI; starter set of headless subcommands (grow later) |
| Command name | `workstation` |
| Layout | Sidebar rail (k9s/lazydocker style): persistent left nav, main pane, global status footer |
| Data/action architecture | **Hybrid**: native Python reads of stable on-disk formats; every mutation shells out to the existing single entry point |
| Theming | Catppuccin Mocha via a port of the user's `mocha_theme.py` (AtcomSearch) — same public API |
| Success bar | Replaces daily muscle memory as the default interface |

## Packaging & installation

New top-level `tui/` directory:

```
tui/
  pyproject.toml            # dist: workstation-tui; console script: workstation
  src/workstation_tui/
  tests/
```

- `pyproject.toml` declares real deps (textual, click, rich, pydantic) — all already in
  the blessed env, so install resolution is a no-op there, but the package stays honest
  standalone.
- **Install rides the existing python-env machinery.** `makefile/lib/python-env.sh`
  gains one step after the lib install:
  `uv pip install --python "$env_dir/bin/python" -e "<repo>/tui"`
  (repo root derived from the script's own path). Editable install ⇒ `chezmoi update`
  / `git pull` updates the TUI fleet-wide with no reinstall. Dependency changes in
  `pyproject.toml` are the one case needing `make python-env-rebuild`.
  The python-env stamp already bakes a cksum of `python-env.sh`, so adding this step
  triggers the rebuild automatically on next provision.
- **Launcher (Linux):** `~/.local/bin/workstation` → symlink to the venv's generated
  `workstation` entry-point script (the textual/typer pattern — console-script shebangs
  point into the env; the wpy symlink-to-python trap does not apply).
- **python-env promoted to both scopes:** drop the `MODE=dev` gate in
  `makefile/Makefile`; the target joins base provision in both modes. User-facing ⇒
  README.html + CLAUDE_CHANGELOG rows; the CLAUDE.md python-env invariant line updates.
- **Windows:** `bootstrap.ps1`'s `Invoke-PythonEnv` gains the same editable install
  from the chezmoi source dir, plus a `workstation.cmd` shim in `workstation\bin`
  (existing PATH mechanism) targeting the venv's `Scripts\workstation.exe`.

## Code architecture

Strict two-layer split; nothing under `core/` imports Textual.

```
src/workstation_tui/
  cli.py                 # Click group; bare → TUI; subcommands call core directly
  core/
    context.py           # platform, WSL, group (`chezmoi data` .group), MODE default,
                         #   capability flags (has make? sudo? systemctl? chezmoi?)
    versions.py          # versions.mk parser → {tool: pin} (raw pins only)
    stamps.py            # stamp-dir scanner → fresh/stale/missing per tool
    hostsfile.py         # hosts.conf parser (READ-only; writes go via manage-hosts)
    chezmoi.py           # status/diff readers + apply/update command builders
    makeiface.py         # target inventory + `make -C makefile <t> MODE=<m>` builders
    fleet.py             # reachability probes, update-hosts.sh invocation plans
    health.py            # doctor/check-updates/invariants/services/WSL-interop readers
    runner.py            # subprocess engine: streaming, sudo/UAC, cancel, task lock
    models.py            # pydantic: ToolStatus, HostEntry, PendingChange, TaskResult…
  app/
    app.py               # WorkstationApp: sidebar nav, footer, keymap
    theme.py             # mocha_theme.py port (see Theming)
    screens/             # dashboard.py, provision.py, dotfiles.py, fleet.py, health.py
    widgets/             # log_pane.py, sudo_modal.py, confirm_modal.py, status_cards.py
```

**Tool inventory refinement:** the TUI's tool inventory does NOT come from `versions.py` —
`versions.mk` variable names aren't reliably derivable into tool names (e.g.
`TEALDEER_VERSION` → `tldr`). Instead `makeiface.py` shells out to `make inventory` and
parses its `DOCTOR_ROWS` dump (`kind|name|version` rows — the same data `make doctor`
renders) for the authoritative tool↔version list. `versions.py` stays a thin
`versions.mk` raw-pin parser, used only where a bare pin value is needed directly (e.g.
comparing `PYTHON_VERSION` against a stamp).

**Data flow:** screens ask core for pydantic models (cheap native reads; refreshed on
screen entry, on a manual refresh key, and after any task finishes) → mutations are
`Command` objects built by core, executed by `runner.py`, streamed into the log pane →
on completion the affected panel re-reads state. Click subcommands use the identical
core calls and print via rich — one logic path, two front doors.

**Read-parser drift guard:** the core parsers are the one place the hybrid approach
duplicates *read* knowledge (versions.mk, hosts.conf, stamps). Each is pinned by unit
tests against **the repo's real files as fixtures**, so a format change breaks the
TUI's tests in the same commit. `check-invariants.sh` is not extended for these.

## Theming

`app/theme.py` is a port of the user's AtcomSearch `mocha_theme.py`, keeping the same
public API so patterns transfer 1:1:

- `M` (20-key Mocha palette) + `EXTRA`, `ROLE` semantic map.
- Composable CSS fragments: `CORE_CSS`, `BAR_CSS`, `PANEL_CSS`, `HOME_CSS`,
  `LAYOUT_CSS`, `LOG_CSS`, `INPUT_CSS`, `MODAL_CSS` → `MOCHA_CSS`.
- Markup helpers: `keycap`, `kb`, `action_line`, `tab_label`, `tab_bar`, `field`,
  `heading`, `muted`, `status_msg`.
- Status vocabulary: `TASK_ICONS`, `YES`/`NO`/`NA`, `SEL_ON`/`SEL_OFF`, `icon`,
  `sel_marker`, `bool_marker`, `count_text`.

Dropped as AtcomSearch-specific: `TYPE_COLOUR`, `FILE_ICONS`/`FILE_STATUS`,
`SIZE_WARN_BYTES`/`size_style`. Added: workstation vocabulary (stamp
`fresh`/`stale`/`missing`, host reachability). Role assignments follow the source
module: mauve titles, blue interactive/selected, sapphire in-progress, green/yellow/red
status, peach live, overlay0 muted. The port targets current Textual on CPython 3.14 —
implementation must verify the component-class CSS selectors (`datatable--header` etc.)
against the pinned Textual version.

## The five screens (layout A: sidebar rail)

Sidebar: Dashboard · Provision · Dotfiles · Fleet · Health. Global footer: host
identity (`host · group · MODE · WSL · EL family`) + per-screen key bar (`kb()` badges).
`[1-5]` jump, `[g]` refresh, `[q]` quit, `[?]` help.

1. **Dashboard** — live summary cards per domain (provision: fresh/stale stamp counts +
   updates available; dotfiles: pending file count + source git state; fleet: hosts
   up/total + last push age; health: doctor/lint/services rollup). Enter on a card
   opens its panel.
2. **Provision** — table of every tool from versions.mk/tools.mk: name, pin, stamp
   state (`✓ fresh` / `⟳ stale` / `✗ missing`), scope; filter box. Actions: `[r]` run
   target, `[c]` clean+reinstall, `[u]` check-updates, `[R]` full provision
   (`make dev`/`prod`). Log pane streams output; sudo overlay raised as needed.
3. **Dotfiles** — chezmoi pending list (status codes) + live diff of highlighted file
   side-by-side; source-repo git line (branch, clean/dirty, ahead/behind). Actions:
   `[a]` apply (diff → in-app confirm → `chezmoi apply --force`), `[U]` update
   (pull+apply, same confirm flow), `[A]` re-add (sync-from-host files, e.g. WT
   settings.json), `[d]` full-screen diff. chezmoi's own prompts never fire under the
   TUI — `--force` after explicit in-app confirmation, by policy.
4. **Fleet** — hosts.conf table (name, host, group, reachability probed async on
   entry). Actions: `[s]` ssh (app.suspend into a real session), `[p]` push
   (update-hosts.sh for that host, streamed), `[P]` push all, `[a]/[e]/[x]`
   add/edit/remove via form modals whose submit shells out to `manage-hosts.sh`
   flags — **the TUI never writes hosts.conf itself** (manage-hosts remains the only
   writer; its .sh↔.ps1 parity pair is untouched).
5. **Health** — check rows with cached last result + age: doctor.sh, check-updates,
   invariants+lint, template render, services (systemctl `is-active` for
   dozzle/cockpit/docker/rsyslog — dev + non-WSL only, mirroring the make gates), WSL
   interop (binfmt handler present, powershell.exe reachable). `[enter]` re-run one,
   `[R]` run all, `[o]` open last log.

## Execution engine

- All mutations flow through `runner.py`: asyncio subprocess, stdout/stderr merged,
  streamed line-by-line into the panel's RichLog; exit code + duration recorded;
  affected panel re-reads state on completion.
- **One mutation at a time, globally.** A running task locks all mutating actions
  (reads stay live); a second request is refused with "task running". No queueing in
  v1. Prevents concurrent `make` stamp races and chezmoi self-locking.
- **Cancel:** SIGINT to the process group, SIGKILL after a grace period.
- **Sudo overlay (Linux, any mode, on demand):** before a privileged action, check
  `sudo -n -v`; if the timestamp is stale, a modal collects the password and validates
  via `sudo -S -v` (wrong password → inline error, retry). The real command then runs
  unmodified (`make`'s internal `$(SUDO)` hits the cached timestamp). A keepalive
  refreshes `sudo -n -v` every 60s while a privileged task runs. The password exists
  only transiently in the modal, never logged or persisted. If sudoers has
  `timestamp_timeout=0` (validate succeeds, `-n` still fails), offer app-suspend and
  run the command in the raw terminal instead. Prod's standard targets never need
  sudo (`SUDO` empty in prod scope), but the overlay is available on prod for actions
  that do (service ops, explicit `--mode dev` override).
- **Windows elevation:** actions requiring elevation launch via
  `Start-Process -Verb RunAs` → native UAC popup; the TUI shows a "waiting for UAC
  consent…" task state; declining cancels the task cleanly. Elevation remains
  exceptional on Windows, matching the repo posture (SSHFS-Win precedent).
- **Interactive commands never run inside a pane.** chezmoi prompts are eliminated by
  policy (above); ssh suspends the whole app.

## Headless CLI (starter set)

```
workstation                      # → Textual app
workstation status  [--json]     # dashboard summary
workstation doctor               # doctor.sh, streamed, exits with its rc
workstation updates              # check-updates.sh summary
workstation provision <tool>…    # make -C makefile <tool> MODE=<detected> (--mode override)
workstation hosts list [--json]
workstation dotfiles status|diff|apply|update   # apply = diff + y/N + --force
workstation --version / --help
```

- `--json` prints the pydantic models — the scripting/SSH-oneliner surface.
- Headless privileged commands do **not** get the overlay: `make`'s own sudo prompt
  reaches the terminal, which is already interactive.
- Zsh completions via Click's generated completer, evaluated from a small tracked
  `_workstation` stub in the zsh completions dir — auto-generated, so it does NOT join
  the hand-maintained script-flag↔completion parity invariant. bash/nushell: v2.

## Platform & mode gating (`core/context.py`, resolved once at startup)

| Capability | dev Linux | prod Linux | Windows | WSL dev |
|---|---|---|---|---|
| Provision panel (make) | full | full (targets are sudo-free) | hidden → bootstrap status card | full |
| Dotfiles panel | full | full | full | full |
| Fleet panel | full | view + probes (+push if keys present) | view/add/edit via `manage-hosts.ps1` | full |
| Health panel | full | doctor/updates/lint only | chezmoi + interop checks | services "n/a WSL" |
| Elevation UX | sudo overlay | sudo overlay (on demand) | UAC popup (on demand) | sudo overlay |

- Group from `chezmoi data` `.group`; MODE defaults from group (dev_machine → dev);
  WSL detection mirrors `bootstrap.sh`'s `is_wsl()` logic.
- Every unavailable capability renders a visible "not available here: <reason>"
  placeholder — features degrade honestly, never hide silently.
- Windows shell-outs target the `.ps1` siblings via `powershell.exe`.

## Error handling

- Task failures are loud: red task row (`TASK_ICONS["failed"]`), log preserved and
  reopenable, footer notification. Nothing auto-retries.
- Parser failures never crash the app: unparseable input renders an explicit
  "unparseable: <file>: <reason>" state in the affected panel only.
- Missing capability ≠ error (see gating table).
- The TUI writes nothing outside `~/.cache/workstation-tui/` (cached check results +
  timestamps) and `~/.config/workstation-tui/` (reserved, empty in v1). All repo/host
  mutations go through the existing scripts/make/chezmoi.

## Testing

- `tui/tests/` (pytest):
  - Core parser units against **the repo's real files as fixtures** plus curated edge
    cases (mangled hosts.conf, unknown stamp names).
  - Runner tests with scripted fake commands: success, failure, cancel,
    sudo-validate paths.
  - Textual Pilot smoke tests: app boots on a fake core, sidebar navigates all five
    screens, sudo modal accept/reject.
- CI: `tui-tests` job in `.github/workflows/lint.yml` (astral-sh/setup-uv,
  `uv run --directory tui pytest`).
- Local: `make -C makefile tui-test` wrapper, discoverable next to `lint`.
- `check-invariants.sh`: one new check asserting the `tui/` editable-install step
  exists in BOTH `makefile/lib/python-env.sh` and `bootstrap.ps1`'s
  `Invoke-PythonEnv` (new parity pair, alongside the existing PY_LIBS one).

## Phasing (one PR each)

1. **Foundations** — `tui/` skeleton, core models + parsers + tests, python-env
   promotion to both scopes + editable install + launchers (Linux/Windows), CI job.
2. **CLI** — Click group + starter subcommands, zsh completions stub.
3. **Shell + Dashboard** — Textual app, theme port, sidebar nav, read-only dashboard.
4. **Runner + Provision** — engine, sudo overlay/UAC, provision panel.
5. **Dotfiles + Fleet** — the two mutation-heavy panels.
6. **Health + docs** — health panel, README.html §tui + CLAUDE_CHANGELOG rows,
   troubleshooting entries.

## Documentation & invariant touchpoints

- README.html: new §tui (what it is, launch, panels, headless commands, platform
  matrix) + §daily cross-reference; README.css/js only if a new nav entry needs it.
- CLAUDE_CHANGELOG.md: rows for python-env promotion and the TUI itself.
- CLAUDE.md: python-env invariant line updated (both scopes + editable TUI install);
  parity-pair list gains the editable-install dual-edit; conventions note that
  `workstation` completions are Click-generated (exempt from flag-parity checks).
