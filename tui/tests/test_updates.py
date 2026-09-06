from pathlib import Path

from workstation_tui.core.makeiface import check_updates_command
from workstation_tui.core.updates import (
    UpdateRow,
    UpdatesCache,
    load_updates_cache,
    parse_updates,
    save_updates_cache,
    sort_rows,
)


def test_check_updates_command_porcelain_argv(tmp_path: Path) -> None:
    base = check_updates_command(tmp_path, "dev", porcelain=False)
    assert base[-1] == "MODE=dev"
    assert "CHECK_UPDATES_PORCELAIN=1" not in base

    # Default is porcelain=True: the var is appended as the LAST argv token.
    porcelain = check_updates_command(tmp_path, "dev")
    assert porcelain[:-1] == base
    assert porcelain[-1] == "CHECK_UPDATES_PORCELAIN=1"


def test_parse_updates_happy_path_all_statuses() -> None:
    text = "\n".join([
        "ok|fzf|0.74.3",
        "update|omp|18.0.11 → 19.0.0",
        "ahead|jj|pin 0.44.0 is newer than the latest clean tag 0.43.0",
        "rolling|node|tracks latest — force a refresh: make clean-node node MODE=<dev|prod>",
        "unknown|weird-tool|no upstream tag source registered",
    ])
    rows = parse_updates(text)
    assert [r.status for r in rows] == ["ok", "update", "ahead", "rolling", "unknown"]
    assert [r.name for r in rows] == ["fzf", "omp", "jj", "node", "weird-tool"]


def test_parse_updates_update_detail_split_others_none() -> None:
    rows = parse_updates("update|omp|18.0.11 → 19.0.0\nok|fzf|0.74.3")
    update_row, ok_row = rows
    assert update_row.pinned == "18.0.11"
    assert update_row.latest == "19.0.0"
    assert ok_row.pinned is None
    assert ok_row.latest is None


def test_parse_updates_garbage_blank_non_str_returns_empty() -> None:
    assert parse_updates("") == []
    assert parse_updates("   \n\n   ") == []
    assert parse_updates("not-a-valid-line-at-all") == []
    assert parse_updates(b"ok|fzf|0.74.3") == []  # type: ignore[arg-type]
    assert parse_updates(None) == []  # type: ignore[arg-type]
    assert parse_updates(12345) == []  # type: ignore[arg-type]


def test_parse_updates_unknown_status_line_skipped() -> None:
    rows = parse_updates("bogus-status|tool|detail\nok|fzf|0.74.3")
    assert len(rows) == 1
    assert rows[0].name == "fzf"


def test_updates_cache_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "updates-cache.json"
    cache = UpdatesCache(
        checked_at="2026-09-05T00:00:00Z",
        rows=[
            UpdateRow(status="update", name="omp", detail="18.0.11 → 19.0.0",
                      pinned="18.0.11", latest="19.0.0"),
            UpdateRow(status="ok", name="fzf", detail="0.74.3"),
        ],
    )
    assert save_updates_cache(path, cache) is True
    loaded = load_updates_cache(path)
    assert loaded == cache
    assert not path.with_suffix(".tmp").exists()


def test_load_updates_cache_corrupt_json_returns_empty(tmp_path: Path) -> None:
    path = tmp_path / "updates-cache.json"
    path.write_text("{not valid json")
    assert load_updates_cache(path) == UpdatesCache()
    assert load_updates_cache(tmp_path / "missing.json") == UpdatesCache()


def test_sort_rows_status_and_name_keys() -> None:
    rows = [
        UpdateRow(status="ok", name="zzz", detail="1.0"),
        UpdateRow(status="update", name="bbb", detail="1.0 → 2.0", pinned="1.0", latest="2.0"),
        UpdateRow(status="rolling", name="aaa", detail="tracks latest"),
        UpdateRow(status="unknown", name="ccc", detail="no source"),
        UpdateRow(status="ahead", name="ddd", detail="ahead of upstream"),
    ]
    by_status = sort_rows(rows, key="status")
    assert [r.status for r in by_status] == ["update", "ahead", "unknown", "ok", "rolling"]

    by_name = sort_rows(rows, key="name")
    assert [r.name for r in by_name] == ["aaa", "bbb", "ccc", "ddd", "zzz"]

    # Unknown sort key falls back to status order.
    by_unknown_key = sort_rows(rows, key="bogus")
    assert [r.status for r in by_unknown_key] == ["update", "ahead", "unknown", "ok", "rolling"]
