# Orchestration phase 3: design

Status: approved by the person 2026-11-09. Builds on phases 1, 2a and 2b
(`2026-11-07-orchestration-phase2-design.md`), whose constraints stay in force except where
"Decided by the person" below changes them.

## Intent

Phase 2 left four things out on purpose. The person now wants them:

1. results that go back to where the request came from, without a manual step each time;
2. one view of the jobs on every host they work on;
3. jobs started from a Windows session;
4. a way to stop a job's current turn and redirect it.

## Decided by the person (2026-11-09)

- **Automatic writes are allowed, per repository.** This replaces phase 2's "no write to a server"
  rule for repositories where the person switches publishing on. Each kind is switched on
  separately:
  - a GitHub comment on the issue or pull request that asked;
  - a GitHub draft pull request from a new branch;
  - an SVN commit to a new branch.
- A watched SVN revision's review stays a local result and a notice unless SVN branch commits are
  on for that repository.
- **Only passing work is published.** A job whose checks fail, or whose repository has no checks,
  is never published automatically. It waits for the person, as today.
- The cross-host view is one view that pulls job lists from dev servers over SSH.
- Windows-side requests run as jobs inside WSL. No native Windows sandbox.
- Steering is "stop this turn now and resume with my message".

Unchanged from phase 2, and binding:

- No code reaches a model provider a repository's registry entry doesn't list.
- Nothing is merged, and nothing is written to an existing branch, to trunk, or to a default
  branch. Publishing only ever creates something new (a comment, a branch, a draft PR).
- Sources start off, then observe. Publishing starts off.
- `allow`, source settings and now publish settings are the person's to run, in their own
  terminal. A Claude Code session can't change them.
- Explain mechanism, permissions and impact before anything runs on a remote dev server.

## Goals

1. **Publish.** A finished job's result can be posted back, automatically where the repository
   allows it, or by the person with one command.
2. **Fleet view.** `ws-agent fleet` lists jobs and inbox items across this host and named
   remote hosts; `ws-agent ui --fleet` shows them in the fzf view.
3. **Windows requests.** `ws-agent` on Windows forwards to the WSL distribution, so a Windows
   Claude Code session gets tier 3 (queued jobs) for repositories that live in WSL.
4. **Interrupt.** `ws-agent interrupt <id> TEXT` stops the running turn and resumes the same
   session with the message.

## Non-goals

- Merging, closing or labelling anything; marking a draft PR ready; replying to review comments.
- Publishing a job the person started with `run` automatically. Automatic publishing is for jobs
  that came from a source (they have somewhere to go back to). `publish` by hand works for any job.
- Editing or deleting what was published. A second publish of the same job is refused.
- A web page or a daemon on remote hosts. The fleet view is pull-only, over the person's own SSH.
- Jobs whose working copy lives on the Windows filesystem. The repository must be in WSL.
- Injecting text into a turn while it runs. Neither CLI takes input mid-turn when headless.

## Anti-goals (a failure even if it works)

- A write the repository's publish settings don't name, or any write from a repository where
  publishing is off.
- A push to a branch that already exists, a force push, or a commit to trunk.
- Publishing a job with failing or missing checks, or one that ended needs-you, waiting or failed.
- Someone else's words published under the person's name: a comment body built from an issue's
  text, a commit message taken from a log message.
- Credentials reaching the engine. The job sandbox stays as it is; publishing happens outside
  it, after the job, by ws-agent itself.
- A remote host changed by the fleet view.

## Design

### 1. Publish

**Settings** (`~/.config/workstation/agents.toml`, per repository, written only by a new
`ws-agent publish-to` command that refuses inside a Claude Code session):

```toml
[repo."~/src/foo".publish]
mode = "off"            # off (default) | manual | auto
comment = false         # GitHub: post the report on the issue/PR that asked
draft_pr = false        # GitHub: push ws-agent/<id> and open a draft PR
svn_branch = ""         # SVN: a branch parent such as "^/branches/ws-agent"; "" = never commit
```

- `manual`: nothing is published until the person runs `ws-agent publish <id>`.
- `auto`: serve publishes a source job when it ends `succeeded` with `checks: pass`.
- An unknown mode reads as `off`, as for sources.

**What is written**, by ws-agent after the job, outside the sandbox, with the person's
credentials:

- *GitHub comment* (`gh api -X POST repos/<slug>/issues/<n>/comments`): a fixed template with the
  job id, the engine, the checks result, the changed files and the job's own summary. The summary
  is model output about someone else's code, so it is posted inside a quoted block, cut to a
  length limit, with `@` mentions and issue references defused so it can't notify or link people.
  The request's own text is never echoed.
- *Draft PR*: in a throwaway clone under the job directory (never the person's checkout):
  `git apply` the job's patch onto its recorded base, commit as the person with a fixed message
  (`ws-agent <id>: <the person's own instruction's first line>`, or the job id alone for an SVN
  or inferred job), `git push origin HEAD:refs/heads/ws-agent/<id>` (refused by ws-agent if that
  ref exists), then `gh pr create --draft`. For a request on a pull request, the draft PR
  targets that PR's branch; for an issue, the default branch.
- *SVN branch*: `svn copy <url>@<rev> <svn_branch>/<id>` then a checkout of that branch, `svn
  patch`, `svn commit` with a fixed message. Refused if the branch path exists. Never trunk: the
  target must be under `svn_branch`, which must not be the watched URL or a parent of it.

**Guards**, all in one function every path goes through (`agent_publish.allowed(job, kind)`):

- the repository is still allowed and its publish settings name this kind;
- the job is `succeeded`, its checks passed (auto) or the person ran the command (manual; a
  failing job then needs `--even-failing`);
- the job hasn't been published before (`published.json` in its result folder records each
  write with its URL);
