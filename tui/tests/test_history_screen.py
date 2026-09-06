"""HistoryScreen (Phase C Task 5): task history browser + gated re-run.

Same `FakeRunner`/`fake_provider` fixtures as the rest of the suite; the
store is a real on-disk `HistoryStore(tmp_path / "h")` pre-seeded via its
own append() API (Task 3's actual persistence, not a fake), matching the
brief's "tests inject history_store=..., write via the store API" note.
"""

from datetime import UTC, datetime, timedelta
from pathlib import Path

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.widgets.history_screen import HistoryScreen
from workstation_tui.app.widgets.text_view import TextViewScreen
from workstation_tui.core.fleet import rel_age
from workstation_tui.core.history import HistoryEntry, HistoryStore
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(runner=None, history_store=None, sudo_status_fn=None) -> WorkstationApp:
    return WorkstationApp(
        summary_provider=fake_provider,
        runner=runner or FakeRunner(),
        tools_provider=tools_provider,
        sudo_status_fn=sudo_status_fn or (lambda: "valid"),
        history_store=history_store,
    )


def _entry(
    entry_id: str,
    *,
    kind: str = "task",
    command: list[str] | None = None,
    summary: str = "make doctor",
    returncode: int | None = 0,
    duration_secs: float = 5.0,
    outcome: str = "ok",
    needs_sudo: bool = False,
    started_at: datetime | None = None,
) -> HistoryEntry:
    started = started_at or datetime.now(UTC)
    default_command = ["make", "doctor"] if kind in ("task", "sequence") else None
    return HistoryEntry(
        id=entry_id,
        started_at=started.isoformat(),
        kind=kind,
        command=command if command is not None else default_command,
        summary=summary,
        returncode=returncode,
        duration_secs=duration_secs,
        cancelled=False,
        outcome=outcome,
        needs_sudo=needs_sudo,
    )


async def _open_history(pilot, app) -> None:
    await pilot.pause()
    await pilot.press("H")
    for _ in range(4):
        await pilot.pause()


# -- 1. `H` opens the screen --------------------------------------------------


async def test_capital_h_opens_history_screen(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path / "h")
    app = make_app(history_store=store)
    async with app.run_test() as pilot:
        await _open_history(pilot, app)
        assert isinstance(app.screen, HistoryScreen)


# -- 2. seeded store -> rows newest-first with glyphs/rel-age -----------------


async def test_rows_render_newest_first_with_glyphs_and_age(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path / "h")
    now = datetime.now(UTC)
    oldest = _entry(
        "20260101-000000-aaaa", summary="oldest run", outcome="failed",
        returncode=1, started_at=now - timedelta(hours=2),
    )
    newest = _entry(
        "20260101-000001-bbbb", summary="newest run", outcome="ok",
        returncode=0, started_at=now - timedelta(minutes=5),
    )
    store.append(oldest, ["old log"])
    store.append(newest, ["new log"])

    app = make_app(history_store=store)
    async with app.run_test() as pilot:
        await _open_history(pilot, app)
        screen = app.screen
        assert isinstance(screen, HistoryScreen)
        table = screen.query_one("#history-table")
        assert table.row_count == 2
        keys = [rk.key.value for rk in table.ordered_rows]
        assert keys == [newest.id, oldest.id]  # newest first

        newest_row = table.get_row(newest.id)
        assert newest_row[1].plain == "✓"  # OUTCOME_ICONS["ok"]
        assert newest_row[3].plain == "newest run"
        assert newest_row[0].plain == rel_age(5 * 60)

        oldest_row = table.get_row(oldest.id)
        assert oldest_row[1].plain == "✗"  # OUTCOME_ICONS["failed"]
        assert oldest_row[0].plain == rel_age(2 * 3600)


# -- 3. enter opens TextViewScreen with the exact log text --------------------


