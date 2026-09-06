"""Generalized #141 regression: a render/log callback landing AFTER a
panel's widget tree has been torn down must never raise NoMatches.

Root cause (fix round 1, reviewer finding): `_composed` was set True on
mount and never reset — so a callback scheduled from a background worker
(refresh_panel's thread worker, launch_task's on_result/log_to, a probe
cycle's on-loop worker) that fires after the panel has been unmounted (app
exit, test teardown, or an explicit `.remove()`) still saw `_composed is
True` and crashed trying to `query_one` a widget no longer in the DOM. This
rotated across whichever panel's callback happened to land last in a given
run — provision.py's `_render_rows`, health.py's `_render_rows`/services/
interop lines, and (added here proactively) dotfiles.py/fleet.py's own
render + log methods, none of which reset `_composed` on unmount.

The fix: every panel with a `_composed` flag gains `on_unmount(self) ->
None: self._composed = False`, and every tree-touching guard checks
`self._composed and self.is_attached` (belt-and-suspenders — either one
flipping false is enough to skip the render). State itself stays in plain
attributes exactly as before; only the render/log side effects are skipped.

One deterministic test, all four panels: mount a full app (so every panel
is composed for real), unmount each panel directly (`await panel.remove()`
— the same lifecycle a torn-down app/screen goes through), then invoke its
render + log methods directly. No panel may raise.
"""

from pathlib import Path

from workstation_tui.app.app import WorkstationApp
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import tools_provider


async def test_render_and_log_callbacks_noop_after_unmount(tmp_path: Path) -> None:
    # F10: inject tools_provider/health_cache_path like the other app
    # tests (test_history_screen.py etc.) — without these, an
    # uninjected WorkstationApp's _default_tools runs a REAL `make
    # inventory` (30s timeout) and health_cache_path reads the REAL
    # ~/.cache/workstation-tui/health.json, both real-filesystem/real-
    # subprocess side effects this suite otherwise never touches.
    app = WorkstationApp(
        summary_provider=fake_provider,
        tools_provider=tools_provider,
        health_cache_path=tmp_path / "health.json",
    )
    async with app.run_test() as pilot:
        await pilot.pause()
        # Capture references BEFORE removing anything — app.query_one can't
        # find a widget once it's out of the DOM, so every panel this test
        # still wants to poke after unmount is grabbed up front.
        panels = {pid: app.query_one(f"#{pid}") for pid in
                  ("provision", "health", "dotfiles", "fleet")}
        for panel_id, panel in panels.items():
            assert panel._composed is True  # sanity: really was mounted
            await panel.remove()
            assert panel._composed is False  # on_unmount reset it
            assert panel.is_attached is False

            # Every panel's tree-touching render/log method, called
            # directly on the now-unmounted instance — must not raise.
            panel._render_rows()
            panel.append_log(f"line after {panel_id} unmount")

        # dotfiles.py/fleet.py carry a couple of extra guarded methods
        # (Task 2 fix round 1) not shared by the other two panels.
        panels["dotfiles"]._render_git_line()
        panels["dotfiles"]._apply_diff("diff text", None)

        panels["health"]._render_services_line()
        panels["health"]._render_interop_line()
