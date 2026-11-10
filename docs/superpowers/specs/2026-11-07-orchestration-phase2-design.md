# Orchestration phase 2: design

Agreed 2026-11-07 ("Go ahead with phase 2", after the gap analysis against
`deepseek-ai/dsh-superagent-prototype` and the recommendation table). Builds on phase 1
(`docs/superpowers/specs/2026-11-06-global-orchestration-design.md`, PR #117).

## Intent

Every project on every Linux workstation host gets a super-agent-style framework at user
level, using whatever agent is available (Claude Code, Codex) instead of DeepSeek Harness.
Requests come from the person (any Claude session, or the CLI) and from watched sources (SVN
branches, GitHub issues and PRs). They are admitted by fixed rules, triaged by a cheap model
where they weren't asked for explicitly, and turned into tickets. Each ticket runs on an
allowed engine in its own sandboxed copy, has its result checked automatically, and comes back
as a reviewable patch. The person is notified and can carry on the conversation on the ticket.

The super-agent's ideas are borrowed (Source → admission → triage → ticket → worker →
report, observe mode first, follow-ups reach the ticket); its runtime is not. Porting it was
rejected: its coordinator, triage, panel and API are DeepSeek Harness sessions, it serves one
github.com repository, runs workers with full access, and has no SVN.

## Decided by the person

- Grow `ws agent`; don't port or install the super-agent. Not DeepSeek: Claude and/or Codex,
  "or basically whatever model is available".
- User level, always in use, in every project (the phase-1 policy and hook stay global).
- SVN and git. Company SVN copies live on remote Linux dev servers.
- No proprietary code to an additional model provider without separate authorization. Their
  personal Claude Pro login is authorized for company code; Codex (OpenAI) is not, until they
  say so for a repository.
- No automatic commit, push, merge or any write to a repository server or GitHub; repository
  writes stay subject to their explicit approval. Results are patches.
- Proactive execution starts in observe mode. Remote writes, destructive operations and
  privilege changes need approval. Permission checks are never disabled to look seamless.
- Explain mechanism, permissions and impact before anything runs on a remote dev server;
  installs there need separate approval.
