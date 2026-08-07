from workstation_tui.app.app import WorkstationApp
from tests.test_app_shell import FAKE_SUMMARY, fake_provider


async def test_dashboard_renders_summary_counts() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        panel = app.query_one("#dashboard")
        text = panel.summary_text()
        assert "104/108" in text          # fresh/total
        assert "2 pending" in text        # dotfiles
        assert "9" in text and "3 dev" in text and "6 prod" in text


async def test_dashboard_card_enter_jumps_to_panel() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        app.query_one("#card-dotfiles").focus()
        await pilot.press("enter")
        assert app.query_one("#content").current == "dotfiles"


async def test_dashboard_shows_reader_warnings() -> None:
    bad = FAKE_SUMMARY.model_copy(
        update={"inventory_errors": ["make inventory failed: boom"]}
    )
    app = WorkstationApp(summary_provider=lambda: bad)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert "make inventory failed" in app.query_one("#dashboard").summary_text()


async def test_refresh_calls_provider_again() -> None:
    calls = []

    def counting_provider():
        calls.append(1)
        return FAKE_SUMMARY

    app = WorkstationApp(summary_provider=counting_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        first = len(calls)
        assert first >= 1
        await pilot.press("g")
        await pilot.pause()
        assert len(calls) > first


async def test_health_card_renders_rollup(tmp_path) -> None:
    import time as _time

    from workstation_tui.core.health import save_cache
    from workstation_tui.core.models import CheckResult

    save_cache(tmp_path / "health.json", {
        "doctor": CheckResult(check_id="doctor", ok=True, summary="31/31 ok",
                              finished_at=_time.time(), returncode=0),
    })
    app = WorkstationApp(
        summary_provider=fake_provider,
        health_cache_path=tmp_path / "health.json",
        interop_reader=lambda: "enabled",
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        text = app.query_one("#dashboard").summary_text()
        assert "doctor" in text
        assert "enabled" in text          # interop (FAKE_SUMMARY is WSL)
        assert "n/a on WSL" in text       # services gating reason


async def test_cards_fill_area_equally() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test(size=(100, 40)) as pilot:
        await pilot.pause()
        cards = list(app.query(".card"))
        assert len(cards) == 4
        widths = {c.region.width for c in cards}
        heights = {c.region.height for c in cards}
        assert len(widths) == 1, f"unequal widths: {widths}"
        assert len(heights) == 1, f"unequal heights: {heights}"
        # full-bleed: the grid claims most of the content height
        grid = app.query_one("#cards")
        assert grid.region.height >= 30
