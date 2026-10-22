"""`ws apply` (every shell's wsa): when it asks before an apply and when it applies without
asking, its refusals, the difference between a check that found nothing and one that couldn't
run, and what reaches mise bootstrap (mise stubbed; test_mise.py runs the real one)."""

from __future__ import annotations

import io
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from helpers import Scratch

from wslib import baseline, cli, dotfiles

RAN = "no local edit would be overwritten"
COULDNT = "the local-edit check couldn't run"


class Apply(Scratch):
    def setUp(self) -> None:
        super().setUp()
        self.src, self.live = self.repo / "dotfiles/rc file", self.home / ".rc file"
        self.status = self.entries({"target": "~/.rc file", "source": "dotfiles/rc file"})
        self.write(self.src, "one\n")
        self.write(self.live, "one\n")
        self.fake_mise(self.status)
        store = baseline.Store()
        dotfiles.record_agreed(dotfiles.load(store, status_doc=self.status), store, "test")

    def wsa(self, *args: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = cli.main(["apply", *args])
        return rc, out.getvalue(), err.getvalue()

    def bootstraps(self) -> list[str]:
        log = self.root / "mise.log"
        lines = log.read_text().splitlines() if log.exists() else []
        return [ln[ln.index(" bootstrap ") + 1:] for ln in lines if " bootstrap " in ln]  # after -C <home>

    def refused(self, rc: int, err: str) -> None:
        self.assertEqual(rc, 1)
        self.assertIn("refusing to overwrite them non-interactively", err)
        self.assertEqual(self.bootstraps(), [])

    # --- what it asks about ---------------------------------------------------------

    def test_a_repo_only_change_applies_without_asking(self) -> None:
        self.write(self.src, "one\nrepo\n")
        rc, out, err = self.wsa("--force-dotfiles")
        self.assertEqual((rc, err), (0, ""))
        self.assertIn(f"checked 1 managed file(s): {RAN}", out)
        self.assertEqual(self.bootstraps(), ["bootstrap --only dotfiles --yes --force-dotfiles"])

    def test_a_local_only_edit_is_shown_and_refused_without_a_terminal(self) -> None:
        self.write(self.live, "one\nlocal\n")
        rc, out, err = self.wsa()
        self.refused(rc, err)
        self.assertIn("+++ ~/.rc file (repo)", out)
        self.assertIn("-local", out)  # the line the apply would drop
        self.assertIn("~/.rc file  (edited here since the last deploy)", out)
        self.assertIn("ws reconcile", err)
        self.assertNotIn(RAN, out)

    def test_both_sides_changed_asks(self) -> None:
        self.write(self.src, "one\nrepo\n")
        self.write(self.live, "one\nlocal\n")
        rc, out, err = self.wsa()
        self.refused(rc, err)
        self.assertIn("-local", out)
        self.assertIn("+repo", out)
        self.assertIn("(edited here since the last deploy)", out)

    def test_a_missing_baseline_asks(self) -> None:
        (self.state / "dotfiles/baseline.json").unlink()
        self.write(self.live, "one\nlocal\n")
        rc, out, err = self.wsa()
        self.refused(rc, err)
        self.assertIn("no baseline says which side changed", out)

    def test_a_corrupt_baseline_asks(self) -> None:
        # An unreadable index holds no baselines: every difference is unknown, so it asks.
        self.write(self.state / "dotfiles/baseline.json", "{ not json")
        self.write(self.src, "one\nrepo\n")  # a repo-only change, had the baseline been readable
        rc, out, err = self.wsa()
        self.refused(rc, err)
        self.assertIn("no baseline says which side changed", out)

    def test_a_mode_only_difference_applies_without_asking(self) -> None:
        self.live.chmod(0o755)
        rc, out, _ = self.wsa()
        self.assertEqual(rc, 0)
        self.assertIn(RAN, out)

    def test_a_missing_source_doesnt_ask(self) -> None:
        # mise refuses the whole apply then (it writes nothing): ws doesn't claim an overwrite.
        self.write(self.live, "one\nlocal\n")
        self.src.unlink()
        self.status["files"][0]["state"] = "source_missing"  # type: ignore[index]
        self.fake_mise(self.status)
        rc, out, _ = self.wsa()
        self.assertEqual(rc, 0)
        self.assertIn(RAN, out)

    def test_a_template_differing_only_in_mode_applies(self) -> None:
        self.write(self.repo / "dotfiles/zshrc.tera", "# {{ vars.name }}\n")
        st = self.entries({"target": "~/.zshrc", "source": "dotfiles/zshrc.tera", "mode": "template"})
        self.write(self.home / ".zshrc", "# me\n")
        self.fake_mise(st, "dotfile differs: ~/.zshrc\n  mode differs: 0644 -> 0755\n")  # no content hunk
        self.assertEqual(self.wsa()[0], 0)
        diff = ("dotfile differs: ~/.zshrc\n--- ~/.zshrc (current)\n+++ src (desired)\n"
                "@@ -1,2 +1 @@\n # me\n-alias local=1\n")
        self.write(self.home / ".zshrc", "# me\nalias local=1\n")
        self.fake_mise(st, diff)
        rc, out, _ = self.wsa()
        self.assertEqual(rc, 1)
        self.assertIn("-alias local=1", out)

    def test_a_template_that_cant_be_rendered_still_asks(self) -> None:
        self.write(self.repo / "dotfiles/zshrc.tera", "# {{ vars.name }}\n")
        st = self.entries({"target": "~/.zshrc", "source": "dotfiles/zshrc.tera", "mode": "template"})
        self.write(self.home / ".zshrc", "# me\nalias local=1\n")
        self.fake_mise(st, "--- a\n+++ b\n@@ -1 +1 @@\n-not what is there\n+x\n")
        rc, out, err = self.wsa()
        self.refused(rc, err)
        self.assertIn("~/.zshrc: no diff to show (mise's diff didn't apply", out)

    def test_it_asks_and_does_what_it_is_told(self) -> None:
        self.write(self.live, "one\nlocal\n")
        with mock.patch("wslib.core.interactive", return_value=True), \
                mock.patch("wslib.ui.confirm", return_value=False) as ask:
            rc, _, err = self.wsa()
        self.assertEqual(rc, 1)
        self.assertIn("backs each up first, and stops if it can't", ask.call_args.args[0])
        self.assertIn("nothing applied", err)
        self.assertEqual(self.bootstraps(), [])
        rc, out, _ = self.confirmed()
        self.assertEqual(rc, 0)
        self.assertEqual(self.bootstraps(), ["bootstrap --only dotfiles --yes"])
        # wsa backed the edit up itself, before mise ran, and told the hook so.
        (orig, dest, why, _), = baseline.backup_sets()[0][1]
        self.assertEqual((orig, Path(dest).read_text(), why), (str(self.live), "one\nlocal\n", baseline.LOCAL_EDIT))
        self.assertIn("backed up 1 file(s) first", out)
        self.assertEqual(self.backed_up_env(), ["WS_BACKED_UP=1"])

    def test_without_a_prompt_the_hook_backs_up(self) -> None:
        self.write(self.src, "one\nrepo\n")
        self.assertEqual(self.wsa()[0], 0)
        self.assertEqual(self.backed_up_env(), ["WS_BACKED_UP="])

    # --- the answer covers only what was shown --------------------------------------------

    def confirmed(self, meanwhile: object = None) -> tuple[int, str, str]:
        """wsa answered yes, with `meanwhile` run while the prompt waits."""
        def answer(_question: str, _default: bool = False) -> bool:
            if callable(meanwhile):
                meanwhile()
            return True
        with mock.patch("wslib.core.interactive", return_value=True), mock.patch("wslib.ui.confirm", side_effect=answer):
            return self.wsa()

    def backed_up_env(self) -> list[str]:
        log = self.root / "mise.log.env"
        return log.read_text().splitlines() if log.exists() else []

    def stopped(self, rc: int, err: str, why: str) -> None:
        self.assertEqual(rc, 1)
        self.assertIn(f"wsa: nothing applied: {why}", err)
        self.assertEqual(self.bootstraps(), [])

    def test_an_edit_while_the_prompt_waits_stops_the_apply(self) -> None:
        self.write(self.live, "one\nlocal\n")
        rc, _, err = self.confirmed(lambda: self.write(self.live, "one\nlocal\nsaved while you read the diff\n"))
        self.stopped(rc, err, "~/.rc file changed while you were deciding")
        self.assertIn("Run wsa again to review it", err)
        self.assertEqual(baseline.backup_sets(), [])

    def test_a_file_put_at_risk_while_the_prompt_waits_stops_it(self) -> None:
        other_src, other = self.repo / "dotfiles/other", self.home / ".other"
        self.write(other_src, "x\n")
        self.write(other, "x\n")
        st = self.entries({"target": "~/.rc file", "source": "dotfiles/rc file"},
                          {"target": "~/.other", "source": "dotfiles/other"})
        self.fake_mise(st)
        store = baseline.Store()
        dotfiles.record_agreed(dotfiles.load(store, status_doc=st), store, "test")
        self.write(self.live, "one\nlocal\n")
        rc, _, err = self.confirmed(lambda: self.write(other, "x\nedited meanwhile\n"))
        self.stopped(rc, err, "~/.other changed while you were deciding")

    def test_a_template_render_changed_while_the_prompt_waits_stops_it(self) -> None:
        # The template file, or a variable it uses: either way mise's render moves.
        self.write(self.repo / "dotfiles/zshrc.tera", "# {{ vars.name }}\n")
        st = self.entries({"target": "~/.zshrc", "source": "dotfiles/zshrc.tera", "mode": "template"})
        self.write(self.home / ".zshrc", "# me\nalias local=1\n")
        self.fake_mise(st, "--- a\n+++ b\n@@ -1,2 +1 @@\n # me\n-alias local=1\n")
        new_render = "--- a\n+++ b\n@@ -1,2 +1 @@\n-# me\n-alias local=1\n+# a new name\n"
        rc, _, err = self.confirmed(lambda: self.fake_mise(st, new_render))
        self.stopped(rc, err, "~/.zshrc changed while you were deciding")

    def test_a_recheck_that_cant_run_stops_it(self) -> None:
        self.write(self.live, "one\nlocal\n")
        broken = f"""printf '%s\\n' "$*" >>"{self.root / 'mise.log'}"; echo 'mise broke' >&2; exit 1"""
        rc, _, err = self.confirmed(lambda: self.fake("mise", broken))
        self.stopped(rc, err, "couldn't check again after your answer (mise broke)")

    def test_a_backup_that_fails_stops_it(self) -> None:
        self.write(self.live, "one\nlocal\n")
        with mock.patch("wslib.baseline.Backup.save", side_effect=OSError(28, "No space left on device")):
            rc, _, err = self.confirmed()
        self.stopped(rc, err, "couldn't back up ~/.rc file (No space left on device)")
        self.assertEqual(self.live.read_text(), "one\nlocal\n")

    # --- refusals, and checks that can't run ----------------------------------------------

    def test_a_wrong_config_root_always_refuses(self) -> None:
        self.status["files"][0]["origin"]["config_root"] = "/somewhere/else"  # type: ignore[index]
        self.fake_mise(self.status)
        rc, _, err = self.wsa()
        self.assertEqual(rc, 1)
        self.assertIn("would apply the wrong checkout", err)
        self.assertEqual(self.bootstraps(), [])

    def test_no_config_root_skips_only_that_check(self) -> None:
        del self.status["files"][0]["origin"]["config_root"]  # type: ignore[index]
        self.fake_mise(self.status)
        self.write(self.live, "one\nlocal\n")
        rc, _, err = self.wsa()
        self.assertIn("the wrong-checkout check couldn't run", err)
        self.refused(rc, err)  # the local-edit check still ran

    def test_a_status_that_fails_applies_with_a_warning_and_mises_exit_code(self) -> None:
        log = self.root / "mise.log"
        self.fake("mise", f"""printf '%s\\n' "$*" >>"{log}"
case " $* " in
  *" dot status "*) echo 'template error' >&2; exit 1 ;;
  *" bootstrap "*) exit 3 ;;
esac""")
        rc, out, err = self.wsa()
        self.assertEqual(rc, 3)  # mise's own status
        self.assertIn(f"{COULDNT} (template error). Applying without it", err)
        self.assertNotIn(RAN, out)
        self.assertEqual(self.bootstraps(), ["bootstrap --only dotfiles --yes"])

    def test_an_unreadable_file_is_a_check_that_couldnt_run(self) -> None:
        with mock.patch("wslib.apply.local_edits", side_effect=PermissionError(13, "Permission denied")):
            rc, out, err = self.wsa()
        self.assertEqual(rc, 0)
        self.assertIn(COULDNT, err)
        self.assertNotIn(RAN, out)
