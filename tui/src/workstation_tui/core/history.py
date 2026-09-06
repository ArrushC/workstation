"""History core: entry model + never-raise on-disk store.

`HistoryEntry` is the record of one runner task/sequence/push/keydist run;
`HistoryStore` persists them as an append-only `root/index.jsonl` (one
`entry.model_dump_json()` per line, oldest line first) plus one
`root/<id>.log` file per entry holding its captured output. This mirrors
`core/updates.py`'s `UpdatesCache` discipline (Task 2) and `core/health.py`'s
cache (atomic tmp + `os.replace` writes, never-raise load/save) but for an
append-only log of entries rather than a single cached snapshot.

This is pure-core groundwork for Task 4's recording hooks and Task 5's
history browser — no UI, no app wiring here.

core/ NEVER imports textual.
"""

import os
import re
import secrets
import threading
from datetime import datetime
from pathlib import Path

from pydantic import BaseModel

#: `new_entry_id` ids are `<8-digit date>-<6-digit time>-<4 hex chars>`
#: (see `new_entry_id` below). `read_log` uses this as a strict allow-list —
#: since every id it's ever asked to look up either came from `new_entry_id`
#: or is untrusted input, matching this shape is sufficient (and simpler
#: than blacklisting "/", "\\", "..") to refuse any path-traversal attempt.
_ENTRY_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$")


class HistoryEntry(BaseModel):
    """One recorded run: a task, sequence, push, or keydist operation."""

    id: str
    started_at: str  # ISO-8601 UTC
    kind: str  # task|sequence|push|keydist
    command: list[str] | None
    summary: str
    returncode: int | None
    duration_secs: float
    cancelled: bool = False
    outcome: str  # ok|failed|cancelled
    needs_sudo: bool = False


def outcome_for(returncode: int | None, cancelled: bool) -> str:
    """Classify a run's outcome from its returncode + cancellation flag.

    `cancelled` wins regardless of returncode; otherwise `returncode == 0`
    is "ok" and anything else (including None) is "failed".
    """
    if cancelled:
        return "cancelled"
    if returncode == 0:
        return "ok"
    return "failed"


def new_entry_id(now: datetime) -> str:
    """Generate a sortable, collision-resistant history entry id.

    `<YYYYMMDD>-<HHMMSS>-<4 hex chars>` — the timestamp prefix keeps ids
    naturally sortable by creation time; the `secrets.token_hex(2)` suffix
    disambiguates entries created within the same second.
    """
    return now.strftime("%Y%m%d-%H%M%S") + "-" + secrets.token_hex(2)


