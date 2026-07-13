---
name: project-sdd-subagent-calibration
description: "Subagent-driven development on this repo — haiku implementers write byte-exact code from complete-code briefs but their REPORT narratives are unreliable (wrong metrics, one false self-check); keep sonnet reviewers even for docs tasks; project-prefix brief/report filenames."
metadata:
  type: project
---

Calibration data from running superpowers:subagent-driven-development across PRs #74–#79 (2026-07-11 → 2026-07-13):

- **haiku implementers + complete-code briefs work**: 7/7 transcription tasks produced byte-exact code (reviewers diffed against the briefs). Keep dispatching haiku when the plan contains the full code; sonnet floor only for prose-description tasks.
- **But haiku report NARRATIVES are unreliable**: three tasks self-reported wrong line counts/metrics, and one (PR #79 Task 5) made a **false self-check claim** — asserted the changelog row was "appended as last table row" when it was inserted mid-table. The code artifacts were still correct or the reviewer caught the miss.
- **Therefore**: never downgrade or skip the sonnet reviewer, even for docs-only (spec-only review) tasks — that spec-only review is what caught the false claim. Reviewers and the controller must verify placement/ordering/count constraints against the DIFF, never against the implementer's report.
- **Brief/report filenames must be project-prefixed** (`<project>-task-N-{brief,report}.md`, passed as the explicit OUTFILE to `task-brief`): the default `task-N-*.md` names COLLIDE across projects in `.superpowers/sdd/` — a stale same-named report from a previous project was nearly trusted during PR #76 Task 4.
- Useful reviewer-dispatch pattern that has repeatedly paid off: name the task's ONE legitimate outside-the-diff focused check in the dispatch (e.g. "you may live-run the read-only invariant check — its correctness IS the deliverable"); the PR #79 Task 4 reviewer used it to independently re-derive all flag sets and live-run the check.

**Why:** These are cross-project workflow facts that only lived in per-project ledgers (`.superpowers/sdd/progress.md`), which get overwritten every project and are git-ignored scratch.

**How to apply:** When executing any plan with superpowers:subagent-driven-development here: implementers haiku for complete-code briefs / sonnet for prose briefs; reviewers sonnet always; prefix brief/report files with the project slug; treat implementer reports as claims (verify constraints from the diff); follow [[feedback-skip-redundant-final-review]] for the review-stage shape and [[feedback-use-pr-review-workflow]] for landing the branch.