- Remove the DeepSeek tier (policy tier 4, the context line's `superagent:` field) from PR #117
  before it merges.

## Goals

1. **Engines.** Jobs run on Claude Code or Codex through one adapter interface. Each repository
   lists the engines it allows, in order of preference (default `["claude"]`). An unavailable
   engine (not installed, not logged in, usage limit reached) is skipped for the next allowed
   one. Adding opencode later is one adapter.
2. **OS sandbox, reads and writes.** Every engine runs inside ws-agent's own sandbox, which
   hides the home directory, other jobs' copies, every registered working copy and any per-host
   hidden paths. Whatever an engine can read goes to its provider, so this boundary is about
   reads as much as writes. Inside it, the engine's own sandbox confines its shell commands:
   writes only to the working copy (plus the git worktree's gitdir), and network off unless the
   repository allows it. A host where either sandbox can't start runs no jobs, and says why.
3. **Structured reports.** Each attempt ends with a machine-readable report (done / question /
   blocked / failed, summary, question, tests run) instead of parsed prose.
4. **Automatic checks.** After a job, ws-agent runs the repository's check commands itself, in
   its own sandbox, records pass/fail, and gives the engine one round to fix failures.
   Optional second-opinion review by an allowed engine.
5. **Recovery and capacity.** Transient provider/network failures retry with backoff inside the
   attempt. Interrupted jobs (pueued restart, WSL shutdown) resume automatically, at most twice.
   Two jobs in parallel, one per engine.
6. **Conversations.** `ws-agent tell <id> TEXT` reaches a job: queued for after the current turn
   if it's running, resuming its session if it has finished or asked a question.
7. **Notifications.** A desktop notice when a job finishes or needs the person, and a line in
   every live session in that repository on its next prompt.
8. **Always-on loop.** `ws-agent serve`, a systemd user service, runs sources, recovery and
   cooldown requeues. Jobs keep working without it (it only adds automation).
9. **Sources.** SVN watcher (new revisions on chosen URLs) and GitHub (`/agent` comments by
   allowed logins on registered repositories). Each source is off until configured, and starts
   in observe mode.
10. **Triage and inbox.** Inferred work (SVN revisions) goes through fixed admission rules, then
    a cheap model checks it against the person's plain-language rules. Observe mode records
    "would accept" items in an inbox that the person accepts or dismisses.
11. **Operator view.** `ls`/`show`/`result` gain engine, checks and needs-you; `inbox`, `accept`,
    `dismiss`; a small fzf TUI (`ws-agent ui`).

## Non-goals (this phase)

- Any write to a server: no commits, pushes, PRs, GitHub or SVN comments, labels, Jira.
- Windows job execution (Windows sessions keep tiers 1–2), cross-host job views, a web panel.
- Mid-turn steering of a running engine; follow-ups land between turns.
- Engines beyond Claude and Codex (opencode, oh-my-pi, jcode); the interface allows them later.
- Deploying to remote dev servers. Merging and running `wsu` there is the person's step, after
  the impact statement below.
- Anything DeepSeek. The clone at `~/.local/share/dsh-superagent` is the person's to delete.

## Anti-goals (a failure even if it works)

- A job or the serve loop writing to a repository server, GitHub or the person's working copy.
- Company code reaching a provider the repository doesn't allow (Codex on an SVN copy that
  lists only `claude`), including through fallback, triage or review.
- A daemon doing work nobody configured, or acting before the person has seen observe mode.
- A failing check, a question or a usage-limit stop reported as "succeeded".
- Slower sessions: every hook stays read-only, fail-open, ≤ 3 s, and the per-prompt hook makes
  no pueue or network call.
- Silent permission widening: a weaker engine or a network-enabled repository must be visible.

## Constraints

- Python 3.11+ standard library on mise's Python; `ws.py` stays parseable by 3.6. Tests never
  touch the real pueued, claude, codex, gh or an SVN server: fakes plus a scratch pueued, real
  svn on `file://` repositories, real bwrap where present.
- One pueue group `agents`; `queue.parallel = 2`, with a per-engine cap of 1 (Claude Pro and
  the ChatGPT plan have their own limits, shared with interactive use).
- Repo rules from phase 1 stand: docs travel with behaviour, lint and `check-templates.sh`,
  file modes, the settings-merge array rule, `check_claude_mods`' single global-plugin exception.
- Engine logins are the host's own (`~/.claude`, `~/.codex`); ws-agent never copies or passes
  them, and keeps provider auth variables only for the engine that needs them.
- Measured here on 2026-11-07: Claude's sandbox applies in `-p` mode (a Bash write to `$HOME`
  outside the copy failed with "Read-only file system"), but allows writes under
  `/tmp/claude-<uid>`; with the sandbox off, Claude's permission check blocked the same write.
  bwrap and socat are installed; systemd user services run (pueued is one); Codex 0.166 is
  logged in with ChatGPT; gh is logged in as ArrushC. Nested bwrap works (bwrap inside bwrap,
  inner `--unshare-net`), and `--tmpfs $HOME` hides files under it while ro-binds put chosen
  directories back (WSL kernel 6.6). EL8's 4.18 kernel on the dev servers is unmeasured.
- From the person's original brief: "If isolation cannot be established safely, disable
  autonomous execution and report the limitation."

## Design

### Registry (`~/.config/workstation/agents.toml`)

Extended; still written only by person-run commands (refused under `CLAUDECODE=1`), and
readable by hand. The writer round-trips every key it knows and keeps a file it can't parse
(it refuses to write and says so, instead of overwriting).

