"""Pre-apply backups: the pre-dotfiles hook's outcomes (a set written, nothing to back up, a
check that couldn't run, a file at risk that couldn't be backed up) and the one that stops
the apply, and backup sets that never collide across processes."""

from __future__ import annotations

import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

from helpers import WS, Scratch

from wslib import baseline, cli, dotfiles


@unittest.skipIf(os.name == "nt", "the hook is driven through bash stubs")
class SnapshotHook(Scratch):
    def setUp(self) -> None:
        super().setUp()
        self.status = self.entries({"target": "~/.rc", "source": "dotfiles/rc"})
        self.write(self.repo / "dotfiles/rc", "one\n")
        self.live = self.write(self.home / ".rc", "one\n")
        self.fake_mise(self.status)
        store = baseline.Store()
        dotfiles.record_agreed(dotfiles.load(store, status_doc=self.status), store, "t")

    def hook(self, rc: int = 0, **env: str) -> subprocess.CompletedProcess[str]:
        p = subprocess.run([sys.executable, str(WS / "ws.py"), "baseline", "snapshot"], capture_output=True,
                           text=True, env=dict(os.environ, **env))
        self.assertEqual(p.returncode, rc, p.stdout + p.stderr)
        return p

    def break_backups(self) -> None:
        # A file where the backups directory goes: every backup fails, on any OS, even as root.
        self.write(self.state / "dotfiles" / "backups", "not a directory")

    def test_nothing_to_back_up_goes_ahead(self) -> None:
        self.break_backups()  # irrelevant: nothing needs a backup
        p = self.hook()
        self.assertIn("pre-apply backup: nothing to back up (1 managed file(s) checked", p.stdout)
        self.assertNotIn("FAILED", p.stderr)

    def test_a_local_edit_is_backed_up(self) -> None:
        self.write(self.live, "one\nlocal\n")
        p = self.hook()
        self.assertIn("backed up 1 local edit(s) the apply may overwrite", p.stdout)
        self.assertNotIn("nothing to back up", p.stdout)

    def test_a_local_edit_that_cant_be_backed_up_stops_the_apply(self) -> None:
        self.write(self.live, "one\nlocal\n")
        self.break_backups()
        p = self.hook(rc=cli.STOP_APPLY)
        self.assertIn("PRE-APPLY BACKUP FAILED: couldn't copy ~/.rc (", p.stderr)
        self.assertIn("The apply is stopped", p.stderr)
        self.assertIn("WS_BACKED_UP=1", p.stderr)  # how to overwrite anyway
        self.assertNotIn("nothing to back up", p.stdout)

    def test_a_check_that_cant_run_goes_ahead_and_says_so(self) -> None:
        self.write(self.live, "one\nlocal\n")
        self.fake("mise", "echo 'not json'")
        p = self.hook()
        self.assertIn("no pre-apply backup: the check couldn't run", p.stderr)
        self.assertNotIn("nothing to back up", p.stdout)

    def test_a_caller_that_backed_up_skips_it(self) -> None:
        self.write(self.live, "one\nlocal\n")
        self.break_backups()
        p = self.hook(WS_BACKED_UP="1")
        self.assertEqual((p.stdout, p.stderr), ("", ""))

    def test_the_tasks_pass_only_the_stop_through(self) -> None:
        # tasks/dotfiles-snapshot: 3 stops the bootstrap; anything else (a crash, no Python)
        # is 0. (The Windows task does the same with `if errorlevel 3 if not errorlevel 4`.)
        task = Path(__file__).resolve().parents[3] / "tasks" / "dotfiles-snapshot"
        for code, want in ((0, 0), (1, 0), (2, 0), (3, 3), (4, 0)):
            with self.subTest(code):
                fake_root = self.root / f"checkout{code}"
                (fake_root / "tasks").mkdir(parents=True)
                (fake_root / "tasks" / "dotfiles-snapshot").write_text(task.read_text())
                self.write(fake_root / "scripts/ws/ws.py", f"import sys; sys.exit({code})\n")
                p = subprocess.run(["bash", str(fake_root / "tasks" / "dotfiles-snapshot")], capture_output=True, text=True)
                self.assertEqual(p.returncode, want, p.stderr)


class BackupSets(Scratch):
    def test_sets_made_at_once_never_collide(self) -> None:
        # Eight processes in the same second (the stamp pinned), all starting together: each
        # gets a set of its own, holding just its file.
        start = time.time() + 1.0
        script = f"""import sys, time
sys.path.insert(0, {str(WS)!r})
from pathlib import Path
from wslib import baseline, core
core.stamp = lambda: "20260101-000000"
time.sleep(max(0.0, {start!r} - time.time()))
b = baseline.Backup("pre-apply")
b.save(Path(sys.argv[1]), sys.argv[1].encode(), "t")
print(b.dir)
"""
        procs = [subprocess.Popen([sys.executable, "-c", script, str(self.home / f"f{i}")], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True) for i in range(8)]
        results = [p.communicate(timeout=120) for p in procs]
        self.assertEqual([p.returncode for p in procs], [0] * 8, [err for _, err in results])
        self.assertEqual(len({out.strip() for out, _ in results}), 8)
        sets = baseline.backup_sets()
        self.assertEqual(sorted(len(entries) for _, entries in sets), [1] * 8)
        self.assertEqual(sorted(e[0] for _, entries in sets for e in entries),
                         sorted(str(self.home / f"f{i}") for i in range(8)))


if __name__ == "__main__":
    unittest.main()
