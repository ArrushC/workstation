# Orchestration phase 4: design

Status: draft for the person's approval (2026-11-19). Builds on phases 1 to 3
(`2026-11-07-orchestration-phase2-design.md`, `2026-11-09-orchestration-phase3-design.md`), whose
constraints stay in force.

## Intent

Three things DSH's super agent has and `ws agent` doesn't. The person wants them added:

1. more engines: opencode, oh-my-pi (`omp`) and jcode;
2. a web panel with an API, where today there is only a terminal picker;
3. a coordinator that is a model session, for requests too big for one job.

## Decided by the person (2026-11-19)

- All three engines get an adapter.
- Each host serves its own panel. No panel aggregates other hosts.
- The panel and its API can view everything and do what `ws-agent ui` does: tell, interrupt,
  cancel, retry, close, accept, dismiss. Never `run`, `allow`, `watch`, `github`, `publish-to`,
  `publish` or `fleet add`.
- The coordinator is a planner with follow-up: for a request the person marks as big, a model
  session splits it into jobs, picks among the engines the repository allows, reads each report
  and decides whether to retry, send a follow-up or ask the person. It has only the powers a
  session has. It is not always on.

## Still in force

No proprietary code to a provider the repository doesn't allow. No write to a server except
through publish, which only the person switches on. Nothing is installed or left running on a
remote dev server without the person's separate approval. If isolation can't be established, the
feature is off and says why.

## Part A: engines

### What an engine entry means now

opencode, omp and jcode are harnesses: each can send code to many providers. Allowing "opencode"
would say nothing about where code goes. So for these three, a repository's entry names the
provider and model, and that is the only one the adapter will start:

    ws-agent allow ~/src/foo --engine claude --engine opencode:openai/gpt-5.2

- `claude` and `codex` stay as they are (their provider is implied).
- `opencode`, `omp` or `jcode` without `:provider/model` is refused at `allow`, and reads as absent
  from a hand-edited file.
- The adapter always passes that model explicitly, never the harness's default or "auto".
- `repos`, `ls`, `show`, `exit.json`, the published comment and the panel show the full entry.
- Usage-limit cooldowns are kept per full entry.

### The adapters

Each implements the existing `Engine` protocol in `engines.py` (argv from a `Confinement`, output
to an `Outcome`), one class per harness:

| Harness | Headless form | Session |
|---|---|---|
| opencode | `opencode run --format json --model P/M --session ID` | its session id |
| omp | `omp -p --mode json --model P/M --session-dir <job dir>` | `--resume ID` |
| jcode | `jcode run --json --provider P` | to be measured |

- **Report.** None of the three takes a JSON schema. The prompt asks for the report as one final
  fenced JSON block; `conform()` validates it. A missing or invalid report gets one more turn in
  the same session asking only for the report, then the attempt is an `error`.
- **State.** Each adapter binds only its own harness's config and login directories into the
  sandbox (`ro_paths`, `rw_paths`), as Claude's and Codex's do. Sessions live in the job directory
  where the harness allows it.
- **Failures.** Each adapter maps its harness's auth, usage-limit and transient errors onto
  `Outcome.kind`. What it can't classify is `error`, never a retry.

### Confinement

The job sandbox (`agent_sandbox.wrap`) stays the read and write boundary for every engine. What
differs is the inner sandbox that keeps the model's shell commands offline: Claude and Codex have
one, these three may not.

- Each adapter declares what it enforces (`Engine.enforces`). An adapter that can't keep commands
  offline is refused for a repository unless that repository already has `--network`. The refusal
  names the reason. Nothing is silently weaker.
- An adapter whose harness can't run inside the job sandbox at all is not registered, and `allow`
  says why. jcode is the likely case: it is built around a background daemon. If `jcode run` needs
  a daemon outside the sandbox, jcode ships as "not supported, because…" and nothing else.
- jcode's `claude` provider reads Claude Code's own credential file. Whether a subscription login
  may be used through another harness is the person's to check with that plan's terms. The
  adapter never selects it implicitly; it is used only if an entry names it.

### Out of scope for part A

Triage stays Claude Haiku. `--review` stays limited to an engine in the repository's list.
Engines beyond these three.

## Part B: the panel and its API

### Shape

`ws-agent panel` serves one host's jobs, inbox and status over HTTP, with a single static page on
top of a JSON API. Python stdlib only (`http.server`), no build step, no external assets.

- **It listens on a Unix socket, never on a TCP port:** `$XDG_RUNTIME_DIR/ws-agent/panel.sock`,
  in a 0700 directory. On a shared dev server, a localhost port is open to every user there; a
  socket in the person's own runtime directory is not.
- **`ws-agent panel open [host]` is how a browser reaches it.** It makes a listener on
  `127.0.0.1:<port>` on the machine the person is sitting at and connects it to the socket:
  - this host: a small relay inside the same process;
  - another host: `ssh -N -L 127.0.0.1:<port>:<socket path> <host>`, with the panel started by
    that same SSH session and ending with it.
- **Nothing is installed or left running on a dev server.** No unit, no port, no daemon: the
  remote panel lives exactly as long as the person's `panel open <host>`. The host must be one of
  `[fleet] hosts`, as the fleet view requires.
- On Windows, `ws-agent panel open` forwards to WSL like every other command; the Windows browser
  reaches WSL's `127.0.0.1` through WSL's localhost forwarding.

