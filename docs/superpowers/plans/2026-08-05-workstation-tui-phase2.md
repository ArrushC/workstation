# Workstation TUI — Phase 2 (Headless CLI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the starter set of headless `workstation` subcommands (`status`, `doctor`, `updates`, `provision`, `hosts list`, `dotfiles …`) as pure consumers of the Phase 1 core, plus the zsh completions stub — and clear the two carry-forward blockers before the CLI consumes those readers.

**Architecture:** New core modules (`chezmoi.py` readers/builders, `proc.py` passthrough runner, `summary.py` aggregator) stay Textual-free; `cli.py` grows Click subcommands that compose core calls and stream long-running commands straight to the terminal (no async engine — that's Phase 4's `runner.py` for the TUI). Mutations remain shell-outs to the existing single entry points; headless privileged commands let `make`'s own sudo prompt reach the terminal.

**Tech Stack:** Python ≥3.14, click, pydantic v2, pytest, uv, GNU Make, chezmoi.

**Spec:** `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` (§Headless CLI). Carry-forwards from Phase 1's final review: `.claude/memory/project-workstation-tui-phase2-carryforwards.md`.

## Global Constraints

- Branch: `feat/workstation-tui-phase2` (already created off `feat/workstation-tui`; the PR at the end targets `feat/workstation-tui` — it auto-retargets to main when PR #116 merges). Push after every commit.
- Nothing under `tui/src/workstation_tui/core/` may import `textual`.
- Core readers NEVER raise: every read returns `(data, errors)` or a model. Passthrough commands are the sanctioned exception — they stream inherited stdio and return an exit code.
- Mutating chezmoi flows: always diff → explicit y/N confirm → `--force` (chezmoi's own prompts must never fire; repo memory: non-interactive `chezmoi apply` hangs on overwrite prompts).
- `--mode` override exists ONLY on `provision` (spec); every other command uses `detect_context().mode`.
- `--json` exists on `status` and `hosts list` only (spec); it prints pydantic `model_dump_json`.
- Tests: `cd tui && uv run pytest -q` (or `make -C makefile tui-test MODE=prod`). Unit tests inject/monkeypatch subprocess collaborators; real-repo integration tests only for cheap read-only paths. CliRunner for every subcommand.
- New tracked completion file: LF-only, mode 100644, `#compdef` on line 1. It is Click-generated at eval time — EXEMPT from the script-flag↔completion parity invariant (documented in Task 8).
- Pre-commit hook runs `scripts/check-invariants.sh` — a task is not done if its commit fails it. Never `--no-verify`.
- Conventional-commit subjects as given per task.

---

### Task 1: Carry-forward hardening (blockers first)

**Files:**
- Modify: `tui/src/workstation_tui/core/hostsfile.py`
- Modify: `tui/tests/test_hostsfile.py`
- Modify: `tui/tests/test_context.py`
- Modify: `tui/tests/test_makeiface.py` (remove unused import)
- Delete: `tui/uv.lock`; Modify: `.gitignore`

**Interfaces:**
- Consumes: Phase 1 modules as shipped.
- Produces: `read_hosts` that never raises (same signature); no other signature changes. Later tasks may rely on `read_hosts` returning `([], [error])` for a missing/undecodable hosts.conf.

- [ ] **Step 1: Write the failing tests for `read_hosts` never-raise**

Append to `tui/tests/test_hostsfile.py`:

```python
def test_read_hosts_missing_file(tmp_path: Path) -> None:
    entries, errors = read_hosts(tmp_path)  # no hosts.conf here
    assert entries == []
    assert len(errors) == 1
    assert "hosts.conf" in errors[0]


def test_read_hosts_undecodable(tmp_path: Path) -> None:
    (tmp_path / "hosts.conf").write_bytes(b"\xff\xfe\x00bad")
    entries, errors = read_hosts(tmp_path)
    assert entries == []
    assert len(errors) == 1
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd tui && uv run pytest tests/test_hostsfile.py -q`
Expected: 2 failures (`FileNotFoundError`, `UnicodeDecodeError` escape).

- [ ] **Step 3: Make `read_hosts` never-raise**

In `tui/src/workstation_tui/core/hostsfile.py` replace the `read_hosts` body:

```python
def read_hosts(repo_root: Path) -> tuple[list[HostEntry], list[str]]:
    try:
        text = (repo_root / "hosts.conf").read_text(encoding="utf-8")
    except OSError as exc:
        return [], [f"hosts.conf unreadable: {exc}"]
    except UnicodeDecodeError as exc:
        return [], [f"hosts.conf undecodable: {exc}"]
    return parse_hosts_text(text)
```

(Also update the module docstring's read-only sentence to mention the never-raise contract, matching `read_inventory`.)

- [ ] **Step 4: Add `_detect_group` failure-branch tests**

Append to `tui/tests/test_context.py`:

```python
def test_group_none_when_chezmoi_fails(tmp_path: Path) -> None:
    def run_rc1(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="boom")
    ctx = detect_context(which=which_all, run=run_rc1,
                         proc_version=tmp_path / "absent", platform="linux")
    assert ctx.group is None
    assert ctx.mode == "prod"


def test_group_none_on_malformed_json(tmp_path: Path) -> None:
    def run_garbage(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout="not json{", stderr="")
    ctx = detect_context(which=which_all, run=run_garbage,
                         proc_version=tmp_path / "absent", platform="linux")
    assert ctx.group is None


def test_group_none_on_non_string_group(tmp_path: Path) -> None:
    def run_int_group(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout='{"group": 7}', stderr="")
    ctx = detect_context(which=which_all, run=run_int_group,
                         proc_version=tmp_path / "absent", platform="linux")
    assert ctx.group is None
```

Run: `cd tui && uv run pytest tests/test_context.py -q` — expected: all pass immediately (the branches exist; they were merely untested — that's the point of pinning them now).

- [ ] **Step 5: Cosmetics + lockfile decision**

- Remove the unused `from unittest.mock import MagicMock` line from `tui/tests/test_makeiface.py`.
- `git rm tui/uv.lock` and add `tui/uv.lock` to the repo-root `.gitignore`'s Python block. Rationale (record in the commit body): the repo's blessed env tracks latest by design; an unenforced lockfile (CI never ran `--locked`) is pinning theater.

- [ ] **Step 6: Full suite + commit**

Run: `cd tui && uv run pytest -q` — expected `31 passed` (26 + 5 new).

```bash
git add tui/ .gitignore
git commit -m "fix(tui): read_hosts never-raise + _detect_group failure tests + drop unenforced uv.lock"
git push -u origin feat/workstation-tui-phase2
```

---

### Task 2: Models — PendingChange + Summary

**Files:**
- Modify: `tui/src/workstation_tui/core/models.py`
- Test: `tui/tests/test_models.py`

**Interfaces:**
- Produces (later tasks import verbatim):
  - `PendingChange(BaseModel)`: `code: str` (two-char chezmoi status code), `path: str`
  - `Summary(BaseModel)`: `context: HostContext`, `tools_total: int`, `tools_fresh: int`, `tools_stale: int`, `tools_missing: int`, `inventory_errors: list[str]`, `dotfiles_pending: int`, `dotfiles_errors: list[str]`, `hosts_total: int`, `hosts_dev: int`, `hosts_prod: int`, `hosts_errors: list[str]`

- [ ] **Step 1: Write the failing test**

Append to `tui/tests/test_models.py`:

```python
def test_pending_change_and_summary_round_trip() -> None:
    from workstation_tui.core.models import HostContext, PendingChange, Summary

    pc = PendingChange(code="MM", path=".claude/settings.json")
    assert pc.code == "MM"
    s = Summary(
        context=HostContext(
            os="linux", is_wsl=True, group="dev_machine", mode="dev",
            has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
        ),
        tools_total=105, tools_fresh=100, tools_stale=3, tools_missing=2,
        inventory_errors=[], dotfiles_pending=1, dotfiles_errors=[],
        hosts_total=9, hosts_dev=3, hosts_prod=6, hosts_errors=[],
    )
    assert '"tools_fresh":100' in s.model_dump_json()
```

- [ ] **Step 2: Run to verify it fails** — `cd tui && uv run pytest tests/test_models.py -q` → ImportError.

- [ ] **Step 3: Implement**

Append to `tui/src/workstation_tui/core/models.py`:

```python
class PendingChange(BaseModel):
    """One `XY path` row of `chezmoi status`."""

    code: str  # two-char chezmoi status code, e.g. "MM", " A"
    path: str


class Summary(BaseModel):
    """Dashboard rollup consumed by `workstation status` (and the Phase 3 dashboard)."""

    context: HostContext
    tools_total: int
    tools_fresh: int
    tools_stale: int
    tools_missing: int
    inventory_errors: list[str]
    dotfiles_pending: int
    dotfiles_errors: list[str]
    hosts_total: int
    hosts_dev: int
    hosts_prod: int
    hosts_errors: list[str]
```

- [ ] **Step 4: Run to verify pass**, then **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/models.py tui/tests/test_models.py
git commit -m "feat(tui): PendingChange + Summary models"
git push
```

---

### Task 3: chezmoi reader + command builders

**Files:**
- Create: `tui/src/workstation_tui/core/chezmoi.py`
- Test: `tui/tests/test_chezmoi.py`

**Interfaces:**
- Consumes: `PendingChange` (Task 2).
- Produces: `parse_status_text(text: str) -> tuple[list[PendingChange], list[str]]`; `read_status(*, run=subprocess.run) -> tuple[list[PendingChange], list[str]]` (never raises); `diff_command() -> list[str]` = `["chezmoi", "diff"]`; `apply_command() -> list[str]` = `["chezmoi", "apply", "--force"]`; `update_command() -> list[str]` = `["chezmoi", "update", "--force"]`.

- [ ] **Step 1: Write the failing test**

`tui/tests/test_chezmoi.py`:

```python
import subprocess

from workstation_tui.core.chezmoi import (
    apply_command,
    diff_command,
    parse_status_text,
    read_status,
    update_command,
)

SAMPLE = """\
MM .claude/settings.json
 A .config/newfile
DA .config/oldname
this line has no status code
"""


def test_parse_status_text() -> None:
    changes, errors = parse_status_text(SAMPLE)
    assert [(c.code, c.path) for c in changes] == [
        ("MM", ".claude/settings.json"),
        (" A", ".config/newfile"),
        ("DA", ".config/oldname"),
    ]
    assert len(errors) == 1


def test_read_status_success() -> None:
    def fake_run(cmd, **kwargs):
        assert cmd == ["chezmoi", "status"]
        return subprocess.CompletedProcess(cmd, 0, stdout=SAMPLE, stderr="")
    changes, errors = read_status(run=fake_run)
    assert len(changes) == 3


def test_read_status_never_raises() -> None:
    def fake_run(cmd, **kwargs):
        raise FileNotFoundError("chezmoi")
    changes, errors = read_status(run=fake_run)
    assert changes == []
    assert "chezmoi status failed" in errors[0]


def test_command_builders() -> None:
    assert diff_command() == ["chezmoi", "diff"]
    assert apply_command() == ["chezmoi", "apply", "--force"]
    assert update_command() == ["chezmoi", "update", "--force"]
```

- [ ] **Step 2: Run to verify it fails** — module missing.

- [ ] **Step 3: Implement `core/chezmoi.py`**

```python
"""chezmoi read layer + mutation command builders.

Reads never raise (rc!=0 / missing binary / timeout become error strings).
Mutations are BUILDERS only — the CLI/TUI streams them via proc.run_passthrough,
always after an in-band diff + explicit confirm, hence the hard-wired --force
(chezmoi's own overwrite prompts hang non-interactive runs; repo memory).
"""

import re
import subprocess

from workstation_tui.core.models import PendingChange

# `chezmoi status` porcelain: two status chars, space, target path.
_STATUS_RE = re.compile(r"^([A-Z ]{2}) (.+)$")


def parse_status_text(text: str) -> tuple[list[PendingChange], list[str]]:
    changes: list[PendingChange] = []
    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        m = _STATUS_RE.match(line)
        if m is None:
            errors.append(f"line {lineno}: not a chezmoi status row: {line!r}")
            continue
        changes.append(PendingChange(code=m.group(1), path=m.group(2)))
    return changes, errors


def read_status(*, run=subprocess.run) -> tuple[list[PendingChange], list[str]]:
    try:
        proc = run(["chezmoi", "status"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        return [], [f"chezmoi status failed: {exc}"]
    if proc.returncode != 0:
        return [], [f"chezmoi status failed (rc={proc.returncode}): {proc.stderr.strip()}"]
    return parse_status_text(proc.stdout)


def diff_command() -> list[str]:
    return ["chezmoi", "diff"]


def apply_command() -> list[str]:
    return ["chezmoi", "apply", "--force"]


def update_command() -> list[str]:
    return ["chezmoi", "update", "--force"]
```

- [ ] **Step 4: Run to verify pass** (`4 passed`), then **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/chezmoi.py tui/tests/test_chezmoi.py
git commit -m "feat(tui): chezmoi status reader + mutation command builders"
git push
```

---

### Task 4: Passthrough runner + make command builders

**Files:**
- Create: `tui/src/workstation_tui/core/proc.py`
- Modify: `tui/src/workstation_tui/core/makeiface.py`
- Test: `tui/tests/test_proc.py`, `tui/tests/test_makeiface.py`

**Interfaces:**
- Produces:
  - `proc.run_passthrough(cmd: list[str], *, run=subprocess.run) -> int` — inherits stdio (no capture), scrubs `MAKEFLAGS`/`MFLAGS`/`MAKELEVEL` from the child env, returns the exit code; returns `127` with a message on `stderr` if the binary is missing (never raises).
  - `makeiface.make_command(repo_root: Path, goals: list[str], mode: str) -> list[str]`; `provision_command(repo_root, tools: list[str], mode) -> list[str]`; `doctor_command(repo_root, mode) -> list[str]`; `check_updates_command(repo_root, mode) -> list[str]`.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_proc.py`:

```python
import subprocess
import sys

from workstation_tui.core.proc import run_passthrough


def test_run_passthrough_returns_exit_code() -> None:
    rc = run_passthrough([sys.executable, "-c", "import sys; sys.exit(3)"])
    assert rc == 3


def test_run_passthrough_scrubs_make_env(monkeypatch) -> None:
    monkeypatch.setenv("MAKEFLAGS", "w -j8 --jobserver-auth=3,4")
    rc = run_passthrough(
        [sys.executable, "-c",
         "import os, sys; sys.exit(1 if 'MAKEFLAGS' in os.environ else 0)"]
    )
    assert rc == 0


def test_run_passthrough_missing_binary() -> None:
    rc = run_passthrough(["definitely-not-a-real-binary-xyz"])
    assert rc == 127
```

Append to `tui/tests/test_makeiface.py`:

```python
def test_command_builders(tmp_path: Path) -> None:
    from workstation_tui.core.makeiface import (
        check_updates_command,
        doctor_command,
        make_command,
        provision_command,
    )

    base = ["make", "--no-print-directory", "-C", str(tmp_path / "makefile")]
    assert make_command(tmp_path, ["fzf", "zellij"], "dev") == [*base, "fzf", "zellij", "MODE=dev"]
    assert provision_command(tmp_path, ["node-runtime"], "prod") == [*base, "node-runtime", "MODE=prod"]
    assert doctor_command(tmp_path, "dev") == [*base, "doctor", "MODE=dev"]
    assert check_updates_command(tmp_path, "prod") == [*base, "check-updates", "MODE=prod"]
```

- [ ] **Step 2: Run to verify failure** (module/functions missing).

- [ ] **Step 3: Implement**

`tui/src/workstation_tui/core/proc.py`:

```python
"""Synchronous passthrough runner for headless commands.

The child inherits stdout/stderr/stdin, so make's sudo prompt, chezmoi's
pager-less diff, and doctor's colored report reach the terminal untouched.
The Phase 4 async engine (runner.py) supersedes this for the TUI; the CLI
keeps using this simple path. Scrubs MAKEFLAGS/MFLAGS/MAKELEVEL for the same
reason read_inventory does: inherited jobserver flags make nested make
ignore --no-print-directory.
"""

import os
import subprocess
import sys

_SCRUB = ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")


def run_passthrough(cmd: list[str], *, run=subprocess.run) -> int:
    env = {k: v for k, v in os.environ.items() if k not in _SCRUB}
    try:
        return run(cmd, env=env).returncode
    except FileNotFoundError:
        print(f"workstation: command not found: {cmd[0]}", file=sys.stderr)
        return 127
```

Append to `tui/src/workstation_tui/core/makeiface.py`:

```python
def make_command(repo_root: Path, goals: list[str], mode: str) -> list[str]:
    return [
        "make", "--no-print-directory", "-C", str(repo_root / "makefile"),
        *goals, f"MODE={mode}",
    ]


def provision_command(repo_root: Path, tools: list[str], mode: str) -> list[str]:
    return make_command(repo_root, tools, mode)


def doctor_command(repo_root: Path, mode: str) -> list[str]:
    return make_command(repo_root, ["doctor"], mode)


def check_updates_command(repo_root: Path, mode: str) -> list[str]:
    return make_command(repo_root, ["check-updates"], mode)
```

(While here, refactor `read_inventory` to build its command via `make_command(repo_root, ["inventory"], mode)` — one builder, no drift; its existing tests keep passing.)

- [ ] **Step 4: Run both test files + full suite**, then **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/proc.py tui/src/workstation_tui/core/makeiface.py tui/tests/test_proc.py tui/tests/test_makeiface.py
git commit -m "feat(tui): passthrough runner + make command builders"
git push
```

---

### Task 5: Summary aggregator

**Files:**
- Create: `tui/src/workstation_tui/core/summary.py`
- Test: `tui/tests/test_summary.py`

**Interfaces:**
- Consumes: `detect_context`, `read_inventory`, `stamps.scan`/`DEFAULT_STAMP_DIR`, `chezmoi.read_status`, `read_hosts`, `Summary`, `StampState`.
- Produces: `gather_summary(repo_root: Path, *, context: HostContext | None = None, stamp_dir: Path | None = None, read_inventory=read_inventory, read_status=read_status, read_hosts=read_hosts) -> Summary` — every collaborator injectable; `context=None` triggers `detect_context()`.

- [ ] **Step 1: Write the failing test**

`tui/tests/test_summary.py`:

```python
from pathlib import Path

from workstation_tui.core.models import (
    HostContext,
    HostEntry,
    InventoryRow,
    PendingChange,
)
from workstation_tui.core.summary import gather_summary

CTX = HostContext(
    os="linux", is_wsl=False, group="dev_machine", mode="dev",
    has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
)


def test_gather_summary_composes(tmp_path: Path) -> None:
    (tmp_path / "fzf-0.74.2.done").touch()
    rows = [
        InventoryRow(kind="scope", name="fzf", version="0.74.2"),
        InventoryRow(kind="scope", name="zellij", version="0.44.3"),
    ]
    s = gather_summary(
        tmp_path,
        context=CTX,
        stamp_dir=tmp_path,
        read_inventory=lambda root, mode: (rows, []),
        read_status=lambda: ([PendingChange(code="MM", path=".zshrc")], []),
        read_hosts=lambda root: (
            [HostEntry(name="a", address="1.2.3.4", user="u", group="dev_machine"),
             HostEntry(name="b", address="1.2.3.5", user="u", group="prod_machine")],
            [],
        ),
    )
    assert (s.tools_total, s.tools_fresh, s.tools_stale, s.tools_missing) == (2, 1, 0, 1)
    assert s.dotfiles_pending == 1
    assert (s.hosts_total, s.hosts_dev, s.hosts_prod) == (2, 1, 1)
    assert s.context.mode == "dev"


def test_gather_summary_propagates_errors(tmp_path: Path) -> None:
    s = gather_summary(
        tmp_path,
        context=CTX,
        stamp_dir=tmp_path,
        read_inventory=lambda root, mode: ([], ["make inventory failed"]),
        read_status=lambda: ([], ["chezmoi status failed"]),
        read_hosts=lambda root: ([], ["hosts.conf unreadable"]),
    )
    assert s.inventory_errors and s.dotfiles_errors and s.hosts_errors
    assert s.tools_total == 0
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement `core/summary.py`**

```python
"""Compose the dashboard rollup from the individual core readers."""

from pathlib import Path

from workstation_tui.core.chezmoi import read_status as _read_status
from workstation_tui.core.context import detect_context
from workstation_tui.core.hostsfile import read_hosts as _read_hosts
from workstation_tui.core.makeiface import read_inventory as _read_inventory
from workstation_tui.core.models import HostContext, StampState, Summary
from workstation_tui.core.stamps import DEFAULT_STAMP_DIR, scan


def gather_summary(
    repo_root: Path,
    *,
    context: HostContext | None = None,
    stamp_dir: Path | None = None,
    read_inventory=_read_inventory,
    read_status=_read_status,
    read_hosts=_read_hosts,
) -> Summary:
    ctx = context if context is not None else detect_context()
    rows, inv_errors = read_inventory(repo_root, ctx.mode)
    statuses = scan(stamp_dir if stamp_dir is not None else DEFAULT_STAMP_DIR, rows)
    pending, dot_errors = read_status()
    hosts, host_errors = read_hosts(repo_root)
    return Summary(
        context=ctx,
        tools_total=len(statuses),
        tools_fresh=sum(t.state is StampState.FRESH for t in statuses),
        tools_stale=sum(t.state is StampState.STALE for t in statuses),
        tools_missing=sum(t.state is StampState.MISSING for t in statuses),
        inventory_errors=inv_errors,
        dotfiles_pending=len(pending),
        dotfiles_errors=dot_errors,
        hosts_total=len(hosts),
        hosts_dev=sum(h.group == "dev_machine" for h in hosts),
        hosts_prod=sum(h.group == "prod_machine" for h in hosts),
        hosts_errors=host_errors,
    )
```

- [ ] **Step 4: Run to verify pass**, then **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/summary.py tui/tests/test_summary.py
git commit -m "feat(tui): summary aggregator for status/dashboard"
git push
```

---

### Task 6: `workstation status` + `workstation hosts list`

**Files:**
- Modify: `tui/src/workstation_tui/cli.py`
- Create: `tui/src/workstation_tui/repo.py`
- Test: `tui/tests/test_cli_status.py`

**Interfaces:**
- Consumes: `gather_summary`, `read_hosts`, models.
- Produces: `repo.find_repo_root() -> Path | None` — resolves the workstation checkout (chezmoi source dir): `$WORKSTATION_REPO` env override → `~/.local/share/chezmoi` if it contains `makefile/Makefile` → editable-install location (`Path(workstation_tui.__file__).parents[3]` when it contains `makefile/Makefile`) → `None`. CLI commands error cleanly (exit 2, message on stderr) when it returns `None`.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_cli_status.py`:

```python
import json
from pathlib import Path

from click.testing import CliRunner

from workstation_tui.cli import main
from workstation_tui.repo import find_repo_root


def test_find_repo_root_env_override(tmp_path: Path, monkeypatch) -> None:
    (tmp_path / "makefile").mkdir()
    (tmp_path / "makefile" / "Makefile").touch()
    monkeypatch.setenv("WORKSTATION_REPO", str(tmp_path))
    assert find_repo_root() == tmp_path


def test_find_repo_root_rejects_bogus_env(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(tmp_path / "nope"))
    root = find_repo_root()
    assert root is None or (root / "makefile" / "Makefile").exists()


def test_status_json(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["status", "--json"])
    assert result.exit_code == 0, result.output
    data = json.loads(result.output)
    assert data["tools_total"] > 90
    assert "dotfiles_pending" in data


def test_status_human(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["status"])
    assert result.exit_code == 0, result.output
    assert "tools" in result.output
    assert "hosts" in result.output


def test_hosts_list_json(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["hosts", "list", "--json"])
    assert result.exit_code == 0, result.output
    data = json.loads(result.output)
    assert isinstance(data, list) and len(data) >= 2
    assert {"name", "address", "user", "group"} <= set(data[0])


def test_hosts_list_human(repo_root: Path, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["hosts", "list"])
    assert result.exit_code == 0
    assert "dev_machine" in result.output
```

(These are real-repo integration tests: `status` runs a real `make inventory` + `chezmoi status` on this checkout — read-only and fast. `repo_root` is the session fixture from Phase 1.)

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement**

`tui/src/workstation_tui/repo.py`:

```python
"""Locate the workstation repo checkout (the chezmoi source dir)."""

import os
from pathlib import Path

import workstation_tui


def _is_repo(path: Path) -> bool:
    return (path / "makefile" / "Makefile").is_file()


def find_repo_root() -> Path | None:
    env = os.environ.get("WORKSTATION_REPO")
    if env:
        p = Path(env).expanduser()
        if _is_repo(p):
            return p
    default = Path.home() / ".local/share/chezmoi"
    if _is_repo(default):
        return default
    # Editable install: tui/src/workstation_tui/__init__.py -> repo is parents[3].
    editable = Path(workstation_tui.__file__).resolve().parents[3]
    if _is_repo(editable):
        return editable
    return None
```

In `tui/src/workstation_tui/cli.py`, add below the existing `main` group (keep the bare-invocation placeholder untouched):

```python
import json as _json
import sys

from workstation_tui.core.hostsfile import read_hosts
from workstation_tui.core.summary import gather_summary
from workstation_tui.repo import find_repo_root


def _require_repo() -> "Path":
    root = find_repo_root()
    if root is None:
        click.echo(
            "workstation: cannot locate the workstation repo "
            "(set WORKSTATION_REPO or clone to ~/.local/share/chezmoi)",
            err=True,
        )
        sys.exit(2)
    return root


@main.command()
@click.option("--json", "as_json", is_flag=True, help="Machine-readable output.")
def status(as_json: bool) -> None:
    """Dashboard summary: tools, dotfiles, hosts."""
    s = gather_summary(_require_repo())
    if as_json:
        click.echo(s.model_dump_json())
        return
    c = s.context
    click.echo(f"host     {c.os} · group={c.group or '?'} · mode={c.mode}"
               f"{' · WSL' if c.is_wsl else ''}")
    click.echo(f"tools    {s.tools_fresh}/{s.tools_total} fresh · "
               f"{s.tools_stale} stale · {s.tools_missing} missing")
    click.echo(f"dotfiles {s.dotfiles_pending} pending")
    click.echo(f"hosts    {s.hosts_total} ({s.hosts_dev} dev · {s.hosts_prod} prod)")
    for err in (*s.inventory_errors, *s.dotfiles_errors, *s.hosts_errors):
        click.echo(f"warning  {err}", err=True)


@main.group()
def hosts() -> None:
    """Fleet host inventory (hosts.conf)."""


@hosts.command(name="list")
@click.option("--json", "as_json", is_flag=True, help="Machine-readable output.")
def hosts_list(as_json: bool) -> None:
    """List hosts.conf entries."""
    entries, errors = read_hosts(_require_repo())
    if as_json:
        click.echo(_json.dumps([e.model_dump() for e in entries]))
    else:
        for e in entries:
            click.echo(f"{e.name:<18} {e.address:<16} {e.user:<20} {e.group}")
    for err in errors:
        click.echo(f"warning  {err}", err=True)
```

(`from pathlib import Path` if not already imported. Keep imports at top of file per style — the snippet shows them inline for placement clarity only.)

- [ ] **Step 4: Run tests + full suite**, then **Step 5: Commit**

```bash
git add tui/src/workstation_tui/cli.py tui/src/workstation_tui/repo.py tui/tests/test_cli_status.py
git commit -m "feat(tui): workstation status + hosts list subcommands"
git push
```

---

### Task 7: `doctor`, `updates`, `provision`

**Files:**
- Modify: `tui/src/workstation_tui/cli.py`
- Test: `tui/tests/test_cli_make.py`

**Interfaces:**
- Consumes: `doctor_command`, `check_updates_command`, `provision_command`, `run_passthrough`, `detect_context`.
- Produces: `workstation doctor`, `workstation updates`, `workstation provision <tool>… [--mode dev|prod]` — each streams via passthrough and exits with the child's rc.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_cli_make.py`:

```python
from click.testing import CliRunner

import workstation_tui.cli as cli
from workstation_tui.cli import main


def _capture(monkeypatch, rc=0):
    calls: list[list[str]] = []
    def fake_passthrough(cmd):
        calls.append(cmd)
        return rc
    monkeypatch.setattr(cli, "run_passthrough", fake_passthrough)
    return calls


def test_doctor_streams_and_exits_with_rc(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    calls = _capture(monkeypatch, rc=1)
    result = CliRunner().invoke(main, ["doctor"])
    assert result.exit_code == 1
    assert calls[0][-2:] == ["doctor", f"MODE={cli.detect_context().mode}"]


def test_updates(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["updates"])
    assert result.exit_code == 0
    assert "check-updates" in calls[0]


def test_provision_tools_and_mode_override(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["provision", "fzf", "zellij", "--mode", "prod"])
    assert result.exit_code == 0
    assert calls[0][-3:] == ["fzf", "zellij", "MODE=prod"]


def test_provision_requires_tool(repo_root, monkeypatch) -> None:
    monkeypatch.setenv("WORKSTATION_REPO", str(repo_root))
    result = CliRunner().invoke(main, ["provision"])
    assert result.exit_code != 0
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement** (append to `cli.py`; add the imports `run_passthrough`, `doctor_command`, `check_updates_command`, `provision_command`, `detect_context` at top):

```python
@main.command()
def doctor() -> None:
    """Run the repo doctor (make doctor) and exit with its status."""
    ctx = detect_context()
    sys.exit(run_passthrough(doctor_command(_require_repo(), ctx.mode)))


@main.command()
def updates() -> None:
    """Check every version pin against upstream (make check-updates)."""
    ctx = detect_context()
    sys.exit(run_passthrough(check_updates_command(_require_repo(), ctx.mode)))


@main.command()
@click.argument("tools", nargs=-1, required=True)
@click.option("--mode", type=click.Choice(["dev", "prod"]), default=None,
              help="Override the detected MODE.")
def provision(tools: tuple[str, ...], mode: str | None) -> None:
    """Install/refresh one or more tools via make (sudo may prompt on dev)."""
    resolved = mode or detect_context().mode
    sys.exit(run_passthrough(provision_command(_require_repo(), list(tools), resolved)))
```

- [ ] **Step 4: Run tests + full suite**, then **Step 5: Commit**

```bash
git add tui/src/workstation_tui/cli.py tui/tests/test_cli_make.py
git commit -m "feat(tui): doctor, updates, provision subcommands"
git push
```

---

### Task 8: `dotfiles` group

**Files:**
- Modify: `tui/src/workstation_tui/cli.py`
- Test: `tui/tests/test_cli_dotfiles.py`

**Interfaces:**
- Consumes: `read_status`, `diff_command`, `apply_command`, `update_command`, `run_passthrough`.
- Produces: `workstation dotfiles status|diff|apply|update`. `apply` = stream diff → `click.confirm` → `chezmoi apply --force`; declining aborts rc 1 without applying. `update` = confirm (notes pull+apply) → `chezmoi update --force`.

- [ ] **Step 1: Write the failing tests**

`tui/tests/test_cli_dotfiles.py`:

```python
from click.testing import CliRunner

import workstation_tui.cli as cli
from workstation_tui.cli import main
from workstation_tui.core.models import PendingChange


def _capture(monkeypatch, rc=0):
    calls: list[list[str]] = []
    def fake_passthrough(cmd):
        calls.append(cmd)
        return rc
    monkeypatch.setattr(cli, "run_passthrough", fake_passthrough)
    return calls


def test_dotfiles_status(monkeypatch) -> None:
    monkeypatch.setattr(
        cli, "read_status",
        lambda: ([PendingChange(code="MM", path=".zshrc")], []),
    )
    result = CliRunner().invoke(main, ["dotfiles", "status"])
    assert result.exit_code == 0
    assert "MM .zshrc" in result.output


def test_dotfiles_status_clean(monkeypatch) -> None:
    monkeypatch.setattr(cli, "read_status", lambda: ([], []))
    result = CliRunner().invoke(main, ["dotfiles", "status"])
    assert result.exit_code == 0
    assert "in sync" in result.output


def test_dotfiles_diff(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "diff"])
    assert result.exit_code == 0
    assert calls == [["chezmoi", "diff"]]


def test_dotfiles_apply_confirmed(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "apply"], input="y\n")
    assert result.exit_code == 0
    assert calls == [["chezmoi", "diff"], ["chezmoi", "apply", "--force"]]


def test_dotfiles_apply_declined(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "apply"], input="n\n")
    assert result.exit_code == 1
    assert calls == [["chezmoi", "diff"]]  # diff shown, apply never ran


def test_dotfiles_update_confirmed(monkeypatch) -> None:
    calls = _capture(monkeypatch)
    result = CliRunner().invoke(main, ["dotfiles", "update"], input="y\n")
    assert result.exit_code == 0
    assert calls == [["chezmoi", "update", "--force"]]
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement** (append to `cli.py`; import `read_status`, `diff_command`, `apply_command`, `update_command` at top):

```python
@main.group()
def dotfiles() -> None:
    """chezmoi workflow: status, diff, apply, update."""


@dotfiles.command(name="status")
def dotfiles_status() -> None:
    """Pending chezmoi changes."""
    pending, errors = read_status()
    if not pending and not errors:
        click.echo("dotfiles in sync")
    for p in pending:
        click.echo(f"{p.code} {p.path}")
    for err in errors:
        click.echo(f"warning  {err}", err=True)


@dotfiles.command(name="diff")
def dotfiles_diff() -> None:
    """Full chezmoi diff."""
    sys.exit(run_passthrough(diff_command()))


@dotfiles.command(name="apply")
def dotfiles_apply() -> None:
    """Show the diff, confirm, then apply with --force (prompts never fire)."""
    run_passthrough(diff_command())
    if not click.confirm("Apply these changes?"):
        raise SystemExit(1)
    sys.exit(run_passthrough(apply_command()))


@dotfiles.command(name="update")
def dotfiles_update() -> None:
    """Pull the source repo and apply (chezmoi update --force)."""
    if not click.confirm("Pull the dotfiles repo and apply to this host?"):
        raise SystemExit(1)
    sys.exit(run_passthrough(update_command()))
```

- [ ] **Step 4: Run tests + full suite**, then **Step 5: Commit**

```bash
git add tui/src/workstation_tui/cli.py tui/tests/test_cli_dotfiles.py
git commit -m "feat(tui): dotfiles subcommand group (status/diff/apply/update)"
git push
```

---

### Task 9: zsh completions stub + pyrightconfig

**Files:**
- Create: `chezmoi/dot_config/zsh/completions/_workstation`
- Create: `tui/pyrightconfig.json`

**Interfaces:** none consumed by later tasks.

- [ ] **Step 1: Create the completion stub**

`chezmoi/dot_config/zsh/completions/_workstation` (LF, mode 100644):

```zsh
#compdef workstation
# First-party zsh completion for the workstation CLI (tui/). Unlike the
# sibling _*.sh completions there is NO hand-maintained flag list here:
# Click generates the completer at eval time from the installed CLI, so this
# stub is EXEMPT from the script-flag<->completion parity invariant.
# Degrades silently when the CLI isn't installed yet (mid-bootstrap).
if (( $+commands[workstation] )); then
  eval "$(_WORKSTATION_COMPLETE=zsh_source workstation 2>/dev/null)"
  # zsh_source defines + compdef-registers _workstation_completion for future
  # attempts; invoke it directly to serve THIS attempt too.
  (( $+functions[_workstation_completion] )) && _workstation_completion "$@"
fi
```

- [ ] **Step 2: Create `tui/pyrightconfig.json`** (quiets the repo-level basedpyright noise on every tui/ file):

```json
{
  "venvPath": ".",
  "venv": ".venv",
  "extraPaths": ["src"],
  "pythonVersion": "3.14"
}
```

- [ ] **Step 3: Verify**

```bash
file chezmoi/dot_config/zsh/completions/_workstation          # ASCII text, no CRLF
git ls-files --stage chezmoi/dot_config/zsh/completions/_workstation | grep 100644 || true  # after add
zsh -fc 'autoload -Uz compinit; compinit -C; fpath=(chezmoi/dot_config/zsh/completions $fpath); source chezmoi/dot_config/zsh/completions/_workstation' 2>&1 | head -3   # syntax parse smoke (may warn about compdef context; must not syntax-error)
python3 -c "import json; json.load(open('tui/pyrightconfig.json'))"
make -C makefile lint MODE=prod   # completion-parity checks must stay green (this file is not in their pair list)
```

- [ ] **Step 4: Commit**

```bash
git add chezmoi/dot_config/zsh/completions/_workstation tui/pyrightconfig.json
git commit -m "feat(tui): Click-generated zsh completions stub + tui pyrightconfig"
git push
```

---

### Task 10: Docs + gate + PR

**Files:**
- Modify: `CLAUDE_CHANGELOG.md`, `CLAUDE.md`

- [ ] **Step 1: CLAUDE_CHANGELOG.md** — append one row:

```markdown
| workstation TUI Phase 2: headless CLI (status/doctor/updates/provision/hosts list/dotfiles) + Click-generated zsh completions | No | README §tui still lands with the TUI's final phase; CLI is documented in-tool via --help until then |
```

- [ ] **Step 2: CLAUDE.md** — in the script-flag↔completion parity bullet (file-care "Version-pin dual/triple-edits" list), append one sentence: `The `_workstation` completion is Click-generated at eval time — deliberately EXEMPT from this parity check (no hand-maintained flag list).`

- [ ] **Step 3: Full gate**

```bash
make -C makefile lint MODE=prod
make -C makefile tui-test MODE=prod      # expect 45+ passed
bash scripts/check-templates.sh
~/.local/bin/workstation status          # live smoke on this host (read-only)
~/.local/bin/workstation hosts list
```

(The live smoke works immediately because the editable install picks the new code up with no rebuild.)

- [ ] **Step 4: Commit + PR**

```bash
git add CLAUDE_CHANGELOG.md CLAUDE.md
git commit -m "docs: workstation CLI phase-2 changelog + completions-exemption note"
git push
gh pr create --base feat/workstation-tui --title "feat(tui): workstation TUI Phase 2 — headless CLI" --body "$(cat <<'EOF'
Phase 2 of the workstation TUI (spec §Headless CLI), stacked on #116:

- carry-forward hardening: read_hosts never-raise, _detect_group failure tests,
  unenforced uv.lock dropped
- core: chezmoi status reader + mutation builders, passthrough runner
  (MAKEFLAGS-scrubbed), make command builders, summary aggregator, repo locator
- CLI: status [--json], hosts list [--json], doctor, updates,
  provision <tool>… [--mode], dotfiles status|diff|apply|update
  (diff → confirm → --force; chezmoi prompts never fire)
- Click-generated zsh completions stub (exempt from flag-parity by design)
  + tui/pyrightconfig.json

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01UfFaGAdVaLjVVrnq4jNJ9p
EOF
)"
gh pr checks --watch
```

Hand the PR to the user for review/merge.
