# Workstation TUI — Phase 5 (Dotfiles + Fleet Panels) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the two mutation-heavy panels: Dotfiles (pending list + live per-file diff + git state; apply/update/re-add/full-diff, always diff→confirm→`--force`) and Fleet (probed hosts table; ssh, push one/all, add/edit/remove through manage-hosts) — plus the one prerequisite repo change: a non-interactive `--remove` for the manage-hosts parity pair.

**Architecture:** New core readers/builders stay Textual-free (`gitstate.py`, `fleet.py`, `chezmoi.py` additions); two generic widgets (`ConfirmModal`, `TextViewScreen`) plus a `HostFormModal`; `launch_task` grows log routing (`log_to`) and a sequential variant (`run_task_sequence`) for edit=remove+add; panels replace their placeholders with fully injectable providers so Pilot tests never touch chezmoi/ssh/make/scripts.

**Tech Stack:** Python ≥3.14, asyncio, Textual 8.x, pydantic v2, pytest + pytest-asyncio, uv, bash + PowerShell (manage-hosts parity pair).

**Spec:** `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` §screens (Dotfiles, Fleet), §Execution engine (reuse). **Scope decision recorded:** `[e]` edit ships as remove+add (two sequential runner tasks) — hosts.conf rows are 4 plain fields, a true in-place edit primitive isn't worth a third script surface.

## Global Constraints

- Branch: `feat/workstation-tui-phase5` (created off main). Push after every commit. PR targets main.
- `manage-hosts.sh` ↔ `manage-hosts.ps1` are a PARITY PAIR — the non-interactive remove lands in BOTH in ONE commit. `.sh` stays LF/100755/shfmt/shellcheck-clean; `.ps1` keeps its UTF-8 BOM. NO new flag tokens (reuse `--name`/`--skip-confirm`), so the completions-parity invariant needs no changes — verify lint stays green.
- The TUI NEVER writes hosts.conf — all mutations shell out to manage-hosts; all pushes shell out to update-hosts.sh.
- chezmoi mutations: always diff → in-app confirm → `--force`; never a bare apply. `needs_sudo=False` for every chezmoi/fleet task.
- Rendering: subprocess-derived text `markup=False`; exception text `escape()`; dynamic notify text `markup=False`.
- Workers: task workers in `group="task"`; refresh in `group="summary"`; probes in `group="probes"` (exclusive within group).
- Tests: `cd tui && uv run pytest -q`; suite enters at 112 passed; env-independent (no ambient sudo/ssh/chezmoi-state dependence — inject everything).
- Pre-commit invariant hook stays green; never `--no-verify`. Conventional-commit subjects as given.
- Both scripts hardcode `HOSTS_CONF="$REPO_ROOT/hosts.conf"` — script tests use a SACRIFICIAL entry against the real tracked file and MUST leave `git diff hosts.conf` empty at the end.

---

### Task 1: Non-interactive `--remove` for the manage-hosts parity pair

**Files:**
- Modify: `scripts/manage-hosts.sh`
- Modify: `scripts/manage-hosts.ps1`
- Modify: `README.html` (§hosts CLI table/prose)
- Modify: `CLAUDE_CHANGELOG.md`

**Interfaces:**
- Produces: `manage-hosts.sh --remove [--name N] [--skip-confirm]` — with `--name`: validates existence (exit 1 + warn when absent), removes without prompting when `--skip-confirm`, else asks the existing y/N; without `--name`: existing interactive flow unchanged. `manage-hosts.ps1 -Remove [-Name N] [-SkipConfirm]` — identical semantics. Task 3's `manage_hosts_remove_command` relies on `--remove --name N --skip-confirm` exiting 0 on success, 1 on unknown host.

- [ ] **Step 1: Extend `remove_host()` in `manage-hosts.sh`**

