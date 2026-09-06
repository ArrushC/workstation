"""UpdatesScreen (Phase C Task 2): cache-first render + background refresh.

`ScriptedRunner` (subclass of test_provision_panel.FakeRunner, same shape as
test_task_routing.py's ScriptedRunner/test_health_panel.py's EchoRunner)
streams a fixed set of lines then returns a fixed TaskResult — used to
script porcelain `status|name|detail` output for the fresh-check tests, and
an rc!=0 "the fresh check always fails" runner for the render-only tests so
a pre-seeded cache's table/summary can be asserted deterministically
without racing the background check that `on_mount` always kicks off.
"""

from datetime import UTC, datetime
from pathlib import Path

from textual.widgets import Static

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.widgets.updates_screen import UpdatesScreen
from workstation_tui.core.models import TaskResult
from workstation_tui.core.updates import (
    UpdateRow,
    UpdatesCache,
    load_updates_cache,
    save_updates_cache,
)
from tests.test_app_shell import FAKE_SUMMARY, fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


class ScriptedRunner(FakeRunner):
    def __init__(self, lines: list[str], rc: int = 0, cancelled: bool = False) -> None:
        super().__init__()
        self._lines = lines
        self._rc = rc
        self._cancelled = cancelled

    async def run(self, command, on_line):
        self.commands.append(command)
        for line in self._lines:
            on_line(line)
        return TaskResult(
            command=command, returncode=self._rc, duration_secs=0.01,
            cancelled=self._cancelled,
        )


def make_app(tmp_path: Path, runner=None) -> WorkstationApp:
    return WorkstationApp(
        summary_provider=fake_provider,
        runner=runner or FakeRunner(),
        tools_provider=tools_provider,
        sudo_status_fn=lambda: "valid",
        updates_cache_path=tmp_path / "updates.json",
    )


def no_make_app(tmp_path: Path) -> WorkstationApp:
    def no_make_provider():
        context = FAKE_SUMMARY.context.model_copy(
            update={"has_make": False, "os": "windows"}
        )
        return FAKE_SUMMARY.model_copy(update={"context": context})

    return WorkstationApp(
        summary_provider=no_make_provider,
        runner=FakeRunner(),
        tools_provider=tools_provider,
        sudo_status_fn=lambda: "valid",
        updates_cache_path=tmp_path / "updates.json",
    )


async def _open_provision(pilot, app) -> None:
    await pilot.pause()
    await pilot.press("2")
    await pilot.pause()
    app.query_one("#provision-table").focus()


# -- `u` opens the screen; unavailable host refuses with a toast -----------


async def test_u_opens_updates_screen_or_toasts_when_unavailable(tmp_path: Path) -> None:
    app = make_app(tmp_path)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        await pilot.press("u")
        await pilot.pause()
        assert isinstance(app.screen, UpdatesScreen)

    app2 = no_make_app(tmp_path / "unavailable")
    async with app2.run_test() as pilot:
        await _open_provision(pilot, app2)
        await pilot.press("u")
        await pilot.pause()
        assert len(app2.screen_stack) == 1  # no modal pushed


# -- pre-seeded cache renders immediately, sorted status-first -------------


async def test_cache_preseeded_renders_sorted_with_glyphs_and_summary(
    tmp_path: Path,
) -> None:
    cache = UpdatesCache(
        checked_at=datetime.now(UTC).isoformat(),
        rows=[
            UpdateRow(status="ok", name="fzf", detail="0.74.3"),
            UpdateRow(status="update", name="omp", detail="18.0.11 → 19.0.0",
                      pinned="18.0.11", latest="19.0.0"),
            UpdateRow(status="rolling", name="node", detail="tracks latest"),
        ],
    )
    save_updates_cache(tmp_path / "updates.json", cache)
    # rc!=0 so the background check never touches self._cache/the table —
    # the render under test stays exactly the one from on_mount's seeded load.
    runner = ScriptedRunner(lines=[], rc=1)
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        await pilot.press("u")
        for _ in range(6):
            await pilot.pause()
        screen = app.screen
        assert isinstance(screen, UpdatesScreen)
        table = screen.query_one("#updates-table")
        assert table.row_count == 3
        keys = [rk.key.value for rk in table.ordered_rows]
        assert keys == ["omp", "fzf", "node"]  # status order: update, ok, rolling
        update_row = table.get_row("omp")
        assert update_row[0].plain == "↑"
        assert update_row[2].plain == "18.0.11"
        assert update_row[3].plain == "19.0.0"
        summary = str(screen.query_one("#updates-summary", Static).content)
        assert "1 updates" in summary
        assert "1 ok" in summary
        assert "1 rolling" in summary
        assert "0 unchecked" in summary
        assert "never" not in summary


