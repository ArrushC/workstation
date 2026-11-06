# Global orchestration: design

Agreed 2026-11-06. Goal: every Claude Code session on a workstation host decides by
itself how to execute a development request (directly, with native subagents, as a queued
headless job, or through DeepSeek Super-agent), in any repository, git or SVN. Super-agent is
an optional backend for authorized GitHub repositories (phase 2, its own plan); nothing in
phase 1 needs GitHub.

## Why this shape

- dsh-superagent's engine is VCS-neutral, but its setup (`src/app/setup.ts` →
  `resolveDeployment`, `src/deployment.ts:87`) refuses to start until a GitHub repository with
  agent push access is configured, and its prompts and Executor tools treat a pull request as
  "done". SVN has no request surface (issues/comments) to be a Source. Forking it, or adding
  a local Source behind a placeholder GitHub repo, is a maintained fork of a one-commit
  research prototype pinned to DSH 0.2.1 alpha. Rejected; Super-agent stays unmodified.
- Proprietary SVN code goes to no model provider beyond the one Claude Code already uses.
- pueue is a process queue, not an orchestrator: the coordination added on top of it is the
  minimum (a job record, a working copy per job, a derived state, dedupe, retry/resume).

## Components

| Component | Source in this repo | Deployed to |
|---|---|---|
| Routing policy | `## Orchestration` in `dotfiles/claude/CLAUDE.md` | `~/.claude/CLAUDE.md` (every session, both OSes) |
| Context hook | plugin `dotfiles/claude/skills/workstation-orchestration/` (SessionStart command hook), enabled in `settings.enforced.json` | `~/.claude/skills/workstation-orchestration/` |
| `ws agent` | `scripts/ws/wslib/{vcs,agent_registry,jobs,agent_exec,agent}.py` | runs from the checkout |
| `ws-agent` launcher | `dotfiles/local/bin/ws-agent` | `~/.local/bin/ws-agent` (Linux) |
| SVN client | `"dnf:subversion"` in `config.linux.toml` | system package |

