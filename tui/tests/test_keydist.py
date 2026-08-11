"""Task 6: guided key distribution — picker preselect/toggle/confirm and the
app-suspend resume flow (`k` on Fleet).

Tests 1-3 drive `KeyDistModal` directly through a bare `App` harness (same
`push_screen_wait`-from-a-worker pattern as test_host_form.py/
test_sudo_modal.py). Tests 4-6 drive it end-to-end through a full
`WorkstationApp` with an injected `copy_id_fn` recorder (never a real
`suspend()`/subprocess — same discipline `ssh_to`'s tests already follow).
"""

from textual.app import App
from textual.widgets import SelectionList

from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.widgets.keydist_modal import KeyDistModal
from workstation_tui.core.models import HostEntry
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider

_UNSET = "not-dismissed"  # sentinel distinct from a real None/list result

HOSTS = [
    HostEntry(name="alpha", address="10.0.0.1", user="u", group="dev_machine"),
    HostEntry(name="beta", address="10.0.0.2", user="u", group="dev_machine"),
    HostEntry(name="gamma", address="10.0.0.3", user="u", group="dev_machine"),
]


# -- modal-only harness (tests 1-3) ------------------------------------------


class Host(App):
    def __init__(self, hosts, probe_states, *, key_present: bool = True) -> None:
        super().__init__()
        self._hosts = hosts
        self._probe_states = probe_states
        self._key_present = key_present
        self.result = _UNSET

    def on_mount(self) -> None:
        self.run_worker(self._ask())

    async def _ask(self) -> None:
        self.result = await self.push_screen_wait(
            KeyDistModal(self._hosts, self._probe_states, self._key_present)
        )


async def test_preselect_is_exactly_the_ssh_failed_hosts() -> None:
    probe_states = {
        "alpha": ("up", "setup"),
        "beta": ("up", "ssh-failed"),
        "gamma": ("down", None),
    }
    app = Host(HOSTS, probe_states)
    async with app.run_test() as pilot:
        await pilot.pause()
        selection_list = app.screen.query_one("#keydist-list", SelectionList)
        assert set(selection_list.selected) == {"beta"}


async def test_a_toggles_all() -> None:
    probe_states = {
        "alpha": ("up", "setup"),
        "beta": ("up", "ssh-failed"),
        "gamma": ("down", None),
    }
    app = Host(HOSTS, probe_states)
    async with app.run_test() as pilot:
        await pilot.pause()
        selection_list = app.screen.query_one("#keydist-list", SelectionList)
        selection_list.focus()
        # Starts with exactly beta selected (not all) -> "a" selects all.
        await pilot.press("a")
        await pilot.pause()
        assert set(selection_list.selected) == {"alpha", "beta", "gamma"}
        # All selected -> "a" again clears.
        await pilot.press("a")
        await pilot.pause()
        assert selection_list.selected == []


async def test_zero_selected_confirm_warns_and_stays_open(monkeypatch) -> None:
    # No ssh-failed host -> nothing preselected.
    probe_states = {
        "alpha": ("up", "setup"),
        "beta": ("up", "setup"),
        "gamma": ("down", None),
    }
    app = Host(HOSTS, probe_states)
    calls: list = []
    async with app.run_test() as pilot:
        await pilot.pause()
        modal = app.screen
        assert isinstance(modal, KeyDistModal)
        monkeypatch.setattr(modal, "notify", lambda *a, **k: calls.append((a, k)))
        selection_list = modal.query_one("#keydist-list", SelectionList)
        selection_list.focus()
        assert selection_list.selected == []
        await pilot.press("enter")
        await pilot.pause()
        # Still on the modal — push_screen_wait never resolved.
        assert app.screen is modal
    assert app.result == _UNSET
    assert calls, "must warn the user"
    assert calls[0][0][0] == "no hosts selected"
    assert calls[0][1].get("severity") == "warning"


