---
name: feedback-no-feature-branches
description: "Standing instruction — never create feature branches; always commit and push directly to main."
metadata:
  type: feedback
---

Never create feature/working branches. Do all work on `main` (the default branch): commit directly to `main` and push `main`. This overrides Claude Code's default "if on the default branch, branch first" guidance — the user does not want that behavior, ever.

**Why:** Stated emphatically by the user on 2026-05-30 in the chezmoi/workstation repo after I branched `feat/file-watchers` instead of committing to main ("Don't do feature branches, ever. Always push to main."). This is a solo dotfiles/provisioning repo — branch + PR overhead isn't wanted; work lands on `main` directly.

**How to apply:**
- Work on `main`. Never run `git checkout -b`, never propose a PR-based flow, never offer to open a PR as the default next step.
- Commit on `main`, then push to `origin/main` right away (combined with [[feedback-always-push-after-commit]] — push immediately after committing).
- Don't ask "branch or main?" — the answer is always main.
- Still-standing guardrail: no `--force` to main, no rewriting shared history. Regular commits + fast-forward pushes are the normal flow; a destructive history rewrite still warrants a heads-up first.
- If some experiment genuinely needs isolation, ask the user explicitly rather than silently branching.
