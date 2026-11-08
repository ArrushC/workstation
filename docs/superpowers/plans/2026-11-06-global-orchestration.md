# Global Orchestration (phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Claude Code session on a workstation Linux host routes development work by itself (direct, subagents, queued headless job, later Super-agent) in git and SVN repositories, with queued jobs that are inspectable, cancellable, resumable and never write upstream.

**Architecture:** A routing policy in the global `CLAUDE.md`; a global SessionStart plugin hook that prints one `[orchestration]` line for the current repository; `ws agent` (stdlib Python in `scripts/ws/wslib`, reached through a `ws-agent` launcher) that records a job's base, queues it on a pueue group, runs headless `claude -p` in a private working copy behind write-refusing `svn`/`git` shims, and collects a patch.

**Tech Stack:** Python 3.11+ stdlib (`ws`), bash, pueue 4.0.4, Claude Code 2.1.319 (`-p`, `--session-id`, `--resume`, `--permission-prompts none`), Subversion 1.14 (dnf), git.

**Spec:** `docs/superpowers/specs/2026-11-06-global-orchestration-design.md`

## Prerequisites (operator, before Task 1)

- `sudo dnf install -y subversion` on this host (Task 7 adds it to the dnf batch for every host). Without it, the SVN tests skip and nothing about SVN counts as verified.
- Confirm organisational authorisation (asked with this plan). It gates only the real-company-repository demonstration in Task 8; every other step uses scratch repositories.

## Global Constraints