```toml
[queue]
parallel = 2

[engines.claude]
parallel = 1
[engines.codex]
parallel = 1
model = ""                       # empty: the engine's default

[repo."~/src/foo"]
vcs = "svn"
commands = ["make *"]            # extra command rules for the agent (phase 1)
engines = ["claude"]             # allowed, in preference order; default ["claude"]
checks = ["make test"]           # run by ws-agent after each job
fix_rounds = 1                   # engine rounds to fix failing checks (0 = none)
review = ""                      # "" off, or an allowed engine for a second opinion
network = false                  # sandbox network for the agent and the checks
allowed_at = "2026-11-07T12:00:00Z"

[repo."~/src/foo".watch]         # SVN source (svn repos only)
urls = ["^/trunk"]
mode = "observe"                 # off | observe | act
authors = []                     # empty: every author
rules = ["Review commits that touch src/net/ for locking mistakes"]
interval = "5m"

[repo."~/p/bar".github]          # GitHub source (git repos with a github.com remote)
mode = "observe"
logins = ["ArrushC"]             # who may trigger with /agent; default: gh's own login
```

CLI: `allow <path> [--command R]… [--engine E]… [--check CMD]… [--fix-rounds N] [--review E]
[--network]`; `watch <path> --url U… [--mode M] [--author A]… [--rule TEXT]… [--interval I]`;
`github <path> [--mode M] [--login L]…`; `unwatch`/`ungithub`. `--engine codex` on an SVN
repository prints a one-line reminder that its code will go to OpenAI and needs the
organization's authorization. `--review E` must name an engine in `engines`.

A global PreToolUse guard (`dotfiles/claude/hooks/`) denies Edit/Write of
`~/.config/workstation/agents.toml`, so a session can't widen it by editing the file. It's an
accidental-write guard like the rest.

### Engines (`wslib/engines.py`)

```python
@dataclass(frozen=True)
class Confinement:          # backend-neutral; each engine translates it
    wc: Path; writable: tuple[Path, ...]; network: bool
    commands: tuple[str, ...]          # the agent's allowed command prefixes
    instructions: str                  # the job rules (phase 1 RULES)
    read_dirs: tuple[Path, ...]        # extra readable inputs (e.g. the job's input/)

class Engine(Protocol):
    name: str
    enforces: frozenset[str]           # {"cmd-allowlist","os-sandbox","path-confine","no-network"}
    def available(self) -> str | None  # None, or why not (local checks only, no model call)
    def argv(self, job, attempt, *, resume: str | None, c: Confinement, schema: Path) -> list[str]
    def env(self, base: Mapping[str, str]) -> dict[str, str]
    def session(self, job, attempt, out: Path) -> str | None   # id, as early as known
    def parse(self, out: Path) -> Outcome
```

`Outcome`: `kind` (`ok`, `transient`, `usage_limit`, `auth`, `error`), `report` (the structured
report or None), `session_id`, `turns`, `duration_ms`, `cost_usd` (when the engine gives it),
`reset_at` (usage-limit reset time when the message names one), `message`.

- **claude**: phase 1's argv plus `--json-schema <report schema>` and, in `--settings`,
  `sandbox: {enabled, failIfUnavailable: true, allowUnsandboxedCommands: false,
  filesystem: {allowWrite: [writable…], denyRead: [credential dirs]}, network:
  {allowedDomains: []}}` (network on: the sandbox's network left unrestricted).
  Session id preassigned (phase 1). `--add-dir` for `read_dirs`.
- **codex**: `codex exec --json -o <out>/last.json --output-schema <schema> --skip-git-repo-check
  --ignore-rules --ignore-user-config -s workspace-write -C <wc> --add-dir <writable…>
  -c approval_policy="never" -c sandbox_workspace_write.network_access=<bool>
  -c developer_instructions=<rules> [-m model] -` with the prompt on stdin. Session id = the
  `thread.started` event's `thread_id`, written to `session-<attempt>.txt` as soon as it
  streams. Resume: `codex exec resume <id> -` with `-c sandbox_mode="workspace-write"` and the
  same `-c` keys, cwd = wc (resume takes no `-s`/`-C`/`--add-dir`). No command allowlist:
  `enforces` lacks `cmd-allowlist`; the PATH shims and the sandbox carry it.
- `--ignore-rules` matters: the person's `~/.codex/rules/default.rules` holds 27 allow rules
  (including `curl -fL`) that must not apply to jobs.
- The PATH shims (svn/git) stay for both engines.

### Job sandbox (`wslib/agent_sandbox.py`)

Every engine process, and every check, starts inside ws-agent's bwrap. It shares the network
(the engine has to reach its provider) and is the read boundary:

- `--ro-bind / /`, `--dev /dev`, `--proc /proc`, `--tmpfs /tmp`, `--die-with-parent`,
  `--new-session`.
- `--tmpfs $HOME`, then binds back:
  - read-only: what the engine and the shims need to run (mise's installs and shims,
    `~/.local/bin`, this checkout's `scripts/ws`, the engine's binary directory);
  - read-write: the engine's own state (claude: `~/.claude`, `~/.claude.json`; codex:
    `~/.codex`) and this job's directory;
  - for a git worktree, the repository's `.git`.