class HistoryStore:
    """Append-only on-disk history: `root/index.jsonl` + `root/<id>.log`.

    Every method is defensive end to end (broad try/except) — a missing,
    unwritable, or otherwise hostile `root` degrades to a falsy/empty
    return rather than raising, since a history-write failure must never
    take down the runner that's recording it.

    A single `threading.Lock` serializes every public method (`append`,
    `load`, `read_log`, `prune`, `record`) — every call site is off the
    event loop (`asyncio.to_thread`), so two `record()` calls (e.g. two
    commands from a fast `_sequence_flow`, or a task finishing right as
    the previous one's write is still landing) can otherwise interleave
    as: A appends its index line, A reads the whole index for its prune,
    B appends its own line to the same file, A's prune-rewrite then wins
    the `os.replace` race and silently drops B's just-written line (and
    orphans B's `.log` forever — prune only unlinks logs for entries it
    can see in the index it read). The lock makes each `append`/`prune`/
    `record` call atomic with respect to every other call on the SAME
    `HistoryStore` instance; `load`/`read_log` take it too purely for
    read/write consistency (never strictly needed, since a torn read is
    already handled — see `load`'s per-line skip) but the cost is one
    file's worth of I/O, not worth reasoning about separately. A single
    process/instance is the only actor here (every recorder shares
    `app.history_store`), so a plain non-reentrant `Lock` is enough;
    public methods take it once and call the `_locked` helpers below —
    `record()` must NOT call the public `append`/`prune` (that would
    re-acquire the same non-reentrant lock and deadlock).
    """

    def __init__(self, root: Path) -> None:
        self.root = root
        self._lock = threading.Lock()

    def _index_path(self) -> Path:
        return self.root / "index.jsonl"

    def append(self, entry: HistoryEntry, log_lines: list[str]) -> bool:
        """Append one entry to the index and write its log file.

        Creates `root` as needed. Never raises.

        NOTE: the index line is written BEFORE the log file — a `False`
        return (log-file write failure) can still leave the index entry
        durable on disk.
        """
        with self._lock:
            return self._append_locked(entry, log_lines)

    def _append_locked(self, entry: HistoryEntry, log_lines: list[str]) -> bool:
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            with self._index_path().open("a") as f:
                f.write(entry.model_dump_json() + "\n")
            (self.root / f"{entry.id}.log").write_text("\n".join(log_lines))
            return True
        except Exception:
            return False

    def load(self, limit: int = 200) -> list[HistoryEntry]:
        """Load history entries, newest first.

        Parses each `index.jsonl` line independently, skipping any line
        that fails to parse (corrupt line, schema mismatch) rather than
        aborting the whole load. Returns at most `limit` entries. Never
        raises — a missing/unreadable index degrades to `[]`.
        """
        with self._lock:
            return self._load_locked(limit)

    def _load_locked(self, limit: int) -> list[HistoryEntry]:
        try:
            path = self._index_path()
            if not path.exists():
                return []
            entries: list[HistoryEntry] = []
            for line in path.read_text().splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(HistoryEntry.model_validate_json(line))
                except Exception:
                    continue
            entries.reverse()
            return entries[:limit]
        except Exception:
            return []

    def read_log(self, entry_id: str) -> str:
        """Read a recorded entry's log content.

        Refuses any id that doesn't match `new_entry_id`'s strict shape
        (blocks `/`, `\\`, `..`, and anything else that isn't a plain
        generated id) rather than trying to blacklist traversal patterns.
        Returns `""` on a missing file or any I/O error. Never raises.
        """
        with self._lock:
            return self._read_log_locked(entry_id)

    def _read_log_locked(self, entry_id: str) -> str:
        try:
            if not _ENTRY_ID_RE.match(entry_id):
                return ""
            log_path = self.root / f"{entry_id}.log"
            if not log_path.exists():
                return ""
            return log_path.read_text()
        except Exception:
            return ""

    def prune(self, keep: int = 200) -> int:
        """Keep only the newest `keep` entries; delete the rest's logs.

        Rewrites `index.jsonl` atomically (tmp + `os.replace`) and unlinks
        the `.log` file of every dropped entry (missing files are fine).
        Returns the number of entries removed. Never raises — any failure
        (unwritable root, corrupt index, etc.) returns 0.
        """
        with self._lock:
            return self._prune_locked(keep)

    def _prune_locked(self, keep: int) -> int:
        try:
            path = self._index_path()
            if not path.exists():
                return 0
            lines = [line for line in path.read_text().splitlines() if line.strip()]
            if len(lines) <= keep:
                return 0
            kept_lines = lines[-keep:] if keep > 0 else []
            dropped_lines = lines[: len(lines) - len(kept_lines)]

            tmp_path = path.parent / (path.name + ".tmp")
            tmp_path.write_text("".join(line + "\n" for line in kept_lines))
            os.replace(tmp_path, path)

            removed = 0
            for line in dropped_lines:
                removed += 1
                try:
                    entry = HistoryEntry.model_validate_json(line)
                except Exception:
                    continue
                try:
                    (self.root / f"{entry.id}.log").unlink(missing_ok=True)
                except Exception:
                    pass
            return removed
        except Exception:
            return 0

    def record(self, entry: HistoryEntry, log_lines: list[str], keep: int = 200) -> bool:
        """Append an entry then prune to `keep`, atomically with respect
        to every other call on this store (see the class docstring).
        Never raises.
        """
        with self._lock:
            try:
                ok = self._append_locked(entry, log_lines)
                self._prune_locked(keep)
                return ok
            except Exception:
                return False
