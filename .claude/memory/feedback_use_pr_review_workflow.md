---
name: feedback-use-pr-review-workflow
description: "Standing workflow (from 2026-06-15) — land changes via feature branch + PR; the user merges. Do NOT push or merge to main directly."
metadata:
  type: feedback
---

Land all changes through a **feature branch + pull request**, not direct commits to `main`. Claude cannot push or merge to `main` in this environment — the auto-mode classifier denies direct-to-`main` pushes and PR self-merges — and the user has chosen to keep PR review on. The **user** merges the PR.

**Why:** Supersedes the earlier "always work on `main`, never branch" preference (2026-05-30). Across the 2026-06-15 version-bump session every direct push to `main` and every `gh pr merge` of Claude's own PR was blocked by the harness; asked how to reconcile this with the old preference, the user chose on 2026-06-15 to "use PR reviews from here on" rather than restore direct-push permission.

**How to apply:**
- For each unit of work: `git checkout -b <type>/<slug>`, commit, push the branch, open a PR with `gh pr create` (clear title + body explaining the change and any verification done).
- Do NOT attempt to push to `main` or `gh pr merge` your own PR — the classifier blocks both. Surface the open PR and let the user merge (they typically run `! gh pr merge <n> --squash --delete-branch` in-session).
- Branch-push-without-asking still applies — see [[feedback-always-push-after-commit]]: push the feature branch immediately after committing; `main` advances ONLY via the user's merge.
- `.claude/` changes (settings, memory) follow the same flow now — PR, don't commit straight to `main` (refines [[feedback-commit-claude-dir-routinely]], which said commit routinely; the "routinely" still holds, the destination is a PR).
- If the user later restores direct-push permission, revisit this memory.
- Still-standing guardrail: no `--force`, no rewriting shared history.
