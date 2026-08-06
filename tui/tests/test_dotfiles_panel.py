from workstation_tui.app.app import WorkstationApp
from workstation_tui.app.panels.dotfiles import _assemble_full_diff
from workstation_tui.core.models import GitState, PendingChange
from tests.test_app_shell import fake_provider
from tests.test_provision_panel import FakeRunner, tools_provider

PENDING = [PendingChange(code="MM", path=".zshrc"),
           PendingChange(code=" A", path=".config/new")]
GIT = GitState(branch="main", dirty=False, ahead=1, behind=0)


def make_app(runner=None, pending=None):
    return WorkstationApp(
        summary_provider=fake_provider, runner=runner or FakeRunner(),
        tools_provider=tools_provider, sudo_status_fn=lambda: "valid",
        pending_provider=lambda: (pending if pending is not None else PENDING, []),
        git_state_provider=lambda root: (GIT, []),
        target_diff_fn=lambda path: (f"--- {path}\n+new line\n", None),
    )


async def test_pending_table_and_git_line() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        table = app.query_one("#dotfiles-table")
        assert table.row_count == 2
        git_text = str(app.query_one("#dotfiles-git").content)
        assert "main" in git_text and "1" in git_text


async def test_cursor_shows_target_diff() -> None:
    app = make_app()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        diff_text = str(app.query_one("#dotfiles-diff").content)
        assert ".zshrc" in diff_text and "+new line" in diff_text


async def test_apply_flow_confirm_then_force() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#dotfiles-table").focus()
        await pilot.press("a")
        await pilot.pause()
        await pilot.press("y")          # ConfirmModal
        for _ in range(4):
            await pilot.pause()
    assert ["chezmoi", "apply", "--force"] in runner.commands


async def test_apply_declined_never_runs() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#dotfiles-table").focus()
        await pilot.press("a")
        await pilot.pause()
        await pilot.press("escape")
        for _ in range(3):
            await pilot.pause()
    assert runner.commands == []


async def test_re_add_selected() -> None:
    runner = FakeRunner()
    app = make_app(runner)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        app.query_one("#dotfiles-table").focus()
        await pilot.press("A")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(4):
            await pilot.pause()
    assert ["chezmoi", "re-add", ".zshrc"] in runner.commands


async def test_in_sync_message() -> None:
    app = make_app(pending=[])
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        assert any("in sync" in l for l in app.query_one("#dotfiles").log_lines)


# -- Finding 4: full-diff must not silently drop per-file errors ---------


def test_assemble_full_diff_cases() -> None:
    # Pure function, no app/worker needed — the 3 cases the task spec asks
    # for (all-ok, mixed, all-error), plus the pre-existing empty/no-op
    # case action_full_diff already guards against (kept here for
    # completeness of the pure function's own contract).
    # all-ok: no error section at all.
    assert _assemble_full_diff(["diff-a", "diff-b"], []) == "diff-a\ndiff-b"

    # mixed: THIS is the Finding 4 bug — the old code's `"\n".join(parts)
    # if parts else ...` branch dropped errors entirely whenever any diff
    # succeeded. Now the successful diff and the error both survive.
    mixed = _assemble_full_diff(["diff-a"], ["bad/path: boom"])
    assert mixed == "diff-a\n\n--- errors ---\nbad/path: boom"

    # all-error: no successful diff at all, still labelled as an errors
    # section (was previously just the bare joined error text with no
    # section header).
    all_error = _assemble_full_diff([], ["a: boom", "b: boom2"])
    assert all_error == "--- errors ---\na: boom\nb: boom2"

    # neither (defensive — action_full_diff already refuses to invoke the
    # worker when self.pending is empty, so this shouldn't occur in
    # practice, but the pure function still needs a sane fallback).
    assert _assemble_full_diff([], []) == "no changes"


async def test_markup_shaped_paths_render_safely() -> None:
    hostile = [PendingChange(code="MM", path=".config/[/]weird"),
               PendingChange(code=" A", path=".config/[tag]x")]
    app = make_app(pending=hostile)
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("3")
        for _ in range(3):
            await pilot.pause()
        table = app.query_one("#dotfiles-table")
        assert table.row_count == 2  # no MarkupError crash
