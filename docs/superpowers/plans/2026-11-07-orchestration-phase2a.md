# Orchestration phase 2a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ws agent` jobs run on Claude Code or Codex (per repository) inside a two-layer OS sandbox that
hides reads, end with a structured report, get their checks run and one fix round, retry transient
failures, accept follow-ups (`tell`/`answer`), and notify the person.

**Architecture:** A new engine layer (`engines.py`) puts Claude and Codex behind one interface. A new job
sandbox (`agent_sandbox.py`) wraps every engine and check in ws-agent's own bwrap. `agent_exec.execute`
becomes an attempt loop over those two. New modules hold checks (`agent_checks.py`) and events
(`agent_events.py`). Job state stays derived; the registry gains per-repository engine and check
settings. Phase 2b (serve, sources, triage, inbox, TUI) gets its own plan after this one ships.

**Tech Stack:** Python 3.11+ stdlib on mise's Python (`ws.py` stays 3.6-parseable), bubblewrap,
pueue 4.0.4, Claude Code 2.1.319, Codex 0.166.0, bash for the plugin hooks.

**Spec:** `docs/superpowers/specs/2026-11-07-orchestration-phase2-design.md` (goals 1–7). Phase 1:
`docs/superpowers/specs/2026-11-06-global-orchestration-design.md`.

## Global Constraints

- Work in the worktree `~/worktrees/workstation-phase2`, branch `feat/orchestration-phase2`; never edit
  `~/.config/mise` (the live checkout). Push after every commit; the person merges.
- Tests never reach the real pueued, claude, codex, gh or an SVN server: fakes (`tests/agent_helpers.py`),
  a scratch pueued, real svn on `file://`, real bwrap (skip a test when `bwrap` is missing).
- Agents never run `wsa`, `mise dot apply` or a bulk `mise bootstrap` against the real `$HOME`; sudo
  steps go to the person.
- A user-facing change updates `README.md` (`## Agent orchestration`) in the same commit.
- `mise run lint` and `bash scripts/check-templates.sh` pass before each commit (the pre-commit hook
  runs lint).
- Default engines `["claude"]`. Codex only where the person ran `allow --engine codex`. A job never
  runs, falls back, triages or reviews on an engine its repository doesn't list.
- Two jobs in parallel (`[queue] parallel = 2`), at most one per engine (`[engines.<name>] parallel = 1`).
- Transient retry backoff `(15, 60, 240)` seconds, at most 3 retries; usage-limit cooldown is the
  reported reset, else 1 h; check timeout 20 min each; `fix_rounds` default 1; review off by default.
