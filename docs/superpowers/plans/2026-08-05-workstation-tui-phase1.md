# Workstation TUI — Phase 1 (Foundations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `tui/` package skeleton with tested core parsers, promote python-env to both scopes, install the TUI editable into the blessed env with a `workstation` launcher on Linux + Windows, and wire CI.

**Architecture:** A `workstation-tui` Python package (src layout, hatchling) whose `core/` layer is pure logic — no Textual imports — consumed later by both the Click CLI and the Textual app. Reads are native (versions.mk text, stamp dir, hosts.conf, a new machine-readable `make inventory` dump of `DOCTOR_ROWS`); installation rides the existing python-env machinery (editable install, so `chezmoi update` updates the TUI fleet-wide).

**Tech Stack:** Python ≥3.14 (blessed env CPython 3.14.6), pydantic v2, click, pytest, uv, GNU Make, chezmoi.

**Spec:** `docs/superpowers/specs/2026-08-05-workstation-tui-design.md`. One refinement over the spec, decided here: the tool inventory comes from a new `make inventory` target that prints the existing `DOCTOR_ROWS` (`kind|name|version` per line) rather than from deriving tool names out of versions.mk variables — `TEALDEER_VERSION` → `tldr` proves the var→tool mapping is not derivable, and DOCTOR_ROWS is already the single source of truth doctor.sh consumes. Task 12 records this in the spec.

## Global Constraints

- Python floor: `requires-python = ">=3.14"` (blessed env is CPython 3.14.6).
- Package deps exactly: `textual`, `click`, `rich`, `pydantic` (+ dev group: `pytest`). No version pins — the blessed env tracks latest (repo precedent).
- Nothing under `tui/src/workstation_tui/core/` may import `textual` (spec rule).
- `PY_LIBS` in `makefile/lib/python-env.sh` and `$PythonLibs` in `bootstrap.ps1` stay ONE LINE each (check-invariants parses them). This plan does not change either list.
- Shell edits: LF-only, git mode 100755 for `makefile/lib/*.sh`, `shfmt -i 2`-clean, shellcheck-clean at warning+. Verify per task: `file <path>` (no CRLF), `git ls-files --stage <path>` (100755).
- `bootstrap.ps1` must keep its UTF-8 BOM after editing. Verify: `head -c3 bootstrap.ps1 | xxd` shows `ef bb bf`.
- `makefile/lib/python-env.sh` ↔ `bootstrap.ps1` `Invoke-PythonEnv` are a parity pair: their halves of any task land in the SAME commit.
- Makefile recipe lines are TAB-indented.
- Every `make` invocation in commands below needs `MODE=` (scope.mk errors without it); use `MODE=prod` for read-only/lint-style targets by repo convention.
- Branch: `feat/workstation-tui` (already exists, spec committed). Push after every commit.
- The pre-commit hook runs `scripts/check-invariants.sh` — a task is not done if its commit fails the hook.

---

### Task 1: `tui/` package skeleton + minimal Click entry

**Files:**
- Create: `tui/pyproject.toml`
- Create: `tui/src/workstation_tui/__init__.py`
- Create: `tui/src/workstation_tui/cli.py`
- Create: `tui/src/workstation_tui/core/__init__.py`
- Create: `tui/tests/__init__.py` (empty), `tui/tests/conftest.py`
- Test: `tui/tests/test_cli.py`
- Modify: `.gitignore` (repo root)

**Interfaces:**
- Produces: console script `workstation` → `workstation_tui.cli:main` (Click group; bare invocation prints a placeholder line and exits 0). `workstation_tui.__version__: str`. `tui/tests/conftest.py` exposes fixture `repo_root: Path` (the workstation repo checkout root) used by every later test task.

- [ ] **Step 1: Write the package metadata and skeleton**

`tui/pyproject.toml`:

```toml
[project]
name = "workstation-tui"
version = "0.1.0"
description = "Control-panel TUI + CLI for the workstation provisioning system"
requires-python = ">=3.14"
dependencies = ["textual", "click", "rich", "pydantic"]

[project.scripts]
workstation = "workstation_tui.cli:main"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/workstation_tui"]

[dependency-groups]
dev = ["pytest"]
```

`tui/src/workstation_tui/__init__.py`:

```python
"""workstation-tui — control-panel TUI + CLI for the workstation repo."""

__version__ = "0.1.0"
```

`tui/src/workstation_tui/core/__init__.py`:

```python
"""Pure logic layer. MUST NOT import textual (spec rule; CLI + app both consume it)."""
```

`tui/tests/conftest.py`:

```python
from pathlib import Path

import pytest

# tui/tests/conftest.py -> parents[0]=tests, [1]=tui, [2]=repo root
_REPO_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return _REPO_ROOT
```

- [ ] **Step 2: Write the failing CLI test**

`tui/tests/test_cli.py`:

```python
from click.testing import CliRunner

from workstation_tui import __version__
from workstation_tui.cli import main


def test_version_flag() -> None:
    result = CliRunner().invoke(main, ["--version"])
    assert result.exit_code == 0
    assert __version__ in result.output


def test_bare_invocation_is_placeholder() -> None:
    result = CliRunner().invoke(main, [])
    assert result.exit_code == 0
    assert "later phase" in result.output
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd tui && uv run pytest -q`
Expected: import error — `workstation_tui.cli` does not exist yet. (First run also resolves the ephemeral test env; that is normal.)

- [ ] **Step 4: Implement `cli.py`**

```python
"""Click entry point. Bare invocation will launch the Textual app (later phase)."""

import click

from workstation_tui import __version__


@click.group(invoke_without_command=True)
@click.version_option(__version__, prog_name="workstation")
@click.pass_context
def main(ctx: click.Context) -> None:
    """Workstation control panel — TUI + headless subcommands."""
    if ctx.invoked_subcommand is None:
        click.echo("workstation: the TUI arrives in a later phase — see --help.")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd tui && uv run pytest -q`
