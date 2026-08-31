---
name: feedback-recommend-dont-poll
description: When the user asks for options or "lots of questions", lead with a decided recommendation + reasoning, not an AskUserQuestion menu
metadata:
  type: feedback
---

Even when the user explicitly invites questions ("Do ask me as many questions as
possible"), they usually want **decisions with reasoning**, not a multiple-choice
menu to fill in. On the 2026-08-31 zellij work they asked for maximum questions,
were shown a 4-question `AskUserQuestion` (mauve scope, UI background, status
bar, keybind conflict), answered exactly one, and replied: *"I want you to
recommend me."*

**Why:** they are the sole operator of this repo and have deep context; being
polled on palette/config minutiae is slower than reading a recommendation they
can override. The invitation to ask questions is really an invitation to *raise
the issues* — not to hand the decisions back.

**How to apply:** do the research, then present a short decision table
(*decision → recommendation → why*) and proceed. Keep genuinely
consequential-and-reversible-only-at-cost choices visible by flagging them in the
plan with the revert cost ("`default_layout` is a one-line revert"), rather than
blocking on them. Reserve `AskUserQuestion` for forks where proceeding wrong
would waste substantial work. Pairs with [[feedback-skip-redundant-final-review]]
— both are about not spending the user's turns on ceremony.
