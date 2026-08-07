import contextlib
import subprocess

from workstation_tui.app.app import PANELS, WorkstationApp
from workstation_tui.core.models import HostContext, HostEntry, Summary

FAKE_SUMMARY = Summary(
    context=HostContext(
        os="linux", is_wsl=True, group="dev_machine", mode="dev",
        has_make=True, has_chezmoi=True, has_systemctl=True, has_sudo=True,
    ),
    tools_total=108, tools_fresh=104, tools_stale=0, tools_missing=4,
    inventory_errors=[], dotfiles_pending=2, dotfiles_errors=[],
    hosts_total=9, hosts_dev=3, hosts_prod=6, hosts_errors=[],
)


def fake_provider() -> Summary:
    return FAKE_SUMMARY


async def test_app_boots_and_shows_sidebar() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app.query_one("#sidebar") is not None
        assert app.query_one("#content").current == "dashboard"
        labels = [item.panel_id for item in app.query(".nav-item")]
        assert labels == [pid for pid, _ in PANELS]


async def test_number_keys_switch_panels() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("2")
        assert app.query_one("#content").current == "provision"
        await pilot.press("5")
        assert app.query_one("#content").current == "health"
        await pilot.press("1")
        assert app.query_one("#content").current == "dashboard"


async def test_q_quits() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("q")
    assert app.return_code in (0, None)


async def test_nav_click_switches_panel() -> None:
    app = WorkstationApp(summary_provider=fake_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        items = list(app.query(".nav-item"))
        await pilot.click(items[3])  # Fleet
        assert app.query_one("#content").current == "fleet"
        assert items[3].has_class("active")


async def test_provider_error_surfaces_in_header() -> None:
    def failing_provider() -> Summary:
        raise RuntimeError("workstation repo not found")

    app = WorkstationApp(summary_provider=failing_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.pause()
        header_text = str(app.query_one("#app-header").content)
        assert "workstation repo not found" in header_text


async def test_ssh_to_real_path_uses_double_dash(monkeypatch) -> None:
    # Finding 2 (ssh hardening): no ssh_fn injected here — this exercises
    # the REAL subprocess.run path (tests elsewhere inject ssh_fn as a
    # recorder). ssh_to's docstring notes the genuine suspend()+TTY path
    # can't be driven headlessly, so suspend() is monkeypatched to a no-op
    # context manager (same "swap the instance attribute, not the class"
    # trick as test_makeiface.py's subprocess.run patches) purely to let
    # this synchronous method run and let us inspect the argv it builds.
    calls: list[list[str]] = []
    monkeypatch.setattr(subprocess, "run", lambda cmd: calls.append(cmd))
    app = WorkstationApp(summary_provider=fake_provider)
    monkeypatch.setattr(app, "suspend", contextlib.nullcontext)
    entry = HostEntry(name="alpha", address="10.0.0.1", user="me", group="dev_machine")
    app.ssh_to(entry)
    assert calls == [["ssh", "--", "me@10.0.0.1"]]


async def test_provider_error_with_markup_text_does_not_crash() -> None:
    def hostile_provider():
        raise RuntimeError("config [/etc/foo] missing")

    app = WorkstationApp(summary_provider=hostile_provider)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.pause()
        header_text = str(app.query_one("#app-header").content)
        assert "RuntimeError" in header_text
        assert "/etc/foo" in header_text