# -- fresh check (rc 0): cache written + table re-rendered -----------------


async def test_fresh_check_success_writes_cache_and_rerenders_table(
    tmp_path: Path,
) -> None:
    lines = [
        "update|omp|18.0.11 → 19.0.0",
        "ok|fzf|0.74.3",
    ]
    runner = ScriptedRunner(lines=lines, rc=0)
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        await pilot.press("u")
        for _ in range(8):
            await pilot.pause()
        screen = app.screen
        assert isinstance(screen, UpdatesScreen)
        table = screen.query_one("#updates-table")
        assert table.row_count == 2
        banner = str(screen.query_one("#updates-banner", Static).content)
        assert banner == ""

    cache = load_updates_cache(tmp_path / "updates.json")
    assert cache.checked_at is not None
    assert {r.name for r in cache.rows} == {"omp", "fzf"}
    assert next(r for r in cache.rows if r.name == "omp").status == "update"


# -- rc != 0: banner shows the failure, on-disk cache stays untouched ------


async def test_rc_nonzero_shows_banner_and_leaves_cache_unchanged(
    tmp_path: Path,
) -> None:
    cache_path = tmp_path / "updates.json"
    original = UpdatesCache(
        checked_at="2020-01-01T00:00:00+00:00",
        rows=[UpdateRow(status="ok", name="fzf", detail="0.74.3")],
    )
    save_updates_cache(cache_path, original)
    runner = ScriptedRunner(lines=["boom"], rc=3)
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        await pilot.press("u")
        for _ in range(6):
            await pilot.pause()
        screen = app.screen
        assert isinstance(screen, UpdatesScreen)
        banner = str(screen.query_one("#updates-banner", Static).content)
        assert "failed" in banner
        assert "rc=3" in banner

    assert load_updates_cache(cache_path) == original


# -- `s` cycles sort key status -> name -------------------------------------


async def test_s_toggles_sort_to_name_order(tmp_path: Path) -> None:
    cache = UpdatesCache(
        checked_at=datetime.now(UTC).isoformat(),
        rows=[
            UpdateRow(status="ok", name="zzz", detail="1.0"),
            UpdateRow(status="update", name="bbb", detail="1.0 → 2.0",
                      pinned="1.0", latest="2.0"),
            UpdateRow(status="rolling", name="aaa", detail="tracks latest"),
        ],
    )
    save_updates_cache(tmp_path / "updates.json", cache)
    runner = ScriptedRunner(lines=[], rc=1)  # keep the seeded cache stable
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        await pilot.press("u")
        for _ in range(6):
            await pilot.pause()
        screen = app.screen
        table = screen.query_one("#updates-table")
        assert [rk.key.value for rk in table.ordered_rows] == ["bbb", "zzz", "aaa"]

        await pilot.press("s")
        await pilot.pause()
        assert [rk.key.value for rk in table.ordered_rows] == ["aaa", "bbb", "zzz"]

        await pilot.press("s")
        await pilot.pause()
        assert [rk.key.value for rk in table.ordered_rows] == ["bbb", "zzz", "aaa"]


# -- entry gated while a task is already in flight --------------------------


