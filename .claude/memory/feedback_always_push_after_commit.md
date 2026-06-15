---
name: feedback-always-push-after-commit
description: "Standing instruction — after every commit, push immediately. Overrides the default \"don't push unless explicitly asked\" guardrail."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: a68f55e4-9279-4e62-b0c6-386b3fa4e6eb
---

After every `git commit` I make, immediately push to the matching upstream branch without asking. This is a standing authorization that overrides the default Claude Code rule of "DO NOT push to the remote repository unless the user explicitly asks you to do so".

**Why:** Stated by the user as a durable working preference on 2026-05-25 in the chezmoi repo. No further reason given, but the natural read is they want commits visible on the remote immediately — no stale local-only state, no second prompt per commit.

**How to apply:**
- After ANY commit I create (single, sequence, fix-up commits, doc-only commits — all of them): run `git push` to the tracked upstream right after, in the same response if possible. Under the current PR-review workflow ([[feedback-use-pr-review-workflow]]) that upstream is the **feature branch**, never `main` directly.
- For a sequence of commits in one task, push once at the end (no need to push between each individual commit unless the user has indicated otherwise).
- `main` is off-limits for direct pushes now — the harness blocks them and it advances only via the user merging a PR; don't try to push `main` even for a fast-forward. Other edge cases that still require asking first: force-pushes, pushes from a detached HEAD, pushes to a branch that has divergent remote commits. The "never `--force` to main/master / rewrite shared history" guardrail still stands.
- If `git push` fails (auth, branch protection, hook rejection), surface the error to the user and let them decide next steps — don't try to bypass.
- Reverse: the user can override per-task with "don't push" or "hold the push" — respect that for the current task without forgetting the standing rule.
