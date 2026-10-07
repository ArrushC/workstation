---
name: workstation-tui-removed
description: The workstation TUI (Textual control panel + headless CLI) was removed 2026-09-06 by user decision — do not re-propose it
metadata:
  type: project
---

Removed 2026-09-06 by user decision: "using the tui for this workstation is causing more maintainability and unnecessary complexity." The TUI had shipped v1-complete (2026-08-07, six phases) and gone through a full post-v1 roadmap (Phases A-C, plus a Phase D fallback) — none of that mattered to the call; the decision was cost/complexity vs. value, not a defect.

**What stayed:** `python-env` remains a BOTH-SCOPES step (now `scripts/lib/python-env.sh` via `mise run python-env`, + `bootstrap.ps1`'s `Invoke-PythonEnv`) building the blessed uv-managed Python venv with its ad-hoc scripting libs (Textual, Click, rich, httpx, pydantic, typer, polars, duckdb) and the `wpy`/`textual`/`typer` launchers, on every host. Only the TUI-specific pieces were cut.

**DO NOT re-propose a TUI / Textual control panel for this repo.** If a future request sounds like "let's build a dashboard/control-panel/TUI for workstation," surface this decision first rather than treating it as a fresh idea.
