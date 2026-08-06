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

# DOCTOR_ROWS names that differ from their stamp file's basename — the three
# hand-written bespoke targets in makefile/Makefile write stamps under their
# short names (claude-<ver>.done, node-<ver>.done, go-<ver>.done) while their
# inventory rows carry the target name. Remap here rather than renaming the
# stamps: a rename would orphan every provisioned host's existing stamps.
_STAMP_BASENAME_OVERRIDES = {
    "claude-cli": "claude",
    "node-runtime": "node",
    "go-runtime": "go",
}


def stamp_state(stamp_dir: Path, name: str, version: str) -> StampState:
    name = _STAMP_BASENAME_OVERRIDES.get(name, name)
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
