---
name: feedback-use-pr-review-workflow
description: "Standing workflow (from 2026-06-15) — land changes via feature branch + PR; the user merges by default, but an explicit in-conversation go-ahead makes gh pr merge work. Never push to main directly."
metadata:
  type: feedback
---

Land all changes through a **feature branch + pull request**, not direct commits to `main`. The user has chosen to keep PR review on, so the **user** merges the PR by default. Direct-to-`main` pushes are denied by the auto-mode classifier; `gh pr merge` of Claude's own PR **is permitted when the user explicitly authorizes it in-conversation** (proven 2026-07-02: `gh pr merge --squash --delete-branch` on PR #58 succeeded after the user said "go ahead" — the earlier blanket "harness blocks all self-merges" claim was stale or context-dependent).

**Why:** Supersedes the earlier "always work on `main`, never branch" preference (2026-05-30). Across the 2026-06-15 version-bump session every direct push to `main` and every `gh pr merge` of Claude's own PR was blocked by the harness; asked how to reconcile this with the old preference, the user chose on 2026-06-15 to "use PR reviews from here on" rather than restore direct-push permission.

**How to apply:**
- For each unit of work: `git checkout -b <type>/<slug>`, commit, push the branch, open a PR with `gh pr create` (clear title + body explaining the change and any verification done).
- Do NOT push to `main` directly, ever. Do NOT self-merge a PR **unprompted** — surface the open PR and let the user merge (they typically run `! gh pr merge <n> --squash --delete-branch` in-session). If the user explicitly authorizes the merge in-conversation, `gh pr merge <n> --squash --delete-branch` works — do it rather than bouncing the merge back to them (authorization is per-task, not standing).
- **The go-ahead must name the merge, not just continuation** (learned 2026-07-04, PR #61): a bare "Continue" — even sent right after Claude surfaced the open PR as the only remaining step — was DENIED by the auto-mode classifier ("the user never asked for a merge"). What has passed: "go ahead" in direct reply to a merge offer (#58). So: generic continuation phrasing ≠ merge authorization; don't attempt the merge on it. Surface the PR and let the user either run the `!` merge themselves or say the merge explicitly ("merge it", "merge PR <n>").
- **"Action on the PR" is the user's recurring post-PR phrase, and it is NOT merge authorization by itself** (first hit 2026-07-12 on PR #76, where the classifier blocked a merge attempt on it; pattern confirmed 2026-07-13 on PRs #78 and #79). The established resolution: answer it with an `AskUserQuestion` offering "Merge it for me (Recommended)" / "Show status/diff first" / "Leave it open" — a selected "Merge it for me" IS the named per-task authorization, and `gh pr merge <n> --squash --delete-branch` then proceeds cleanly. Don't guess, don't merge on the bare phrase, don't make the user re-type a merge sentence — ask the three-option question.
- Branch-push-without-asking still applies — see [[feedback-always-push-after-commit]]: push the feature branch immediately after committing; `main` advances ONLY via the user's merge.
- `.claude/` changes (settings, memory) follow the same flow now — PR, don't commit straight to `main` (refines [[feedback-commit-claude-dir-routinely]], which said commit routinely; the "routinely" still holds, the destination is a PR).
- If the user later restores direct-push permission, revisit this memory.
- Still-standing guardrail: no `--force`, no rewriting shared history.
