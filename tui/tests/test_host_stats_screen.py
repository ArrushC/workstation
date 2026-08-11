"""HostStatsScreen (Task 5): enter routing + the two-stage load worker.

No real ssh/subprocess in this suite — `exec_fn`/`probe` are always
injected fakes (the `probe_setup` fake-subprocess pattern in test_fleet.py
is the model; `Host` below is test_push_screen.py's minimal
`push_screen_wait` harness, reused verbatim so a screen can be driven
standalone with no WorkstationApp plumbing).
"""

from textual.app import App
from textual.screen import ModalScreen
from textual.widgets import Static

from workstation_tui.app.widgets.host_stats import HostStatsScreen
from workstation_tui.core.models import HostEntry
from tests.test_fleet_panel import make_app

ENTRY = HostEntry(name="alpha", address="10.0.0.1", user="u", group="dev_machine")

# Realistic multi-section sample text (same shape as test_hoststats.py's
# SAMPLE_TEXT), trimmed to what this file's assertions actually check.
SAMPLE_TEXT = """\
===vitals===
uptime up 3 days
mem 1234/7951MB
disk 12345678/98765432 (13%)
kernel Linux 5.14.0-427.el9.x86_64
os Rocky Linux 9.4 (Blue Onyx)
===workstation===
repo present
commit a1b2c3d 2 hours ago
branch main
dirty 3
stamp 1733356800
drift 0
===session===
users 2
names alice bob
===tools===
chezmoi chezmoi version 2.48.0
git git version 2.45.0
make GNU Make 4.3
"""


class _FakeStatsProc:
    """Fake asyncio.subprocess.Process exposing just what HostStatsScreen
    uses: `communicate()` (resolves with sample bytes, or raises
    TimeoutError to model `asyncio.wait_for`'s timeout without an actual
    15s sleep), plus `kill()`/`wait()` for the reap-after-kill path."""

    def __init__(self, *, stdout: bytes = b"", raise_timeout: bool = False) -> None:
        self._stdout = stdout
        self._raise_timeout = raise_timeout
        self.killed = False
        self.wait_calls = 0

    async def communicate(self):
        if self._raise_timeout:
            raise TimeoutError()
        return self._stdout, b""

    def kill(self) -> None:
        self.killed = True

    async def wait(self) -> int:
        self.wait_calls += 1
        return -9


class Host(App):
    """Minimal push_screen_wait harness (test_push_screen.py's `Host`,
    reused here so a bare HostStatsScreen can be driven with no
    WorkstationApp/FleetPanel wiring at all)."""

    def __init__(self, screen_factory):
        super().__init__()
        self.screen_factory = screen_factory
        self.result = "UNSET"

    def on_mount(self) -> None:
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(self.screen_factory())


def _content(screen, field_id: str) -> str:
    return str(screen.query_one(f"#host-stats-{field_id}", Static).content)


# -- enter routing: FleetPanel opens HostStatsScreen for the selected row --


async def test_enter_opens_host_stats_screen_for_selected_entry(monkeypatch) -> None:
    import workstation_tui.app.panels.fleet as fleet_mod

    class _RecordingHostStatsScreen(ModalScreen[None]):
        """Fleet-panel wiring double (same shape as test_push_screen.py's
        `_RecordingPushScreen`): records the entry HostStatsScreen was
        constructed with, then dismisses immediately — no real probe/ssh
        worker ever starts."""

        captured: HostEntry | None = None

        def __init__(self, entry, **kwargs) -> None:
            super().__init__()
            _RecordingHostStatsScreen.captured = entry

        def on_mount(self) -> None:
            self.dismiss(None)

    monkeypatch.setattr(fleet_mod, "HostStatsScreen", _RecordingHostStatsScreen)
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("enter")
        await pilot.pause()
    assert _RecordingHostStatsScreen.captured is not None
    assert _RecordingHostStatsScreen.captured.name == "alpha"


# -- happy path: parsed stats land in the rendered Statics -----------------


async def test_happy_path_renders_parsed_values() -> None:
    calls: list = []

    async def fake_probe(address, **kwargs):
        return "up"

    async def fake_exec(*args, **kwargs):
        calls.append(args)
        return _FakeStatsProc(stdout=SAMPLE_TEXT.encode())

    app = Host(lambda: HostStatsScreen(ENTRY, exec_fn=fake_exec, probe=fake_probe))
    async with app.run_test() as pilot:
        for _ in range(5):
            await pilot.pause()
        screen = app.screen
        assert _content(screen, "uptime") == "up 3 days"
        assert _content(screen, "mem") == "1234/7951MB"
        assert _content(screen, "branch") == "main"
        assert _content(screen, "repo") == "present"
        assert _content(screen, "chezmoi") == "chezmoi version 2.48.0"
        # latency is TUI-measured (not remote) -> always a numeric "...ms",
        # never the "–" absent-value dash.
        assert _content(screen, "latency").endswith("ms")
        assert _content(screen, "latency") != "–"
    assert len(calls) == 1


# -- probe "down": unreachable banner, ssh never attempted -----------------


async def test_probe_down_shows_unreachable_without_ssh() -> None:
    calls: list = []

    async def fake_probe(address, **kwargs):
        return "down"

    async def fake_exec(*args, **kwargs):
        calls.append(args)
        return _FakeStatsProc()

    app = Host(lambda: HostStatsScreen(ENTRY, exec_fn=fake_exec, probe=fake_probe))
    async with app.run_test() as pilot:
        for _ in range(3):
            await pilot.pause()
        screen = app.screen
        status = str(screen.query_one("#host-stats-status", Static).content)
        assert "unreachable" in status
        assert screen.query_one("#host-stats-grid").display is False
    assert calls == []


# -- ssh timeout: unreachable banner + the fake proc gets killed -----------


async def test_ssh_timeout_kills_proc_and_shows_unreachable() -> None:
    proc = _FakeStatsProc(raise_timeout=True)

    async def fake_probe(address, **kwargs):
        return "up"

    async def fake_exec(*args, **kwargs):
        return proc

    app = Host(lambda: HostStatsScreen(ENTRY, exec_fn=fake_exec, probe=fake_probe))
    async with app.run_test() as pilot:
        for _ in range(3):
            await pilot.pause()
        screen = app.screen
        status = str(screen.query_one("#host-stats-status", Static).content)
        assert "unreachable" in status
    assert proc.killed is True
    # Kill+reap, not just kill (probe_setup discipline) — a second wait()
    # after kill() so no zombie child is left behind.
    assert proc.wait_calls == 1


# -- R re-runs the whole two-stage worker -----------------------------------


async def test_rerun_key_invokes_exec_fn_again() -> None:
    calls: list = []

    async def fake_probe(address, **kwargs):
        return "up"

    async def fake_exec(*args, **kwargs):
        calls.append(args)
        return _FakeStatsProc(stdout=SAMPLE_TEXT.encode())

    app = Host(lambda: HostStatsScreen(ENTRY, exec_fn=fake_exec, probe=fake_probe))
    async with app.run_test() as pilot:
        for _ in range(3):
            await pilot.pause()
        assert len(calls) == 1
        await pilot.press("R")
        for _ in range(3):
            await pilot.pause()
    assert len(calls) == 2
