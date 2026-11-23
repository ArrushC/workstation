# Orchestration phase 4: design

Status: approved by the person 2026-11-19 (second version, including the three loosened rules). Builds on phases 1 to 3
(`2026-11-07-orchestration-phase2-design.md`, `2026-11-09-orchestration-phase3-design.md`), whose
constraints stay in force except where "Rules this loosens" below says otherwise.

The first version of this document proposed more engines, a panel and a planner. A reading of
DSH's own documents (`deepseek-ai/dsh-superagent-prototype`: philosophy, domain model,
authorization, execution, panel) showed that two of those aren't what DSH has, and that what it
does have, and `ws agent` lacks, is the conversation around a piece of work. The person asked
for the design to be rewritten around that.

## Intent

Adopt the super agent's way of working without losing its value: a request made in a GitHub
conversation is acknowledged there, questions are asked and answered there, later comments reach
the work without calling the agent again, its pull request is followed through review and CI
until it is merged or closed, and one place shows what waits for the person. All of it on
`ws agent`'s own ground: sandboxed jobs, any repository, the engines a repository allows, checks
before anything is written.

DSH's principle is kept as the test for every part: take as little human attention as possible.
A comment is posted only when someone must act or can use a result.

## What DSH does, and where this stands

| DSH behaviour | Today | This phase |
|---|---|---|
| Acknowledges a request once, in the thread | Silent until the result | Part A |
| A worker's question goes to the thread; a reply there answers it | Local only, `ws-agent answer` | Part A |
| Later comments reach the work without a mention | Only `/agent ...` | Part A |
| "Stop" in the thread stops the work | `ws-agent cancel` | Part A |
| Review comments and CI on its pull request wake the worker, which pushes fixes | Published once, never updated | Part B |
| Work ends when its pull request is merged or closed | Ends when the engine stops | Part B |
| Unasked work from new issues, default-branch CI, listed bots, recorded first | SVN revisions only | Part C |
| Every decision kept with its reason | Log lines, open inbox items | Part C |
| Panel: what needs a person, health, history | Terminal picker | Part D |
| Chat source (Feishu) | none | not in this phase |
| Auto-merge of small approved pull requests | none | never (the person's rule) |
| Settings and prompts edited in the panel | terminal only | never (see Part D) |
| Main session: a model that routes and replies | fixed code + Haiku triage | kept as is |

What `ws agent` has that DSH doesn't, and keeps: a read-hiding sandbox (DSH's workers run with
full access and its wrappers "establish defaults, not a security boundary"), SVN, every
repository instead of one, more than one engine, the repository's own checks before publishing,
new branches only.

## Rules this loosens (the person's to approve, each a per-repository switch, off by default)

1. **More automatic comments.** Today one comment per job, with the result. With the switches
   below: an acknowledgement, a question, and a short note per pull-request update.
2. **Pushing to a branch that exists.** Today a job's `ws-agent/<id>` branch is written once.
   With `--pr-updates`, new commits are added to that same branch, and only to it.
3. **Reading more of GitHub.** With `--follow`, comments and reviews on a job's own issue and
   pull request, and its check runs. With `--infer`, new issues and default-branch CI.

Switches are set with `publish-to` (writes) and `github` (reads), in the person's own terminal,
refused in a session, as today. `--mode manual` still means serve writes nothing by itself.

## Who can drive a job

Only the logins the repository lists (`ws-agent github --login`), as today. A comment from
anyone else, or from a bot, never reaches a job and never answers a question. DSH delivers every
message on a subscribed thread as context; here other people's words go to an agent only when an
allowed person wrote them. CI results reach a job as facts ws-agent reads from the API (check
name, conclusion, commit), with the failing log's tail as an untrusted file beside the copy.

## Part A: the conversation

Settings: `ws-agent github <path> --follow`; `ws-agent publish-to <path> --ack --questions`.

