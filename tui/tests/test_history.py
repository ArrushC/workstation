import os
import re
import threading
from datetime import datetime, timezone
from pathlib import Path

import pytest

from workstation_tui.core.history import (
    HistoryEntry,
    HistoryStore,
    new_entry_id,
    outcome_for,
)


def _entry(entry_id: str, kind: str = "task", returncode: int | None = 0) -> HistoryEntry:
    return HistoryEntry(
        id=entry_id,
        started_at="2026-09-06T00:00:00Z",
        kind=kind,
        command=["make", "doctor"],
        summary="doctor",
        returncode=returncode,
        duration_secs=1.5,
        cancelled=False,
        outcome=outcome_for(returncode, False),
        needs_sudo=False,
    )


def test_append_and_load_round_trip_newest_first(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path)
    e1 = _entry("20260906-000001-aaaa")
    e2 = _entry("20260906-000002-bbbb")
    e3 = _entry("20260906-000003-cccc")

    assert store.append(e1, ["line one"]) is True
    assert store.append(e2, ["line two"]) is True
    assert store.append(e3, ["line three"]) is True

    loaded = store.load()
    assert [e.id for e in loaded] == [e3.id, e2.id, e1.id]
    assert loaded[0] == e3


def test_load_skips_corrupt_line(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path)
    e1 = _entry("20260906-000001-aaaa")
    store.append(e1, ["ok"])
    # Append a corrupt line directly.
    with (tmp_path / "index.jsonl").open("a") as f:
        f.write("not-json-at-all\n")
    e2 = _entry("20260906-000002-bbbb")
    store.append(e2, ["ok2"])

    loaded = store.load()
    assert [e.id for e in loaded] == [e2.id, e1.id]


def test_read_log_content_missing_and_traversal(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path)
    e1 = _entry("20260906-000001-aaaa")
    store.append(e1, ["hello", "world"])

    assert store.read_log(e1.id) == "hello\nworld"
    assert store.read_log("does-not-exist") == ""
    assert store.read_log("../x") == ""
    assert store.read_log("../../etc/passwd") == ""
    assert store.read_log("sub/dir") == ""
    assert store.read_log("back\\slash") == ""


def test_prune_keeps_newest_n_deletes_dropped_logs_returns_count(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path)
    ids = [f"20260906-00000{i}-aaa{i}" for i in range(1, 6)]
    for entry_id in ids:
        store.append(_entry(entry_id), [f"log for {entry_id}"])

    removed = store.prune(keep=2)
    assert removed == 3

    loaded = store.load()
    assert [e.id for e in loaded] == [ids[4], ids[3]]

    # Dropped logs are unlinked; kept logs remain.
    for dropped_id in ids[:3]:
        assert not (tmp_path / f"{dropped_id}.log").exists()
    for kept_id in ids[3:]:
        assert (tmp_path / f"{kept_id}.log").exists()

    # index.jsonl.tmp must not linger after the atomic replace.
    assert not (tmp_path / "index.jsonl.tmp").exists()


def test_record_is_append_then_prune(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path)
    ids = [f"20260906-00000{i}-aaa{i}" for i in range(1, 4)]
    for entry_id in ids[:-1]:
        store.append(_entry(entry_id), [entry_id])

    assert store.record(_entry(ids[-1]), [ids[-1]], keep=2) is True

    loaded = store.load()
    assert [e.id for e in loaded] == [ids[2], ids[1]]
    assert not (tmp_path / f"{ids[0]}.log").exists()


def test_concurrent_record_calls_never_lose_an_entry_or_orphan_a_log(
    tmp_path: Path,
) -> None:
    """F2 regression: `HistoryStore.record()` (append then prune) is now
    serialized by an internal lock, so two threads racing `record()` on a
    full store (every call triggers a real prune at keep=3) must never
    drop the other thread's just-written index line, and `prune` must
    never orphan a `.log` file whose entry survived. Pre-lock, this was
    a ~1/30 race (append -> read-for-prune -> the OTHER thread's append
    -> this thread's os.replace wins, silently dropping the other's
    line and leaving its `.log` on disk forever) — run enough trials
    that a reintroduced race would show up.
    """
    store = HistoryStore(tmp_path)
    for i in range(5):
        store.append(_entry(f"20260906-00000{i}-seed"), [f"seed {i}"])

    for trial in range(30):
        e1 = _entry(f"20260906-{trial:06d}-a001")
        e2 = _entry(f"20260906-{trial:06d}-b002")
        barrier = threading.Barrier(2)

        def _record(entry: HistoryEntry) -> None:
            barrier.wait(timeout=5)
            store.record(entry, [f"log for {entry.id}"], keep=3)

        threads = [
            threading.Thread(target=_record, args=(e1,)),
            threading.Thread(target=_record, args=(e2,)),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5)

        loaded_ids = {e.id for e in store.load(limit=1000)}
        assert e1.id in loaded_ids, f"trial {trial}: lost {e1.id}"
        assert e2.id in loaded_ids, f"trial {trial}: lost {e2.id}"

    # No orphans left behind: every `.log` file on disk belongs to an
    # entry still present in the (pruned) index, and vice versa.
    final_ids = {e.id for e in store.load(limit=1000)}
    disk_log_ids = {p.stem for p in tmp_path.glob("*.log")}
    assert disk_log_ids == final_ids


@pytest.mark.skipif(
    os.geteuid() == 0,
    reason="root ignores directory permission bits, so a chmod(0o000) "
           "directory is still fully readable/writable as root",
)
def test_unwritable_root_never_raises_locked_directory(tmp_path: Path) -> None:
    # Root is a directory with no permissions.
    locked_root = tmp_path / "locked"
    locked_root.mkdir()
    locked_root.chmod(0o000)
    try:
        store = HistoryStore(locked_root / "sub")
        assert store.append(_entry("20260906-000001-aaaa"), ["x"]) is False
        assert store.load() == []
        assert store.read_log("20260906-000001-aaaa") == ""
        assert store.prune(keep=1) == 0
    finally:
        locked_root.chmod(0o755)


def test_unwritable_root_never_raises_file_as_root(tmp_path: Path) -> None:
    # Root path is a regular file, so mkdir must fail — root-proof (a
    # file can never be mkdir'd into regardless of uid).
    file_root = tmp_path / "not-a-dir"
    file_root.write_text("i am a file")
    store2 = HistoryStore(file_root)
    assert store2.append(_entry("20260906-000002-bbbb"), ["x"]) is False
    assert store2.load() == []
    assert store2.read_log("20260906-000002-bbbb") == ""
    assert store2.prune(keep=1) == 0


def test_outcome_for_table_and_new_entry_id_shape() -> None:
    assert outcome_for(0, False) == "ok"
    assert outcome_for(1, False) == "failed"
    assert outcome_for(None, False) == "failed"
    assert outcome_for(0, True) == "cancelled"
    assert outcome_for(None, True) == "cancelled"
    assert outcome_for(1, True) == "cancelled"

    now = datetime(2026, 9, 6, 12, 34, 56, tzinfo=timezone.utc)
    entry_id = new_entry_id(now)
    assert re.match(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$", entry_id)
    assert entry_id.startswith("20260906-123456-")

    # Uniqueness across calls (token_hex(2) suffix varies).
    other = new_entry_id(now)
    assert other.startswith("20260906-123456-")