Give it optional parameters (mirroring how `--add` parses its subflags). Change the signature to `remove_host() { local name="${1:-}" skip_confirm="${2:-false}"; ...}`: when `name` is empty, run the existing interactive body unchanged; when provided, skip `print_hosts`/`read -rp`, validate `host_exists "$name"` (absent → `warn` + `return 1`), then honor `skip_confirm` (true → remove without the y/N read; false → keep the confirm read). Wire the arg parser: the `--remove)` case gains a subflag loop identical in style to `--add)`'s, accepting `--name` and `--skip-confirm`, then calls `remove_host "$rm_name" "$rm_skip_confirm"`; propagate its return code to `exit`. Update the usage text line to `--remove [--name N --skip-confirm]`.

- [ ] **Step 2: Mirror in `manage-hosts.ps1`**

`Remove-HostEntry` gains `param([string]$HostName = "", [switch]$SkipConfirm)`-style optional inputs (match the file's existing parameter idioms); the `-Remove` dispatch passes the already-declared `-Name`/`-SkipConfirm` script params. Same semantics: absent name → interactive; unknown host → warning + exit 1; SkipConfirm bypasses the y/N. Update the .ps1 usage comment block.

- [ ] **Step 3: Docs**

README.html §hosts: extend the manage-hosts CLI documentation with the new non-interactive remove form (match the existing `--add` documentation style — find it via `rg -n 'skip-confirm' README.html`). CLAUDE_CHANGELOG.md: append row
`| manage-hosts non-interactive remove: --remove --name N --skip-confirm (.sh + .ps1 parity) — TUI fleet panel substrate | Yes | §hosts CLI docs gained the remove form |`

- [ ] **Step 4: Verify (sacrificial-entry roundtrip + hygiene)**

```bash
bash scripts/manage-hosts.sh --add --name zz-tui-test --ip 10.99.99.99 --user tester --group prod_machine --skip-confirm
bash scripts/manage-hosts.sh --remove --name zz-tui-test --skip-confirm
git diff --exit-code hosts.conf                      # MUST be empty
bash scripts/manage-hosts.sh --remove --name no-such-host --skip-confirm; echo "rc=$?"   # warn + rc=1
file scripts/manage-hosts.sh                         # no CRLF
git ls-files --stage scripts/manage-hosts.sh         # 100755
head -c3 scripts/manage-hosts.ps1 | xxd              # ef bb bf
make -C makefile lint MODE=prod                      # incl. completions parity — must stay green
```

- [ ] **Step 5: Commit (ONE commit — parity pair + docs)**

```bash
git add scripts/manage-hosts.sh scripts/manage-hosts.ps1 README.html CLAUDE_CHANGELOG.md
git commit -m "feat(hosts): non-interactive manage-hosts remove (--name/--skip-confirm, sh+ps1 parity)"
git push -u origin feat/workstation-tui-phase5
```

---

### Task 2: Git state reader + chezmoi additions

**Files:**
- Modify: `tui/src/workstation_tui/core/models.py` (append), `tui/src/workstation_tui/core/chezmoi.py`
- Create: `tui/src/workstation_tui/core/gitstate.py`
- Test: `tui/tests/test_gitstate.py`, `tui/tests/test_chezmoi.py` (append)

**Interfaces:**
- `GitState(BaseModel)`: `branch: str`, `dirty: bool`, `ahead: int`, `behind: int`.
- `gitstate.read_git_state(repo_root: Path, *, run=subprocess.run) -> tuple[GitState | None, list[str]]` — `git -C <root> status --porcelain=v2 --branch`, parses `# branch.head`, `# branch.ab +A -B` (missing ab line → 0/0), dirty = any non-`#` line; never raises (`(None, [error])`).
- `chezmoi.target_diff(path: str, *, run=subprocess.run) -> tuple[str, str | None]` — captured `chezmoi diff <path>` (30s timeout): `(stdout, None)` on rc 0, `("", error)` otherwise; `chezmoi.re_add_command(path: str) -> list[str]` = `["chezmoi", "re-add", path]`.

- [ ] **Step 1: Failing tests**

`tui/tests/test_gitstate.py`:

```python
import subprocess
from pathlib import Path

from workstation_tui.core.gitstate import read_git_state

PORCELAIN = """\
# branch.oid 2846240deadbeef
# branch.head main
# branch.upstream origin/main
# branch.ab +2 -1
1 .M N... 100644 100644 100644 abc def CLAUDE.md
"""


def _fake_run(stdout: str, rc: int = 0):
    def run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, rc, stdout=stdout, stderr="")
    return run


def test_parses_branch_ab_dirty(tmp_path: Path) -> None:
    state, errors = read_git_state(tmp_path, run=_fake_run(PORCELAIN))
    assert errors == []
    assert state.branch == "main"
    assert (state.ahead, state.behind) == (2, 1)
    assert state.dirty is True


def test_clean_no_upstream(tmp_path: Path) -> None:
    state, _ = read_git_state(
        tmp_path, run=_fake_run("# branch.oid x\n# branch.head main\n")
    )
    assert (state.ahead, state.behind) == (0, 0)
    assert state.dirty is False


def test_never_raises(tmp_path: Path) -> None:
    def run(cmd, **kwargs):
        raise FileNotFoundError("git")
    state, errors = read_git_state(tmp_path, run=run)
    assert state is None
    assert "git" in errors[0]


def test_real_repo(repo_root: Path) -> None:
    state, errors = read_git_state(repo_root)
    assert errors == []
    assert state.branch  # real checkout has a branch
```

Append to `tui/tests/test_chezmoi.py`:

```python
def test_target_diff_success_and_failure() -> None:
    from workstation_tui.core.chezmoi import re_add_command, target_diff

    def ok_run(cmd, **kwargs):
        assert cmd == ["chezmoi", "diff", ".zshrc"]
        return subprocess.CompletedProcess(cmd, 0, stdout="-old\n+new\n", stderr="")

    text, err = target_diff(".zshrc", run=ok_run)
    assert err is None and "+new" in text

    def bad_run(cmd, **kwargs):
        raise FileNotFoundError("chezmoi")

    text, err = target_diff(".zshrc", run=bad_run)
    assert text == "" and "chezmoi diff failed" in err
    assert re_add_command(".zshrc") == ["chezmoi", "re-add", ".zshrc"]
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** `models.py` append `GitState`; `gitstate.py`:

```python
"""Source-repo git state for the Dotfiles panel (never raises)."""

import subprocess
from pathlib import Path

from workstation_tui.core.models import GitState


def read_git_state(repo_root: Path, *, run=subprocess.run) -> tuple[GitState | None, list[str]]:
    try:
        proc = run(
            ["git", "-C", str(repo_root), "status", "--porcelain=v2", "--branch"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, [f"git status failed: {exc}"]
    if proc.returncode != 0:
        return None, [f"git status failed (rc={proc.returncode}): {proc.stderr.strip()}"]
    branch, ahead, behind, dirty = "?", 0, 0, False
    for line in proc.stdout.splitlines():
        if line.startswith("# branch.head "):
            branch = line.removeprefix("# branch.head ").strip()
        elif line.startswith("# branch.ab "):
            parts = line.removeprefix("# branch.ab ").split()
            ahead = int(parts[0].lstrip("+"))
            behind = int(parts[1].lstrip("-"))
        elif line and not line.startswith("#"):
            dirty = True
    return GitState(branch=branch, dirty=dirty, ahead=ahead, behind=behind), []
```

`chezmoi.py` additions: `target_diff` (mirror `read_status`'s never-raise shape, error string prefix `chezmoi diff failed`), `re_add_command`.

- [ ] **Step 4: Run to verify pass** — full suite `117 passed` (112 + 4 gitstate + 1 chezmoi). **Step 5: Commit** `feat(tui): git state reader + chezmoi target-diff/re-add builders`, push.

---

### Task 3: Fleet core — probes + command builders

**Files:**
- Create: `tui/src/workstation_tui/core/fleet.py`
- Test: `tui/tests/test_fleet.py`

**Interfaces:**
- `async probe_host(address: str, *, port: int = 22, timeout: float = 3.0) -> Literal["up", "down"]` — `asyncio.open_connection` with `asyncio.wait_for`; ANY exception → "down"; closes the socket on success.
- `async probe_all(entries: list[HostEntry], *, probe=probe_host) -> dict[str, str]` — name→state, gathered concurrently.
- `push_command(repo_root: Path, name: str | None) -> list[str]` — `[str(repo_root/"scripts/update-hosts.sh")]` + (`["--name", name]` when name given; bare = all hosts).
- `manage_hosts_add_command(repo_root: Path, entry: HostEntry, *, os_name: str = "linux") -> list[str]`; `manage_hosts_remove_command(repo_root: Path, name: str, *, os_name: str = "linux") -> list[str]` — linux: `["bash", str(script), "--add", "--name", …, "--skip-confirm"]` / `[..., "--remove", "--name", name, "--skip-confirm"]`; windows: `["powershell.exe", "-NoProfile", "-File", str(ps1), "-Add", "-Name", …, "-SkipConfirm"]` analog.

- [ ] **Step 1: Failing tests** — `tui/tests/test_fleet.py`:

```python
import asyncio
from pathlib import Path

from workstation_tui.core.fleet import (
    manage_hosts_add_command,
    manage_hosts_remove_command,
    probe_all,
    probe_host,
    push_command,
)
from workstation_tui.core.models import HostEntry

E = HostEntry(name="a", address="127.0.0.1", user="u", group="dev_machine")


async def test_probe_host_up_and_down() -> None:
    server = await asyncio.start_server(lambda r, w: w.close(), "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    assert await probe_host("127.0.0.1", port=port, timeout=2.0) == "up"
    server.close()
    await server.wait_closed()
    assert await probe_host("127.0.0.1", port=1, timeout=0.5) == "down"


async def test_probe_all_uses_injected_probe() -> None:
    async def fake_probe(address, *, port=22, timeout=3.0):
        return "up" if address == "127.0.0.1" else "down"

    entries = [E, HostEntry(name="b", address="10.0.0.9", user="u", group="prod_machine")]
    result = await probe_all(entries, probe=fake_probe)
    assert result == {"a": "up", "b": "down"}


def test_push_command(tmp_path: Path) -> None:
    assert push_command(tmp_path, "build-01")[-2:] == ["--name", "build-01"]
    assert push_command(tmp_path, None)[-1].endswith("update-hosts.sh")


def test_manage_hosts_commands(tmp_path: Path) -> None:
    add = manage_hosts_add_command(tmp_path, E)
    assert add[0] == "bash" and "--add" in add and "--skip-confirm" in add
    assert add[add.index("--name") + 1] == "a"
    rm = manage_hosts_remove_command(tmp_path, "a", os_name="windows")
    assert rm[0] == "powershell.exe" and "-Remove" in rm and "-SkipConfirm" in rm
```

- [ ] **Step 2: Verify failure. Step 3: Implement** (module docstring notes: TUI never writes hosts.conf — these builders are the ONLY mutation path, via the parity-pair scripts). **Step 4: verify pass** — `121 passed`. **Step 5: Commit** `feat(tui): fleet core — reachability probes + push/manage-hosts builders`, push.

---

### Task 4: Generic widgets — ConfirmModal + TextViewScreen + HostFormModal

**Files:**
- Create: `tui/src/workstation_tui/app/widgets/confirm_modal.py`, `.../text_view.py`, `.../host_form.py`
- Test: `tui/tests/test_widgets.py`

**Interfaces:**
- `ConfirmModal(ModalScreen[bool])` — `ConfirmModal(message: str, *, title: str = "confirm")`; renders message `markup=False`; keys `y`→dismiss(True), `n`/`escape`→dismiss(False).
- `TextViewScreen(ModalScreen[None])` — `TextViewScreen(text: str, *, title: str)`; scrollable (`VerticalScroll` + `Static(markup=False)`); `escape`/`q` dismisses.
- `HostFormModal(ModalScreen[HostEntry | None])` — `HostFormModal(*, initial: HostEntry | None = None)`; four Inputs (name/address/user) + group select (Input constrained: accept only `dev_machine`/`prod_machine`, default `prod_machine`); Enter on the last field / `ctrl+s` submits; validation: all fields non-empty + valid group, inline error `markup=False` otherwise; `escape` → dismiss(None). Prefills from `initial` (edit mode).

- [ ] **Step 1: Failing tests** — `tui/tests/test_widgets.py` (Host-app pattern from test_sudo_modal.py: `run_worker` + `push_screen_wait`; interact via `pilot.press`; query via `app.screen.query_one`):

```python
from textual.app import App

from workstation_tui.app.widgets.confirm_modal import ConfirmModal
from workstation_tui.app.widgets.host_form import HostFormModal
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.models import HostEntry


class Host(App):
    def __init__(self, screen_factory):
        super().__init__()
        self.screen_factory = screen_factory
        self.result = "UNSET"

    def on_mount(self) -> None:
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(self.screen_factory())


async def test_confirm_yes_and_no() -> None:
    app = Host(lambda: ConfirmModal("apply these changes? [/tricky] markup"))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("y")
        await pilot.pause()
    assert app.result is True

    app = Host(lambda: ConfirmModal("sure?"))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is False


async def test_text_view_dismisses() -> None:
    app = Host(lambda: TextViewScreen("line1\n[/not-markup]\nline3", title="diff"))
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is None


async def test_host_form_submit_and_validation() -> None:
    app = Host(lambda: HostFormModal())
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press(*"box1")          # name field focused first
        await pilot.press("tab")
        await pilot.press(*"10.0.0.5")
        await pilot.press("tab")
        await pilot.press(*"me")
        await pilot.press("tab")            # group field, default prod_machine kept
        await pilot.press("ctrl+s")
        await pilot.pause()
        await pilot.pause()
    assert app.result == HostEntry(name="box1", address="10.0.0.5", user="me",
                                   group="prod_machine")


async def test_host_form_rejects_bad_group_then_escape() -> None:
    app = Host(lambda: HostFormModal())
    async with app.run_test() as pilot:
        await pilot.pause()
        for _ in range(3):
            await pilot.press("x")
            await pilot.press("tab")
        await pilot.press(*"staging")       # invalid group
        await pilot.press("ctrl+s")
        await pilot.pause()
        error = str(app.screen.query_one("#host-form-error").content)
        assert "group" in error.lower()
        await pilot.press("escape")
        await pilot.pause()
    assert app.result is None


async def test_host_form_prefill() -> None:
    initial = HostEntry(name="old", address="1.2.3.4", user="u", group="dev_machine")
    app = Host(lambda: HostFormModal(initial=initial))
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.screen.query_one("#host-form-name").value == "old"
        await pilot.press("ctrl+s")
        await pilot.pause()
        await pilot.pause()
    assert app.result == initial
```

- [ ] **Step 2: Verify failure. Step 3: Implement** (theme-styled per sudo_modal.py precedent; ids `#host-form-name/-address/-user/-group`, error `#host-form-error`; ConfirmModal/TextViewScreen tiny). **Step 4: verify pass** — `126 passed`. **Step 5: Commit** `feat(tui): confirm/text-view/host-form modals`, push.

---

### Task 5: App plumbing — log routing + task sequences + new providers

**Files:**
- Modify: `tui/src/workstation_tui/app/app.py`
- Test: `tui/tests/test_task_routing.py`

**Interfaces:**
- `launch_task(command, *, needs_sudo=False, log_to: Callable[[str], None] | None = None, on_done: Callable[[], None] | None = None)` — `log_to=None` keeps the provision-panel default (all existing tests stay green); `on_done` runs after the refresh (panels reload their own data).
- `run_task_sequence(commands: list[list[str]], *, log_to=None, on_done=None)` — runs the commands one after another through the SAME gate/refusal machinery (`_task_inflight` held across the whole sequence); aborts the rest on first non-zero rc (notify `sequence aborted (rc=N)` severity error, markup-safe).
- Constructor grows injectable providers for the new panels: `pending_provider=read_status`, `git_state_provider=read_git_state`, `target_diff_fn=target_diff`, `probe_all_fn=probe_all`, `ssh_fn=None` (None → real suspend+ssh; tests inject a recorder).
- `_apply_summary` continues feeding provision; dotfiles/fleet panels get their data via their own `refresh_panel()` methods (Tasks 6-7) called from `action_refresh`'s worker via `call_from_thread` — but ONLY reads that are cheap; probes run in their own `group="probes"` async worker.

- [ ] **Step 1: Failing tests** — `tui/tests/test_task_routing.py`:

```python
from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import TaskResult
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(runner=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
    )


async def test_log_to_routes_lines() -> None:
    app = make_app()
    captured: list[str] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["fake", "cmd"], log_to=captured.append)
        for _ in range(4):
            await pilot.pause()
    assert any("fake output" in line for line in captured)
    assert any("$ fake cmd" in line for line in captured)


async def test_sequence_runs_in_order_and_aborts_on_failure() -> None:
    class ScriptedRunner(FakeRunner):
        def __init__(self):
            super().__init__()
            self.rcs = [0, 3, 0]

        async def run(self, command, on_line):
            self.commands.append(command)
            on_line("out")
            return TaskResult(command=command, returncode=self.rcs[len(self.commands) - 1],
                              duration_secs=0.0)

    runner = ScriptedRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.run_task_sequence([["one"], ["two"], ["three"]], log_to=lambda _: None)
        for _ in range(6):
            await pilot.pause()
    assert runner.commands == [["one"], ["two"]]  # third never ran (rc=3 aborted)


async def test_on_done_called() -> None:
    app = make_app()
    done: list[bool] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        app.launch_task(["x"], log_to=lambda _: None, on_done=lambda: done.append(True))
        for _ in range(4):
            await pilot.pause()
    assert done == [True]
```

- [ ] **Step 2: Verify failure. Step 3: Implement** — refactor `_task_flow(command, needs_sudo, log_to, on_done)`; extract the gate into `async _sudo_gate(needs_sudo) -> bool`; `run_task_sequence` = new async worker holding `_task_inflight` for the whole span, calling `_sudo_gate` once (sequences are never sudo in this phase — assert/ignore), looping commands via `self._runner.run(cmd, log_cb)`. Existing provision behavior byte-compatible (default log_to = provision panel). **Step 4: verify pass** — `129 passed` and ALL prior tests green. **Step 5: Commit** `feat(tui): task log routing, sequences, panel providers`, push.

---

### Task 6: Dotfiles panel

**Files:**
- Create: `tui/src/workstation_tui/app/panels/dotfiles.py`
- Modify: `tui/src/workstation_tui/app/app.py` (swap placeholder; wire refresh)
- Test: `tui/tests/test_dotfiles_panel.py`

**Interfaces:**
- `DotfilesPanel(Static)` id `#dotfiles`: left `DataTable` (`#dotfiles-table`: code, path) of pending changes; right `VerticalScroll`>`Static` (`#dotfiles-diff`, markup=False) showing the highlighted file's captured diff (fetched via thread worker on cursor move, exclusive `group="dotfiles-diff"`); bottom git line `#dotfiles-git` (`branch · clean/dirty · ↑A ↓B`, themed) + key bar + `log_lines` mirror + small RichLog (`#dotfiles-log`, markup=False, max_lines=5000).
- Bindings: `a` apply (ConfirmModal("apply N pending changes?") → `launch_task(apply_command(), log_to=panel, on_done=panel refresh)`), `U` update (confirm → `update_command()`), `A` re-add selected (confirm → `re_add_command(path)`), `d` full diff (captured `chezmoi diff` via thread worker → `TextViewScreen`).
- `refresh_panel()` reloads pending list + git state via app providers (thread worker `group="dotfiles-refresh"`); `set_unavailable(msg)` when `not context.has_chezmoi` (single-shot, guarded against re-log — the Phase-4 parked lesson).
- App: swap placeholder; `_apply_summary` triggers `panel.refresh_panel()` and unavailable-gating mirrors provision's has_make pattern (guard: only on availability CHANGE, to avoid duplicate logs).

- [ ] **Step 1: Failing tests** — `tui/tests/test_dotfiles_panel.py` (all providers injected; FakeRunner):

```python
from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import GitState, PendingChange
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider

PENDING = [PendingChange(code="MM", path=".zshrc"),
           PendingChange(code=" A", path=".config/new")]
GIT = GitState(branch="main", dirty=False, ahead=1, behind=0)


def make_app(runner=None, pending=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        pending_provider=lambda: (pending if pending is not None else PENDING, []),
        git_state_provider=lambda root: (GIT, []),
        target_diff_fn=lambda path: (f"--- {path}\n+new line\n", None),
    )


async def test_pending_table_and_git_line() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        table = app.query_one("#dotfiles-table")
        assert table.row_count == 2
        git_text = str(app.query_one("#dotfiles-git").content)
        assert "main" in git_text and "1" in git_text


async def test_cursor_shows_target_diff() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        diff_text = str(app.query_one("#dotfiles-diff").content)
        assert ".zshrc" in diff_text and "+new line" in diff_text


async def test_apply_flow_confirm_then_force() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#dotfiles-table").focus()
        await pilot.press("a")
        await pilot.pause()
        await pilot.press("y")          # ConfirmModal
        for _ in range(4):
            await pilot.pause()
    assert ["chezmoi", "apply", "--force"] in runner.commands


async def test_apply_declined_never_runs() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#dotfiles-table").focus()
        await pilot.press("a")
        await pilot.pause()
        await pilot.press("escape")
        for _ in range(3):
            await pilot.pause()
    assert runner.commands == []


async def test_re_add_selected() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#dotfiles-table").focus()
        await pilot.press("A")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert ["chezmoi", "re-add", ".zshrc"] in runner.commands


async def test_in_sync_message() -> None:
    app = make_app(pending=[])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        assert any("in sync" in l for l in app.query_one("#dotfiles").log_lines)
```

- [ ] **Step 2: Verify failure. Step 3: Implement** per the Interfaces block (styling per provision.py precedent; horizontal split via the theme's `.h-split`; diff fetch worker guards against cursor-move floods with `exclusive=True` in its group). **Step 4: verify pass** — `135 passed`, all priors green. **Step 5: Commit** `feat(tui): dotfiles panel — pending, live diff, git line, apply/update/re-add`, push.

---

### Task 7: Fleet panel

**Files:**
- Create: `tui/src/workstation_tui/app/panels/fleet.py`
- Modify: `tui/src/workstation_tui/app/app.py` (swap placeholder; wire probes + ssh seam)
- Test: `tui/tests/test_fleet_panel.py`

**Interfaces:**
- `FleetPanel(Static)` id `#fleet`: `DataTable` `#fleet-table` (probe glyph via HOST_ICONS — "unknown" until probed, name, address, user, group); RichLog `#fleet-log` (markup=False, max_lines=5000) + `log_lines` mirror; key bar.
- Bindings: `s` ssh to selected (`app.ssh_to(entry)` — real impl: `with self.suspend(): subprocess.run(["ssh", f"{user}@{address}"])`; tests inject `ssh_fn` recorder), `p` push selected (ConfirmModal → `launch_task(push_command(root, name), log_to=panel)`), `P` push all (ConfirmModal("push ALL hosts?") → `push_command(root, None)`), `a` add (HostFormModal → confirm-free → `launch_task(manage_hosts_add_command(...), on_done=reload hosts)`), `e` edit (HostFormModal(initial=selected) → `run_task_sequence([remove_command(old name), add_command(new entry)], on_done=reload)`), `x` remove (ConfirmModal(f"remove {name}?") → remove command).
- Probing: on panel entry + refresh, async worker `group="probes"` runs `probe_all_fn(entries)`; results update glyphs (call_from_thread not needed — async worker is on-loop).
- Hosts data: `read_hosts` via an injectable `hosts_provider` app ctor param (default real); reload after mutations via `on_done`.

- [ ] **Step 1: Failing tests** — `tui/tests/test_fleet_panel.py`:

```python
from workstation_tui.app.app import WorkstationApp
from workstation_tui.core.models import HostEntry
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider

HOSTS = [
    HostEntry(name="alpha", address="10.0.0.1", user="u", group="dev_machine"),
    HostEntry(name="beta", address="10.0.0.2", user="u", group="prod_machine"),
]


async def fake_probe_all(entries, **kwargs):
    return {e.name: ("up" if e.name == "alpha" else "down") for e in entries}


def make_app(runner=None, ssh_calls=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        hosts_provider=lambda: (HOSTS, []),
        probe_all_fn=fake_probe_all,
        ssh_fn=(ssh_calls.append if ssh_calls is not None else None),
    )


async def test_table_lists_hosts_with_probe_glyphs() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        table = app.query_one("#fleet-table")
        assert table.row_count == 2


async def test_ssh_selected() -> None:
    calls: list = []
    app = make_app(ssh_calls=calls)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("s")
        await pilot.pause()
    assert calls and calls[0].name == "alpha"


async def test_push_selected_confirms_then_runs() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("p")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert runner.commands and runner.commands[0][-2:] == ["--name", "alpha"]


async def test_push_all_declined() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("P")
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
    assert runner.commands == []


async def test_add_host_via_form() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("a")
        await pilot.pause()
        await pilot.press(*"gamma")
        await pilot.press("tab")
        await pilot.press(*"10.0.0.3")
        await pilot.press("tab")
        await pilot.press(*"me")
        await pilot.press("ctrl+s")
        for _ in range(5):
            await pilot.pause()
    assert runner.commands
    cmd = runner.commands[0]
    assert "--add" in cmd and "gamma" in cmd and "--skip-confirm" in cmd


async def test_remove_host_confirmed() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("x")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert runner.commands and "--remove" in runner.commands[0]


async def test_edit_host_runs_remove_then_add() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("e")
        await pilot.pause()
        await pilot.press("ctrl+s")      # prefilled form, unchanged submit
        for _ in range(6):
            await pilot.pause()
    assert len(runner.commands) == 2
    assert "--remove" in runner.commands[0] and "--add" in runner.commands[1]
```

- [ ] **Step 2: Verify failure. Step 3: Implement.** `app.ssh_to(entry)`: injected `ssh_fn` when provided; real path = `with self.suspend(): subprocess.run(["ssh", f"{entry.user}@{entry.address}"])` in a plain method (document that Textual's suspend context requires a real TTY — headless tests always inject). **Step 4: verify pass** — `142 passed`. **Step 5: Commit** `feat(tui): fleet panel — probes, ssh, push, add/edit/remove`, push.

---

### Task 8: Docs + gate + PR

- [ ] **Step 1: CLAUDE_CHANGELOG.md** — append AT THE END:
`| workstation TUI Phase 5: Dotfiles panel (pending/diff/git, apply-update-re-add) + Fleet panel (probes/ssh/push/add-edit-remove via manage-hosts) | No | §hosts remove form documented in phase-5 Task 1; README §tui still lands with the final phase |`

- [ ] **Step 2: Full gate**

```bash
make -C makefile lint MODE=prod
make -C makefile tui-test MODE=prod     # expect 142 passed
bash scripts/check-templates.sh
git diff --exit-code hosts.conf         # sacrificial entries never leaked
```

- [ ] **Step 3: Commit + PR** — `docs: phase-5 changelog row`; PR body summarizing the two panels + the manage-hosts parity extension; `gh pr checks --watch`. Hand to the user (interactive smokes: dotfiles apply flow + fleet ssh/push need a real terminal).
