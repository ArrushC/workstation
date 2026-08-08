# TUI Feedback Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the five live-usage fixes/features: chezmoi path absolutization, health summary hygiene, fleet setup probe, dynamic footer keys, and working tab completion.

**Architecture:** Core fixes stay Textual-free (`chezmoi.py` builders, `health.py` summary picking, `fleet.py` two-stage probe); the footer becomes app-owned state re-rendered by `switch_panel` from a static per-panel key registry; completion is a deploy-and-verify operation with an in-repo stub fix only if verification demands it.

**Tech Stack:** Python ≥3.14, Textual 8.x, asyncio, pytest + pytest-asyncio, zsh (completion verify), chezmoi.

**Spec:** `docs/superpowers/specs/2026-08-07-tui-feedback-batch-design.md`.

## Global Constraints

- Branch: `feat/tui-feedback-batch` (created off main; spec committed). Push after every commit. PR targets main.
- Core never imports textual; readers/probes never raise; dynamic text markup-inert (`Text()` cells, `markup=False` notifies).
- No real ssh/chezmoi mutations in the test suite — inject everything. The completion DEPLOY step is the one sanctioned `$HOME` mutation (a pending ` A`-state add, prompt-free, targeted).
- Suite enters at 177 passed; existing tests that pin now-changed argv/content are updated MINIMALLY and every adjustment listed in reports.
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.

---

### Task 1: Chezmoi path absolutization + health summary hygiene

**Files:**
- Modify: `tui/src/workstation_tui/core/chezmoi.py`, `tui/src/workstation_tui/core/health.py` (summary pick), `tui/src/workstation_tui/app/panels/health.py` (summary render + record pick)
- Test: `tui/tests/test_chezmoi.py` (adjust + add), `tui/tests/test_health_panel.py` (add)

**Interfaces:**
- `target_diff(path, ...)` builds `["chezmoi", "diff", str(Path.home() / path)]`; `re_add_command(path)` → `["chezmoi", "re-add", str(Path.home() / path)]`. Docstrings state WHY (chezmoi resolves relative targets against CWD; status paths are destDir-relative — reproduced live 2026-08-07).
- Health summary pick (in `panels/health.py` `_record_result`): last line that is non-empty after `.strip()` AND doesn't start with `"$ "`; store `line.strip()[:80]`.
- Health summary render: `Text(summary.strip(), no_wrap=True, overflow="ellipsis")` (display-time strip covers pre-fix cached entries).

- [ ] **Step 1: Failing/adjusted tests.** In `test_chezmoi.py`: update `test_target_diff_success_and_failure`'s argv assertion to `["chezmoi", "diff", str(Path.home() / ".zshrc")]` (import Path) and the `re_add_command` assertion likewise; add:

```python
def test_target_paths_absolutized_against_home() -> None:
    from pathlib import Path

    from workstation_tui.core.chezmoi import re_add_command, target_diff

    captured = {}

    def run(cmd, **kwargs):
        captured["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    target_diff(".claude/settings.json", run=run)
    assert captured["cmd"][2] == str(Path.home() / ".claude/settings.json")
    assert re_add_command(".claude/settings.json")[2] == str(
        Path.home() / ".claude/settings.json"
    )
```

In `test_health_panel.py` add:

```python
async def test_summary_skips_command_echo_and_strips(tmp_path: Path) -> None:
    from workstation_tui.core.health import load_cache
    from workstation_tui.core.models import TaskResult

    class EchoRunner(FakeRunner):
        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("  padded real output  ")
            on_line("")                      # trailing blank
            return TaskResult(command=command, returncode=0, duration_secs=0.1)

    app = make_app(tmp_path, EchoRunner())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("5")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#health-table").focus()
        await pilot.press("enter")
        for _ in range(6):
            await pilot.pause()
    cached = load_cache(tmp_path / "health.json")
    assert cached["doctor"].summary == "padded real output"   # stripped, not "$ ..." echo
```

- [ ] **Step 2: Verify failures → implement → full suite** (REAL count; expect 179). **Step 3: Commit** `fix(tui): absolutize chezmoi target paths + health summary hygiene`, push.

