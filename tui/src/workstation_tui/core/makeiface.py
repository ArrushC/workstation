"""Read layer over make: the DOCTOR_ROWS tool inventory.

`make inventory` (added alongside doctor) prints the canonical
`kind|name|version` rows — the same single source of truth doctor.sh
consumes. Parsing versions.mk variable names instead is a trap: the var→tool
mapping is not derivable (TEALDEER_VERSION → tldr).

Mutation command *builders* join this module in a later phase.
"""

import os
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
    try:
        # Scrub inherited MAKEFLAGS, MFLAGS, MAKELEVEL from the environment.
        # When make is invoked with jobserver-auth flags, GNU make ignores
        # --no-print-directory and prints directory-announcement lines, which
        # corrupts parsed inventory rows. Build an explicit env to ensure
        # the nested make inventory subprocess runs cleanly.
        env = {k: v for k, v in os.environ.items()
               if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
        proc = subprocess.run(
            ["make", "--no-print-directory", "-C", str(repo_root / "makefile"),
             "inventory", f"MODE={mode}"],
            capture_output=True, text=True, timeout=30, env=env,
        )
        if proc.returncode != 0:
            return [], [f"make inventory failed (rc={proc.returncode}): {proc.stderr.strip()}"]
        return parse_inventory(proc.stdout)
    except subprocess.TimeoutExpired as exc:
        return [], [f"make inventory failed: timeout after {exc.timeout}s"]
    except OSError as exc:
        return [], [f"make inventory failed: {exc}"]
