"""Auto-refresh watch mode (spec §1): `w` toggles a set_interval timer that
re-runs action_refresh() while idle, skips ticks under load, and surfaces
its state immediately in the header — no waiting for the next refresh."""

import asyncio

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.widgets.help_screen import HelpScreen
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(*, watch_interval_secs: float = 30.0, summary_provider=None) -> WorkstationApp:
    return WorkstationApp(
        summary_provider=summary_provider or fake_provider,
        runner=FakeRunner(),
        tools_provider=tools_provider,
        sudo_status_fn=lambda: "valid",
        watch_interval_secs=watch_interval_secs,
    )


async def test_toggle_flips_state_and_header_marker() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.watch_enabled is False
        header_before = str(app.query_one("#app-header").content)
        assert "watch" not in header_before

        await pilot.press("w")
        # No pilot.pause() beyond the press — the header must update
        # IMMEDIATELY on toggle, not wait for the next refresh cycle.
        assert app.watch_enabled is True
        header_on = str(app.query_one("#app-header").content)
        assert "watch 30s" in header_on

        await pilot.press("w")
        assert app.watch_enabled is False
        header_off = str(app.query_one("#app-header").content)
        assert "watch" not in header_off


async def test_tick_calls_provider_again_while_idle() -> None:
    calls = 0

    def counting_provider():
        nonlocal calls
        calls += 1
        return fake_provider()

    app = make_app(watch_interval_secs=0.05, summary_provider=counting_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        baseline = calls
        await pilot.press("w")
        await asyncio.sleep(0.2)
        await pilot.pause()
        assert calls > baseline
        # Pause the timer again before the context exits — otherwise a
        # straggling 0.05s tick can fire mid-teardown, after the app's
        # widgets are already gone, and crash the test on an unrelated
        # NoMatches (the timer, not the toggle behaviour under test).
        await pilot.press("w")
        await pilot.pause()


async def test_tick_skipped_while_busy() -> None:
    calls = 0

    def counting_provider():
        nonlocal calls
        calls += 1
        return fake_provider()

    app = make_app(watch_interval_secs=0.05, summary_provider=counting_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        baseline = calls
        # Mark busy BEFORE the timer even exists, so there is no window
        # where a tick could see _task_inflight=False and kick off a
        # still-in-flight refresh worker whose thread finishes only later
        # (which would otherwise race the `calls == baseline` assertion
        # below against a legitimately-started-but-slow-to-land call).
        app._task_inflight = True
        await pilot.press("w")
        await asyncio.sleep(0.2)
        await pilot.pause()
        assert calls == baseline
        app._task_inflight = False
        await pilot.press("w")  # pause the timer before context teardown
        await pilot.pause()


async def test_w_documented_in_footer_and_help() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        footer = str(app.query_one("#key-bar").content)
        assert "Watch" in footer

        await pilot.press("?")
        await pilot.pause()
        assert type(app.screen).__name__ == "HelpScreen"
        help_content = str(app.screen.query_one("#help-content").content)
        assert "Watch" in help_content