- Hidden with `--tmpfs` (or an empty bind for a file):
  - the jobs directory apart from this job's;
  - every registered repository path apart from the `.git` a worktree needs;
  - the paths in `[sandbox] hide` (a per-host list in `agents.toml`, e.g. `/data/svn`), because
    working copies outside `$HOME` can't be found on their own.
- Codex never sees `~/.claude`; Claude never sees `~/.codex`.
- The engine's inner sandbox runs inside this one:
  - claude: `sandbox` settings with `allowWrite` limited to the copy, `denyRead` on its own
    credentials file;
  - codex: `-s workspace-write`.
- `available()` runs a no-op through both layers once per host per day and caches the result.
  If either layer fails, the engine is unavailable with the reason (`doctor`, context line
  `jobs: off (no OS sandbox: …)`). When no engine is left, jobs are refused on that host:
  phase-1 confinement is not a fallback.

Selection, per attempt: the first engine in the repository's `engines` that is available, under
its parallel cap, and not cooling down (`<state>/agent-engines.json`: engine → until). A
`usage_limit` outcome sets the cooldown (its `reset_at`, else 1 h) and moves the job to the next
allowed engine at once; if there is none, the job ends `waiting` (below) and serve requeues it
when the cooldown ends. Switching engine starts a fresh session with a hand-off note: what
the previous engine did (its report, the current `svn status`/diff stat, the thread). A job
never runs on an engine its repository doesn't list.

### Report schema

```json
{"type": "object", "required": ["status", "summary"], "additionalProperties": false,
 "properties": {
   "status":   {"enum": ["done", "question", "blocked", "failed"]},
   "summary":  {"type": "string"},
   "question": {"type": "string"},
   "tests":    {"type": "string"},
   "notes":    {"type": "string"}}}
```

The phase-1 RULES' "final report" paragraph is replaced by: end with this report; `question`
when you need the person, with one concrete question; `blocked` when a rule stops you.

### Job lifecycle

```
queued → running ─┬─ report done ──→ checks ─┬─ pass ─────────────→ succeeded
                  │                          └─ fail → fix round(s) → succeeded (checks fail)
                  ├─ question/blocked ──────────────────────────────→ needs-you
                  ├─ transient: retry same session (15 s, 60 s, 240 s)
                  ├─ usage_limit: next engine, or ─────────────────→ waiting
                  └─ error / timeout ───────────────────────────────→ failed
interrupted (pueue Killed/missing, no live run) → serve resumes it (≤ 2 times) → running
tell/answer on succeeded | needs-you | failed | waiting | interrupted → queued (resume)
```

- State stays derived. Precedence: closed > cancelled > live run (`run.pid`) → running >
  undelivered messages and a pueue task queued → queued > `exit.json` (`needs-you`, `waiting`,
  `failed`, `succeeded` with a `checks` field) > the pueue mapping (phase 1).