- a per-source daily cap on automatic publishes (default 5), separate from the job cap;
- the patch is non-empty for a PR or branch.

Every publish is logged, sends a desktop notice with the URL, and adds an event line.

**Policy text** gains one sentence: a session may run `ws-agent publish <id>` only when the
person asks for that job by name; it never changes publish settings.

### 2. Fleet view

- `~/.config/workstation/agents.toml` gains `[fleet] hosts = ["dev10", "dev11"]` (SSH host
  aliases from the person's own `~/.ssh/config`), set by `ws-agent fleet add <host>`.
- `ws-agent fleet [--json]` runs, per host, `ssh -o BatchMode=yes -o ConnectTimeout=5 <host>
  ws-agent ls --all --json` and `ws-agent inbox --json`, in parallel, and prints one table with a
  host column. An unreachable host is one row saying so. Nothing is cached.
- `ws-agent ui --fleet` uses the same rows; its keys run the matching command over SSH on the
  row's host (`ssh -t <host> ws-agent result <id> --diff`, `tell`, `cancel`, `retry`, `close`,
  `accept`, `dismiss`).
- Read commands need nothing new on the remote host beyond phase 2b being applied there. No
  service, no listening port, no polling: it runs only when the person opens the view.
- Titles and reports from a remote host are someone else's text as far as this host is
  concerned: printed through `printable`, never put in event lines.

### 3. Windows requests

- `ws-agent.cmd` and a `ws-agent` function in the PowerShell and Nushell profiles forward to
  `wsl.exe -d <distro> -- ws-agent …`, translating a Windows path under `\\wsl$\<distro>\` (or
  the `wsl.localhost` form) to its Linux path. A path on a Windows drive is refused with a
  message saying the repository has to live in WSL.
- The SessionStart hook on Windows runs the same forwarder for `context`, so a Windows session
  in a WSL repository gets the `[orchestration]` line and with it tier 3. Elsewhere on Windows
  the line stays absent and sessions keep tiers 1–2.
- `allow`, source and publish settings still refuse from a Claude Code session: the forwarder
  passes `CLAUDECODE` through (`WSLENV`).
- The distribution name comes from `config.local.toml` (`vars.wsl_distro`), written by
  `bootstrap.ps1` when it finds one; without it the forwarder says so.

### 4. Interrupt

- `ws-agent interrupt <id> TEXT`: posts the message to the job's thread, then sends SIGINT to
  the engine's process group (recorded in `run.pid`), escalating to SIGTERM after 10 s. The
  executor sees the turn end early with a message pending and resumes the same session with it,
  as `tell` does between turns. The attempt's timeout keeps counting.
- If the engine has already finished, it behaves exactly like `tell`.
- An interrupted turn's partial edits stay in the copy; the resume prompt says the turn was cut
  short and tells the engine to check the copy's state first (the existing resume text).
- Refused inside a queued job, like `tell`.

## Impact on remote dev servers

- Publishing on a dev server writes to the company SVN server (a new branch per job) with the
  person's svn credentials, only where `svn_branch` is set for that repository there. Nothing is
  on by default.
- The fleet view makes SSH connections from the laptop to the listed hosts when opened, and runs
  `ws-agent` read commands there. Its action keys run the same commands the person could type in
  an SSH session.

## Delivery

Four pull requests, in this order, each usable alone:

1. interrupt (smallest; no new permissions);
2. Windows requests;
3. fleet view;
4. publish, built manual-first: `publish-to`, `publish <id>`, then `auto` in serve.

Each gets a plan, tests that fail first, a whole-branch review and live checks before merge.
Publish is validated only against scratch repositories (a private GitHub repository the person
creates, a `file://` SVN repository) before the person switches it on anywhere real.

## Calls made by the designer (not the person's decisions)

- Publishing is done by ws-agent after the job, never by the engine: the sandbox, the read-only
  git and the svn shim stay exactly as they are.
- Automatic publishing covers source jobs only; `run` jobs are published by hand.
- "No checks configured" counts as not passing for automatic publishing.
- A separate daily cap of 5 automatic publishes per source.
- Commit messages and comment templates are fixed text plus the person's own instruction; model
  and third-party text is quoted, cut and defused.
- A job is published at most once; there is no update or retract.
- The fleet view has no cache and no remote component.
- Interrupt uses SIGINT then SIGTERM on the engine's process group and the existing resume path.

## As built (differences from the text above)

- Windows: no `wsl_distro` setting and no profile functions. The distribution comes from the directory's
  `\\wsl.localhost\<distro>\` path, and three launcher files on `PATH` cover Git Bash, PowerShell and cmd.
  Arguments cross to WSL as one base64 word.
- Publish: the draft PR's commit is built with git plumbing on a throwaway index in the person's repository
  (new objects only), not in a clone, and pushed to the remote's URL so no remote-tracking ref is written.
  The issue a job answers is found through the source's threads map, not stored on the job.
- Publish: `publish <id> --dry-run` was added. A PR that fails to open after its branch was pushed is retried
  without pushing again.

## Settled after the first draft (the person, 2026-11-09)

- A watched SVN revision's review job is never committed, even where `svn_branch` is set: reviews
  stay local. An SVN branch commit is only ever made by `ws-agent publish <id>` for a job the
  person started, or automatically for no SVN job at all in this phase.
- A published GitHub comment says in its first line that an agent wrote it.
