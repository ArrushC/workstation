"""Updates core: parsing + caching for `make check-updates`'s porcelain output.

`check_updates_command` (core/makeiface.py, `porcelain=True` by default)
builds the argv that runs `make check-updates MODE=<mode>
CHECK_UPDATES_PORCELAIN=1` — GNU make exports a command-line `VAR=value`
assignment into the recipe environment, and `makefile/lib/check-updates.sh`
(lines ~138-148) takes its porcelain branch whenever `CHECK_UPDATES_
PORCELAIN` is non-empty, printing ONLY `status|name|detail` lines (one per
tool, no banner/summary/ANSI). `parse_updates` below turns that stdout into
`UpdateRow`s; `load_updates_cache`/`save_updates_cache` persist the last run
to disk, following the same discipline as `core/health.py`'s
`load_cache`/`save_cache`: never raise, missing/corrupt/schema-mismatch
degrades to empty, writes are atomic (tmp + os.replace).

This is pure-core groundwork for Task 2's UpdatesScreen — no UI here.

core/ NEVER imports textual.
"""

import json
import os
import re
from pathlib import Path

from pydantic import BaseModel

#: The five statuses `check-updates.sh` ever prints (worker mode: ok, update,
#: ahead, rolling, unknown — see the script's case analysis). Any other
#: first field is not a real row and is skipped rather than raised on.
_KNOWN_STATUSES = {"ok", "update", "ahead", "rolling", "unknown"}

#: `update` detail shape is exactly `<pinned> → <latest>` (U+2192 arrow,
#: spaces either side) — makefile/lib/check-updates.sh lines 66 and 118.
_UPDATE_DETAIL_RE = re.compile(r"^(\S+) → (\S+)$")

#: Sort weight for `sort_rows(rows, key="status")` — updates/ahead/unknown
#: float to the top (things worth a human's attention), ok/rolling sink.
STATUS_ORDER: dict[str, int] = {"update": 0, "ahead": 1, "unknown": 2, "ok": 3, "rolling": 4}


class UpdateRow(BaseModel):
    """One parsed `status|name|detail` porcelain line."""

    status: str
    name: str
    detail: str
    pinned: str | None = None
    latest: str | None = None


class UpdatesCache(BaseModel):
    """On-disk cache of the last `check-updates` porcelain run."""

    checked_at: str | None = None  # ISO-8601 UTC
    rows: list[UpdateRow] = []


def parse_updates(text: str) -> list[UpdateRow]:
    """Parse porcelain `status|name|detail` lines into `UpdateRow`s.

    Defensive end to end — this feeds a cache that must degrade gracefully
    rather than crash the TUI: a non-str `text`, blank lines, lines that
    don't split into exactly 3 `|`-separated fields, and statuses outside
    `_KNOWN_STATUSES` are all silently skipped. Only `status == "update"`
    attempts the `pinned → latest` detail split; every other status
    keeps `pinned`/`latest` as `None`. Never raises.
    """
    try:
        if not isinstance(text, str):
            return []
        rows: list[UpdateRow] = []
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line:
                continue
            parts = line.split("|", 2)
            if len(parts) != 3:
                continue
            status, name, detail = parts
            if status not in _KNOWN_STATUSES:
                continue
            pinned: str | None = None
            latest: str | None = None
            if status == "update":
                match = _UPDATE_DETAIL_RE.match(detail)
                if match is not None:
                    pinned, latest = match.group(1), match.group(2)
            rows.append(
                UpdateRow(status=status, name=name, detail=detail, pinned=pinned, latest=latest)
            )
        return rows
    except Exception:
        return []


def load_updates_cache(path: Path) -> UpdatesCache:
    """Load the updates cache from JSON.

    Returns an empty `UpdatesCache()` on a missing file, corrupt JSON, or
    schema mismatch. Never raises.
    """
    try:
        if not path.exists():
            return UpdatesCache()
        data = json.loads(path.read_text())
        return UpdatesCache(**data)
    except Exception:
        return UpdatesCache()


def save_updates_cache(path: Path, cache: UpdatesCache) -> bool:
    """Save the updates cache atomically (tmp + os.replace), like `core/health.py`.

    Creates parent directories as needed. Returns False on failure (write
    error, permission issue, etc.) rather than raising.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(cache.model_dump(), indent=2))
        os.replace(tmp_path, path)
        return True
    except Exception:
        return False


def sort_rows(rows: list[UpdateRow], key: str) -> list[UpdateRow]:
    """Sort rows for display.

    `key="status"` sorts by `STATUS_ORDER` then name; `key="name"` sorts by
    name alone; any other key falls back to the status-order sort.
    """
    if key == "name":
        return sorted(rows, key=lambda row: row.name)
    return sorted(
        rows, key=lambda row: (STATUS_ORDER.get(row.status, len(STATUS_ORDER)), row.name)
    )