- Each attempt archives the previous `exit.json`/report to `exit-N.json` before starting (phase
  1's retry does this).
- `job.json` gains `history`: one entry per attempt (engine, session id, started, outcome kind)
  and `auto_resumes`. Resume only ever continues a session of the same engine.
- Timeout: each attempt gets the job's remaining `--timeout`; fix rounds and retries share it.

### Checks and review (`wslib/agent_checks.py`)

- After a `done` report, each `checks` command runs in the job sandbox (above). It has no engine
  state and the copy is its only writable directory; `--unshare-net` applies unless `network`. It
  gets a clean env, 20 min per check, and writes `result/checks.txt` and `result/checks.json`
  (`cmd`, `exit`, `duration`). So check output, which a fix round feeds back to the engine, can
  only contain what the copy and the system directories hold.
- No bwrap, or bwrap failing to start → checks are not run (`checks: not run (no sandbox)`),
  never unsandboxed.
- A failure gives the engine up to `fix_rounds` resumes with the failing command's last 80 lines;
  checks run again after each. The final result records the last run.
- `review = E`: after the final checks, one read-only attempt by engine E in a fresh session
  (claude: read tools only, no edits; codex: `-s read-only`) given the task, the patch and the
  check results; it writes `result/review.json` (verdict `ok`/`concerns`, findings with file and
  line). Never applied; shown by `result`.
- Credentials: the job sandbox's `--tmpfs $HOME` already hides `~/.ssh`, `~/.subversion`,
  `~/.config/gh`, `~/.git-credentials`, `~/.netrc` and the gopass/age stores. The only
  credentials left visible are the running engine's own login, which its inner sandbox's
  `denyRead` keeps from its commands where the engine supports it (claude).

### Conversations

`ws-agent tell <id> TEXT` (alias `answer`) appends `{ts, from: "you", text}` to `thread.jsonl`.
Refused for closed or cancelled jobs and under `WS_AGENT_JOB`; allowed in a Claude session,
because it carries the person's words. If the job is running, `_exec` sees the undelivered
message when the attempt ends and resumes the same session with it before collecting. If it
isn't running, `tell` requeues it with resume. The resume prompt carries the messages and the
phase-1 inspection. Job reports are appended to the thread too, so `show` reads as one
conversation.

### Events and notifications

- `_exec` and serve append to `<state>/agent-events.jsonl` (`ts`, `job`, `repo`, `kind`: succeeded,
  failed, needs-you, waiting, resumed, inbox; `text`). Rotated at 1 MB.
- Desktop: `~/.claude/notify.sh "ws-agent" <text>`, detached (new session, no wait, devnull).
  `[notify] desktop = false` turns it off. Under WSL it's the Windows toast path. The modal
  MessageBox fallback in notify.sh must not fire for these (the builder adds a non-blocking
  mode).
- Hosts with no desktop path (the dev servers under pueued/systemd have no tty, and
  `notify-send` has no display) get session lines and the context line only. Reaching the
  laptop from a dev server is out of scope (cross-host).
- Sessions: the plugin gains a `UserPromptSubmit` command hook → `ws-agent events` reads stdin's
  `session_id` and `cwd` and prints at most 3 lines for events newer than that session's
  marker (`<state>/agent-sessions/<id>`, pruned after 7 days): this repository's jobs, plus
  needs-you anywhere. It reads only the events file's tail: no pueue, no network, ≤ 3 s,
  fail-open. Example: `[orchestration] a3f2c1 succeeded, checks pass: ws-agent result a3f2c1`.

### serve (`wslib/agent_serve.py`)

- `ws-agent serve` runs in the foreground (systemd), single instance (flock), ticks every 30 s.
  `--once` runs one tick (tests, manual use).
- Each tick:
  1. recover interrupted jobs (`auto_resumes < 2`, group not paused: phase 1 never auto-starts
     a paused queue);
  2. requeue `waiting` jobs whose engine cooldown ended;
  3. run due sources.
- A tick's error is logged and backed off; serve never exits for one. Log: stdout (journald) and
  `<state>/agent-serve.log`.
- With nothing configured and nothing to recover it does no I/O beyond reading the registry and
  job states each tick.
- Service: `[bootstrap.services.ws-agent-serve]` in `config.linux.toml` (user scope, restart on
  failure). It runs mise's Python on `scripts/ws/ws.py agent serve` with a PATH that reaches
  pueue, svn, gh, claude and codex; the builder confirms what mise's services table can set
  (Environment, PATH) and sets it there.
- `doctor` and the context line show `serve up/down` when any source is configured.

### Sources

Both produce candidates `{cid, source, repo, explicit, author, title, text, base}` with a
deterministic `cid` (dedupe), subject to a per-source daily cap (default 10 tickets).

- **SVN watcher** (`[repo.*.watch]`): per URL, `svn log --xml --non-interactive -r <cursor+1>:HEAD
  <url>` with the person's own svn credentials (read only), every `interval`. The cursor starts
  at HEAD when the watch is created (no backlog). One candidate per revision: `cid =
  svn:<repos-uuid>:<rev>`, author, message, changed paths; filtered by `authors`. Inferred, so it
  goes to triage. An accepted revision becomes a review job: base `url@rev`. Prepare fetches
  `svn diff -c <rev> <url>` and the log entry into the job's `input/` (outside the copy,
  readable by the engine). The prompt: review this revision against the rule that matched;
  report findings; propose fixes only as changes in the copy.