### Access

- A random token per panel run, printed once as part of the URL `panel open` shows. The first
  request trades it for an `HttpOnly`, `SameSite=Strict` cookie. Every other request without the
  cookie is `403`.
- `Host` must be `127.0.0.1:<port>` or `localhost:<port>` (DNS rebinding). A `POST` must carry a
  matching `Origin` and a header a plain form can't send.
- `Content-Security-Policy: default-src 'self'`. Titles, reports, log lines and inbox text are
  other people's or a model's words: the API returns them as JSON strings and the page inserts
  them as text, never as HTML.

### API

Read:

    GET /api/status                 serve, queue, engines, cooldowns, disk
    GET /api/jobs                   id, state, checks, engine, title, repo, created
    GET /api/jobs/<id>              what `show` prints, as fields
    GET /api/jobs/<id>/result       report, changed files, checks, review
    GET /api/jobs/<id>/diff         the patch
    GET /api/jobs/<id>/log?tail=N   the end of exec.log
    GET /api/inbox, /api/inbox/<id>
    GET /api/plans, /api/plans/<id> (part C)

Act (each calls the function the CLI command calls, under the same locks):

    POST /api/jobs/<id>/tell | interrupt | cancel | retry | close
    POST /api/inbox/<id>/accept | dismiss

Anything else is `404`. There is no route for `run`, `allow`, `disallow`, `watch`, `github`,
`publish-to`, `publish`, `fleet` or a plan's start. The page polls every 5 s.

### Page

One screen: jobs (state, checks, engine, title, repository) and the open inbox, a detail pane
with report, files, diff and log, and the action buttons the row allows. Light and dark.

## Part C: the coordinator

### What the person sees

    ws-agent plan --title T --prompt P [--repo R] [--go]

1. A model session reads the repository (read-only, in the job sandbox, on a private copy) and
   returns a plan: at most 6 tasks, each with a title, a prompt, the paths it will change, the
   engine entry to use (from the repository's list) and the tasks it depends on.
2. Without `--go` the plan waits: `ws-agent plans`, `ws-agent plan --show <id>`, then
   `ws-agent accept <id>` or `dismiss <id>`. With `--go` it starts.
3. Tasks become ordinary jobs. Tasks with no dependency between them run in parallel only if
   their paths don't overlap (the check `run --paths` already makes); otherwise in order.
4. When a job of the plan ends, the coordinator session is resumed with that job's report and
   check verdict and returns exactly one decision:
   - `continue`: start the tasks that were waiting on it;
   - `tell <task> <text>`: a follow-up to that job (at most 2 per task);
   - `retry <task>` (at most 1 per task);
   - `ask <question>`: the plan shows as needs-you; `ws-agent answer <plan> "..."` resumes it;
   - `done <summary>` or `give-up <why>`.
5. `ws-agent result <plan>` shows the summary, each job's result, and one combined patch.

### How it is held

- The coordinator only reads and answers in a fixed schema. Fixed code starts, tells and retries
  jobs and enforces every limit. The coordinator has no shell that writes and no `ws-agent`.
- It runs on the first engine the repository allows that can run (`engines.select`), since it
  reads the code. Its session, like a job's, is one private copy in the job sandbox.
- It never widens anything: no engine outside the repository's list, no network the repository
  lacks, no `allow`, no source or publish setting, no publish.
- Limits per plan: 6 tasks, 20 coordinator turns, 2 tells and 1 retry per task, the plan's own
  timeout. Past any of them the plan stops as needs-you with what it has.
- A dependent task's copy starts from its base with the earlier tasks' patches applied, so its
  own patch is the difference on top. The plan's result is the ordered series and their sum, and
  the repository's checks run once more on the sum.
- Reports fed back to the coordinator are quoted as untrusted, as elsewhere.
- serve drives step 4 on its tick. With serve stopped a plan stands still; nothing is lost.

### Not in this part

- Source requests (GitHub `/agent`, SVN revisions) don't go through the coordinator.
- A plan, and a job that belongs to one, is not published. `publish` refuses with that reason.
- No plan across repositories.

## Session policy

`dotfiles/claude/CLAUDE.md`'s `## Orchestration` gains one line within its 50-line cap: work that
is big and separable and meant for the background goes to `ws-agent plan`, never started with
`--go` unless the person said so. Starting the panel is the person's.

## Order and size

Three pull requests, each usable alone: A engines, B panel, C coordinator (the panel's plan
routes land with C). Each is built test-first with stand-in binaries, as phases 2 and 3 were,
then tried for real on a scratch repository before it is marked ready.

## Anti-goals

- Code reaching a provider no entry names, through a harness default, "auto", a fallback or the
  coordinator's choice.
- A listener another user or another machine can reach, or a web page that can start work,
  change what agents may touch, or publish.
- A coordinator that loops, spends without bound, or acts on a request nobody marked.
- An engine that runs with less confinement than the others without the repository saying so.

## Calls made by the builder (the person can overturn any)

1. Provider and model are part of the engine entry and required for the three harnesses.
2. The panel listens on a Unix socket and exists only while `panel open` runs; there is no
   always-on panel service, on any host.
3. A token and same-origin checks even though the listener is local.
4. A harness that can't keep commands offline needs the repository's `--network`; one that can't
   run in the sandbox isn't offered.
5. A plan waits for `accept` unless `--go`.
6. Plans aren't published in this phase.
