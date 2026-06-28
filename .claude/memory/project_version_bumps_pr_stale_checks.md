---
name: project-version-bumps-pr-stale-checks
description: weekly automation/version-bumps PR checks can be stale relative to main — verify head_sha before merging
metadata:
  type: project
---

The weekly `version-bumps.yml` bot opens PRs on a **long-lived, reused branch**
`automation/version-bumps` (peter-evans/create-pull-request). A bot PR can sit
open while newer PRs merge to `main` and add new invariants — and GitHub does
**not** re-run a PR's checks when only the base branch advances. So `gh pr checks
<n>` can show a **stale green** that predates an invariant now enforced on `main`.

This bit us with PR #27 (2026-06-28): its green checks predated the
`machine-memory TOOLS block in sync` invariant (added later by #28). It merged
clean, then `lint` on `main` (run #156) went red because the bumped `versions.mk`
didn't carry a regenerated `<!-- TOOLS -->` block (the `sync-tool-memory.sh`
Claude hook never fires in CI). Fixed in PR #45: `scripts/bump-versions.sh` now
runs `scripts/gen-tool-memory.sh` after any bump, so future bump PRs ship the
block in lockstep — but the stale-check hazard remains for ANY auto-PR on that
reused branch.

**Why:** `gh pr checks` reports the last completed check run for the PR head,
which may have run against an older tree or an older set of repo invariants;
`mergeStateStatus: CLEAN` does not mean the checks reflect current `main`.

**How to apply:** before merging any `automation/version-bumps` (or other stale
auto-PR), confirm the checks are fresh — compare the check-run `head_sha` to the
PR head and to current `main`, e.g. `gh pr view <n> --json statusCheckRollup,headRefOid`
and `gh api repos/{owner}/{repo}/commits/<pr-head>/check-runs --jq '.check_runs[].head_sha'`.
If they lag, push an empty commit / re-run CI (or just run `make -C makefile lint
MODE=prod` locally on the merged tree) before merging. Relates to
[[project_verify_tool_bumps_at_runtime.md]] and [[feedback_use_pr_review_workflow.md]].
