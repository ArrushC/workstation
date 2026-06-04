---
name: feedback-skip-redundant-final-review
description: When subagent-driven-development has already done per-task two-stage reviews (spec + quality), skip the skill's "final cross-cutting review" pass — the user interrupted it as redundant.
metadata:
  type: feedback
---

When executing a plan via [[using-superpowers]] + subagent-driven-development, the workflow normally ends with a "final code reviewer for the entire implementation" pass before [[superpowers-finishing-a-development-branch]].

**Skip that step on this repo.** If every task already cleared its two-stage review (spec compliance + code quality), the user finds the across-all-commits final pass redundant — too much token spend for marginal signal. Go straight from the last task's completion to `superpowers:finishing-a-development-branch`.

**Why:** Confirmed in-session (2026-05-25). The Dozzle+Cockpit implementation had ~9 thorough per-task reviews; the user interrupted the dispatched final review and said "Continue", signaling they wanted the implementation declared done.

**How to apply:** After the last task is marked complete, do not dispatch a final cross-cutting reviewer. Instead invoke the finishing skill directly with a brief summary of what landed. If a genuine cross-cutting concern surfaces (e.g. invariant drift across commits the per-task reviewers couldn't see), flag it inline in your summary rather than spinning up another agent for it.

This applies specifically when per-task reviews were already done; the rule does NOT relax review rigor for tasks where reviewers weren't dispatched.

**Also skip the per-task _code-quality_ (second) stage for pure documentation changes.** Confirmed in-session (2026-06-03, the zsh prompt-plugin work): on a docs-only task (README + CLAUDE.md + file-care + changelog), the spec-compliance reviewer already verifies markup validity, structure-matching, factual accuracy, and "only-intended-files-changed" — the user interrupted the follow-up code-quality agent as redundant. So for tasks that only touch prose/docs (no code, no shell logic, no templates with behavior), run the spec-compliance review and then stop; do not dispatch the code-quality stage. Code/logic/template tasks still get BOTH stages — and the code-quality stage earned its keep this session by catching a real bug (fzf-tab not inheriting `FZF_DEFAULT_OPTS` without `use-fzf-default-opts yes`), so keep it for anything executable.

Also consider [[also auto-commit-everything-routinely]] — already in MEMORY.md — same general "less ceremony" philosophy.
