---
name: feedback-commit-claude-dir-routinely
description: Standing instruction — every file under `.claude/` in this project (settings.json, settings.local.json, memory/*) is regular tracked content. Commit changes alongside the work that produced them, never defer as "session drift".
metadata:
  type: feedback
---

Files under `.claude/` at the repo root are not gitignored, not excluded, not "session-state". They are normal tracked source-control content. Treat them like any other tracked file:

- When a `/plugin` toggle or `/config` change modifies `.claude/settings.json`, include that change in the next commit (or its own `chore(claude): ...` commit), not in an "end-of-session cleanup".
- When the harness auto-extends `.claude/settings.local.json` with new prompt allowlist entries, commit those too — they encode hard-won "this command is read-only enough to allow" decisions that should sync across machines.
- When new memory files land under `.claude/memory/`, commit them with the work that motivated saving them.

**Why:** Stated by the user on 2026-05-25. Claude Code permissions, plugin enablements, and saved memories should sync across every machine that clones this repo. Letting them sit dirty in working trees defeats the cross-host parity the rest of chezmoi gives. The user explicitly asked to "mark as non-ignored and actually begin committing changes" — the file was never gitignored, but my behavioral pattern of deferring its commits had the same effect.

**How to apply:**
- Default behavior: any time `git status` shows a `.claude/*` modification — stage and commit it. Don't ask first (combines with [[feedback-always-push-after-commit]] — commit + push).
- Bundle with adjacent work where the change is causal (e.g. session permission allowlist entries get added because of new commands run during a feature commit — bundle them).
- If commits get too noisy, group with a single `chore(claude): ...` commit at logical breakpoints (e.g. end of a multi-task work cycle), but never leave the tree dirty across cycles.
- Exception: if the user explicitly says "don't commit settings yet", respect that for the current task only — the standing rule resumes on the next.
- Audit on file scope: this rule covers `.claude/settings.json`, `.claude/settings.local.json`, `.claude/memory/**`. Does NOT cover user-home `~/.claude/` files (those are tracked separately via chezmoi).