- **Acknowledgement** (`--ack`, auto mode): when a request becomes a job, one comment in fixed
  words: an agent picked it up (job id, engine entry), and it will write again with a result or
  a question. Never for a request that went to the inbox, was refused or is a duplicate.
- **Questions** (`--questions`): a job that ends `question` or `blocked` and came from GitHub
  posts its question on the thread. The model's words sit in a code fence, as all posted model
  text does. The job shows as awaiting answer.
- **Answers and follow-ups** (`--follow`): on a thread with a live job, a comment by an allowed
  login needs no `/agent`:
  - the job is awaiting an answer: the comment is the answer (`answer`), and the job resumes;
  - otherwise it is a follow-up (`tell`): delivered after the current turn, or resuming a
    finished job in the same session and copy.
- **Stop:** a comment from an allowed login whose first line is `/agent stop` cancels the job.
  With `--ack`, one comment says it stopped. Nothing else in a comment is read as a command.
- **Order.** A job's comments to one thread go out in the order they were queued. One that may
  have been posted but wasn't confirmed is never posted again automatically (phase 3's rule),
  and holds back later ones until the person looks.
- **Limits per job:** 1 acknowledgement, 3 questions, 10 delivered follow-ups a day. Past a
  limit the job waits for the person locally, with a notice.

A thread is "live" while its job is neither closed nor cancelled. `unwatch`-style forgetting,
admission (daily caps, still allowed, login listed) and `handled` apply to follow-ups as they do
to requests.

## Part B: following the pull request

Settings: `ws-agent publish-to <path> --draft-pr --pr-updates`; reads need `--follow`.

Once a job's draft pull request is open, the job is **delivered**: it waits on people, not on an
engine. serve follows that pull request:

- **Review feedback.** A review with a body, a review comment or a pull-request comment by an
  allowed login is a follow-up to the job (Part A). Approvals without text wake nothing.
- **CI.** When check runs on the commit ws-agent pushed conclude with a failure, the job is told
  once per commit, in fixed words naming the checks, with each failing log's tail (bounded) in
  its input folder. At most 2 CI rounds per job; after that it is the person's.