- `wslib` code: Python 3.11+ stdlib only; `scripts/ws/ws.py` unchanged (stays 3.6-parseable).
- Shell: bash, `shfmt -i 2`-clean, LF, gitleaks-clean. `dotfiles/local/bin/ws-agent` is git mode 100755 and is added to `check_dotfiles_mode`'s list; every other new file under `dotfiles/` is 100644.
- `actions.toml`: ASCII only.
- Agents never run `mise dot apply`, `wsa` or `sudo` on the real host; the operator does (Task 8).
- pueue group `agents`, default `parallel = 1`; job timeout default `2h`.
- `ws-agent allow` / `disallow` exit 3 when `CLAUDECODE=1`.
- `ws-agent run` exits 3 when `WS_AGENT_JOB` is set (a job never queues jobs).
- Jobs never write to an SVN server and never `git push`.
- `ws-agent context`: one line, ≤ 400 chars, exit 0 always, empty output on any internal error; the hook's timeout is 5 s.
- Every commit passes `mise run lint`, `bash scripts/check-templates.sh` and `bash scripts/test-ws.sh`.
- User-facing behaviour updates `README.md` in the same commit (Task 7 owns it; Tasks 1–6 ship no user-reachable surface until Task 5's launcher, so Task 5 adds the README stub and Task 7 completes it).

## Review Focus

1. **Interrupted job (WSL shutdown, pueued restart):** state reads `interrupted`, `retry` resumes the same Claude session in the same working copy, and no second job appears. Tests in Tasks 3 and 4.
2. **Unusual source working copy:** for a mixed-revision or switched SVN copy without `--rev`, `run` refuses and names `--rev`. Local modifications produce a warning, and the job starts from the clean recorded base. Tests in Task 1 (probe) and Task 5 (refusal text).
3. **Property changes and unversioned files:** the result keeps `svn:executable` and `svn:eol-style` changes (patch plus `props.txt`), and a new file the job never `svn add`ed is listed in `warnings.txt`, not lost. Tests in Task 4.
4. **A job launched from inside a Claude session:** the child Claude gets no `CLAUDECODE`/`CLAUDE_CODE_*`. Its own context line says it is a queued job, and `ws-agent run` inside it is refused. Tests in Tasks 4 and 5.
5. **Upstream writes through shims:** `svn commit`, `svn -q ci`, `svn copy ^/trunk ^/branches/x`, `svn delete https://…/f`, `svn propset --revprop -r 5 svn:log x`, `svn update` and `git push` are refused. `svn delete f.c`, `svn propset svn:eol-style native f.c` and `svn diff` pass through. Tests in Task 4.

---

### Task 1: VCS probe

**Files:**
- Create: `scripts/ws/wslib/vcs.py`
- Test: `scripts/ws/tests/test_vcs.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) class Probe` with these fields:
    - `kind: str`: `"svn"`, `"git"` or `"none"`
    - `root: Path | None`
    - `url: str = ""`: SVN root URL, or the git `remote.origin.url`
    - `repos_root: str = ""`
    - `rev: str = ""`: SVN BASE revision of the root, or the git HEAD sha
    - `version: str = ""`: `svnversion` output
    - `mixed: bool = False`, `switched: bool = False`, `modified: bool = False`
    - `branch: str = ""`
    - `github: str = ""`: `owner/name` for a github.com origin
  - `probe(path: Path, *, thorough: bool = False) -> Probe`
  - `short_url(p: Probe) -> str`: SVN `^/trunk` form; otherwise `url`
- Rule: find `.svn` or `.git` by walking up before starting any subprocess. `thorough=False` (the hook) never runs `svnversion` or `git status`. `thorough=True` (`run`) does and fills `version`, `mixed`, `switched` and `modified`. The nearer of `.svn` and `.git` wins.

- [ ] **Step 1: Write the failing tests** (SVN cases use `svnadmin create` + `file://`; `skipUnless(shutil.which("svnadmin"))`)
  - `test_none`: a plain directory gives `kind == "none"` and `root is None`.
  - `test_git_github`: `git init`, a commit, origin `git@github.com:ArrushC/demo.git` → `kind == "git"`, `github == "ArrushC/demo"`, `len(rev) == 40`.
  - `test_git_dirty_only_thorough`: an edited tracked file gives `modified is False` (fast) and `modified is True` with `thorough=True`.
  - `test_svn_basic`: checkout of `file://…/trunk` at r1, probed from a subdirectory → `kind == "svn"`, `root ==` the checkout, `rev == "1"`, `short_url(p) == "^/trunk"`.
  - `test_svn_mixed`: commit r2, then `svn update -r1` on one file → `thorough=True` gives `mixed is True` and `":" in version`.
  - `test_svn_switched`: `svn switch` of a subdirectory → `switched is True`.
- [ ] **Step 2: Run them; expect failures** — `cd scripts/ws/tests && python3 -m unittest test_vcs -v` → `ModuleNotFoundError: wslib.vcs`.
- [ ] **Step 3: Implement `vcs.py`** to the Interfaces block (`svn info --show-item wc-root|url|repos-root-url|revision`, `svnversion <root>`; `git rev-parse`, `git config remote.origin.url`).
- [ ] **Step 4: Run them; expect PASS**, then `bash scripts/test-ws.sh` → `PASS: ws: N tests`.
- [ ] **Step 5: Commit** — `git add scripts/ws/wslib/vcs.py scripts/ws/tests/test_vcs.py && git commit -m "ws: probe a directory's git or SVN working copy"`

### Task 2: Repository registry

**Files:**
- Create: `scripts/ws/wslib/agent_registry.py`
- Test: `scripts/ws/tests/test_agent_registry.py`

**Interfaces:**
- Consumes: `core.config_dir()`, `core.tilde()`, `core.expand()`, `core.atomic_write()`.
- Produces:
  - `class Refused(Exception)`
  - `@dataclass(frozen=True) class Repo` with `path: Path`, `vcs: str`, `commands: tuple[str, ...]` and `allowed_at: str`
  - `registry_path() -> Path`: `core.config_dir() / "agents.toml"`
  - `load() -> tuple[dict[str, Repo], int]`: repos keyed by tilde path, plus `[queue].parallel` (default 1)
  - `find(root: Path) -> Repo | None`
  - `allow(root: Path, vcs: str, commands: list[str]) -> Repo`
  - `disallow(root: Path) -> bool`
  - Both writers raise `Refused("ws-agent: a Claude Code session can't change which repositories jobs may use; run this in your own terminal")` when `os.environ.get("CLAUDECODE") == "1"`.
- The file is written by a small emitter: strings via `json.dumps`, string arrays, the `[queue]` table kept. The format is the spec's TOML example, with the header comment `# ws-agent: repositories queued jobs may work in (per host). Edit with ws-agent allow/disallow.`

- [ ] **Step 1: Write the failing tests** (on `helpers.Scratch`; each test pops `CLAUDECODE` unless it sets it)
  - `test_allow_roundtrip`: `allow(p, "svn", ["make *"])`, then `find(p).commands == ("make *",)`. `load()[1] == 1`. The file parses with `tomllib`.
  - `test_keeps_queue_table`: with `[queue]\nparallel = 2\n` pre-written, `allow` leaves `load()[1] == 2`.
  - `test_disallow`: it returns `True` and `find(p) is None`; a second call returns `False`.
  - `test_refused_inside_claude`: with `CLAUDECODE=1`, both `allow` and `disallow` raise `Refused`, and the file is unchanged.
  - `test_quotes_survive`: a command `make "a b"` round-trips exactly.
- [ ] **Step 2: Run them; expect failures** — `python3 -m unittest test_agent_registry -v`.
- [ ] **Step 3: Implement `agent_registry.py`** to the Interfaces block.
- [ ] **Step 4: Run them; expect PASS**, then `bash scripts/test-ws.sh`.
- [ ] **Step 5: Commit** — `git commit -m "ws: per-host registry of repositories queued agent jobs may use"`

### Task 3: Job records, pueue adapter, derived state

**Files:**
- Create: `scripts/ws/wslib/jobs.py`
- Test: `scripts/ws/tests/test_jobs.py`

**Interfaces:**
- Consumes: `core.state_dir()`, `core.atomic_write()`, `core.now_iso()`.
- Produces:
  - `@dataclass class Job`:
    - `id: str`, `title: str`, `repo: str` (tilde), `vcs: str`
    - `base: dict[str, str]`: SVN `url`, `repos_root`, `rev`; git `commit`, `branch`
    - `prompt_sha: str`, `paths: list[str]`, `created: str`, `session_id: str`, `timeout: str`
    - `pueue_id: int | None = None`, `attempts: int = 0`
    - `cancelled: bool = False`, `closed: bool = False`
    - `warnings: list[str] = field(default_factory=list)`
  - Paths and records:
    - `jobs_dir() -> Path`: `core.state_dir() / "agent-jobs"`
    - `job_dir(job_id: str) -> Path`
    - `new_id() -> str`: 6 lowercase hex characters, unique under `jobs_dir()`
    - `save(job: Job) -> None`: `job.json`, written atomically
    - `load(job_id: str) -> Job` (unique-prefix match; `KeyError` otherwise)
    - `all_jobs() -> list[Job]`
  - pueue adapter:
    - `pueue_tasks() -> dict[int, str] | None`: `None` when `pueue status --json` fails. Statuses map to `Queued`, `Running`, `Paused`, `Stashed`, `Locked`, `Success`, `Failed` or `Killed`. pueue 4 `Done.result` maps to `Success`, `Failed` (`{"Failed": n}`, `FailedToSpawn`, `DependencyFailed`) or `Killed`; `Errored` counts as `Failed`.
    - `ensure_group(parallel: int) -> None`: `pueue group add agents -p N` if absent, else `pueue parallel N -g agents`
    - `enqueue(job: Job, *, resume: bool) -> int`: `pueue add --print-task-id --group agents --label ws-agent:<id> --working-directory <job_dir> -- <sys.executable> <ws.py> agent _exec <id> [--resume]`
    - `kill(job: Job) -> None`: `pueue kill` then `pueue remove` (each tolerant of an already-finished task)
  - Derived state and job lookups:
    - `state(job: Job, tasks: dict[int, str] | None) -> str`: one of `closed`, `cancelled`, `succeeded`, `failed`, `running`, `queued`, `interrupted` or `unknown`, in the spec's order. Uses `result/exit.json` `{"exit_code": int}`. Gives `unknown` only when tasks is `None` and there is no `exit.json`.
    - `duplicate(repo: str, prompt_sha: str, jobs: list[Job], tasks) -> Job | None`
    - `overlaps(repo: str, paths: list[str], jobs: list[Job], tasks) -> list[Job]`: an active job in the same repo with a shared path or a glob match (`fnmatch` both ways)

- [ ] **Step 1: Write the failing tests**. A `fake("pueue", …)` bash script answers `status --json` from a JSON file the test writes, and logs every argv to a file.
  - `test_state_order`: a parametrised table checks:
    - `closed` beats everything
    - `cancelled` beats `exit.json`
    - `exit_code` 0 gives `succeeded`; 1 gives `failed`
    - `Running` gives `running`; `Queued` gives `queued`
    - `Killed` without `exit.json` gives `interrupted`
    - a task missing from pueue gives `interrupted`
    - pueued down gives `unknown`
  - `test_pueue_v4_done_mapping`: `{"Done": {"result": {"Failed": 2}}}` gives `Failed`. `{"Done": {"result": "Killed"}}` gives `Killed`.
  - `test_enqueue_argv`: the logged argv contains `--group agents`, `--label ws-agent:<id>` and `agent _exec <id>`. With `resume=True`, it ends in `--resume`. The returned int comes from the fake's stdout.
  - `test_duplicate`: the same repo and sha with a `running` job returns it. A `closed` or `failed` job returns `None`.
  - `test_overlaps`: `["src/*.c"]` against an active job's `["src/a.c"]` gives that job. A different repo gives `[]`.
  - `test_load_prefix`: a unique prefix loads the job. An ambiguous prefix raises `KeyError`.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement `jobs.py`.**
- [ ] **Step 4: Run them; expect PASS**, then `bash scripts/test-ws.sh`.
- [ ] **Step 5: Commit** — `git commit -m "ws: agent job records, pueue adapter and derived job state"`

### Task 4: Job execution (`_exec`), shims, result collection

**Files:**
- Create: `scripts/ws/wslib/agent_exec.py`
- Test: `scripts/ws/tests/test_agent_exec.py`

**Interfaces:**
- Consumes: `jobs.load/save/job_dir`, `vcs.Probe`, `agent_registry.find`.
- Produces:
  - Shim rules and wrapper:
    - `svn_refusal(args: list[str]) -> str | None` and `git_refusal(args: list[str]) -> str | None`: `None` means allowed. Otherwise the message is `ws-agent: svn <sub> writes to the repository; a person runs it`, or the git equivalent. The subcommand is the first non-option token, skipping the values of `--username`, `--password`, `--config-dir` and `--config-option`. URL tokens match `^[A-Za-z][A-Za-z0-9+.-]*://` or start with `^/`. The allowed set is the spec's list.
    - `shim(tool: str, real: str, args: list[str]) -> int`: prints the refusal to stderr and returns 3, otherwise `os.execv`.
    - `write_shims(bindir: Path) -> None`: for each of `svn` and `git` found on PATH, writes `bindir/<tool>`. Each shim is a `#!<sys.executable> -I` script that puts the ws dir on `sys.path` and calls `shim()` with the real binary's absolute path (mode 0755).
  - Environment and command line:
    - `clean_env(base: Mapping[str, str], bindir: Path, job_id: str) -> dict[str, str]`: drops `CLAUDECODE` and every `CLAUDE_CODE_*`. Prepends `bindir` to `PATH`. Sets `WS_AGENT_JOB=<id>` and `SVN_EDITOR=false`.
    - `claude_argv(job: Job, jobdir: Path, *, resume: bool, rules: list[str]) -> list[str]`: the spec's command. `--resume <session_id>` is used when `resume` and the session's transcript exists (`claude` keeps it under `~/.claude/projects/<cwd-slug>/<id>.jsonl`). Otherwise it uses `--session-id`, with a new uuid on a fresh start that is stored on the job.
    - `permission_rules(job: Job, repo_commands: tuple[str, ...]) -> list[str]`: `Read`, `Edit`, `Write`, `Glob`, `Grep`, `Bash(svn *)`, `Bash(git *)`, `Bash(rg *)`, `Bash(fd *)`, `Bash(ls *)`, `Bash(cat *)`, `Bash(head *)`, `Bash(tail *)`, `Bash(wc *)`, `Bash(diff *)`, `Bash(python3 -m unittest*)`, plus `Bash(<c>)` for each repo command.
  - Running and collecting:
    - `prepare(job: Job, jobdir: Path) -> None`: if `wc/` exists, nothing. SVN runs `svn checkout --non-interactive <url>@<rev> wc`. git runs `git -C <repo> worktree add -b ws-agent/<id> <wc> <commit>`.
    - `collect(job: Job, jobdir: Path) -> list[str]`:
      - SVN writes `status.txt`, `changes.diff` (`svn diff`) and `props.txt` (`svn proplist -v` for every path whose status has a property column `M` or an `A`).
      - git runs `add -A` and writes `diff --cached --binary <commit>` to `changes.diff`, plus `status.txt`.
      - It returns warnings, which are also written to `warnings.txt`: each unversioned `?` path, and `no changes` when the diff is empty.
    - `execute(job_id: str, *, resume: bool) -> int`:
      - It prepares the working copy, writes the shims and `rules.md`, and runs `timeout --kill-after=60s <timeout> claude …` with the prompt on stdin, stdout to `result/claude.json` and stderr to `exec.log`.
      - It then collects, writes `result/exit.json` `{"exit_code", "finished", "is_error", "session_id", "num_turns", "duration_ms"}` and increments `attempts`.
      - It returns 0 only for claude exit 0 with `is_error` false.
      - A preparation failure writes `exit.json` with `exit_code` 1 and the error in `exec.log`.
- `rules.md` (exact text):

```
You are a queued ws-agent job running unattended. Work only inside this working copy.
Do not delegate further: no ws-agent commands, and at most one writer at a time.
Never commit, push, copy, merge, switch, update, lock or change revision properties;
leave every change uncommitted (svn add new files; for git, stage nothing yourself).
When you finish, end with: what changed, the checks you ran and their results, open risks.
If you can't finish, start your final message with BLOCKED: and the reason.
```

- [ ] **Step 1: Write the failing tests**. A `fake("claude", …)` writes its argv and env to files, edits `wc/` (adds a line, creates `new.txt`, and under SVN runs `svn propset svn:executable '*' run.sh`), then prints `{"type":"result","is_error":false,"session_id":"S","num_turns":3,"duration_ms":10,"result":"done"}`.
  - `test_svn_refusals`: a table of the five Review Focus 5 refusals plus `svn update`, and the three pass-throughs.
  - `test_git_refusals`: `git push`, `git -c x=y push` and `git svn dcommit` are refused. `git status` and `git commit -m x` are allowed.
  - `test_clean_env`: with `CLAUDECODE=1`, `CLAUDE_CODE_SESSION_ID=x` and `CLAUDE_CODE_MESSAGING_TOKEN=y` in the base, the result has none of them. `PATH` starts with `bindir` and `WS_AGENT_JOB == id`.
  - `test_execute_git`: the job runs end to end. `exit.json` has `exit_code == 0`. `changes.diff` contains the added line and `new.txt`. The fake's recorded env has no `CLAUDECODE`. The argv contains `--permission-prompts none`, `--permission-mode acceptEdits` and `--session-id`.
  - `test_execute_svn_props_and_unversioned` (svn only). In the SVN variant, the fake creates `extra.txt` without `svn add`. Afterwards:
    - `props.txt` names `svn:executable` for `run.sh`
    - `svn patch result/changes.diff` into a fresh checkout at the same base reproduces the content and the `svn:executable` property
    - `warnings.txt` lists `extra.txt`
    - `svn log -l1 <repo-url>` still shows the base revision
  - `test_resume_uses_same_session`: a second `execute(resume=True)` after a fake transcript exists passes `--resume S`, not `--session-id`, and `attempts == 2`. The working copy isn't re-prepared (checkout or worktree is not called twice).
  - `test_prepare_failure_recorded`: an SVN URL that doesn't exist gives `exit.json` `exit_code == 1` and `exec.log` contains the svn error.
  - `test_shim_blocks_through_path`: running `bindir/svn commit -m x` as a subprocess exits 3 with the message.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement `agent_exec.py`.**
- [ ] **Step 4: Run them; expect PASS**, then `bash scripts/test-ws.sh`.
- [ ] **Step 5: Commit** — `git commit -m "ws: run queued agent jobs headless in a private working copy behind write-refusing svn/git shims"`

### Task 5: `ws agent` CLI and `ws-agent` launcher

**Files:**
- Create: `scripts/ws/wslib/agent.py`, `dotfiles/local/bin/ws-agent` (100755)
- Modify:
  - `scripts/ws/wslib/cli.py`: add `"agent"` to `COMPLETED`, plus a dispatch branch
  - `scripts/ws/actions.toml`: `agent-ls` (`kind = "read"`, `ws = ["agent", "ls"]`, `os = ["linux"]`, `requires = ["pueue"]`) and `agent-doctor` (read)
  - `scripts/check-invariants.sh`: add `dotfiles/local/bin/ws-agent` to the 100755 list and the shfmt file list
  - `README.md`: a stub under a new "Agent orchestration" heading; Task 7 completes it
- Test: `scripts/ws/tests/test_agent_cli.py`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `main(argv: list[str]) -> int`: argparse subcommands exactly as the spec's table, with exit codes 0, 1, 2 and 3.
  - `context_line(cwd: Path) -> str`: the spec's format. Under `WS_AGENT_JOB` it is `[orchestration] queued job <id>: work directly in this working copy; no further delegation`. It catches every exception and returns `""`.
  - `run` order:
    1. refuse under `WS_AGENT_JOB` (3)
    2. probe with `thorough=True`
    3. refuse `none` (3)
    4. refuse an unregistered root (3), with `ws-agent: <root> isn't allowed for queued jobs; run 'ws-agent allow <root>' in your own terminal`
    5. refuse a mixed or switched copy without `--rev` (3), naming `--rev`
    6. dedupe (3, printing the existing id)
    7. warn on overlaps and local modifications
    8. `ensure_group`
    9. save the job
    10. `enqueue`
    11. print the id
  - `result <id>` prints title, state, base, attempts, Claude's final `result` text, a diffstat of `changes.diff`, the `changes.diff` path and the warnings.
  - `close <id>` refuses unless the state is `succeeded`, `failed` or `cancelled`. It removes `wc/` (git: `worktree remove --force`, then `branch -D ws-agent/<id>`) and keeps `result/`.
- `ws-agent` (bash): resolves Python like `python-cli` (`mise -C "$HOME" which python3`, else `python3`), then `exec "$py" "$HOME/.config/mise/scripts/ws/ws.py" agent "$@"`.

- [ ] **Step 1: Write the failing tests** (fake `pueue` and `claude`; real git; svn where present)
  - `test_run_refuses_unregistered`: exit 3, and the stderr names `ws-agent allow`.
  - `test_run_refuses_inside_job`: `WS_AGENT_JOB=x` gives exit 3.
  - `test_run_records_base_and_queues`: a registered git repo gives exit 0 and a printed id. `job.json` `base.commit == HEAD`. pueue's argv log shows `add` in group `agents`.
  - `test_run_duplicate`: the same prompt twice gives a second exit 3 that prints the first id. `--force` gives exit 0.
  - `test_run_svn_mixed_needs_rev` (svn only): exit 3, and the stderr contains `--rev`.
  - `test_ls_json`: one entry per job, with `state` from the fake pueue.
  - `test_cancel_then_state`: the fake pueue logs `kill`, and the state is `cancelled`.
  - `test_retry_only_failed_or_interrupted`: retrying a `running` job gives exit 3. An `interrupted` job is enqueued with `--resume`.
  - `test_close_removes_wc_keeps_result`.
  - `test_context_line_formats`: three fixtures (SVN allowed, git not allowed, no repository) match the spec examples' shape (regex). Each line is ≤ 400 chars.
  - `test_context_never_raises`: with pueue missing from PATH, the output is a line containing `queue: pueued not running` and the exit is 0.
  - `test_launcher_runs`: `bash dotfiles/local/bin/ws-agent repos` under Scratch gives exit 0.
  - `test_route_json`: in a registered git repo, `route --json` has the keys `vcs`, `root`, `base`, `allowed`, `queue`, `jobs` and `superagent`, with `superagent == "none"`.
  - `test_doctor_no_secrets`: a fake `claude auth status` prints JSON with `authMethod`, `subscriptionType`, `email` and `orgId`. The `doctor` output names the method and plan and contains neither the email nor the org id. A missing `svn` is reported as a finding (exit 1), not a crash.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement `agent.py`, the dispatch, the launcher, the catalogue entries and the lint lists.**
- [ ] **Step 4: Run them; expect PASS**, then `mise run lint` (expect `check_ws` and `check_dotfiles_mode` green) and `bash scripts/test-ws.sh`.
- [ ] **Step 5: Commit** — `git commit -m "ws agent: queue, inspect, cancel, retry and close headless agent jobs"`

### Task 6: Global SessionStart context plugin

**Files:**
- Create:
  - `dotfiles/claude/skills/workstation-orchestration/.claude-plugin/plugin.json` (name `workstation-orchestration`, version `0.1.0`, no `skills` key)
  - `dotfiles/claude/skills/workstation-orchestration/hooks/hooks.json`: `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/context.sh\"","timeout":5}]}]}}`
  - `dotfiles/claude/skills/workstation-orchestration/hooks/context.sh` (100644, run via `bash`): `command -v ws-agent || exit 0`, then `timeout 3 ws-agent context`, printing only a non-empty first line, always exit 0
- Modify:
  - `dotfiles/claude/settings.enforced.json`: `"workstation-orchestration@skills-dir": true` in `enabledPlugins`
  - `scripts/check-invariants.sh` `check_claude_mods`: exempt `workstation-orchestration` from both checks only while its `hooks.json` has no `modules` key and only `type: "command"` hooks; any other plugin still fails as today
- Test: `scripts/ws/tests/test_agent_cli.py`, extended

- [ ] **Step 1: Write the failing tests.**
  - `test_context_hook_prints_line`: a fake `ws-agent` printing `[orchestration] x` gives `bash context.sh` stdout of `[orchestration] x` and exit 0.
  - `test_context_hook_fail_open`: a fake that exits 1, a fake that sleeps 10 s (with `timeout` scaled via `WS_AGENT_HOOK_TIMEOUT=1`, an env override the script honours), and no `ws-agent` all give empty stdout and exit 0.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Create the plugin files, the enforced key and the lint exemption.**
- [ ] **Step 4: Verify**
  - `cp -r dotfiles/claude/skills/workstation-orchestration "$tmp" && claude plugin validate "$tmp" --strict` → valid.
  - Discovery without `SKILL.md`. With a scratch `CLAUDE_CONFIG_DIR` (credentials untouched), copy the plugin to `<scratch>/skills/`, put the enabled key in `<scratch>/settings.json` and run `claude -p 'Reply with the [orchestration] line from your context, or NONE.'`. Expect the line. If it is NONE, add an internal-marker `SKILL.md` (like `workstation-lsp`, `disable-model-invocation: true`) and the `"skills": ["./"]` key, then repeat. If the scratch config can't authenticate, defer this check to Task 8 V2 and say so.
  - `mise run lint` → green. Also make sure a fixture plugin under `dotfiles/claude/skills/x/hooks/hooks.json` with `modules` still fails: create it temporarily, run lint, remove it.
- [ ] **Step 5: Commit** — `git commit -m "claude: global SessionStart hook that reports the repository's orchestration context"`

### Task 7: Routing policy, SVN client, docs

**Files:**
- Modify:
  - `dotfiles/claude/CLAUDE.md`: a new `## Orchestration` section after "Prefer the modern tool", above the TOOLS block
  - `config.linux.toml`: `"dnf:subversion" = "latest"` in `[bootstrap.packages]`, with a comment naming the EL8 and EL9 verification
  - `README.md`: complete "Agent orchestration"
  - `CLAUDE.md` (repo): ws section, Hooks section, and one invariant: "`settings.enforced.json` never adds a hook event: merging replaces hook arrays wholesale; a global command hook ships as the `workstation-orchestration` plugin"
  - `.claude/memory/`: one memory, `svn-and-git-orchestration`, plus its `MEMORY.md` line
- Policy section (exact text):

```markdown
## Orchestration

Standing instruction for every project: choose how to execute each development request
yourself; never ask me to pick a mode. This is my explicit request to use subagents and
queued jobs when they fit. A SessionStart line `[orchestration] …` gives this repository's
VCS, job queue and jobs; `ws-agent route` refreshes it. Without `ws-agent` (Windows, or a
host without it) use tiers 1–2 only.

1. **Direct** (default): questions, explanations, small or single-file changes, quick
   investigations. Don't delegate what you can finish faster yourself.
2. **Subagents** (or an agent team, when the session offers one): separable work inside
   this session, such as parallel searches or investigations, or implement-then-review.
   One writer per set of files. Git: parallel writers use `isolation: "worktree"`. SVN:
   never two writers in one working copy; fan out read-only, or give each writer a job.
3. **Queued job** (`ws-agent run`): long-running or multi-stage work that should outlive
   this session, in a repository `ws-agent repos` lists. Each job gets its own working copy
   at a recorded base (SVN URL@rev or git commit), runs headless Claude Code under pueue,
   and returns a patch. Not listed: ask me to run `ws-agent allow <path>` in my own
   terminal; never work around it.
4. **DeepSeek Super-agent**: only where `ws-agent route` shows a healthy instance for this
   GitHub repository, for issue- or PR-shaped work that benefits from its tickets; each
   submission needs my OK. Never send SVN or unregistered code to it.

When you delegate: state the split (task → backend → files) in a short list and keep the
ids. When `ws-agent ls` shows a job done, read `ws-agent result <id>`, review the diff and
run the relevant checks before you report. Apply a patch to my working copy only with my
approval, then `ws-agent close <id>`.

SVN: never run `svn commit`, `copy`, `merge`, `lock`, `propset --revprop`, or
`move`/`mkdir`/`delete` on a URL (anything that writes to the server) without my explicit
approval in this conversation, and don't `update` or `switch` my working copy unasked.
Deliver `svn diff` patches, keep `svn:*` property changes, and list unversioned files.

Failures: say what failed and why, quoting the log line. `ws-agent retry <id>` resumes an
interrupted job; never start a duplicate. Redo the work directly only after
`ws-agent cancel <id>`, and say so. Never call delegated work done until you have reviewed
and verified it.
```

- [ ] **Step 1: Verify the package name on both ELs** — `podman run --rm docker.io/library/almalinux:8 dnf -q list --available subversion` and the same with `almalinux:9` → both list `subversion`. If EL8 doesn't, put it in `tasks/optional-packages` instead and say so.
- [ ] **Step 2: Edit the files above.** `sync-tool-memory.sh` regenerates the TOOLS block; leave it alone.
- [ ] **Step 3: Verify** — `mise run lint`, `bash scripts/check-templates.sh` and `bash scripts/test-ws.sh` all green. `rg -c '^## Orchestration' dotfiles/claude/CLAUDE.md` gives `1`. `wc -l` of the section is ≤ 45 lines.
- [ ] **Step 4: Commit** — `git commit -m "claude: global routing policy for direct, subagent, queued and Super-agent execution; svn client"`

### Task 8: Ship, deploy, end-to-end verification

The operator merges, applies and installs; the agent runs the scenarios and reports each one as **passed**, **failed** (with output) or **not run** (with the reason). Fixtures: a scratch `file://` SVN repository (`~/scratch/orch-svn`, a small Python module plus tests, `svn:eol-style` and `svn:executable` set on some files) and an unrelated scratch git project (`~/scratch/orch-local`, no remote). Neither holds company code.

- [ ] **Step 1: PR** — push branch `orchestration`, open the PR (description lists every scenario below), and wait for the operator to merge it.
- [ ] **Step 2: Operator deploys** — `wsu` (or `git pull` and `wsa`), `sudo dnf install -y subversion` if not already done, then a new terminal. In their own terminal: `ws-agent allow ~/scratch/orch-svn --command 'python3 -m unittest*'`.
- [ ] **Step 3: Scenarios** (agent; fresh `claude -p` sessions use `--output-format stream-json`; the transcripts are kept in the scratchpad)
  - V1, policy loads: in both fixtures and in `~/`, `claude -p 'Without tools: quote the first sentence of your Orchestration instructions.'` returns the sentence.
  - V2, context line: in both fixtures, a fresh session reports the exact `[orchestration]` line, which matches `ws-agent context` run there.
  - V3, authorisation:
    - `ws-agent run` in `~/scratch/orch-local` exits 3 and names `ws-agent allow`.
    - `ws-agent allow` from inside this session exits 3.
  - V4, automatic routing: requests are written as a person would, with no orchestration words. Each runs twice, and every outcome is reported, because this behaviour is probabilistic.
    - "Fix the typo in README.md": direct edits, with no Agent or `ws-agent` calls.
    - "Find every caller of `parse_row` and separately review error handling in `io.py`": Agent tool calls.
    - In the SVN fixture, "Add an LRU cache to the lookup service with tests; I'll review it tomorrow": `ws-agent run` is called, with `--allowedTools 'Bash(ws-agent *)'` granted.
  - V5, SVN job result:
    - `ws-agent result <id>` shows base `^/trunk@<rev>`, a patch, `props.txt` and warnings.
    - The server revision is unchanged (`svn log -l1 file://…`).
    - `svn patch` into a fresh checkout applies cleanly, and the tests pass there.
  - V6, persistence: start a job, then `systemctl --user restart dev.mise.pueued` mid-run. `ws-agent ls` shows `interrupted`. `ws-agent retry` gives `succeeded`, with the same `session_id` in `exit.json` and one job only.
  - V7, cross-session: a new session in the SVN fixture names the finished job from its context line when asked "anything waiting for me here?".
  - V8, errors:
    - A `--timeout 5s` job ends `failed`, and `result` shows the log tail.
    - With pueued stopped, `run` exits 1 with a clear message and `context` shows `queue: pueued not running`. Restart pueued afterwards.
  - V9, WSL shutdown (operator, optional): `wsl --shutdown` from Windows during a job. After restart the job shows `interrupted`, and `retry` resumes it. Report what was actually observed.
  - V10, nothing else broke:
    - `jq '.hooks.SessionStart' ~/.claude/settings.json` still contains herdr's hook.
    - This repo's own session-context hook still prints.
    - `mise run lint` is green.
    - A Windows session (operator) starts without hook errors and simply has no `[orchestration]` line.
  - V11, company repository (only after the operator confirms authorisation): the operator runs `ws-agent allow` on a real SVN working copy; repeat V5 there.
- [ ] **Step 4: Report** — a table of V1–V11 results, the paths of the transcripts in the scratchpad, and the limits observed. No scenario is marked passed without its evidence.

## After this plan

Phase 2: resume `SETUP.md` at question 2 with a personal GitHub test repository. That gives its own plan: DSH CLI and pnpm as mise pins, an isolation boundary for its full-access workers, an instance registry in `agents.toml` (`[superagent."owner/name"]`: profile, port, state directory), and `ws-agent route` showing a healthy instance. The policy's tier 4 already names it, and it reads `none` until then.