The hook is a plugin because `scripts/lib/claude-settings-merge.sh` replaces hook *arrays*
wholesale: a `SessionStart` entry in `settings.enforced.json` would delete the live one
(herdr's `herdr-agent-state.sh`). Plugin hooks are added beside settings hooks.
`check_claude_mods` gets one named exception: `workstation-orchestration` may carry command
hooks (no `modules`) under `dotfiles/claude/skills` and be enabled in `settings.enforced.json`.

## Routing policy (exact text)

The text in plan Task 7, verbatim. Tiers: 1 direct (default) → 2 subagents (one writer per
file set; git `isolation: "worktree"`; SVN never two writers in one working copy) → 3 queued
job (`ws-agent run`, allowed repositories only) → 4 Super-agent (GitHub repo with a healthy
registered instance; each submission needs the user's OK). It states that it is the user's
standing request to delegate when that fits, so it overrides the default "don't spawn agents
unless asked".

## Context line

`ws-agent context` prints one line (≤ 400 chars, ≤ 3 s, exit 0, empty on any internal error):

```
[orchestration] svn ~/src/foo ^/trunk@4123 modified | jobs: allowed; queue 0/1 running, 1 queued | here: a3f2c1 succeeded (review), b7c1d0 running | superagent: none
[orchestration] git ~/p/bar github ArrushC/bar | jobs: not allowed (ws-agent allow) | here: none | superagent: none
[orchestration] no repository here | superagent: none
```

## `ws agent` contract

Registry `~/.config/workstation/agents.toml` (`core.config_dir()`, which ws's `WS_CONFIG_DIR`
overrides; per host, not tracked):

```toml
[queue]
parallel = 1                 # pueue group "agents"

[repo."~/src/foo"]           # key: the working copy / worktree root, tilde form
vcs = "svn"
commands = ["make *"]        # extra Bash permission rules for jobs in this repo
allowed_at = "2026-11-06T23:40:00Z"
```

`allow`/`disallow` refuse (exit 3) when `CLAUDECODE=1`: a Claude session can't authorize
itself; the person runs them in their own terminal. `run` refuses (exit 3) when
`WS_AGENT_JOB` is set: a job never queues jobs.

| Subcommand | Does |
|---|---|
| `context` | the one line above |
| `route [--json]` | VCS facts, allowed?, queue, jobs here, Super-agent instance (phase 1: `none`) |
| `allow <path> [--command RULE]…`, `disallow <path>`, `repos` | registry |
| `run --title T (--prompt-file F \| --prompt TEXT) [--repo P] [--rev R] [--timeout 2h] [--paths G]… [--force]` | records the base now, queues `_exec`, prints the id |
| `ls [--repo P \| --all] [--json]`, `show <id>`, `result <id>` | state, log tail, summary, patch path, warnings |
| `cancel <id>`, `retry <id>`, `close <id>` | kill+remove the pueue task / requeue with resume / mark reviewed and delete the working copy |
| `doctor` | claude auth (method and plan only), pueued, group parallelism, svn, paths, free disk |
| `_exec <id>` | internal: what pueue runs |

Exit codes: 0 ok, 1 error, 2 usage, 3 refused (not allowed, duplicate, guard).

Job directory `<state>/agent-jobs/<id>/` (`core.state_dir()`): `job.json`, `prompt.md`,
`rules.md`, `bin/` (shims), `wc/` (working copy), `result/` (`claude.json`, `exit.json`,
`changes.diff`, `status.txt`, `props.txt`, `warnings.txt`), `exec.log`.

Base, recorded at `run` time from the repository the user is in:
- SVN: `svn info --show-item url|repos-root-url|wc-root`, revision `--rev` or the root's
  `svn info --show-item revision`. `svnversion` mixed (`a:b`) or switched (`S`) without
  `--rev` → refused, naming `--rev`. Local modifications → a warning (the job starts from the
  clean base). `_exec` runs `svn checkout --non-interactive URL@REV wc`.
- git: `HEAD` commit; dirty tree → warning. `_exec` runs `git worktree add -b ws-agent/<id> wc <commit>`.
- neither → refused.

State, derived each time (no daemon): `closed` > `cancelled` > `exit.json` (`succeeded`/`failed`)
> pueue `Running` → `running`; `Queued`/`Paused`/`Stashed`/`Locked` → `queued`; pueue done or
missing without `exit.json` → `interrupted`.

Dedupe: same repo and prompt sha256 with a job `queued`/`running`/`succeeded`-not-closed →
refused with that id unless `--force`. `--paths` overlapping an active job's → stderr warning.

Headless run (`_exec`): env without `CLAUDECODE` and every `CLAUDE_CODE_*`; `PATH=<job>/bin:…`;
cwd `wc/`; `timeout --kill-after=60s <timeout> claude -p --session-id <uuid> --output-format json
--permission-mode acceptEdits --permission-prompts none --allowedTools <rules>
--append-system-prompt-file rules.md` with the prompt on stdin. Retry resumes with
`--resume <uuid>` when the session exists, else starts a new one. Results: `svn status`,
`svn diff` (property changes included), `svn proplist -v` of changed paths, unversioned `?`
paths as warnings; git `add -A` + `diff --cached --binary <base>`.

Shims in `bin/`: `svn` allows only status, diff, info, log, cat, list, blame, add,
delete/move/propset/propdel on working-copy paths (no URL argument, no `--revprop`), propget,
proplist, revert, resolve(d), cleanup, patch, mergeinfo, help, `--version`; anything else
exits 3 with "ws-agent: svn <sub> writes to the repository; a person runs it". `git` refuses
`push` and `svn`. Defaults, not a security boundary (absolute paths bypass them); the
permission allowlist is the second layer (`Bash(svn *)`, `Bash(git *)`, read-only tools, the
repo's `commands`).

## Limits stated to the user

- Queue: Linux hosts with pueue. Windows: tiers 1–2.
- Jobs don't survive WSL shutdown or Windows sleep; they come back `interrupted`, and `retry`
  resumes the same session and working copy.
- Headless jobs use the host's Claude Code login and its plan's usage limits (this host:
  personal claude.ai Pro), shared with interactive sessions; hence `parallel = 1`.
- Organizational authorization can't be verified from the host; the user confirms it before
  allowing a company repository.
