---
name: workstation-tui-removed
description: The workstation TUI (Textual control panel + headless CLI) was removed 2026-09-06 by user decision — do not re-propose it
metadata:
  type: project
---

Removed 2026-09-06 by user decision: "using the tui for this workstation is causing more maintainability and unnecessary complexity." The TUI had shipped v1-complete (2026-08-07, six phases) and gone through a full post-v1 roadmap (Phases A-C, plus a Phase D fallback) — none of that mattered to the call; the decision was cost/complexity vs. value, not a defect.

**What was removed** (five commits on `chore/remove-tui`):
1. `tui/` — the whole package (src + tests + pyproject.toml + pyrightconfig.json, 97 files) — plus the Click-generated zsh completion stub `chezmoi/dot_config/zsh/completions/_workstation`.
2. The install/launcher/CI wiring: `makefile/lib/python-env.sh`'s editable `tui/` install and `workstation` launcher symlink; `bootstrap.ps1`'s `Invoke-PythonEnv` editable install step and `workstation.cmd` shim; `scripts/check-invariants.sh`'s `check_tui_install_parity`; the `.claude/hooks/parity-reminder.sh` tui clauses; `makefile/Makefile`'s `tui-test` target; the `.github/workflows/lint.yml` `tui-tests` job.
3. Docs: the entire README.html §tui section (nav entry, body, 4 TUI-specific troubleshooting entries), the CLAUDE.md doc-pointer row and python-env sentences naming the TUI, the `docs/claude/invariants.md`/`file-care.md` TUI clauses in the python-env entries. One `CLAUDE_CHANGELOG.md` row records the removal (history rows for the TUI's build-out stay — that file is the archive, not something to rewrite).
4. The 17 superpowers spec/plan docs under `docs/superpowers/{plans,specs}/` for every TUI phase (2026-08-05 through 2026-08-11).
5. This memory: `.claude/memory/project-workstation-tui-phase2-carryforwards.md` (the TUI's post-v1 backlog) is gone; this file replaces it as the pointer to what happened.

**What stayed:** `python-env` remains a BOTH-SCOPES bespoke target (`makefile/lib/python-env.sh` + `bootstrap.ps1`'s `Invoke-PythonEnv`) building the blessed uv-managed Python venv with its ad-hoc scripting libs (Textual, Click, rich, httpx, pydantic, typer, polars, duckdb) and the `wpy`/`textual`/`typer` launchers, on both dev_machine and prod_machine. Only the TUI-specific pieces (editable `tui/` install, `workstation` launcher/shim) were cut — the general-purpose scripting env is untouched and still ships Textual as a library for ad-hoc scripts.

**DO NOT re-propose a TUI / Textual control panel for this repo.** If a future request sounds like "let's build a dashboard/control-panel/TUI for workstation," surface this decision first rather than treating it as a fresh idea.

**Host-side effects of the removal (matters for anyone verifying a live host, or debugging "why did my venv rebuild"):**
- `python-env.sh`'s stamp is `cksum`-keyed on the script's own content, so removing the editable-install lines changes the stamp filename — the next `make provision` (or `make python-env`) rebuilds the venv from scratch, now without the `tui/` package.
- The script self-heals two stale artifacts from earlier provisions: `rm -f ~/.local/bin/workstation` (the old launcher symlink) and `rm -rf ~/.cache/workstation-tui` (the TUI's health/updates/history caches) — both run unconditionally on every `python-env.sh` invocation, dev and prod.
- `bootstrap.ps1`'s `Invoke-PythonEnv` similarly self-heals `%LOCALAPPDATA%\workstation\bin\workstation.cmd` via `Remove-Item -ErrorAction SilentlyContinue`.
- Nothing else on a host needs manual cleanup — no service, no cron, no systemd unit was TUI-owned.

**Where the code still lives:** nowhere in the working tree as of this removal, but full git history holds it — PRs #116-#127 (v1 build-out, six phases) and #141-#143 (Phase C + the Phase D fallback) on `main`, plus the five `chore/remove-tui` commits that took it back out. `git log --all --grep='(tui)' -i` finds the whole arc if it's ever needed for reference (e.g. reviving one specific idea from the post-v1 backlog outside a TUI context).
