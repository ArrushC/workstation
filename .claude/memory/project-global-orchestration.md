---
name: project-global-orchestration
description: "The user works in git AND SVN (company SVN on remote Linux dev servers); global orchestration must stay VCS-independent. Personal Claude Pro is authorized for company SVN code; DeepSeek is not. Super-agent is an optional GitHub-only backend (phase 2)."
metadata:
  type: project
---
Since 2026-11-06 every Claude Code session routes work itself (direct → subagents → `ws-agent run` queued job → DeepSeek Super-agent) — policy in `dotfiles/claude/CLAUDE.md` `## Orchestration`, context from the `workstation-orchestration` SessionStart plugin, jobs in `ws agent` (branch `feat/global-orchestration`, plan `docs/superpowers/plans/2026-11-06-global-orchestration.md`).

Facts the repo doesn't record:
- The user's SVN codebases are company code, mostly on **remote Linux dev servers** (Zed points at `/data/svn/...`), not in WSL. Remote execution means the same workstation deployment on that host (`wsu`), jobs running where the working copies are; explain mechanism, permissions and impact before doing anything remote, and don't install services there unnecessarily.
- **Authorization (user, 2026-11-06):** their personal claude.ai Pro login is authorized for company SVN code, including headless/agent workflows. Proprietary code must NOT go to DeepSeek or any other provider without separate authorization. No automatic commit/push/merge/remote writes — each needs explicit approval.
- dsh-superagent (cloned at `~/.local/share/dsh-superagent/framework`, unmodified) refuses to start without a GitHub repo the agent account can push to (`src/deployment.ts` `resolveDeployment`), and SVN has no request surface — so it is only ever a backend for opted-in personal GitHub repos. Its SETUP.md protocol was paused after Q1 (answer: GitHub only); resume at Q2 with a personal test repo, after phase 1 ships.
- Real-tool behaviour measured here: `svn diff --git` alone breaks `svn patch` on moves (svn 1.14) — use `--show-copies-as-adds`; pueued pauses its group on a graceful stop and marks running tasks Killed; `claude -p --output-format json` prints an array ending in the result.

State 2026-11-07: PR #117 (branch `feat/global-orchestration`, deployed on this WSL host from the branch via wsa) awaits the user's merge. E2E passed V1–V8, the V4 routing cases and confinement; not run: V9 (`wsl --shutdown`), V10 Windows half, V11 a real company SVN copy on a remote dev server (nothing deployed remotely; explain mechanism/permissions first). Deferred review minors: VCS exit codes ignored in collect/inspect, stale Job write-back race, --timeout/--rev validated late, deny-pattern env scrub, doctor TimeoutExpired, registry non-BMP/overwrite of an unparseable file, interrupted attempts not counted. Test fixtures: ~/scratch/orch-svn (+ -repo), ~/scratch/orch-local; probe jobs af6461 bfc6cc 549603 7077eb 905d6a c78189.

**Why:** the user asked for "global, automatic, VCS-independent orchestration" with Super-agent optional, after rejecting a GitHub-only design.
**How to apply:** keep ws agent VCS-neutral and host-local; never route SVN or unregistered code to Super-agent; see [[feedback-use-pr-review-workflow]] for landing changes and [[feedback-sudo-not-passwordless]] for the svn/dnf install path.