- No sandbox → no job ("If isolation cannot be established safely, disable autonomous execution and
  report the limitation"). Phase-1 confinement is not a fallback.
- Hooks stay read-only, fail-open, ≤ 3 s; the per-prompt hook makes no pueue or network call.
- Real model calls only in the validation task and in the two fixture-capture steps, on scratch
  repositories with no proprietary content.

## Review Focus

- A Claude-only repository whose Claude hits its usage limit must end `waiting`, never run on Codex
  (Task 4, `test_claude_only_repo_never_falls_back`).
- A symlink inside the copy that points into `$HOME` must read nothing inside the sandbox (Task 2,
  `test_symlink_out_of_the_copy_reads_nothing`).
- Truncated or empty engine output (killed mid-stream) must parse as `error`, never `ok` (Task 3,
  `test_parse_truncated_output_is_error`).
- A `tell` that lands while the job is collecting or running checks must still be delivered (Task 6,
  `test_message_during_collect_requeues`).
- A check that hangs or floods output must record `timed out` with a bounded tail, never `pass`
  (Task 5, `test_check_timeout_and_output_cap`).

---

### Task 1: Registry v2

**Files:**
- Modify: `scripts/ws/wslib/agent_registry.py`
- Modify: `scripts/ws/wslib/agent.py` (`_allow`, `_repos`, the `allow` parser)
- Modify: `dotfiles/claude/hooks/secret-guard.sh`, `.claude/hooks/test-hooks.sh`
- Modify: `README.md`
- Test: `scripts/ws/tests/test_agent_registry.py`, `scripts/ws/tests/test_agent_cli.py`

**Interfaces:**
- Produces:
  - `KNOWN_ENGINES = ("claude", "codex")`
  - `@dataclass(frozen=True) class Repo(path: Path, vcs: str, commands: tuple[str, ...] = (), allowed_at: str = "", engines: tuple[str, ...] = ("claude",), checks: tuple[str, ...] = (), fix_rounds: int = 1, review: str = "", network: bool = False)`
  - `@dataclass(frozen=True) class EngineSettings(parallel: int = 1, model: str = "")`
  - `@dataclass(frozen=True) class Settings(parallel: int = 2, engines: Mapping[str, EngineSettings], hide: tuple[Path, ...] = (), desktop: bool = True)`; `engine(name) -> EngineSettings` returns the default for an unlisted name
  - `settings() -> Settings`
  - `load() -> tuple[dict[str, Repo], int]` (unchanged shape; the int is `Settings.parallel`)
  - `class Unreadable(Exception)`
  - `allow(root, vcs, commands, *, engines=("claude",), checks=(), fix_rounds=1, review="", network=False) -> Repo` raises `Refused`, `Unreadable` or `ValueError` (unknown engine; `review` not in `engines`)

- [ ] **Step 1: Write the failing tests** (`test_agent_registry.py`)
  - `test_v2_fields_round_trip`: `allow(..., engines=("claude","codex"), checks=("make test",), fix_rounds=0, review="codex", network=True)`, then `find(root)` returns those values.
  - `test_defaults`: a v1 file (`vcs`, `commands`, `allowed_at` only) loads with `engines == ("claude",)`, `fix_rounds == 1`, `review == ""`, `network is False`; `settings().parallel == 2`.
  - `test_settings_tables`: a hand-written `[queue] parallel = 3`, `[engines.codex] parallel = 1, model = "o4"`, `[sandbox] hide = ["/data/svn"]` and `[notify] desktop = false` read back.
  - `test_unknown_tables_and_keys_survive_a_write`: given `[repo."~/r".watch] urls = ["^/trunk"]` and `[future] x = 1`, an `allow` of another repository keeps both, byte-equal after a reparse.
  - `test_unparseable_file_is_never_overwritten`: a file containing `[[bad`. `allow` raises `Unreadable` and the file is unchanged.
  - `test_review_must_be_an_allowed_engine` and `test_unknown_engine_refused`: both raise `ValueError`.
- [ ] **Step 2: Run them, expect failures**

  Run: `cd scripts/ws/tests && python3 -m unittest test_agent_registry -v`

  Expected: FAIL. `Repo` has no `engines`; `settings` is undefined.
- [ ] **Step 3: Implement** in `agent_registry.py`.
  - `_write` rebuilds the whole document from the parsed data: known keys typed, unknown keys and tables passed through. Output is TOML via a small emitter: strings and arrays through `json.dumps`, booleans, ints, nested tables. That fixes the phase-1 minor "overwrites a file it couldn't parse".
  - `_read` raises `Unreadable` when the file exists but `tomllib` fails; `load`/`find`/`settings` treat that as empty, so the hook keeps working.
- [ ] **Step 4: CLI tests** (`test_agent_cli.py`)
  - `test_allow_engines_and_checks`: `ws agent allow <svn wc> --engine claude --engine codex --check 'make test' --fix-rounds 0 --review claude --network` succeeds. It prints a line containing `OpenAI` and `authoriz` (codex on an SVN repository), and `repos` shows `engines: claude, codex`, `checks: make test`, `network: on`.
  - `test_allow_unparseable_registry`: exit 1, and the message names the file.
- [ ] **Step 5: Implement the `allow` flags and the `repos` columns** in `agent.py`.
  - Flags: `--engine` (repeatable, choices `KNOWN_ENGINES`), `--check` (repeatable), `--fix-rounds N`, `--review E`, `--network`.
  - A `ValueError` exits 2 and an `Unreadable` exits 1, each with its message.
- [ ] **Step 6: Guard the registry file against session edits.**
  - In `secret-guard.sh`, deny Edit/Write/MultiEdit/NotebookEdit whose path resolves to `$HOME/.config/workstation/agents.toml`, with the reason "ws-agent's registry changes only through ws-agent allow, run by the person in their own terminal".
  - Add two assertions to `test-hooks.sh`: an edit is denied, a read is allowed.
- [ ] **Step 7: README.** Under "Queued jobs", document the new `allow` flags, the `agents.toml` tables (`[queue]`, `[engines.*]`, `[sandbox] hide`, `[notify]`), and the Codex authorization note.
- [ ] **Step 8: Run everything**

  Run: `bash scripts/test-ws.sh && bash .claude/hooks/test-hooks.sh && mise run lint`

  Expected: PASS.
- [ ] **Step 9: Commit and push.** `ws agent: per-repository engines, checks and review in the registry`.

### Task 2: Job sandbox

**Files:**
- Create: `scripts/ws/wslib/agent_sandbox.py`
- Modify: `config.linux.toml` (dnf batch: `"dnf:bubblewrap" = "latest"`)
- Test: `scripts/ws/tests/test_agent_sandbox.py`

**Interfaces:**
- Consumes: `agent_registry.load()`, `agent_registry.settings().hide`, `jobs.jobs_dir()`, `core.home()`, `core.state_dir()`.
- Produces:
  - `class SandboxError(Exception)`
  - `def bwrap() -> str | None`
  - `def hidden_paths(job_id: str) -> list[Path]`: every other job directory, every registered repository path, `settings().hide`.
  - `def wrap(argv: list[str], *, job_id: str, wc: Path, rw: Sequence[Path] = (), ro: Sequence[Path] = (), network: bool = True, chdir: Path | None = None) -> list[str]`, which raises `SandboxError` when bwrap is missing.
  - `def probe(*, force: bool = False) -> str | None`: `None` when an outer no-op and a nested `bwrap --unshare-net` no-op both succeed, else the reason. Cached for 24 h in `<state>/agent-sandbox.json`.
- Layout `wrap` builds:
  - base: `--die-with-parent --new-session --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs <home>`;
  - read-only, from `ro` (the caller passes the engine's paths): `~/.local/share/mise`, `~/.local/bin` and `core.WS_DIR`;
  - read-write: the job directory, plus `rw`;
  - for git copies: `--ro-bind <repo>/.git <repo>/.git`;
  - each hidden path that exists: `--tmpfs` for a directory, `--ro-bind /dev/null` for a file;
  - `--unshare-net` when `network` is false;
  - then `--chdir`.
  - Paths that don't exist are skipped.

- [ ] **Step 1: Write the failing tests.** They use real bwrap, run `python3 -c` inside, and a scratch HOME.
  - `test_home_is_hidden_but_the_copy_is_writable`: `~/secret.txt` reads `FileNotFoundError`; a write to `wc/x` succeeds and is visible outside afterwards; a write to `~/out` fails with `OSError`.
  - `test_other_jobs_and_registered_repos_are_hidden`: a sibling job directory's file, a registered repository's file and a `[sandbox] hide` directory's file are all unreadable from inside; the job's own `result/` is readable.
  - `test_symlink_out_of_the_copy_reads_nothing`: `wc/link → ~/secret.txt` can't be read.
  - `test_network_off`: with `network=False`, `socket.create_connection(("1.1.1.1", 53), 2)` raises inside; with the default it isn't attempted (no network in CI).
  - `test_nested_sandbox_runs`: `wrap(["bwrap", "--ro-bind", "/", "/", "--unshare-net", "--", "true"], ...)` exits 0, which means the engines' own sandboxes can nest.
  - `test_probe_caches_and_reports`: `probe()` returns `None` and writes the cache; with `bwrap` off PATH and `force=True` it returns a reason containing `bwrap`.
  - `test_git_dir_is_read_only`: for a git job, a write to `<repo>/.git/x` fails inside, and `git -C wc status` still works with `GIT_OPTIONAL_LOCKS=0`.
- [ ] **Step 2: Run them, expect failures**

  Run: `python3 -m unittest test_agent_sandbox -v`

  Expected: ImportError.
- [ ] **Step 3: Implement `agent_sandbox.py`** to the layout above.
- [ ] **Step 4: Run them, expect a pass.**
- [ ] **Step 5: Add `bubblewrap` to the dnf batch, verified on both EL versions:**

  `podman run --rm almalinux:8 dnf -q info bubblewrap` and the same for `almalinux:9`.

  Expected: both print `Name : bubblewrap`. If a release lacks it, it goes in `tasks/optional-packages` instead (CLAUDE.md rule). README's dnf list is generated by the TOOLS block; run `scripts/gen-tool-memory.sh`.
- [ ] **Step 6: Spike: real Claude inside the wrap.** This is a hard gate for the design.
  - In a scratch git repository: `wrap([claude -p … --settings '{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false}}' --allowedTools 'Bash(touch *)'], job_id=<scratch>, wc=<repo>, rw=[~/.claude, ~/.claude.json])`.
  - Prompt: touch `inside.txt` and `~/scratch/escape.txt`.
  - Expected: `inside.txt` exists, `escape.txt` doesn't, and the exit is 0.
  - If Claude can't run, or its sandbox can't start inside the outer layer, **stop and report to the person**: the design's nesting doesn't hold.
- [ ] **Step 7: Commit and push.** `ws agent: a job sandbox that hides the home directory, other jobs and registered copies`.

### Task 3: Engines

**Files:**
- Create: `scripts/ws/wslib/engines.py`
- Create: `scripts/ws/tests/fixtures/claude-structured.json`, `scripts/ws/tests/fixtures/codex-exec.jsonl`, `scripts/ws/tests/fixtures/codex-last.json`
- Modify: `scripts/ws/tests/agent_helpers.py` (a `FAKE_CODEX`, and `FAKE_CLAUDE` printing `structured_output`)
- Test: `scripts/ws/tests/test_engines.py`

**Interfaces:**
- Consumes: `agent_registry.Repo`, `agent_registry.settings()`, `agent_sandbox.probe()`, `jobs.Job`.
- Produces:
  - `REPORT_SCHEMA: dict`, exactly as in the spec's "Report schema".
  - `@dataclass(frozen=True) class Confinement(wc: Path, network: bool, commands: tuple[str, ...], instructions: str, read_dirs: tuple[Path, ...] = ())`.
  - `@dataclass class Outcome(kind: str, report: dict | None, session_id: str, turns: int | None = None, duration_ms: int | None = None, cost_usd: float | None = None, reset_at: str = "", message: str = "")`, where `kind` is one of `ok`, `transient`, `usage_limit`, `auth`, `error`.
  - The `class Engine(Protocol)` members:
    - `name: str`
    - `enforces: frozenset[str]`
    - `def ro_paths(self) -> list[Path]`
    - `def rw_paths(self) -> list[Path]`
    - `def available(self) -> str | None`
    - `def argv(self, job: jobs.Job, adir: Path, *, resume: str | None, c: Confinement, model: str) -> list[str]`
    - `def env(self, base: Mapping[str, str]) -> dict[str, str]`
    - `def session_from(self, adir: Path) -> str | None`
    - `def transcript_exists(self, sid: str) -> bool`
    - `def parse(self, adir: Path, rc: int) -> Outcome`
  - `adir` is one attempt's directory, `result/attempts/<n>/`; the engine writes `stdout` there (codex also `last.json`).
  - `ENGINES: dict[str, Engine] = {"claude": ClaudeEngine(), "codex": CodexEngine()}`.
  - `def cooling(name: str) -> str` returns the ISO until-time, or `""`; `def cool(name: str, until: str) -> None`. Both use `<state>/agent-engines.json`.
  - `def select(entry: Repo, *, exclude: Collection[str] = ()) -> tuple[Engine | None, list[str]]` returns the first allowed, available engine that isn't cooling down, plus a reason for each one skipped.
  - `@contextmanager def slot(name: str, cap: int) -> Iterator[None]`: a flock semaphore over `<state>/agent-engines/<name>.<i>.lock`, `i < cap`, which blocks until one is free.
- Claude argv:
  - Phase 1's `claude_argv` moves here, plus `--json-schema <REPORT_SCHEMA json>` and `--add-dir` for each read dir.
  - `--settings` holds `permissions.blockWritesOutsideWorkingDirectories` and `sandbox`:
    - `enabled`, `failIfUnavailable: true`, `allowUnsandboxedCommands: false`;
    - `filesystem.allowWrite: [wc]`, `filesystem.denyRead: [~/.claude/.credentials.json]`;
    - `network.allowedDomains: []` unless `network`.
  - `rw_paths`: `~/.claude`, `~/.claude.json`. `ro_paths`: the resolved directory of the `claude` binary.
  - `enforces`: `{"cmd-allowlist", "os-sandbox", "path-confine", "no-network"}`.
  - `available`: the binary exists and `claude auth status` JSON has `loggedIn: true`.
- Codex argv:
  - The spec's line: `exec --json -o <adir>/last.json --output-schema <adir>/schema.json --skip-git-repo-check --ignore-rules --ignore-user-config -s workspace-write -C <wc> -c approval_policy="never" -c sandbox_workspace_write.network_access=<bool> -c developer_instructions=<toml-quoted> [-m model] -`.
  - Resume: `exec resume <sid> -` with `-c sandbox_mode="workspace-write"` and the same `-c` keys.
  - `rw_paths`: `~/.codex`. `ro_paths`: the codex binary's directory.
  - `enforces`: `{"os-sandbox", "path-confine", "no-network"}`.
  - `available`: the binary exists and `codex login status` exits 0 printing `Logged in`.
  - `session_from` reads the `thread_id` of the `thread.started` event in `stdout`.
  - `transcript_exists` globs `~/.codex/sessions/**/rollout-*-<sid>.jsonl`.

- [ ] **Step 1: Capture the fixtures from real runs** (scratch git repository, trivial prompt "Report status done with summary 'fixture'").
  - Claude: `claude -p --output-format json --json-schema …`; save the output as `claude-structured.json`.
  - Codex: `codex exec --json -o last.json --output-schema schema.json --skip-git-repo-check --ignore-rules -s read-only -`; save the JSONL as `codex-exec.jsonl` and `last.json` as `codex-last.json`.
  - Then grep both for `token|key|secret`: expected none. Record the field names the parsers rely on: Claude's `structured_output`, Codex's `thread.started.thread_id` and `turn.completed`/`turn.failed`.
- [ ] **Step 2: Write the failing tests** (`test_engines.py`)
  - `test_claude_argv_has_schema_sandbox_and_confinement`: parse the `--settings` JSON. Assert `sandbox.enabled is True`, `failIfUnavailable is True`, `allowWrite == [str(wc)]` and the credentials path in `denyRead`. `--json-schema` parses to `REPORT_SCHEMA`.
  - `test_codex_argv_and_resume_argv`: `--ignore-rules`, `--ignore-user-config`, `-s workspace-write` and `network_access=false` are present, and the prompt is `-` (stdin). Resume uses `exec resume <sid> -` and carries no `-s`/`-C`.
  - `test_parse_claude_fixture` and `test_parse_codex_fixture`: `kind == "ok"`, `report["status"] == "done"`, and the session ids match the fixtures.
  - `test_parse_truncated_output_is_error`: an empty `stdout`, half of the claude fixture, and a JSONL with only `thread.started` all give `kind == "error"`.
  - `test_classify_failures`, table-driven over captured or documented message shapes:
    - Claude `is_error` with `Claude AI usage limit reached|1767225600` → `usage_limit`, with `reset_at` set from the epoch;
    - `API Error: 529`, `API Error: 500`, `Request timed out`, `Connection error` → `transient`;
    - `Invalid API key` / `Please run /login` → `auth`;
    - Codex `error` events with `usage_limit_reached` / `429` → `usage_limit` / `transient`.
    - Keep the patterns as module constants, so a newly measured shape is a one-line change.
  - `test_select_respects_allowed_order_cooldown_and_availability`:
    - `engines=("claude","codex")` with claude cooling → codex;
    - codex unavailable → `(None, reasons)`;
    - `engines=("claude",)` with claude cooling → `(None, ["claude: cooling down until …"])`.
  - `test_slot_caps_concurrency`: two threads each take `slot("claude", 1)`; the second waits until the first leaves.
  - `test_available_needs_the_sandbox`: with `agent_sandbox.probe` patched to return `"no bwrap"`, `select` returns `None` with that reason.
- [ ] **Step 3: Run, expect failures.**
- [ ] **Step 4: Implement `engines.py`;** `agent_exec.claude_argv` becomes a thin call into it until Task 4 removes it.
- [ ] **Step 5: Run, expect a pass**, together with the whole `scripts/test-ws.sh`.
- [ ] **Step 6: Spike: real Codex inside the wrap,** like Task 2 Step 6, with `-s workspace-write`. Ask Codex to touch `inside.txt` and `~/scratch/escape.txt`, and to `cat` a file under `~/.ssh`. Expected: only `inside.txt`; the read finds nothing. If Codex's sandbox can't nest, Codex is unavailable: stop and report.
- [ ] **Step 7: Commit and push.** `ws agent: Claude and Codex engines behind one interface`.

### Task 4: The attempt loop

**Files:**
- Modify: `scripts/ws/wslib/agent_exec.py` (`RULES`, `RESUME`, new `HANDOFF`, `execute`, `_run_engine`, shims, `clean_env`)
- Modify: `scripts/ws/wslib/jobs.py` (`Job`, `state`, `duplicate`)
- Modify: `scripts/ws/wslib/agent.py` (`context_line`, `_here`, `_ls`, `_show`, `_result`, `_doctor`)
- Modify: `README.md`
- Test: `scripts/ws/tests/test_agent_exec.py`, `scripts/ws/tests/test_jobs.py`, `scripts/ws/tests/test_agent_cli.py`

**Interfaces:**
- Consumes: Task 3 (`engines.select`, `engines.slot`, `Engine.*`, `Confinement`, `Outcome`) and Task 2 (`agent_sandbox.wrap`).
- Produces:
  - `Job` gains `engine: str = ""`, `history: list[dict[str, object]] = []` (entries `{attempt, engine, session_id, started, kind}`) and `auto_resumes: int = 0`. An old `job.json` still loads.
  - `exit.json` fields:
    - `exit_code`, `finished`, `attempt`, `engine`, `session_id`;
    - `kind`: `ok`, `transient`, `usage_limit`, `auth`, `error`, `timeout`, `sandbox`, `prepare`, `not_allowed` or `cancelled`;
    - `status`: the report status or `null`;
    - `checks`: `"none"` until Task 5;
    - `reset_at`, `num_turns`, `duration_ms`, `cost_usd`, `warnings`, `reason`.
  - `jobs.state` precedence:
    1. closed;
    2. cancelled;
    3. live run → `running`;
    4. `exit.json`: status `question`/`blocked` → `needs-you`; kind `usage_limit` with no engine left → `waiting`; `exit_code == 0` → `succeeded`; else `failed`;
    5. phase 1's pueue mapping.
  - `ACTIVE` unchanged. `duplicate` also matches `needs-you` and `waiting`.
  - `agent_exec.BACKOFF = (15, 60, 240)`, patched to zeros in tests.
- Flow of `execute(job_id, *, resume)`:
  1. Phase 1's refusals (cancelled, closed, live, not allowed) and `prepare`.
  2. `agent_sandbox.probe()`: a reason → `finish(kind="sandbox")`.
  3. `engines.select(entry)`: `None` → `finish(kind="usage_limit" if every skip was a cooldown else "error", reason=...)`.
  4. Under `engines.slot(engine.name, settings().engine(name).parallel)`: build the `Confinement` and the prompt (fresh, `RESUME`, or `HANDOFF` when `job.engine` differs from the selected engine), then `wrap(engine.argv(...))`.
     - Run it under `timeout --kill-after=60s <remaining>` via `_run_engine` (phase 1's `_run_claude`, renamed) with `cwd=wc` and `env=engine.env(clean_env(...))`.
     - Parse the `Outcome`.
  5. On `transient`: sleep `BACKOFF[i]` and resume the same session, at most 3 times.
  6. On `usage_limit`: `engines.cool(name, reset_at or now+1h)` and loop back to 3, excluding that engine.
  7. Append to `history`, then `collect`, then `finish`.
- Each attempt archives the previous `exit.json` to `exit-<n>.json`.
- `RULES`:
  - The final-report paragraph becomes: "End with the structured report. status: done when finished; question with one concrete question when you need the person; blocked when a rule stops you."
  - The git sentence becomes: "git: edit files only; never run git add, rm, mv, restore or apply (ws-agent stages everything when you finish)."
  - The git shim becomes read-only: `GIT_LOCAL` is removed, and `git_refusal` refuses everything outside `GIT_READ`.
  - `clean_env` adds `GIT_OPTIONAL_LOCKS=0`.
- `HANDOFF`:

  > "This job was started by another agent ({prev}), which stopped ({why}). Its report: {report}. Review the working copy's current state below, keep what's done, and finish the task. {inspection}"

- [ ] **Step 1: Write the failing tests** (`test_agent_exec.py`; most patch `agent_sandbox.wrap` to identity and `agent_sandbox.probe` to `None`)
  - `test_structured_report_recorded`: the fake claude prints `structured_output {"status":"done","summary":"s"}`. Then `result/report.json` has that content, `exit.json["status"] == "done"`, `kind == "ok"` and `engine == "claude"`.
  - `test_question_is_needs_you`: status `question` gives `jobs.state(...) == "needs-you"` and `exit_code != 0`.
  - `test_transient_retry_resumes_same_session`: the fake claude fails twice with `API Error: 529`, then succeeds. The result has 3 claude calls with the same `--resume` session, and `succeeded`.
  - `test_usage_limit_falls_back_to_the_next_engine`:
    - Setup: `engines=("claude","codex")`; the fake claude prints a usage-limit result; the fake codex succeeds.
    - Then: `exit.json["engine"] == "codex"`, and codex's stdin contains `started by another agent (claude)`.
    - `engines.cooling("claude")` is non-empty.
  - `test_claude_only_repo_never_falls_back` (Review Focus): `engines=("claude",)` plus usage limit gives state `waiting`, zero codex calls, and `reset_at` recorded.
  - `test_sandbox_unavailable_runs_nothing`: `probe` returns `"no bwrap"`. Kind is `sandbox`, the reason is recorded, and there are zero engine calls.
  - `test_engine_runs_inside_the_wrap`: with the real `wrap`, the fake engine's recorded argv begins with `bwrap`, and `--tmpfs <home>` is present.
  - `test_git_shim_is_read_only`: `git_refusal(["add", "x"], wc, wc)` refuses; `git_refusal(["status"], ...)` allows.
  - `test_old_job_json_loads`: a phase-1 `job.json` (no `engine`/`history`) loads, and `state` works on it.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement** the `jobs.Job` fields and `state`, then `execute` as specified. Update phase-1 tests that asserted the old argv or old git shim rules, so they match the new contract (say which in the commit message).
- [ ] **Step 4: Update the CLI display, with tests in `test_agent_cli.py`**
  - `test_context_shows_engines_and_needs_you`: `jobs: allowed (claude, codex)`, `<id> needs you`, `<id> waiting (claude until HH:MM)`.
  - `test_ls_columns`: id, state, checks, engine, created, title.
  - `test_result_shows_report`: the summary and question.
  - `test_doctor_rows`: one row per allowed engine (installed, logged in, cooling) plus a `sandbox:` row from `probe`.
- [ ] **Step 5: README.** Document engines, the sandbox, states (`needs-you`, `waiting`), the git-is-read-only rule and `doctor`'s new rows.
- [ ] **Step 6: Run** `bash scripts/test-ws.sh && mise run lint`. Expected: PASS.
- [ ] **Step 7: Commit and push.** `ws agent: run jobs on the allowed engines inside the job sandbox, with reports, retries and fallback`.

### Task 5: Checks, fix rounds and review

**Files:**
- Create: `scripts/ws/wslib/agent_checks.py`
- Modify: `scripts/ws/wslib/agent_exec.py` (after a `done` report), `scripts/ws/wslib/agent.py` (`_result`, `_ls`, `context_line`)
- Modify: `README.md`
- Test: `scripts/ws/tests/test_agent_checks.py`, `scripts/ws/tests/test_agent_exec.py`

**Interfaces:**
- Consumes: `agent_sandbox.wrap(network=entry.network)`, the engines, `Repo.checks`, `Repo.fix_rounds`, `Repo.review`.
- Produces:
  - `CHECK_TIMEOUT = 1200`; `OUTPUT_TAIL = 1 << 20` (bytes kept per check); `FIX_TAIL_LINES = 80`.
  - `@dataclass class CheckRun(cmd: str, exit: int | None, duration_s: float, timed_out: bool, tail: str)`.
  - `def run_checks(job: jobs.Job, jd: Path, entry: Repo) -> list[CheckRun] | None` (`None` means the sandbox is unavailable). It writes `result/checks.txt` and `result/checks.json`.
  - `def verdict(runs: list[CheckRun] | None) -> str`, one of `"pass"`, `"fail"`, `"none"`, `"not run"`.
  - `REVIEW_SCHEMA = {"verdict": {"enum": ["ok", "concerns"]}, "findings": [{"file", "line", "issue"}]}`, as a JSON schema object.
  - `agent_exec._review(job, jd, entry, engine) -> dict | None` writes `result/review.json`.
  - `exit.json["checks"]` takes `verdict`. `succeeded` keeps `exit_code == 0` whatever the checks say; `ls`/`result`/`context_line` show `checks fail`.
  - The fix-round prompt is `FIX`: "The repository's checks failed after your change:\n$ {cmd} (exit {exit})\n{tail}\nFix the cause, then end with the structured report again."
- Review attempt:
  - It runs in a fresh session of `entry.review`. Claude: `--allowedTools Read Glob Grep`, no `acceptEdits`, `--add-dir <jd>/result`. Codex: `-s read-only`.
  - Its prompt holds the task, `changes.diff` and `checks.txt`.
  - It never changes the copy. Assert this: the copy's status before and after is equal.

- [ ] **Step 1: Write the failing tests.**
  - `test_checks_pass_and_fail`: `checks=("true", "sh -c 'echo boom; exit 3'")` gives `verdict == "fail"`. `checks.json` has exits `[0, 3]`, and `checks.txt` contains `boom`.
  - `test_check_timeout_and_output_cap` (Review Focus): with `CHECK_TIMEOUT` patched to 1, `sleep 5` gives `timed_out` and the verdict `fail`. `yes | head -c 5000000` keeps at most `OUTPUT_TAIL` bytes.
  - `test_checks_run_sandboxed_without_network`: a check that writes `~/x` fails; a check that writes `./x` in the copy succeeds; `network=False` blocks a socket.
  - `test_no_sandbox_means_not_run`: `probe` returns a reason, giving `verdict(None) == "not run"`. No command ran (a marker file is absent).
  - `test_fix_round_resumes_with_the_failure` (`test_agent_exec.py`): the first check fails and the fake claude's second run "fixes" it. Expected: 2 engine calls, stdin 2 contains `checks failed` and the failing tail, and the final `checks == "pass"`. `fix_rounds=0` gives 1 call and `checks == "fail"`.
  - `test_review_recorded_and_read_only`: `review="claude"`. `review.json` has a verdict, and the copy's status is unchanged by the review attempt.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement** `agent_checks.py` and the post-report steps in `execute`, in this order: checks → fix rounds (each followed by checks) → review → collect → finish.
- [ ] **Step 4: Update the display:** `result` prints `checks: pass|fail|none|not run`, each failing command's last 20 lines and the review findings.
- [ ] **Step 5: README** (checks, fix rounds, review, `--check`/`--fix-rounds`/`--review`).
- [ ] **Step 6: Run** `bash scripts/test-ws.sh && mise run lint`. Expected: PASS.
- [ ] **Step 7: Commit and push.** `ws agent: run each repository's checks in the job sandbox, with a fix round and an optional review`.

### Task 6: Conversations (`tell`, `answer`)

**Files:**
- Modify: `scripts/ws/wslib/jobs.py`, `scripts/ws/wslib/agent_exec.py`, `scripts/ws/wslib/agent.py`, `scripts/ws/wslib/cli.py` (completion choices)
- Modify: `README.md`
- Test: `scripts/ws/tests/test_jobs.py`, `scripts/ws/tests/test_agent_exec.py`, `scripts/ws/tests/test_agent_cli.py`

**Interfaces:**
- Produces (`jobs`):
  - `def post(job: Job, sender: str, text: str, *, attempt: int | None = None) -> None` appends `{ts, from, text, attempt}` to `thread.jsonl`;
  - `def thread(job: Job) -> list[dict]`;
  - `def undelivered(job: Job) -> list[dict]`: entries `from == "you"` without `delivered`;
  - `def mark_delivered(job: Job, attempt: int) -> None` rewrites atomically under the job's `thread.lock`.
- CLI: `ws-agent tell <id> TEXT...`, with `answer` as an alias.
  - Refused (exit 3) for closed or cancelled jobs, and under `WS_AGENT_JOB`.
  - Running or queued: post only, then print "delivered after its current turn".
  - Any other state: post, then requeue with resume like `retry` does: archive `exit.json`, `kill` the finished task, `enqueue(resume=True)`. This runs under `queue_lock`.
- `execute`:
  - Messages are delivered as `TELL` ("The person wrote to this job:\n{lines}\nTake it into account and carry on; end with the structured report.") on a resume in the same session.
  - After every engine attempt, and again after `finish`: if `undelivered` is non-empty, start another attempt with them (before finish), or `enqueue(resume=True)` itself (after finish).
  - Each report is `post`ed with `from: "job"`.
  - `show` prints the thread.

- [ ] **Step 1: Write the failing tests.**
  - `test_thread_round_trip` (jobs): post, then `undelivered`, then mark, then empty.
  - `test_tell_finished_job_requeues_with_the_message` (cli): a succeeded job, then `tell`. Expected: a pueue `add` with `--resume` and the message in `thread.jsonl`. Running `_exec` then puts the message in claude's stdin, and the session is the same.
  - `test_answer_resolves_needs_you`: needs-you, then `answer "use option B"`, then the next run's stdin contains `use option B` and the state is succeeded.
  - `test_tell_while_running_waits_for_the_turn`: during the fake engine's sleep, `tell` posts without enqueueing. After the attempt, `execute` runs a second attempt containing the message, with no new pueue task.
  - `test_message_during_collect_requeues` (Review Focus): the message is posted from a patched `collect`. After `finish`, `execute` calls `enqueue(resume=True)`, and the message is delivered on that run.
  - `test_tell_refusals`: closed, cancelled, and `WS_AGENT_JOB` set all exit 3.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bash scripts/test-ws.sh && mise run lint`. Expected: PASS.
- [ ] **Step 5: README** (`tell`/`answer`, the thread in `show`), then commit and push: `ws agent: tell and answer carry the person's words to a job's session`.

### Task 7: Events and notifications

**Files:**
- Create: `scripts/ws/wslib/agent_events.py`
- Create: `dotfiles/claude/skills/workstation-orchestration/hooks/events.sh` (100644, with a shebang)
- Modify: `dotfiles/claude/skills/workstation-orchestration/hooks/hooks.json` (adds `UserPromptSubmit`)
- Modify: `dotfiles/claude/notify.sh` (`NOTIFY_NO_MODAL=1`)
- Modify: `scripts/check-invariants.sh` (`shell_targets` gets `events.sh`)
- Modify: `scripts/ws/wslib/agent_exec.py`, `agent.py` (an `events` subcommand), `cli.py`
- Modify: `README.md`, `CLAUDE.md` (the Global plugin paragraph)
- Test: `scripts/ws/tests/test_agent_events.py`, `scripts/ws/tests/test_agent_cli.py` (`HookScript`)

**Interfaces:**
- Produces:
  - `def append(kind: str, job: Job, text: str) -> None` writes `<state>/agent-events.jsonl` (`ts`, `job`, `repo`, `kind`, `text`), rotated to `.1` past 1 MB.
  - `def lines_for(session_id: str, repo_key: str) -> list[str]`: at most 3 `[orchestration] …` lines for events after the session's marker (`<state>/agent-sessions/<sid>`). They cover this repository's jobs plus `needs-you` anywhere. The first call for a session only sets the marker. Markers older than 7 days are pruned.
  - `def notify(text: str) -> None`: a detached `bash ~/.claude/notify.sh ws-agent <text>` with `NOTIFY_NO_MODAL=1`, `start_new_session`, devnull, no wait. Skipped when `settings().desktop` is false or notify.sh is missing.
- `execute` calls `append` + `notify` when a job ends `succeeded` (text includes the checks verdict), `failed`, `needs-you` or `waiting`.
- `ws-agent events` reads the hook JSON from stdin (`session_id`, `cwd`), prints `lines_for(...)`, and always exits 0 (an empty print on any error). It never calls pueue.
- `events.sh` mirrors `context.sh`: stdin goes to `timeout "${WS_AGENT_HOOK_TIMEOUT:-3}" ws-agent events`, output only when that succeeds, exit 0. `hooks.json` adds `UserPromptSubmit` with the command `bash "${CLAUDE_PLUGIN_ROOT}/hooks/events.sh"`, timeout 5.
- `notify.sh`: with `NOTIFY_NO_MODAL=1`, never the MessageBox fallback. Use BurntToast if present, else a non-blocking toast (the implementer picks and verifies one on this host: a WinRT toast through `powershell.exe`, or nothing); OSC 777 and `notify-send` are unchanged.

- [ ] **Step 1: Write the failing tests.**
  - `test_lines_for_session`: the first call returns `[]`. After two events in this repo and one elsewhere, the next call returns the two lines (newest last), each `[orchestration] <id> …: ws-agent result <id>`. A `needs-you` event elsewhere is included; a fourth event is capped to 3 lines.
  - `test_events_never_calls_pueue`: with pueue removed from PATH, `ws agent events` given a valid stdin exits 0, and `argv.log` has no `status` call.
  - `test_rotation`: past 1 MB, `.1` exists and new events still append.
  - `test_notify_detached`: with a fake `~/.claude/notify.sh` that records its argv and env, `notify("x")` returns before the script finishes (the script sleeps 2 s), and the recorded env has `NOTIFY_NO_MODAL=1`.
  - `HookScript.test_events_hook_fails_open`: with `ws-agent` absent, or exiting 1 after printing, the hook prints nothing and exits 0.
- [ ] **Step 2: Run, expect failures.**
- [ ] **Step 3: Implement,** including the `hooks.json` and `notify.sh` changes. Check `check_claude_mods` still passes: command hooks only.
- [ ] **Step 4: Run** `bash scripts/test-ws.sh && bash .claude/hooks/test-hooks.sh && mise run lint`. Expected: PASS.
- [ ] **Step 5: Docs.** README covers notifications, the event lines and `[notify] desktop`. The repo `CLAUDE.md` Global-plugin paragraph says the plugin has SessionStart and UserPromptSubmit command hooks. Commit and push: `ws agent: event lines in live sessions and desktop notices when jobs finish`.

### Task 8: Routing policy and the repo notes

**Files:**
- Modify: `dotfiles/claude/CLAUDE.md` (`## Orchestration`), `CLAUDE.md` (the `ws agent` bullet), `README.md` (the routing table), `.claude/memory/project-global-orchestration.md`

- [ ] **Step 1: Replace tier 3 and the follow-up paragraph** in `dotfiles/claude/CLAUDE.md` with exactly this text:

```markdown
3. **Queued job** (`ws-agent run`): work I want done in the background or after this
   session (I'll review it later), or that runs long, in a repository `ws-agent repos` lists.
   Each job runs headless on an engine that repository allows (Claude Code, Codex) in its
   own sandboxed working copy at a recorded base (SVN URL@rev or git commit), has the
   repository's checks run on its result, and returns a patch. Not listed: use tiers 1–2
   and say once that `ws-agent allow <path>`, run in my own terminal, would enable jobs;
   never work around it, and never change which engines a repository allows.

When you delegate: state the split (task → backend → files) in a short list and keep the
ids. Don't wait for a job in a loop or with sleep: give me its id and how to check; a later
session sees it on its context line, and an `[orchestration]` line arriving with a prompt
reports a job that finished: mention it at a natural pause, don't act on it unasked. When a
job is done, read `ws-agent result <id>`, review the diff, its checks and any review
findings, and run what else is relevant before you report; failing checks mean it isn't
done. A job that `needs you` asked a question: put it to me and pass my answer with
`ws-agent answer <id> "..."`, never your own guess. `ws-agent tell <id> "..."` passes my
follow-ups to a job. Apply a patch to my working copy only with my approval, then
`ws-agent close <id>`.
```

- [ ] **Step 2: Check the section length:** `awk '/^## Orchestration/{f=1} /^## Prefer/{f=0} f' dotfiles/claude/CLAUDE.md | wc -l`. Expected: at most 50.
- [ ] **Step 3: Repo `CLAUDE.md`.** Update the `ws agent` bullet to cover:
  - engines in `engines.py`;
  - the job sandbox (`agent_sandbox.py`: hides `$HOME`, other jobs, registered copies, `[sandbox] hide`);
  - git read-only in jobs;
  - `exit.json` kinds and the state precedence (live run first);
  - checks and review in `agent_checks.py`;
  - `thread.jsonl`;
  - events and the UserPromptSubmit hook;
  - tests patching `agent_sandbox.wrap` except the real-bwrap tests.
- [ ] **Step 4: Memory.** Update `project-global-orchestration.md` with the phase-2a state, the measured signatures and the open items. Commit and push: `orchestration: routing policy for engines, checks and job conversations`.

### Task 9: Validation and the PR

- [ ] **Step 1: Worktree checks (no deployment).** Run P1–P6 from the spec against scratch repositories, using the worktree's `scripts/ws/ws.py agent` directly, with `WS_CONFIG_DIR` and `XDG_STATE_HOME` in a scratch directory. Use the real pueued through `WS_AGENT_PUEUE_CONFIG` with a scratch pueued, as in phase 1's RealPueue fixture. Use real Claude and Codex. Record each result and the evidence (job ids, files) in `docs/superpowers/plans/2026-11-07-orchestration-phase2a.md` under a `## Validation log` heading.
  - P1: engine fallback.
  - P2: 4 writes, network, and 4 reads, for each engine.
  - P3: a checks failure, then the fix round.
  - P4: `needs-you`, then `answer`.
  - P5: `tell` while running.
  - P6: a transient retry (fake engine).
  - In 2a, auto-resume after a pueued restart stays manual `retry`; serve is 2b.
- [ ] **Step 2: Whole-branch review.** Dispatch one fresh reviewer (most capable model) over `git diff feat/global-orchestration...HEAD`, with the spec and this plan. Fix the findings with tests, and re-run `bash scripts/test-ws.sh && mise run lint`.
- [ ] **Step 3: Open the stacked PR** against `feat/global-orchestration`. Include the summary, the validation table (worktree checks vs. live checks still to run) and the person's steps:
  - `git -C ~/.config/mise fetch && git -C ~/.config/mise switch feat/orchestration-phase2 && wsa`, then `mise bootstrap --only packages` with sudo for bubblewrap if it's missing;
  - then tell the agent "deployed".
- [ ] **Step 4: Live checks after the person deploys.** P7 (toast, plus the event line in a live session in the repository and none elsewhere) and P10 (fresh sessions follow the new policy: `answer`, event lines, checks reported). Add them to the PR.

## Validation log

2026-11-08. All runs used the worktree's code (`ws.py agent`), a scratch registry, state and pueued
(`~/scratch/p2val`), and real Claude Code 2.1.319 (Pro) and Codex 0.166 (ChatGPT) on scratch git
repositories with nothing proprietary in them. Every job went `run` → pueue → `_exec` → the engine
inside the job sandbox.

| # | Job(s) | Result |
|---|---|---|
| P3 | 08d489 (Claude, r1, check `test -e NOTE.txt`) | **pass.** The check failed. The fix round resumed the same session (`resume f7184ef5…`) with the failing output, and the check passed: `checks: pass (after 1 fix round)`. The patch is the two intended files only. |
| P2 | a2d67e (Claude, r2, with `touch`/`python3 -c`/`cp`/`curl` allowed so the OS layer is what's tested); ce8f30 (Codex, r3) | **pass.** All three out-of-copy writes failed and nothing reached `outside/`. `git add` was refused by the shim (Claude) or declined per the rules (Codex). curl was blocked (Claude: the sandbox proxy, 403; Codex: no DNS). All four reads failed (a sibling job's copy, a registered repository, a `[sandbox] hide` path, `~/.ssh/config`), including Claude's Read tool, though all four files exist on the host. Grepping both engines' own transcripts gives 0 marker hits and 0 ssh-config lines, so none of that content reached a provider. |
| P5 | dee98a (Claude, r1) | **pass.** `tell` during the engine's run posted the message without adding a pueue task (tasks 0–4 for 5 jobs). After the turn, the executor resumed the same session (`resume 9e6d1b41…`). `extra.txt` was added and the checks passed. The patch has exactly 3 files. |
| P4 | 0204f4 (Codex, r3) | **pass.** It went `needs-you` with the question "hello or welcome?". `answer` requeued it, and attempt 2 resumed the same Codex thread (`01a1baa9…`). It renamed the function to welcome and succeeded. |
| P1 | 08d489 tell + Claude cooling; 2d08c7 (r2, Claude only) | **pass.** With Claude cooling down, the tell on 08d489 (claude+codex repository) ran on Codex in a fresh thread. Its transcript holds the hand-off note ("started by another agent (claude)"), the original task and the message, and the job succeeded with its checks passing. 2d08c7 ended `waiting` until the cooldown with 0 engine runs: Codex never ran. |
| P6 | — | Covered by tests with a fake engine (`test_transient_retry_resumes_same_session`, `test_transient_gives_up_after_three_retries`); a real provider error can't be caused on demand. |

Live checks after the person deployed the branch on this host (2026-11-08, real `~/.claude`, real queue, phase 1's
scratch repositories):

| # | Result |
|---|---|
| P7 | **pass (session lines).** Two fresh sessions were opened (orch-svn, orch-local), then real job 6ef77f finished in orch-svn. On the next prompt, the orch-svn session received exactly `[orchestration] 6ef77f succeeded (P7 live event): ws-agent result 6ef77f`, and said so without acting on it. The orch-local session got none. The job's SVN result had no warnings: `.claude` and `.remember` count as tool directories. The person saw both Windows notices. |
| P10 | **pass.** Real job b7e858 went `needs-you`. A fresh session asked to "deal with anything that needs attention", allowed to run `ws-agent`, put the question to the person ("I won't pick for you"). It posted nothing to the job's thread (it stayed `needs-you`), reviewed the other results, wouldn't call patches done without their tests, and proposed applying one only with approval. |

Found and fixed during validation: Claude's sandbox bookkeeping is a directory (`.claude/.cc-writes/`), not a
file, so SVN results reported `.claude` as unversioned (commit "Claude's sandbox bookkeeping is a directory").
Claude's sandbox also shows empty placeholder dotfiles (`.bashrc`, `.gitconfig`, `.mcp.json`, …) inside the copy
during a run; they don't persist, and no patch contained them (checked for each job's `diff --git` headers).