- **Updating.** When a resumed turn ends `done` with changes and the repository's checks pass:
  one new commit on top of the branch, pushed to `ws-agent/<id>`, and one comment in fixed words
  with the changed files and the summary fenced.
  - Only if the branch's tip at origin is still the commit ws-agent pushed last. If anyone else
    has committed to it, nothing is pushed and the job says the branch is now theirs.
  - Fast-forward only, never forced, to the push URL, one ref, no tags (phase 3's push rules).
  - A patch touching `.github/` is never pushed automatically.
  - At most 5 updates per pull request.
  - With failing checks nothing is pushed: the job waits for the person, as today.
- **The end.** Merged or closed: the job is closed (its copy removed, its result kept), and its
  thread is no longer live. A comment after that starts nothing; a new `/agent` does.
- ws-agent never marks a pull request ready, never merges, never enables auto-merge, never
  resolves a review thread.

`ws-agent publish <id>` by hand can push an update too, under the same rules, when the mode is
manual.

### States

`ls`, `ui` and the panel say whom a job waits for, as DSH's stages do:

| State | Means | Waits for |
|---|---|---|
| queued, running | as today | the engine |
| needs-you | a question, or blocked | the person's answer |
| delivered | a pull request is open | review, or CI |
| succeeded | a result with nothing published | the person (apply, publish or close) |
| failed, waiting, interrupted | as today | the person, or a cooldown |

## Part C: unasked work on GitHub, and a record of decisions

- **Inferred candidates** (`ws-agent github <path> --infer issues,ci`): a new issue by an allowed
  login that doesn't address the agent, and a failed default-branch CI run, become candidates.
  They take the path SVN revisions take: admission rules, Haiku triage against the watch's
  plain-language rules, then the inbox in observe mode, a job in act mode. No backlog: only what
  appears after the switch is set.
- **Decision record.** Every candidate's fate is appended to `agent-serve/decisions.jsonl`
  (bounded): what arrived, from which thread, admitted or refused and why, triage's decision and
  the rule it matched, the job or inbox item it became, and each publish. `ws-agent history
  [thread or job]` prints it. This is what the panel's history reads.

Bots as a source of candidates (DSH's bot list) are left out.

## Part D: the panel

One host's panel, as decided: each host serves its own, and it can view everything and do what
`ws-agent ui` does (tell, interrupt, cancel, retry, close, accept, dismiss), nothing else.

- **Three questions, in DSH's order.**
  1. *Does anything need me?* Jobs awaiting an answer, delivered and awaiting review, failed or
     with a comment or push that gave up, and open inbox items. Each row offers its action.
  2. *Is it healthy?* serve, each source's last poll and error, engines and cooldowns, the queue,
     disk. A healthy line takes no space.
  3. *What happened to this piece of work?* A thread's history from the decision record: what
     arrived, the decision and reason, the job, its turns, what was posted and pushed.
- A filter box finds jobs and threads by id, `#number`, title or repository.
- **Settings are shown, never edited.** `allow`, sources and publish settings stay in the
  person's terminal: a web page that can widen what agents may touch is the thing phases 1 to 3
  were built to prevent. DSH's panel edits them; this is a deliberate difference.
- **Transport.** It listens on a Unix socket in the person's runtime directory (0700), never a
  TCP port: on a shared dev server a localhost port is open to every user. `ws-agent panel open
  [host]` gives the browser a `127.0.0.1` address: a relay for this host, `ssh -L` to the socket
  for a `[fleet]` host, where the panel lives only as long as that command. Nothing is installed
  or left running on a dev server.
- **Access.** A token per run in the URL `panel open` prints, traded for an `HttpOnly`,
  `SameSite=Strict` cookie; `Host` and `Origin` checked; `Content-Security-Policy: default-src
  'self'`; other people's and models' words inserted as text, never HTML.
- **API.** `GET /api/status`, `/api/needs`, `/api/jobs[/<id>[/result|/diff|/log]]`,
  `/api/inbox[/<id>]`, `/api/history?thread=`; `POST /api/jobs/<id>/tell|interrupt|cancel|retry|
  close`, `POST /api/inbox/<id>/accept|dismiss`. No other route exists. Python stdlib, one
  static page, no build step, no external assets.

## Not in this phase

- **More engines** (opencode, oh-my-pi, jcode) and **a planner**. Neither is something DSH's
  super agent has: it runs on one executor, and its main session routes and replies but doesn't
  split work. Both can follow as their own phase if the person still wants them; the draft for
  them is in this file's history (`af070a2`).
- A chat source (DSH's Feishu). The source interface allows one later.
- SVN in the loop: a watched revision's review stays local.
- A model as the main session. Admission stays fixed rules, triage stays Haiku with no tools,
  replies stay fixed words: nothing an untrusted comment can talk into a write.
- Context-only subscriptions and cross-thread correlation.

## Anti-goals

- A comment or commit nobody could use: noise, repeats, a post after the person said stop.
- Someone who isn't on the list steering a job through a comment, a review or a bot.
- A push that moves a branch a person has committed to, or any branch but the job's own.
- A job that loops on CI or review without bound.
- A listener another user or machine can reach, or a page that can change what agents may do.

## Order

Four pull requests, each usable alone and each tried for real on a scratch GitHub repository
before it is marked ready: A conversation, B pull-request following, C inferred candidates and
the decision record, D the panel.

## Calls made by the builder (the person can overturn any)

1. Only allowed logins' comments reach a job; others' never do, even as context.
2. `/agent stop` is the one command read from a comment; no model interprets "please stop".
3. A model's question is posted inside a code fence, like every other posted model text.
4. After a pull request is merged or closed, a new `/agent` is needed; nothing resumes by itself.
5. An update is pushed only while ws-agent's commit is still the branch tip.
6. The panel never edits settings and is never always-on.
7. More engines and the planner are out of this phase.