Expected: `2 passed`

- [ ] **Step 6: Ignore Python build litter**

Append to the repo-root `.gitignore` (after the existing `.chezmoicache/` block):

```gitignore
# Python (tui/ package)
__pycache__/
*.pyc
.pytest_cache/
tui/.venv/
tui/dist/
```

- [ ] **Step 7: Commit**

```bash
git add tui/ .gitignore
git commit -m "feat(tui): workstation-tui package skeleton + minimal Click entry"
git push
```

---

### Task 2: Core pydantic models

**Files:**
- Create: `tui/src/workstation_tui/core/models.py`
- Test: `tui/tests/test_models.py`

**Interfaces:**
- Produces (exact, later tasks import these):
  - `StampState(StrEnum)` with members `FRESH="fresh"`, `STALE="stale"`, `MISSING="missing"`
  - `InventoryRow(BaseModel)`: `kind: Literal["scope","user","bespoke"]`, `name: str`, `version: str`
  - `ToolStatus(BaseModel)`: `name: str`, `kind: str`, `version: str`, `state: StampState`
  - `HostEntry(BaseModel)`: `name: str`, `address: str`, `user: str`, `group: Literal["dev_machine","prod_machine"]`
  - `HostContext(BaseModel)`: `os: Literal["linux","windows"]`, `is_wsl: bool`, `group: str | None`, `mode: Literal["dev","prod"]`, `has_make: bool`, `has_chezmoi: bool`, `has_systemctl: bool`, `has_sudo: bool`

- [ ] **Step 1: Write the failing test**

`tui/tests/test_models.py`:

```python
import pytest
from pydantic import ValidationError

from workstation_tui.core.models import (
    HostEntry,
    InventoryRow,
    StampState,
    ToolStatus,
)


def test_stamp_state_values() -> None:
    assert StampState.FRESH.value == "fresh"
    assert StampState.STALE.value == "stale"
    assert StampState.MISSING.value == "missing"


def test_host_entry_rejects_unknown_group() -> None:
    with pytest.raises(ValidationError):
        HostEntry(name="x", address="10.0.0.1", user="u", group="staging")


def test_inventory_row_rejects_unknown_kind() -> None:
    with pytest.raises(ValidationError):
        InventoryRow(kind="magic", name="fzf", version="0.74.2")


def test_tool_status_round_trip() -> None:
    t = ToolStatus(name="fzf", kind="scope", version="0.74.2", state=StampState.FRESH)
    assert t.model_dump()["state"] == "fresh"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && uv run pytest tests/test_models.py -q`
Expected: FAIL — `models` module does not exist.

- [ ] **Step 3: Implement `core/models.py`**

```python
"""Shared pydantic models — the contract between core readers, CLI, and app."""

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel


class StampState(StrEnum):
    FRESH = "fresh"      # exact stamp for the pinned version exists
    STALE = "stale"      # a stamp exists, but only for another version
    MISSING = "missing"  # no stamp at all


class InventoryRow(BaseModel):
    """One `kind|name|version` row from `make inventory` (DOCTOR_ROWS)."""

    kind: Literal["scope", "user", "bespoke"]
    name: str
    version: str  # pin, "latest", "-", or "<ver>-<hash>" for hashed stamps


class ToolStatus(BaseModel):
    name: str
    kind: str
    version: str
    state: StampState


class HostEntry(BaseModel):
    """One padded row of hosts.conf: name, address, user, group."""

    name: str
    address: str
    user: str
    group: Literal["dev_machine", "prod_machine"]


class HostContext(BaseModel):
    """Host identity + capability flags, resolved once at startup."""

    os: Literal["linux", "windows"]
    is_wsl: bool
    group: str | None  # from `chezmoi data` .group; None when undetectable
    mode: Literal["dev", "prod"]
    has_make: bool
    has_chezmoi: bool
    has_systemctl: bool
    has_sudo: bool
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && uv run pytest tests/test_models.py -q`
Expected: `4 passed`

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/models.py tui/tests/test_models.py
git commit -m "feat(tui): core pydantic models (stamp states, inventory, hosts, context)"
git push
```

---

### Task 3: versions.mk parser

**Files:**
- Create: `tui/src/workstation_tui/core/versions.py`
- Test: `tui/tests/test_versions.py`

**Interfaces:**
- Consumes: `repo_root` fixture (Task 1).
- Produces: `parse_versions_text(text: str) -> dict[str, str]` (VAR name → version, e.g. `"FZF_VERSION": "0.74.2"`); `read_versions(repo_root: Path) -> dict[str, str]` (reads `makefile/versions.mk`).

- [ ] **Step 1: Write the failing test**

`tui/tests/test_versions.py`:

```python
from pathlib import Path

from workstation_tui.core.versions import parse_versions_text, read_versions

SAMPLE = """\
# comment line
EGET_VERSION := 1.3.4
FZF_VERSION      := 0.74.2
NB_VERSION       := latest
NOT_A_PIN = ignored        # `=` not `:=` — not the pin contract
  INDENTED_VERSION := 9.9  # indented — not a pin definition
"""


def test_parse_versions_text() -> None:
    pins = parse_versions_text(SAMPLE)
    assert pins == {
        "EGET_VERSION": "1.3.4",
        "FZF_VERSION": "0.74.2",
        "NB_VERSION": "latest",
    }


def test_read_versions_against_real_repo(repo_root: Path) -> None:
    pins = read_versions(repo_root)
    # Anchor on stable facts, not exact values: the file is large and pins move.
    assert len(pins) > 50
    assert "FZF_VERSION" in pins
    assert pins["CHEZMOI_VERSION"] == "latest"
    assert all(v and " " not in v for v in pins.values())
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && uv run pytest tests/test_versions.py -q`
Expected: FAIL — `versions` module does not exist.

- [ ] **Step 3: Implement `core/versions.py`**

```python
"""Read tool version pins from makefile/versions.mk.

The pin contract (see versions.mk header): every pin is a top-of-line
`SOMENAME_VERSION := value` assignment. Anything else — comments, `=`
assignments, indented lines — is not a pin.
"""