---

### Task 2: Fleet two-stage setup probe

**Files:**
- Modify: `tui/src/workstation_tui/core/fleet.py`, `tui/src/workstation_tui/app/theme.py` (SETUP_ICONS), `tui/src/workstation_tui/app/panels/fleet.py` (column + render), `tui/src/workstation_tui/app/app.py` (only if the probe_all injectable's type hint needs updating)
- Test: `tui/tests/test_fleet.py` (add + adjust), `tui/tests/test_fleet_panel.py` (adjust fakes)

**Interfaces:**
- `async probe_setup(entry: HostEntry, *, timeout: float = 6.0, exec_fn=asyncio.create_subprocess_exec) -> Literal["setup", "missing", "ssh-failed"]` — argv exactly `["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", f"{entry.user}@{entry.address}", "--", "test", "-d", ".local/share/chezmoi"]`, stdout/stderr → DEVNULL, `asyncio.wait_for(proc.wait(), timeout)`; rc 0 → setup, rc 1 → missing, anything else / timeout (kill the child first) / exception → ssh-failed. Never raises.
- `probe_all(entries, *, probe=probe_host, setup_probe=probe_setup) -> dict[str, tuple[str, str | None]]` — per host concurrently: TCP stage → "down" ⇒ `("down", None)`; "up" ⇒ run setup stage ⇒ `("up", state)`.
- Theme: `SETUP_ICONS = {"setup": ("✓", M["green"]), "missing": ("○", M["yellow"]), "ssh-failed": ("✗", M["red"]), "unknown": ("—", M["overlay0"])}`.
- Fleet panel: `probe_states` holds the tuple; table gains a `setup` column (glyph via `icon(state or "unknown", SETUP_ICONS)`) next to the reachability glyph; unprobed rows show `—`/`—`.

- [ ] **Step 1: Failing tests.** `test_fleet.py` add: state-machine test with a fake exec_fn returning scripted rcs (0/1/255) + a timeout case (fake proc whose wait never resolves — use an `asyncio.Event` that's never set, and assert "ssh-failed" with the kill called; keep it simple: a fake process object with `wait()` awaiting `asyncio.sleep(10)` and `kill()` recording, `timeout=0.1`); argv-shape assertion; `probe_all` composition test (down host → `("down", None)`, up host → `("up", "setup")` via injected fakes). `test_fleet_panel.py`: update `fake_probe_all` to the tuple shape; assert the table's new column count / a `setup` glyph presence via row data.
- [ ] **Step 2: Verify failures → implement → full suite** (expect ~183). **Step 3: Commit** `feat(tui): fleet workstation-setup probe (two-stage, batchmode ssh)`, push.

---

### Task 3: Dynamic footer keys

**Files:**
- Modify: `tui/src/workstation_tui/app/app.py` (PANEL_KEYS registry + footer re-render in switch_panel), `tui/src/workstation_tui/app/panels/provision.py`, `dotfiles.py`, `fleet.py`, `health.py` (remove in-panel key lines)
- Test: `tui/tests/test_footer_keys.py`

**Interfaces:**
- `PANEL_KEYS: dict[str, list[tuple[str, str]]]` beside `PANELS`: dashboard `[("←→↑↓", "Move"), ("enter", "Open")]`, provision `[("r", "Run"), ("c", "Clean"), ("u", "Updates"), ("R", "Provision"), ("x", "Cancel")]`, dotfiles `[("a", "Apply"), ("U", "Update"), ("A", "Re-add"), ("d", "Diff")]`, fleet `[("s", "SSH"), ("p", "Push"), ("P", "Push all"), ("a", "Add"), ("e", "Edit"), ("x", "Remove")]`, health `[("enter", "Run"), ("R", "Run all"), ("o", "Log")]`.
- `_render_key_bar(panel_id)` → `kb(GLOBAL_KEYS + PANEL_KEYS[panel_id])` where `GLOBAL_KEYS = [("1-5", "Panels"), ("ctrl+←/→", "Cycle"), ("g", "Refresh"), ("q", "Quit"), ("?", "Help")]`; called from `switch_panel` and once at mount.
- In-panel key-hint Statics (`#provision-keys` + the dotfiles/fleet/health kb() lines) and their CSS blocks are deleted; compose flows unchanged otherwise.

- [ ] **Step 1: Failing tests.** `test_footer_keys.py`: boot → footer contains "Move" and "Help"; press 2 → contains "Provision"-panel keys ("Clean") and NOT "Move"; press 4 → contains "Push all"; assert `app.query("#provision-keys")` is empty (removed). Existing suites must stay green — panels' rendered_text/log assertions don't reference the key lines (verify with rg before assuming; adjust minimally if one does, list it).
- [ ] **Step 2: Verify failures → implement → full suite** (expect ~186). **Step 3: Commit** `feat(tui): dynamic footer shows active-panel keys`, push.

---

### Task 4: Tab completion deploy + verify + docs + gate

**Files:**
- Possibly modify: `chezmoi/dot_config/zsh/completions/_workstation` (ONLY if verification fails)
- Modify: `README.html` (§tui: footer sentence, fleet setup-column sentence, completion troubleshooting entry), `CLAUDE_CHANGELOG.md`

- [ ] **Step 1: Deploy the pending completion** — `chezmoi apply ~/.config/zsh/completions/_workstation` (verify beforehand via `chezmoi status` that the file is ` A` state; afterwards `chezmoi status` must no longer list it; the `MM .claude/settings.json` line must be untouched).
- [ ] **Step 2: Verify the completer pipeline** (deterministic, scriptable): `env _WORKSTATION_COMPLETE=zsh_complete COMP_WORDS="workstation " COMP_CWORD=1 ~/.local/bin/workstation` must emit the subcommand list (Click's completion protocol). Then verify shell wiring end-to-end with zpty:

```zsh
zsh -f -c '
source ~/.zshrc 2>/dev/null || { fpath=(~/.config/zsh/completions $fpath); autoload -Uz compinit; compinit -C; }
zmodload zsh/zpty
zpty z zsh -f -i
zpty -w z "fpath=(~/.config/zsh/completions \$fpath); autoload -Uz compinit; compinit -C"
zpty -w z "workstation \t"
sleep 1
zpty -r z out; print -r -- $out
'
```

(Adapt as needed — zpty scripting is finicky; the REQUIRED outcome is documented evidence that completing `workstation <TAB>` offers subcommands, or a root-caused stub fix. If the stub needs fixing, fix it in `chezmoi/dot_config/zsh/completions/_workstation`, re-apply, re-verify — and note the repo file is the source of truth.)
- [ ] **Step 3: Docs** — README §tui: (a) footer sentence ("the bottom bar shows the active panel's keys after the global set"), (b) fleet setup-column sentence (two-stage probe, BatchMode, the four states), (c) troubleshooting `<details>` entry: completion not working → the file deploys via chezmoi; `czs` shows it pending until `cza`/dotfiles-apply runs. CLAUDE_CHANGELOG row: `| TUI feedback batch: chezmoi path fix (CWD-relative diff bug), health summary hygiene, fleet setup probe, dynamic footer keys, tab-completion deploy+verify | Yes | §tui footer/fleet sentences + completion troubleshooting entry |`
- [ ] **Step 4: Gate** — `make -C makefile lint MODE=prod && make -C makefile tui-test MODE=prod && bash scripts/check-templates.sh`; live smokes `workstation status`, and re-verify `chezmoi status` shows only the settings.json MM line.
- [ ] **Step 5: Commit** `docs: feedback-batch README sentences + changelog` (+ any stub fix in its own prior commit `fix(completions): ...`), push. PR `fix(tui): feedback batch — chezmoi paths, footer keys, setup probe, summary hygiene, completions` to main; `gh pr checks --watch`. Hand to the user (interactive smoke: dotfiles diff from any cwd, footer keys, fleet setup column, `workstation <TAB>` in a NEW shell).