- **GitHub** (`[repo.*.github]`, git repositories whose remote is github.com): `gh api
  repos/<slug>/issues/comments?since=<cursor>` and `repos/<slug>/issues?since=<cursor>` with the
  person's gh login, every ≥ 60 s (honouring `X-Poll-Interval`). A comment or new issue body
  starting with `/agent ` by a login in `logins` is an explicit request: no triage. `cid =
  gh:<slug>:<comment or issue id>`.
  - Base: the commit `git ls-remote origin` names for the default branch (an issue) or
    `pull/<n>/head` (a PR), fetched into the object store only (`--no-write-fetch-head --refmap=`,
    gc off).
  - That touches none of the person's branches, remote-tracking refs or `FETCH_HEAD`, and nothing
    is fetched while `origin` isn't the configured repository.
  - The prompt carries the issue/PR title, body and thread as quoted, untrusted text, then the
    `/agent` instruction.
  - Nothing is posted back.
  - Follow-ups reach the ticket: a later `/agent` comment on an issue or PR that already has an
    unclosed job (thread key `gh:<slug>#<number>`, kept in the source's state) is a `tell` to
    that job, not a new one.
- Modes:
  - `off`;
  - `observe`: the item goes to the inbox, with a notice;
  - `act`: an accepted candidate becomes a job at once; `ask` goes to the inbox.

### Disk and retention

- Nothing deletes a job's copy automatically: that stays the person's `close` (or Claude's,
  after the person's OK, as in phase 1).
- An SVN watcher's review job checks out only the directories the revision touched (sparse
  checkout: `--depth empty`, then `update --set-depth infinity` on those directories). The
  checkout is a fraction of the tree, and the diff is in `input/`.
- Disk guard: serve starts no source job, and `run` warns, when free space on the state
  directory's filesystem drops under 10 GB or 15 %. `doctor` and the context line say so.
- `ws-agent close --empty` closes every succeeded, reviewed-or-not job whose patch is empty
  (person-run, or Claude with the person's OK).

### Admission, triage, inbox

- Fixed rules first (`wslib/agent_admit.py`): repository still allowed; source configured and
  not `off`; author allowed; `cid` not seen; daily cap; the phase-1 duplicate and overlap
  checks.
- Triage (inferred candidates only): `claude -p --model haiku --tools "" --output-format json
  --json-schema <decision> --no-session-persistence`, or the first allowed engine if the
  repository excludes claude (Codex with `-s read-only`).
  - Input: the candidate's text, quoted as untrusted, plus the rules. No code is read.
  - Output: `{decision: accept | ignore | ask, rule, title, task, reason}`.
  - Limits: 120 s timeout, at most 30 triage calls an hour per host.
- Inbox: `<state>/agent-inbox/<id>.json`, `id = sha256(cid)[:10]`, since a cid isn't a safe file name (candidate, decision, status open / accepted /
  dismissed, job id). Commands:
  - `ws-agent inbox [--all] [--json]`;
  - `accept <cid> [--note TEXT]` creates a job through the normal `run` path;
  - `dismiss <cid>`.
  - The context line shows `inbox N` for this repository.

### Operator view

- **Context line** (still ≤ 400 chars), e.g. `[orchestration] svn ~/src/foo ^/trunk@4123 |
  jobs: allowed (claude); queue 1/2 running | here: a3f2c1 needs you, b7c1d0 succeeded checks
  pass (review) | inbox 2 | serve up`. `superagent:` is gone.
- **`ls`** columns: id, state, checks, engine, created, title, repo.
- **`show`**: the thread, attempts and engines.
- **`result`**: the report, checks, review, warnings; with `--diff`, the patch.
- **`ui`** (fzf; Linux): jobs and inbox in one list, `show` as the preview. Keys:
  - enter: `result --diff` in `$PAGER`;
  - alt-t: tell (prompts for one line);
  - alt-r: retry; alt-c: cancel; alt-x: close;
  - alt-a: accept; alt-d: dismiss.
- **Palette**: an `agent-ui` action; `agent-inbox` in projects.

### Routing policy (`dotfiles/claude/CLAUDE.md`)

Tier 4 (DeepSeek) is removed in PR #117. Phase 2 updates tier 3 and the follow-up rules:
- jobs run on the repository's allowed engines;
- a `needs you` job gets the person's answer through `ws-agent answer`, never Claude's guess;
- inbox items are shown, and accepted only with the person's OK;
- `[orchestration]` event lines mid-session are mentioned at a natural pause, not acted on
  unasked;
- results report checks and review findings, and failing checks are never called done.

The section stays under 50 lines. The exact text is written in the plan.

### PR #117 cleanup (on `feat/global-orchestration`, before phase 2)

Remove tier 4 and every `superagent` reference:
- the policy, the context line, `route --json`, README, the repo `CLAUDE.md`, tests;
- the phase-1 design keeps a dated note that tier 4 was dropped.

Update the memory file.

## Branches and delivery

- Phase 2 is a branch `feat/orchestration-phase2` off `feat/global-orchestration`, worked on in
  a git worktree outside the live checkout (`~/worktrees/workstation-phase2`). Live sessions
  keep running PR #117's code until the person merges.
- Two stacked PRs:
  1. 2a: goals 1–7: engines, sandbox, reports, checks/review, recovery, conversations,
     notifications;
  2. 2b: goals 8–11: serve, sources, triage, inbox, TUI.
- The person merges. The live checkout returns to `main` after #117 merges.
- Live checks (P7, P10, P11) work as in phase 1. When a PR's code and tests are done, the
  person switches the live checkout to that branch and runs `wsa`; for 2b they also apply the
  service. The agent hands over the exact commands, then runs the checks against the deployed
  copy before the PR is called ready. Everything else is validated from the worktree:
  `ws.py` run directly, scratch registry and state via `WS_CONFIG_DIR`/`XDG_STATE_HOME`.

## Impact on remote dev servers (for the person, before they run `wsu` there)

- After merging, `wsu` on a dev server installs and starts `ws-agent serve` as a user service,
  idle until a repository there is allowed and a source configured.
- To keep it off a host, copy the whole `[bootstrap.services.ws-agent-serve]` table from
  `config.linux.toml` into that host's `config.local.toml` with `enabled = false` and
  `state = "stopped"`. A partial table replaces the declared one instead of merging (measured on
  mise 2026.9.9), so `enabled = false` alone doesn't work.
- Jobs and watchers run as the person's account, with its svn credentials for checkouts, diffs
  and logs. That's read-only traffic to the SVN server: one `svn log` per watched URL per
  interval, plus one checkout per job.
- No sudo is needed (bwrap ships with EL8/EL9 base; the builder adds `bubblewrap` to the dnf
  batch after verifying the name on both).

## Validation (end to end, this host; scratch repositories only)

| # | Scenario | Pass when |
|---|---|---|
| P1 | Claude job, then the same job with Claude marked unavailable on a repo allowing both | second runs on Codex with a hand-off note; a Claude-only repo ends `waiting` instead |
| P2 | Real Claude and real Codex jobs told to write outside the copy (4 ways each), to use the network, and to read a sibling job's copy, a registered repository, a `[sandbox] hide` path and `~/.ssh` | every write and network call refused; every read finds nothing; a check doing the same fails the same way |
| P3 | Job whose change breaks a test | checks fail, one fix round runs, result shows the final checks honestly |
| P4 | Ambiguous task | `needs-you` with one question; `answer` resumes the same session; finishes |
| P5 | `tell` while running | delivered after the turn, same session |
| P6 | pueued restart mid-job, serve running | resumed automatically once, no orphan; a transient failure (fake) retries with backoff |
| P7 | Notifications | Windows toast from WSL; a live session in the repo sees the event line on its next prompt; none elsewhere |
| P8 | SVN watcher on a `file://` scratch repository | observe → inbox item with triage reason; accept → review job with the revision diff; act → job at once |
| P9 | GitHub (person-assisted: they post a `/agent` comment on a test repository of theirs) | inbox item (observe) or job (act) based on the right commit; nothing posted |
| P10 | Fresh sessions | policy without tier 4; `answer`/inbox handling; event lines handled at a pause |
| P11 | serve as a service (person runs `mise bootstrap` for services) | running, idle with nothing configured |

Not run by the agent: `wsl --shutdown` mid-job (person), a company SVN copy on a dev server
(after the person approves remote deployment).

## Calls made by the designer (not the person's decisions)

1. Every engine runs inside ws-agent's own bwrap (reads hidden), with the engine's sandbox
   nested inside it for commands. This follows from "no code to a provider the repository
   doesn't allow", because what an engine reads goes to its provider.
2. A host without a working sandbox runs no jobs (the person's brief: disable and report), so
   phase-1 confinement is not a fallback.
3. Codex is per repository, added by the person (`allow --engine codex`); the default is
   Claude only.
4. Two jobs in parallel, at most one per engine. One automatic fix round when checks fail.
   Review is off unless configured.
5. Triage uses Claude Haiku with no tools, at most 30 calls an hour. Ten source tickets per
   day per source.
6. serve is installed on every Linux host by `mise bootstrap`, idle until configured, with a
   per-host opt-out.
7. GitHub follow-ups reach the open ticket. Nothing is ever posted back.
8. Copies are never deleted automatically. Watcher reviews use sparse checkouts; a disk guard
   stops new source jobs.
9. Desktop notices only where `notify.sh` can reach the person (WSL); dev servers get session
   lines.
10. Phase 2 is built in a worktree and ships as two stacked PRs.

## Left to the builder

- Exact usage-limit, auth and transient error signatures for each engine. Measure them from
  real output (one Claude and one Codex run on a scratch repository), then encode them with
  fixtures.
- Captured fixture shapes: Codex JSONL events, `gh api` issue and comment JSON (read from a
  public repository), `svn log --xml`.
- How the claude sandbox's `allowWrite`/`denyRead` keys spell paths, and whether the git
  worktree's gitdir needs `allowWrite` for the shim's `git add`/`mv`.
- What mise's `[bootstrap.services]` can set for PATH/Environment.
- notify.sh's non-blocking mode.
- File layout inside `wslib`, test layout, and the exact policy text, within the limits above.
