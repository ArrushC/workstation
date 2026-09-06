"""Fleet `z` key: ssh + remote `zellij attach --create main` (mirrors the
bootstrap.ps1 Windows Terminal / Warp tab-config convention exactly).

Fixtures reused from tests/test_fleet_panel.py (HOSTS, fake_probe_all) and
tests/test_app_shell.py (fake_provider) / tests/test_provision_panel.py
(FakeRunner, tools_provider) — same shape every other panel/palette test
file already uses.
"""

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.palette import EntitiesProvider
from workstation_tui.core.fleet import zellij_ssh_command
from workstation_tui.core.models import HostEntry
from tests.test_app_shell import fake_provider
from tests.test_fleet_panel import HOSTS, fake_probe_all
from tests.test_provision_panel import FakeRunner, tools_provider


def make_app(runner=None, ssh_calls=None, zellij_calls=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        hosts_provider=lambda: (HOSTS, []),
        probe_all_fn=fake_probe_all,
        ssh_fn=(ssh_calls.append if ssh_calls is not None else None),
        zellij_fn=(zellij_calls.append if zellij_calls is not None else None),
    )


async def _settle(pilot) -> None:
    for _ in range(4):
        await pilot.pause()


# -- (a) builder argv pinned EXACTLY -----------------------------------------


def test_zellij_ssh_command_argv() -> None:
    entry = HostEntry(name="alpha", address="10.0.0.1", user="u", group="dev_machine")
    assert zellij_ssh_command(entry) == [
        "ssh", "-t", "--", "u@10.0.0.1", "zellij", "attach", "--create", "main",
    ]


# -- (b) `z` with a seeded fleet reaches the injected zellij_fn --------------


async def test_zellij_selected_reaches_zellij_fn_not_ssh_fn() -> None:
    ssh_calls: list = []
    zellij_calls: list = []
    app = make_app(ssh_calls=ssh_calls, zellij_calls=zellij_calls)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        await _settle(pilot)
        app.query_one("#fleet-table").focus()
        await pilot.press("z")
        await pilot.pause()
    assert zellij_calls and zellij_calls[0].name == "alpha"
    assert ssh_calls == []


# -- (c) blocked on a non-linux summary context ------------------------------


async def test_zellij_blocked_on_windows_context(monkeypatch) -> None:
    zellij_calls: list = []
    app = make_app(zellij_calls=zellij_calls)
    calls: list[tuple[tuple, dict]] = []
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        await _settle(pilot)
        # Same in-place summary flip test_fleet_panel.py's
        # test_push_blocked_on_windows_context uses, rather than a
        # Windows summary_provider from the start.
        app.summary = app.summary.model_copy(
            update={
                "context": app.summary.context.model_copy(
                    update={"os": "windows", "has_make": False}
                )
            }
        )
        monkeypatch.setattr(app, "notify", lambda *a, **k: calls.append((a, k)))
        app.query_one("#fleet-table").focus()
        await pilot.press("z")
        await pilot.pause()
    assert zellij_calls == []
    assert calls, "expected a warning toast"
    assert calls[0][1].get("severity") == "warning"


# -- (d) palette `search("zellij web")` reaches zellij_fn --------------------


async def test_palette_zellij_host_reaches_zellij_fn() -> None:
    zellij_calls: list = []
    app = make_app(zellij_calls=zellij_calls)
    async with app.run_test() as pilot:
        await _settle(pilot)
        provider = EntitiesProvider(app.screen)
        hits = [h async for h in provider.search("zellij alpha")]
        assert any(h.text == "zellij alpha" for h in hits)
        hit = next(h for h in hits if h.text == "zellij alpha")

        result = hit.command()
        if hasattr(result, "__await__"):
            await result
        await _settle(pilot)

        assert app.query_one("#content").current == "fleet"
        assert zellij_calls and zellij_calls[0].name == "alpha"