import re
from pathlib import Path

_PIN_RE = re.compile(r"^([A-Z0-9_]+_VERSION)\s*:=\s*(\S+)", re.MULTILINE)


def parse_versions_text(text: str) -> dict[str, str]:
    return {m.group(1): m.group(2) for m in _PIN_RE.finditer(text)}


def read_versions(repo_root: Path) -> dict[str, str]:
    return parse_versions_text(
        (repo_root / "makefile" / "versions.mk").read_text(encoding="utf-8")
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && uv run pytest tests/test_versions.py -q`
Expected: `2 passed`

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/versions.py tui/tests/test_versions.py
git commit -m "feat(tui): versions.mk pin parser"
git push
```

---

### Task 4: `make inventory` target + inventory reader

**Files:**
- Modify: `makefile/Makefile` (next to the `doctor:` target, around line 823)
- Create: `tui/src/workstation_tui/core/makeiface.py`
- Test: `tui/tests/test_makeiface.py`

**Interfaces:**
- Consumes: `InventoryRow` (Task 2), `repo_root` fixture (Task 1).
- Produces: `parse_inventory(text: str) -> tuple[list[InventoryRow], list[str]]` (rows, error strings for unparseable lines); `read_inventory(repo_root: Path, mode: str) -> tuple[list[InventoryRow], list[str]]` (runs `make inventory`). Make target `inventory` printing one `kind|name|version` row per line.

- [ ] **Step 1: Add the `inventory` target to `makefile/Makefile`**

Directly below the existing `doctor:` recipe (keep the same single-quoting contract — rows contain `|`), add:

```make
# inventory — machine-readable DOCTOR_ROWS dump (kind|name|version, one row
# per line) for the workstation TUI's read layer (tui/…/core/makeiface.py).
# Same single-quoting contract as doctor: rows contain `|`.
inventory:
	@printf '%s\n' $(foreach r,$(DOCTOR_ROWS),'$(r)')
```

Find the `.PHONY:` line that declares `doctor` (`rg -n '\.PHONY.*doctor' makefile/Makefile`) and add `inventory` to it.

- [ ] **Step 2: Verify the target by hand**

Run: `make -C makefile --no-print-directory inventory MODE=prod | head -5` and `make -C makefile --no-print-directory inventory MODE=prod | grep -c '|'`
Expected: rows like `scope|fzf|0.74.2`, count > 90, no "Entering directory" noise, and a `bespoke|python-env|3.14.6-…` row present.

- [ ] **Step 3: Write the failing reader test**

`tui/tests/test_makeiface.py`:

```python
import shutil
from pathlib import Path

import pytest

from workstation_tui.core.makeiface import parse_inventory, read_inventory

SAMPLE = """\
scope|fzf|0.74.2
user|glances|latest
bespoke|python-env|3.14.6-2381415
bespoke|docker-engine|-
garbage line without pipes
too|many|pipes|here
"""


def test_parse_inventory_rows_and_errors() -> None:
    rows, errors = parse_inventory(SAMPLE)
    assert [(r.kind, r.name, r.version) for r in rows] == [
        ("scope", "fzf", "0.74.2"),
        ("user", "glances", "latest"),
        ("bespoke", "python-env", "3.14.6-2381415"),
        ("bespoke", "docker-engine", "-"),
    ]
    assert len(errors) == 2
    assert "garbage line without pipes" in errors[0]


@pytest.mark.skipif(shutil.which("make") is None, reason="make not on PATH")
def test_read_inventory_against_real_repo(repo_root: Path) -> None:
    rows, errors = read_inventory(repo_root, mode="prod")
    assert errors == []
    names = {r.name for r in rows}
    assert {"fzf", "chezmoi", "python-env"} <= names
    assert len(rows) > 90
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd tui && uv run pytest tests/test_makeiface.py -q`
Expected: FAIL — `makeiface` module does not exist.

- [ ] **Step 5: Implement `core/makeiface.py`**

```python
"""Read layer over make: the DOCTOR_ROWS tool inventory.

`make inventory` (added alongside doctor) prints the canonical
`kind|name|version` rows — the same single source of truth doctor.sh
consumes. Parsing versions.mk variable names instead is a trap: the var→tool
mapping is not derivable (TEALDEER_VERSION → tldr).

Mutation command *builders* join this module in a later phase.
"""

import subprocess
from pathlib import Path

from pydantic import ValidationError

from workstation_tui.core.models import InventoryRow


def parse_inventory(text: str) -> tuple[list[InventoryRow], list[str]]:
    rows: list[InventoryRow] = []
    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) != 3:
            errors.append(f"line {lineno}: not kind|name|version: {line!r}")
            continue
        try:
            rows.append(InventoryRow(kind=parts[0], name=parts[1], version=parts[2]))
        except ValidationError as exc:
            errors.append(f"line {lineno}: {exc.errors()[0]['msg']}: {line!r}")
    return rows, errors


def read_inventory(repo_root: Path, mode: str) -> tuple[list[InventoryRow], list[str]]:
    proc = subprocess.run(
        ["make", "--no-print-directory", "-C", str(repo_root / "makefile"),
         "inventory", f"MODE={mode}"],
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        return [], [f"make inventory failed (rc={proc.returncode}): {proc.stderr.strip()}"]
    return parse_inventory(proc.stdout)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd tui && uv run pytest tests/test_makeiface.py -q`
Expected: `2 passed`

- [ ] **Step 7: Commit**

```bash
git add makefile/Makefile tui/src/workstation_tui/core/makeiface.py tui/tests/test_makeiface.py
git commit -m "feat(tui): make inventory target + DOCTOR_ROWS reader"
git push
```

---

### Task 5: Stamp scanner

**Files:**
- Create: `tui/src/workstation_tui/core/stamps.py`
- Test: `tui/tests/test_stamps.py`

**Interfaces:**
- Consumes: `StampState`, `InventoryRow`, `ToolStatus` (Task 2).
- Produces: `stamp_state(stamp_dir: Path, name: str, version: str) -> StampState`; `scan(stamp_dir: Path, rows: list[InventoryRow]) -> list[ToolStatus]`. Default stamp dir constant `DEFAULT_STAMP_DIR = Path.home() / ".local/share/workstation-install"`.

- [ ] **Step 1: Write the failing test**

`tui/tests/test_stamps.py`:

```python
from pathlib import Path

from workstation_tui.core.models import InventoryRow, StampState
from workstation_tui.core.stamps import scan, stamp_state


def make_stamps(tmp_path: Path, names: list[str]) -> Path:
    for n in names:
        (tmp_path / n).touch()
    return tmp_path


def test_fresh_exact_match(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["fzf-0.74.2.done"])
    assert stamp_state(d, "fzf", "0.74.2") is StampState.FRESH


def test_stale_other_version_only(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["ast-grep-0.44.1.done"])
    assert stamp_state(d, "ast-grep", "0.45.0") is StampState.STALE


def test_missing(tmp_path: Path) -> None:
    assert stamp_state(tmp_path, "fzf", "0.74.2") is StampState.MISSING


def test_latest_pin_is_exact(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["nb-latest.done"])
    assert stamp_state(d, "nb", "latest") is StampState.FRESH


def test_dash_version_globs(tmp_path: Path) -> None:
    # "-" rows (docker-engine, lsp-servers-<hash>, wsl-config-<hash>) can't
    # know their stamp suffix: any stamp counts as FRESH, none as MISSING.
    d = make_stamps(tmp_path, ["docker-engine.done", "lsp-servers-8f3a.done"])
    assert stamp_state(d, "docker-engine", "-") is StampState.FRESH
    assert stamp_state(d, "lsp-servers", "-") is StampState.FRESH
    assert stamp_state(d, "wsl-config", "-") is StampState.MISSING


def test_hashed_version_is_exact(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["python-env-3.14.6-2381415.done"])
    assert stamp_state(d, "python-env", "3.14.6-2381415") is StampState.FRESH
    assert stamp_state(d, "python-env", "3.14.6-9999999") is StampState.STALE


def test_scan_maps_rows(tmp_path: Path) -> None:
    d = make_stamps(tmp_path, ["fzf-0.74.2.done"])
    rows = [
        InventoryRow(kind="scope", name="fzf", version="0.74.2"),
        InventoryRow(kind="scope", name="zellij", version="0.44.3"),
    ]
    result = scan(d, rows)
    assert [(t.name, t.state) for t in result] == [
        ("fzf", StampState.FRESH),
        ("zellij", StampState.MISSING),
    ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && uv run pytest tests/test_stamps.py -q`
Expected: FAIL — `stamps` module does not exist.

- [ ] **Step 3: Implement `core/stamps.py`**

```python
"""Scan the workstation-install stamp dir for per-tool freshness.

Stamp naming (makefile/Makefile _RULE_BODY): `<name>-<version>.done`.
Versioned rows: exact stamp → FRESH; any other `<name>-*.done` → STALE
(old-version stamps linger after bumps — that IS the stale signal); none →
MISSING. Rows with version "-" (docker-engine, lsp-servers, wsl-config —
unversioned or content-hash stamps) can't predict their suffix: any
`<name>.done` / `<name>-*.done` → FRESH, else MISSING; never STALE.
"""

from pathlib import Path

from workstation_tui.core.models import InventoryRow, StampState, ToolStatus

DEFAULT_STAMP_DIR = Path.home() / ".local/share/workstation-install"


def stamp_state(stamp_dir: Path, name: str, version: str) -> StampState:
    if version == "-":
        if (stamp_dir / f"{name}.done").exists() or any(
            stamp_dir.glob(f"{name}-*.done")
        ):
            return StampState.FRESH
        return StampState.MISSING
    if (stamp_dir / f"{name}-{version}.done").exists():
        return StampState.FRESH
    if any(stamp_dir.glob(f"{name}-*.done")):
        return StampState.STALE
    return StampState.MISSING


def scan(stamp_dir: Path, rows: list[InventoryRow]) -> list[ToolStatus]:
    return [
        ToolStatus(
            name=r.name,
            kind=r.kind,
            version=r.version,
            state=stamp_state(stamp_dir, r.name, r.version),
        )
        for r in rows
    ]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && uv run pytest tests/test_stamps.py -q`
Expected: `7 passed`

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/stamps.py tui/tests/test_stamps.py
git commit -m "feat(tui): stamp-dir freshness scanner"
git push
```

---

### Task 6: hosts.conf parser

**Files:**
- Create: `tui/src/workstation_tui/core/hostsfile.py`
- Test: `tui/tests/test_hostsfile.py`

**Interfaces:**
- Consumes: `HostEntry` (Task 2), `repo_root` fixture (Task 1).
- Produces: `parse_hosts_text(text: str) -> tuple[list[HostEntry], list[str]]`; `read_hosts(repo_root: Path) -> tuple[list[HostEntry], list[str]]` (reads `hosts.conf` at the repo root). READ-ONLY — all hosts.conf writes go through manage-hosts (spec rule).

- [ ] **Step 1: Write the failing test**

`tui/tests/test_hostsfile.py`:

```python
from pathlib import Path

from workstation_tui.core.hostsfile import parse_hosts_text, read_hosts

SAMPLE = """\
# fleet
atc-cache-dev09   ***REMOVED-IP***      arrush.chaturvedi  dev_machine
cache-apl         ***REMOVED-IP***     arrush.chaturvedi  prod_machine

short-line 10.0.0.1
bad-group   10.0.0.2   user   staging_machine
"""


def test_parse_hosts_text() -> None:
    entries, errors = parse_hosts_text(SAMPLE)
    assert [(e.name, e.group) for e in entries] == [
        ("atc-cache-dev09", "dev_machine"),
        ("cache-apl", "prod_machine"),
    ]
    assert entries[0].address == "***REMOVED-IP***"
    assert entries[0].user == "arrush.chaturvedi"
    assert len(errors) == 2  # short line + invalid group


def test_read_hosts_against_real_repo(repo_root: Path) -> None:
    entries, errors = read_hosts(repo_root)
    assert errors == []
    assert len(entries) >= 2
    assert all(e.group in ("dev_machine", "prod_machine") for e in entries)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && uv run pytest tests/test_hostsfile.py -q`
Expected: FAIL — `hostsfile` module does not exist.

- [ ] **Step 3: Implement `core/hostsfile.py`**

```python
"""Parse hosts.conf (READ-ONLY — every write goes through manage-hosts).

Format (manage-hosts re-pads on save): one host per line,
`name  address  user  group`, whitespace-separated; blank lines and
full-line `#` comments allowed.
"""

from pathlib import Path

from pydantic import ValidationError

from workstation_tui.core.models import HostEntry


def parse_hosts_text(text: str) -> tuple[list[HostEntry], list[str]]:
    entries: list[HostEntry] = []
    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 4:
            errors.append(f"line {lineno}: expected 4 fields, got {len(parts)}: {line!r}")
            continue
        try:
            entries.append(
                HostEntry(name=parts[0], address=parts[1], user=parts[2], group=parts[3])
            )
        except ValidationError as exc:
            errors.append(f"line {lineno}: {exc.errors()[0]['msg']}: {line!r}")
    return entries, errors


def read_hosts(repo_root: Path) -> tuple[list[HostEntry], list[str]]:
    return parse_hosts_text((repo_root / "hosts.conf").read_text(encoding="utf-8"))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && uv run pytest tests/test_hostsfile.py -q`
Expected: `2 passed`

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/hostsfile.py tui/tests/test_hostsfile.py
git commit -m "feat(tui): hosts.conf read-only parser"
git push
```

---

### Task 7: Host context detection

**Files:**
- Create: `tui/src/workstation_tui/core/context.py`
- Test: `tui/tests/test_context.py`

**Interfaces:**
- Consumes: `HostContext` (Task 2).
- Produces: `detect_context(*, which=shutil.which, run=subprocess.run, proc_version=Path("/proc/version"), platform=sys.platform) -> HostContext`. All collaborators injectable for tests; group detection shells `chezmoi data --format json` and reads `.group`, degrading to `None`.

- [ ] **Step 1: Write the failing test**

`tui/tests/test_context.py`:

```python
import json
import subprocess
from pathlib import Path

from workstation_tui.core.context import detect_context


def fake_run_factory(group: str | None, fail: bool = False):
    def fake_run(cmd, **kwargs):
        if fail:
            raise FileNotFoundError(cmd[0])
        data = {"group": group} if group else {}
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(data), stderr="")
    return fake_run


def which_all(name: str) -> str:
    return f"/usr/bin/{name}"


def which_none(name: str) -> None:
    return None


def test_dev_linux_wsl(tmp_path: Path) -> None:
    pv = tmp_path / "version"
    pv.write_text("Linux version 6.6.87.2-microsoft-standard-WSL2 ...")
    ctx = detect_context(
        which=which_all, run=fake_run_factory("dev_machine"),
        proc_version=pv, platform="linux",
    )
    assert ctx.os == "linux"
    assert ctx.is_wsl is True
    assert ctx.group == "dev_machine"
    assert ctx.mode == "dev"
    assert ctx.has_make is True


def test_prod_defaults_when_group_unknown(tmp_path: Path) -> None:
    pv = tmp_path / "version"
    pv.write_text("Linux version 5.14.0-elrepo ...")
    ctx = detect_context(
        which=which_none, run=fake_run_factory(None, fail=True),
        proc_version=pv, platform="linux",
    )
    assert ctx.group is None
    assert ctx.mode == "prod"  # unknown group defaults to the safe scope
    assert ctx.is_wsl is False
    assert ctx.has_sudo is False


def test_windows(tmp_path: Path) -> None:
    ctx = detect_context(
        which=which_all, run=fake_run_factory("dev_machine"),
        proc_version=tmp_path / "absent", platform="win32",
    )
    assert ctx.os == "windows"
    assert ctx.is_wsl is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && uv run pytest tests/test_context.py -q`
Expected: FAIL — `context` module does not exist.

- [ ] **Step 3: Implement `core/context.py`**

```python
"""Resolve host identity + capabilities once at startup.

Group comes from `chezmoi data` (.group — set by .chezmoi.toml.tmpl from
WORKSTATION_GROUP at init). WSL detection mirrors bootstrap.sh is_wsl():
"microsoft" in /proc/version, case-insensitive. Unknown group → prod mode
(the no-sudo scope is the safe default).
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

from workstation_tui.core.models import HostContext


def _detect_group(run) -> str | None:
    try:
        proc = run(
            ["chezmoi", "data", "--format", "json"],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode != 0:
            return None
        value = json.loads(proc.stdout).get("group")
        return value if isinstance(value, str) else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def detect_context(
    *,
    which=shutil.which,
    run=subprocess.run,
    proc_version: Path = Path("/proc/version"),
    platform: str = sys.platform,
) -> HostContext:
    os_name = "windows" if platform.startswith("win") else "linux"
    try:
        is_wsl = os_name == "linux" and "microsoft" in proc_version.read_text().lower()
    except OSError:
        is_wsl = False
    group = _detect_group(run) if which("chezmoi") else None
    return HostContext(
        os=os_name,
        is_wsl=is_wsl,
        group=group,
        mode="dev" if group == "dev_machine" else "prod",
        has_make=which("make") is not None,
        has_chezmoi=which("chezmoi") is not None,
        has_systemctl=which("systemctl") is not None,
        has_sudo=which("sudo") is not None,
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && uv run pytest tests/test_context.py -q`
Expected: `3 passed`. Also run the full suite: `cd tui && uv run pytest -q` — everything green.

- [ ] **Step 5: Commit**

```bash
git add tui/src/workstation_tui/core/context.py tui/tests/test_context.py
git commit -m "feat(tui): host context detection (os/wsl/group/mode/capabilities)"
git push
```

---

### Task 8: Promote python-env to both scopes

**Files:**
- Modify: `makefile/Makefile` — the python-env block (~lines 364–405) + `list`/`help` text (~lines 898, 920)
- Modify: `docs/claude/invariants.md` — python-env section (find with `rg -n 'python-env' docs/claude/invariants.md`)

**Interfaces:**
- Produces: `make python-env MODE=prod` builds the env (no longer skips). Task 9 relies on this target running in both modes.

- [ ] **Step 1: Remove the dev gate**

In `makefile/Makefile`, the python-env rule currently reads:

```make
ifeq ($(MODE),dev)
python-env: $(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done
$(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done: | $(STAMP)/uv-$(UV_VERSION).done
	@printf '==> python-env %s\n' "$(PYTHON_VERSION)"
	@$(LIB)/python-env.sh $(PYTHON_VERSION)
	@mkdir -p $(@D) && touch $@
else
python-env:
	@echo "python-env is a dev_machine target — skipping (MODE=$(MODE))"
endif
```

Replace with (gate gone, rule identical):

```make
python-env: $(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done
$(STAMP)/python-env-$(PYTHON_VERSION)-$(PYTHON_ENV_STAMP).done: | $(STAMP)/uv-$(UV_VERSION).done
	@printf '==> python-env %s\n' "$(PYTHON_VERSION)"
	@$(LIB)/python-env.sh $(PYTHON_VERSION)
	@mkdir -p $(@D) && touch $@
```

Update the block's comment header: change `blessed Python scripting env (dev_machine only).` to `blessed Python scripting env (BOTH scopes — the workstation TUI ships in it).` and drop any other "dev only" phrasing inside that comment. `python-env` already sits in `PROVISION_FANOUT`, which runs in both modes — no fanout change needed.

- [ ] **Step 2: Update `list` and `help` text**

In the `list:` recipe change
`@printf '\npython-env (provisioned on MODE=dev only): blessed Python scripting env (uv-managed CPython + venv)\n'`
to
`@printf '\npython-env (both scopes): blessed Python scripting env (uv-managed CPython + venv)\n'`.
In the `help:` recipe change
`@echo "  make python-env       build the blessed Python scripting env (dev only)"`
to
`@echo "  make python-env       build the blessed Python scripting env (both scopes)"`.
Check for any other stale mention: `rg -n 'python-env' makefile/Makefile` — every hit must now be gate-free and scope-accurate.

- [ ] **Step 3: Update `docs/claude/invariants.md`**

Find its python-env entry (`rg -n 'python-env' docs/claude/invariants.md`) and rewrite the scope claim: dev-only → both scopes, noting the reason (the workstation TUI lives in the env and must exist on prod hosts) and that the target stays USER-LEVEL/never-sudo (unchanged, prod-safe).

- [ ] **Step 4: Verify with dry runs**

Run: `make -C makefile -n python-env MODE=prod | head -3`
Expected: the real recipe (`python-env.sh 3.14.6`), NOT the skip echo.
Run: `make -C makefile -n python-env MODE=dev | head -3`
Expected: identical recipe.
Run: `make -C makefile lint MODE=prod`
Expected: all invariant checks pass.

- [ ] **Step 5: Commit**

```bash
git add makefile/Makefile docs/claude/invariants.md
git commit -m "feat(python-env): promote to both scopes — TUI substrate on prod hosts"
git push
```

---

### Task 9: Editable TUI install + `workstation` launcher (Linux + Windows + invariant check, ONE commit)

**Files:**
- Modify: `makefile/lib/python-env.sh`
- Modify: `makefile/Makefile` (`clean-python-env` recipe)
- Modify: `bootstrap.ps1` (`Invoke-PythonEnv`)
- Modify: `scripts/check-invariants.sh` (new parity check)

These are a parity pair plus the check that enforces it — they MUST land in one commit or the invariant check fails in between.

**Interfaces:**
- Consumes: Task 8 (target runs in both modes), Task 1 (`tui/pyproject.toml` console script).
- Produces: `~/.local/bin/workstation` (Linux) and `%LOCALAPPDATA%\workstation\bin\workstation.cmd` (Windows) running the installed CLI; `check_tui_install_parity` in check-invariants.

- [ ] **Step 1: Extend `makefile/lib/python-env.sh`**

After the `uv pip install --python "$env_dir/bin/python" --upgrade "${PY_LIBS[@]}"` line, add:

```bash
# The workstation TUI installs EDITABLE from this repo checkout, so
# `chezmoi update` / `git pull` updates it fleet-wide with no reinstall.
# Dependency changes in tui/pyproject.toml are the one case needing
# `make python-env-rebuild`. PARITY: Invoke-PythonEnv in bootstrap.ps1
# carries the Windows half (check-invariants.sh check_tui_install_parity).
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
uv pip install --python "$env_dir/bin/python" -e "$repo_root/tui"
```

In the launcher block, after the `ln -sf` lines for textual/typer, add:

```bash
ln -sf "$env_dir/bin/workstation" "$bin_dir/workstation"
```

(`workstation` is a pip-generated console script whose shebang points into the env — the textual/typer symlink pattern, NOT the wpy wrapper case.) Update the closing printf to
`'python-env: CPython %s + %d libs + workstation-tui at %s (launchers: wpy, textual, typer, workstation)\n'`.

- [ ] **Step 2: Extend `clean-python-env` in `makefile/Makefile`**

Change the launcher-removal line to include the new launcher:

```make
	@rm -f $(HOME)/.local/bin/wpy $(HOME)/.local/bin/textual $(HOME)/.local/bin/typer $(HOME)/.local/bin/workstation
```

- [ ] **Step 3: Extend `Invoke-PythonEnv` in `bootstrap.ps1`**

After the `& $uvExe pip install --python $envPy --upgrade $PythonLibs` block (keep its `$LASTEXITCODE` check pattern), add:

```powershell
        # Editable install of the repo's workstation TUI (PARITY: python-env.sh
        # carries the Linux half; check-invariants check_tui_install_parity).
        & $uvExe pip install --python $envPy -e (Join-Path $PSScriptRoot "tui")
        if ($LASTEXITCODE -ne 0) { throw "uv pip install tui exited $LASTEXITCODE" }
```

In the launcher-shim block add:

```powershell
        Set-Content -Path (Join-Path $WsBin "workstation.cmd") -Value "@echo off`r`n`"$(Join-Path $scripts 'workstation.exe')`" %*" -Encoding Ascii
```

And extend the early-return guard so hosts with a valid stamp but no new shim self-heal — change

```powershell
    if ((Test-Path $stamp) -and (Test-Path $wpyShim)) {
```

to

```powershell
    $workstationShim = Join-Path $WsBin "workstation.cmd"
    if ((Test-Path $stamp) -and (Test-Path $wpyShim) -and (Test-Path $workstationShim)) {
```

Update the final `Write-Ok` launcher list to `launchers: wpy, textual, typer, workstation`.

- [ ] **Step 4: Add the parity check to `scripts/check-invariants.sh`**

Directly after `check_python_env_parity()`, add (matching its style):

```bash
# The tui/ editable install is a parity pair: makefile/lib/python-env.sh
# (Linux) and bootstrap.ps1 Invoke-PythonEnv (Windows) must both install the
# repo's tui/ package into the blessed env, or one platform silently ships
# without the workstation TUI.
check_tui_install_parity() {
  hdr "tui editable-install parity (python-env.sh == bootstrap.ps1)"
  local sh_ok=1 ps_ok=1
  grep -qE 'uv pip install .*-e "\$repo_root/tui"' makefile/lib/python-env.sh || sh_ok=0
  grep -qE 'pip install --python \$envPy -e \(Join-Path \$PSScriptRoot "tui"\)' bootstrap.ps1 || ps_ok=0
  if [ "$sh_ok" = 1 ] && [ "$ps_ok" = 1 ]; then
    ok "editable tui/ install present in both halves"
  else
    [ "$sh_ok" = 1 ] || bad "python-env.sh: editable tui/ install line missing"
    [ "$ps_ok" = 1 ] || bad "bootstrap.ps1: editable tui/ install line missing"
  fi
}
```

Add `check_tui_install_parity` to the call list immediately after the existing `check_python_env_parity` call (near the bottom of the script).

- [ ] **Step 5: Check the parity-reminder hook**

Run: `rg -n 'python-env' .claude/hooks/parity-reminder.sh`
If the python-env.sh ↔ bootstrap.ps1 pair is already nudged (it should be, for PY_LIBS), no change. If absent, add the pair following the hook's existing pattern, then run `bash .claude/hooks/test-hooks.sh` and confirm it passes (repo rule: any hook edit → re-run the hook tests).

- [ ] **Step 6: Verify file hygiene + invariants**

```bash
file makefile/lib/python-env.sh                      # must NOT say CRLF
git ls-files --stage makefile/lib/python-env.sh      # 100755
head -c3 bootstrap.ps1 | xxd                         # ef bb bf (BOM intact)
make -C makefile lint MODE=prod                      # all checks incl. the new one
```

- [ ] **Step 7: Verify at runtime (real rebuild — user-level, no sudo)**

```bash
make -C makefile python-env-rebuild MODE=dev
~/.local/bin/workstation --version                   # prints "workstation, version 0.1.0"
readlink ~/.local/bin/workstation                    # points into workstation-python/bin
wpy -c "import workstation_tui; print(workstation_tui.__file__)"
                                                      # resolves under <repo>/tui/src (editable)
```

- [ ] **Step 8: Commit (single commit — parity pair + its check)**

```bash
git add makefile/lib/python-env.sh makefile/Makefile bootstrap.ps1 scripts/check-invariants.sh .claude/hooks/
git commit -m "feat(tui): editable install into blessed env + workstation launchers (Linux/Windows) + parity check"
git push
```

---

### Task 10: CI job + `make tui-test`

**Files:**
- Modify: `.github/workflows/lint.yml` (new job after `templates`)
- Modify: `makefile/Makefile` (new `tui-test` target + `.PHONY` + a `help` line)

**Interfaces:**
- Consumes: the test suite from Tasks 1–7.
- Produces: CI job `tui-tests`; local `make tui-test MODE=prod`.

- [ ] **Step 1: Add the CI job**

Append to `.github/workflows/lint.yml` `jobs:` (same indent as `invariants:`):

```yaml
  tui-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: astral-sh/setup-uv@v6
      - name: Run workstation-tui test suite
        run: cd tui && uv run pytest -q
```

(`uv run` resolves the project deps + dev group and auto-fetches CPython ≥3.14 — no setup-python step needed.)

- [ ] **Step 2: Add the make wrapper**

In `makefile/Makefile`, next to the `lint:` target:

```make
# tui-test — run the workstation-tui suite the same way CI's tui-tests job
# does (uv-managed ephemeral env, NOT the blessed env).
.PHONY: tui-test
tui-test:
	@cd $(REPO_ROOT)/tui && uv run pytest -q
```

Add a `help:` line: `@echo "  make tui-test         run the workstation TUI test suite (uv + pytest)"`.

- [ ] **Step 3: Verify**

Run: `make -C makefile tui-test MODE=prod`
Expected: full suite passes (the counts from Tasks 1–7).
Run: `yq '.jobs | keys' .github/workflows/lint.yml`
Expected: includes `tui-tests`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/lint.yml makefile/Makefile
git commit -m "ci(tui): tui-tests job + make tui-test wrapper"
git push
```

After push: `gh run watch` (or `gh pr checks` once the PR exists) — confirm the new job actually runs and passes.

---

### Task 11: Docs — README, changelog, CLAUDE.md, spec note

**Files:**
- Modify: `README.html` (python-env scope mentions; anchors below)
- Modify: `CLAUDE_CHANGELOG.md` (two rows)
- Modify: `CLAUDE.md` (python-env invariant bullet + parity-pair list)
- Modify: `docs/claude/file-care.md` (python-env.sh entry, if present — check `rg -n 'python-env' docs/claude/file-care.md`)
- Modify: `docs/superpowers/specs/2026-08-05-workstation-tui-design.md` (inventory refinement)

**Interfaces:** none (docs only).

- [ ] **Step 1: README.html**

Find every python-env mention (`rg -n 'python-env|wpy' README.html`) and update scope claims:
- The §stack card `>python-env <small>(dev)</small>`: drop the `(dev)` tag; extend its `data-tip` to mention the `workstation` launcher (e.g. append `+ the workstation TUI/CLI (editable install)`).
- The rebuild snippet `make python-env-rebuild MODE=dev` and the troubleshooting entry that repeats it: change to `make python-env-rebuild MODE=dev   # or MODE=prod` (the target now exists in both scopes).
- Any "dev only"/"dev_machine only" prose around python-env: reword to both-scopes.
- Add `workstation` to the launcher lists that currently read `wpy`/`textual`/`typer` (Linux §stack text and the Windows §setup-windows text near `%LOCALAPPDATA%\workstation\python-env`).
Do NOT add a full §tui section — that is Phase 6; the launcher is a stub until then.

- [ ] **Step 2: CLAUDE_CHANGELOG.md**

Append two rows to the table:

```markdown
| python-env promoted dev-only → both scopes (workstation TUI substrate) | Yes | §stack card lost the `(dev)` tag; rebuild snippets note MODE=dev\|prod |
| workstation TUI Phase 1: tui/ package, editable install into python-env, `workstation` launcher (Linux+Windows), tui-tests CI | Minimal | launcher named in python-env card/launcher lists; full §tui section deferred to the TUI's final phase |
```

- [ ] **Step 3: CLAUDE.md**

- Python-env invariant bullet: change `**python-env is a dev-only bespoke target, USER-LEVEL (never $(SUDO))**` to `**python-env is a BOTH-SCOPES bespoke target, USER-LEVEL (never $(SUDO))**`, and append to that bullet: `The repo's tui/ package (workstation TUI) installs EDITABLE into the env with a `workstation` launcher (wpy-adjacent symlink on Linux, workstation.cmd shim on Windows); the editable-install step is a parity pair verified by check_tui_install_parity.`
- File-care "Parity pairs" line: extend the python-env entry to `makefile/lib/python-env.sh `PY_LIBS` + tui editable-install ↔ bootstrap.ps1 `$PythonLibs` + Invoke-PythonEnv tui install (verified by check-invariants.sh)`.

- [ ] **Step 4: docs/claude/file-care.md + spec**

- If file-care.md has a python-env.sh entry, mirror the scope/parity wording from Step 3.
- In the spec (`docs/superpowers/specs/2026-08-05-workstation-tui-design.md`), in the Code architecture section, amend the `versions.py` line to note: tool inventory actually comes from the `make inventory` DOCTOR_ROWS dump via `makeiface.py` (var→tool names aren't derivable: TEALDEER_VERSION→tldr); `versions.py` parses raw pins only.

- [ ] **Step 5: Verify + commit**

Open README.html in a browser (or at minimum re-run `rg -n '\(dev\)' README.html` near python-env) to confirm no stale scope claims; then:

```bash
git add README.html CLAUDE_CHANGELOG.md CLAUDE.md docs/claude/ docs/superpowers/specs/2026-08-05-workstation-tui-design.md
git commit -m "docs: python-env both-scopes + workstation TUI phase-1 surface"
git push
```

---

### Task 12: Full-suite gate + PR

**Files:** none new.

- [ ] **Step 1: Run everything**

```bash
make -C makefile lint MODE=prod        # invariants + shellcheck + shfmt + gitleaks
make -C makefile tui-test MODE=prod    # full pytest suite
bash scripts/check-templates.sh        # unrelated templates still render
```

Expected: all green.

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "feat(tui): workstation TUI Phase 1 — foundations" --body "$(cat <<'EOF'
Phase 1 of the workstation TUI (spec: docs/superpowers/specs/2026-08-05-workstation-tui-design.md):

- tui/ package (src layout): tested core parsers (versions.mk pins, DOCTOR_ROWS
  inventory via new `make inventory`, stamp freshness, hosts.conf, host context)
  + minimal `workstation` Click entry
- python-env promoted dev-only → both scopes (user-level, prod-safe)
- editable TUI install into the blessed env + `workstation` launchers
  (Linux symlink / Windows .cmd shim) + check-invariants parity check
- tui-tests CI job + `make tui-test`

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01UfFaGAdVaLjVVrnq4jNJ9p
EOF
)"
```

- [ ] **Step 3: Watch checks**

`gh pr checks --watch` — all jobs (invariants, powershell, templates, tui-tests) green. Hand the PR to the user for review/merge.