async def test_entry_gated_while_task_inflight(tmp_path: Path) -> None:
    runner = FakeRunner()
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        app._task_inflight = True
        await pilot.press("u")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, UpdatesScreen)
        banner = str(screen.query_one("#updates-banner", Static).content)
        assert "task running" in banner

    assert runner.commands == []


# -- _make_context() raising RuntimeError degrades instead of crashing -----


async def test_make_context_failure_shows_banner_and_never_launches(
    tmp_path: Path,
) -> None:
    """A misconfigured WORKSTATION_REPO / relocated install makes
    `_make_context()` raise `RuntimeError("workstation repo not found")` —
    `_start_check` must catch it, bannering + toasting instead of letting
    the exception escape `on_mount` and take the whole app down.
    """
    runner = FakeRunner()
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)

        def boom() -> tuple[Path, str]:
            raise RuntimeError("workstation repo not found")

        app._make_context = boom  # type: ignore[method-assign]
        await pilot.press("u")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, UpdatesScreen)
        banner = str(screen.query_one("#updates-banner", Static).content)
        assert banner == "repo not found — showing cached results"

    assert runner.commands == []


# -- dashboard provision card: updates count + never-checked ---------------


async def test_dashboard_card_shows_update_count_and_never_checked(
    tmp_path: Path,
) -> None:
    cache = UpdatesCache(
        checked_at=datetime.now(UTC).isoformat(),
        rows=[
            UpdateRow(status="update", name="omp", detail="1 → 2",
                      pinned="1", latest="2"),
            UpdateRow(status="update", name="jj", detail="1 → 2",
                      pinned="1", latest="2"),
            UpdateRow(status="ok", name="fzf", detail="1.0"),
        ],
    )
    save_updates_cache(tmp_path / "updates.json", cache)

    app = make_app(tmp_path)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.pause()
        text = app.query_one("#dashboard").summary_text()
        assert "↑ 2 updates" in text

    # A separate cache path with no file at all -> never checked.
    app2 = make_app(tmp_path / "empty")
    async with app2.run_test() as pilot:
        await pilot.pause()
        await pilot.pause()
        text2 = app2.query_one("#dashboard").summary_text()
        assert "never checked" in text2


# -- F6: `u` twice does not stack a second UpdatesScreen ---------------------


async def test_action_updates_does_not_stack_a_second_screen(tmp_path: Path) -> None:
    # rc!=0 so the background check on open never mutates state we're not
    # asserting on here; only the screen-identity/count behavior matters.
    runner = ScriptedRunner(lines=[], rc=1)
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        panel = app.query_one("#provision")

        panel.action_updates()
        await pilot.pause()
        assert isinstance(app.screen, UpdatesScreen)
        first = app.screen

        # A second call (the palette's "check updates" reaching here while
        # the screen is already open) must be a no-op, not a second push.
        panel.action_updates()
        await pilot.pause()
        assert app.screen is first
        assert sum(1 for s in app.screen_stack if isinstance(s, UpdatesScreen)) == 1


# -- F9: a naive (tz-less) `checked_at` degrades to "?", never crashes ------


async def test_naive_checked_at_renders_question_mark_no_crash(tmp_path: Path) -> None:
    cache = UpdatesCache(
        checked_at="2026-01-01T00:00:00",  # no tzinfo -> TypeError against
        rows=[UpdateRow(status="ok", name="fzf", detail="0.74.3")],  # datetime.now(UTC)
    )
    save_updates_cache(tmp_path / "updates.json", cache)
    # rc!=0 so the background check never overwrites the seeded cache —
    # the render under test stays exactly the one from on_mount's load.
    runner = ScriptedRunner(lines=[], rc=1)
    app = make_app(tmp_path, runner)
    async with app.run_test() as pilot:
        await _open_provision(pilot, app)
        await pilot.press("u")
        for _ in range(6):
            await pilot.pause()
        screen = app.screen
        assert isinstance(screen, UpdatesScreen)  # never crashed the app
        summary = str(screen.query_one("#updates-summary", Static).content)
        assert "checked ?" in summary