# -- full-app harness (tests 4-6) --------------------------------------------


async def _no_ssh_failed_probe(entries, **kwargs):
    return {e.name: ("up", "setup") for e in entries}


async def _with_ssh_failed_probe(entries, **kwargs):
    return {
        "alpha": ("up", "ssh-failed"),
        "beta": ("up", "ssh-failed"),
        "gamma": ("up", "setup"),
    }


def make_app(*, copy_id_fn=None, probe_all_fn=None, hosts=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        hosts_provider=lambda: (hosts or HOSTS, []),
        probe_all_fn=probe_all_fn or _no_ssh_failed_probe,
        copy_id_fn=copy_id_fn,
    )


async def test_confirm_calls_copy_id_fn_with_entries_in_table_order() -> None:
    calls: list = []

    def recorder(entries):
        calls.append(entries)
        return [(e.name, 0) for e in entries]

    app = make_app(copy_id_fn=recorder)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("k")
        await pilot.pause()
        selection_list = app.screen.query_one("#keydist-list", SelectionList)
        # Select in the REVERSE of table order (gamma then alpha) — the
        # resolved entries handed to copy_id_fn must still come out in
        # table order (alpha, gamma), not selection order.
        selection_list.select("gamma")
        selection_list.select("alpha")
        await pilot.press("enter")
        for _ in range(4):
            await pilot.pause()
    assert calls, "copy_id_fn must have been called"
    assert [e.name for e in calls[0]] == ["alpha", "gamma"]


async def test_resume_flow_logs_rc_reprobes_and_toasts_counts_only(
    monkeypatch,
) -> None:
    probe_call_count = 0

    async def counting_probe(entries, **kwargs):
        nonlocal probe_call_count
        probe_call_count += 1
        return await _with_ssh_failed_probe(entries, **kwargs)

    def recorder(entries):
        return [(e.name, 0 if e.name == "alpha" else 1) for e in entries]

    app = make_app(copy_id_fn=recorder, probe_all_fn=counting_probe)
    notify_calls: list = []
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        calls_before = probe_call_count
        app.query_one("#fleet-table").focus()
        monkeypatch.setattr(app, "notify", lambda *a, **k: notify_calls.append((a, k)))
        await pilot.press("k")
        await pilot.pause()
        # alpha + beta are preselected (both ssh-failed) — confirm as-is.
        await pilot.press("enter")
        for _ in range(6):
            await pilot.pause()
        panel = app.query_one("#fleet")
    assert "copy-id alpha: ok" in panel.log_lines
    assert "copy-id beta: failed (rc=1)" in panel.log_lines
    assert probe_call_count > calls_before, "resume flow must re-probe"
    toasts = [c[0][0] for c in notify_calls if "key distribution" in str(c[0][0])]
    assert toasts, "must toast the counts"
    message = toasts[0]
    assert message == "key distribution — 1 ok, 1 failed"
    assert "alpha" not in message and "beta" not in message


async def test_k_gated_on_push_inflight(monkeypatch) -> None:
    calls: list = []

    def recorder(entries):
        calls.append(entries)
        return [(e.name, 0) for e in entries]

    app = make_app(copy_id_fn=recorder, probe_all_fn=_with_ssh_failed_probe)
    notify_calls: list = []
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("4")
        for _ in range(4):
            await pilot.pause()
        app.query_one("#fleet-table").focus()
        await pilot.press("k")
        await pilot.pause()
        app._push_inflight = True
        monkeypatch.setattr(app, "notify", lambda *a, **k: notify_calls.append((a, k)))
        # alpha + beta already preselected (both ssh-failed) — confirm.
        await pilot.press("enter")
        for _ in range(4):
            await pilot.pause()
    assert calls == [], "copy_id_fn must never be called while a push is inflight"
    assert notify_calls
    assert notify_calls[0][0][0] == "push running"
    assert notify_calls[0][1].get("severity") == "warning"
