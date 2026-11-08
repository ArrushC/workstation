"""wslib.agent_events: what live sessions hear about jobs (one line per event on the next prompt,
from the events file only) and the desktop notice when a job finishes or needs the person."""

from __future__ import annotations

import json
import os
import time
import unittest
from unittest import mock

from agent_helpers import AgentScratch

from wslib import agent_events as ev
from wslib import agent_registry as reg
from wslib import jobs


def _job(job_id: str, repo: str = "~/src/proj", title: str = "the thing") -> jobs.Job:
    job = jobs.Job(id=job_id, title=title, repo=repo, vcs="git", base={}, prompt_sha="s", paths=[], created="x",
                   session_id="", timeout="2h")
    jobs.save(job)
    return job


class Events(AgentScratch):
    def test_lines_for_session(self) -> None:
        self.assertEqual(ev.lines_for("S1", "~/src/proj"), [])   # the first prompt only sets the marker
        ev.append("succeeded", _job("aaa111"), "aaa111 succeeded checks pass (the thing)")
        ev.append("failed", _job("bbb222"), "bbb222 failed (other)")
        ev.append("succeeded", _job("ccc333", repo="~/src/other"), "ccc333 succeeded (elsewhere)")
        lines = ev.lines_for("S1", "~/src/proj")
        self.assertEqual(lines, ["[orchestration] aaa111 succeeded checks pass (the thing): ws-agent result aaa111",
                                 "[orchestration] bbb222 failed (other): ws-agent result bbb222"])
        self.assertEqual(ev.lines_for("S1", "~/src/proj"), [])   # each event once per session
        ev.append("needs-you", _job("ddd444", repo="~/src/other"), "ddd444 needs you (asks)")
        self.assertEqual(len(ev.lines_for("S1", "~/src/proj")), 1)   # a question from anywhere
        for i in range(5):
            ev.append("failed", _job(f"eee00{i}"), f"eee00{i} failed")
        lines = ev.lines_for("S1", "~/src/proj")
        self.assertEqual(len(lines), 3)
        self.assertIn("eee004", lines[-1])   # the newest last
        self.assertEqual(ev.lines_for("S2", "~/src/proj"), [])   # another session starts fresh

    def test_inbox_event_line(self) -> None:
        self.assertEqual(ev.lines_for("S1", "~/src/proj"), [])
        ev.append_inbox("a1b2c3d4e5", "~/src/proj", "inbox: a1b2c3d4e5 (svn) waits for you")
        self.assertEqual(ev.lines_for("S1", "~/src/proj"),
                         ["[orchestration] inbox: a1b2c3d4e5 (svn) waits for you: ws-agent inbox --show a1b2c3d4e5"])

    def test_session_ids_cant_escape_the_marker_dir(self) -> None:
        self.assertEqual(ev.lines_for("../../evil", "~/src/proj"), [])
        self.assertFalse((self.state / "evil").exists())
        self.assertFalse(any(p.name == "evil" for p in self.root.rglob("evil")))

    def test_rotation(self) -> None:
        with mock.patch.object(ev, "EVENTS_MAX", 2000):
            ev.lines_for("S", "~/src/proj")
            for i in range(60):
                ev.append("failed", _job(f"f{i:05d}"), f"f{i:05d} failed " + "x" * 40)
            self.assertTrue(ev.events_path().with_suffix(".jsonl.1").exists())
            self.assertLess(ev.events_path().stat().st_size, 3000)
            ev.append("failed", _job("last01"), "last01 failed")
            self.assertIn("last01", ev.lines_for("S", "~/src/proj")[-1])

    def test_append_waits_for_the_lock(self) -> None:
        # serve and the executors append from different processes; rotation (stat, then rename)
        # and the write happen under agent-events.lock, so two finishes can't lose a line.
        import fcntl
        import threading
        job = _job("ccc999")
        lock = ev.events_path().with_name("agent-events.lock")
        lock.parent.mkdir(parents=True, exist_ok=True)
        with open(lock, "a+") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            t = threading.Thread(target=ev.append, args=("failed", job, "held back"))
            t.start()
            time.sleep(0.4)
            self.assertFalse(ev.events_path().exists() and "held back" in ev.events_path().read_text())
            fcntl.flock(fh, fcntl.LOCK_UN)
        t.join(5)
        self.assertEqual(json.loads(ev.events_path().read_text().splitlines()[-1])["text"], "held back")

    def test_old_markers_pruned(self) -> None:
        ev.lines_for("old", "~/src/proj")
        marker = ev.marker_dir() / "old"
        past = time.time() - 8 * 86400
        os.utime(marker, (past, past))
        ev.lines_for("new", "~/src/proj")
        self.assertFalse(marker.exists())


class Notify(AgentScratch):
    def test_notify_detached(self) -> None:
        # written whole, then renamed: the test polls for the file and must never read it half-written
        script = self.write(self.home / ".claude" / "notify.sh",
                            f'printf "%s\\n" "$@" >"{self.root}/notify.argv"; env >"{self.root}/notify.tmp"; '
                            f'mv "{self.root}/notify.tmp" "{self.root}/notify.env"; sleep 2\n')
        start = time.monotonic()
        ev.notify("aaa111 succeeded (the 'thing'); $(rm -rf /)")
        self.assertLess(time.monotonic() - start, 1.5)   # never waits for the notice
        for _ in range(100):
            if (self.root / "notify.env").exists():
                break
            time.sleep(0.05)
        argv = (self.root / "notify.argv").read_text().splitlines()
        self.assertEqual(argv[0], "ws-agent")
        self.assertNotIn("'", argv[1])
        self.assertNotIn("$(", argv[1])
        self.assertIn("NOTIFY_NO_MODAL=1", (self.root / "notify.env").read_text())
        del script

    def test_notify_off_or_missing(self) -> None:
        ev.notify("nothing to run")   # no notify.sh: nothing happens
        self.write(self.home / ".claude" / "notify.sh", f': >"{self.root}/ran"\n')
        self.write(reg.registry_path(), "[notify]\ndesktop = false\n")
        ev.notify("off")
        time.sleep(0.3)
        self.assertFalse((self.root / "ran").exists())


if __name__ == "__main__":
    unittest.main()