async def test_enter_opens_text_view_with_log_text(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path / "h")
    entry = _entry("20260101-000000-cccc", summary="make fzf")
    store.append(entry, ["$ make fzf", "==> installed"])

    app = make_app(history_store=store)
    async with app.run_test() as pilot:
        await _open_history(pilot, app)
        app.screen.query_one("#history-table").focus()
        await pilot.press("enter")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, TextViewScreen)
        assert screen._title == "make fzf"
        assert screen._text == store.read_log(entry.id)
        assert "$ make fzf" in screen._text
        assert "==> installed" in screen._text


# -- 4. `r` on a task entry -> confirm -> launch_task exact argv + needs_sudo -


async def test_rerun_task_entry_confirm_launches_exact_argv_and_needs_sudo(
    tmp_path: Path,
) -> None:
    store = HistoryStore(tmp_path / "h")
    entry = _entry(
        "20260101-000000-dddd", kind="task", command=["make", "provision"],
        needs_sudo=True,
    )
    store.append(entry, ["log line"])

    sudo_calls: list[None] = []

    def sudo_status_fn():
        sudo_calls.append(None)
        return "valid"

    runner = FakeRunner()
    app = make_app(runner, history_store=store, sudo_status_fn=sudo_status_fn)
    async with app.run_test() as pilot:
        await _open_history(pilot, app)
        app.screen.query_one("#history-table").focus()
        await pilot.press("r")
        await pilot.pause()
        await pilot.press("y")  # ConfirmModal
        for _ in range(5):
            await pilot.pause()
    assert runner.commands == [["make", "provision"]]
    # needs_sudo=True on a "linux" summary means _sudo_gate must have
    # consulted sudo_status_fn — the seam the brief calls out for asserting
    # rerun_history_entry routed the ORIGINAL entry's needs_sudo flag
    # through to launch_task, not just its command.
    assert sudo_calls


# -- 5. `r` on a push entry -> warning toast, runner untouched ----------------


async def test_rerun_push_entry_warns_and_leaves_runner_untouched(
    tmp_path: Path, monkeypatch,
) -> None:
    store = HistoryStore(tmp_path / "h")
    entry = _entry(
        "20260101-000000-eeee", kind="push", command=None,
        summary="push — 2 ok, 0 failed",
    )
    store.append(entry, ["=== host1 (done, rc=0) ==="])

    runner = FakeRunner()
    app = make_app(runner, history_store=store)
    calls: list[tuple[tuple, dict]] = []
    async with app.run_test() as pilot:
        await _open_history(pilot, app)
        monkeypatch.setattr(app, "notify", lambda *a, **k: calls.append((a, k)))
        app.screen.query_one("#history-table").focus()
        await pilot.press("r")
        await pilot.pause()
    assert runner.commands == []
    assert calls and calls[0][0][0] == "re-run from the Fleet panel"
    assert calls[0][1].get("severity") == "warning"


# -- 6. empty store -> single muted "no history yet" line --------------------


async def test_empty_store_shows_no_history_yet(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path / "h")
    app = make_app(history_store=store)
    async with app.run_test() as pilot:
        await _open_history(pilot, app)
        screen = app.screen
        assert isinstance(screen, HistoryScreen)
        table = screen.query_one("#history-table")
        assert table.row_count == 1
        row = table.get_row_at(0)
        assert row[3].plain == "no history yet"


# -- 7. F6: `H` twice does not stack a second HistoryScreen ------------------


async def test_action_history_does_not_stack_a_second_screen(tmp_path: Path) -> None:
    store = HistoryStore(tmp_path / "h")
    app = make_app(history_store=store)
    async with app.run_test() as pilot:
        await _open_history(pilot, app)
        assert isinstance(app.screen, HistoryScreen)
        first = app.screen

        # A second call (the palette's "task history" reaching here while
        # the screen is already open) must be a no-op, not a second push.
        app.action_history()
        await pilot.pause()
        assert app.screen is first
        assert sum(1 for s in app.screen_stack if isinstance(s, HistoryScreen)) == 1
