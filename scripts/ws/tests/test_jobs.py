"""wslib.jobs: agent job records, the pueue adapter, and the state derived from both."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
import unittest

from agent_helpers import REAL_STATUS, AgentScratch

from wslib import jobs


class Jobs(AgentScratch):
    def mkjob(self, **kw: object) -> jobs.Job:
        fields: dict[str, object] = dict(id=jobs.new_id(), title="t", repo="~/src/proj", vcs="git",
                                         base={"commit": "c0ffee"}, prompt_sha="sha", paths=[],
                                         created="2026-11-06T00:00:00+00:00", session_id="", timeout="2h")
        fields.update(kw)
        job = jobs.Job(**fields)  # type: ignore[arg-type]
        jobs.save(job)
        return job

    def exit_json(self, job: jobs.Job, code: int) -> None:
        self.write(jobs.job_dir(job.id) / "result" / "exit.json", json.dumps({"exit_code": code}))

    def test_state_order(self) -> None:
        # (job flags, exit code or None, pueue status of the job's task or None for missing, want)
        cases = [
            ({"closed": True}, 0, "Running", "closed"),
            ({"cancelled": True}, 0, "Success", "cancelled"),
            ({}, 0, "Running", "succeeded"),
            ({}, 1, "Success", "failed"),
            ({}, None, "Running", "running"),
            ({}, None, "Queued", "queued"),
            ({}, None, "Stashed", "queued"),
            ({}, None, "Paused", "queued"),
            ({}, None, "Locked", "queued"),
            ({}, None, "Killed", "interrupted"),
            ({}, None, None, "interrupted"),
            ({}, None, "Failed", "failed"),
            ({}, None, "Success", "failed"),
        ]
        for flags, code, status, want in cases:
            job = self.mkjob(pueue_id=3, **flags)
            if code is not None:
                self.exit_json(job, code)
            tasks = {3: status} if status else {}
            self.assertEqual(jobs.state(job, tasks), want, (flags, code, status))

    def test_state_unknown_when_daemon_down(self) -> None:
        job = self.mkjob(pueue_id=3)
        self.assertEqual(jobs.state(job, None), "unknown")
        self.exit_json(job, 0)
        self.assertEqual(jobs.state(job, None), "succeeded")

    def test_state_never_enqueued_is_interrupted(self) -> None:
        self.assertEqual(jobs.state(self.mkjob(pueue_id=None), {}), "interrupted")

    def test_pueue_status_real_shapes(self) -> None:
        self.write(self.pq / "status.json", json.dumps(REAL_STATUS))
        q = jobs.pueue_status()
        assert q is not None
        self.assertEqual(q.tasks, {0: "Success", 1: "Failed", 2: "Killed", 3: "Running", 4: "Stashed", 5: "Queued",
                                   6: "Running"})
        self.assertEqual((q.running, q.queued), (1, 1))   # task 6 is in another group
        self.assertEqual((q.group, q.parallel), ("Running", 1))

    def test_pueue_status_paused_and_absent_group(self) -> None:
        self.pueue_status({}, group="Paused", parallel=2)
        q = jobs.pueue_status()
        assert q is not None
        self.assertEqual((q.group, q.parallel), ("Paused", 2))
        self.pueue_status({}, agents=False)
        q = jobs.pueue_status()
        assert q is not None
        self.assertEqual(q.group, "")

    def test_pueue_status_none_when_down(self) -> None:
        self.assertIsNone(jobs.pueue_status())   # no status.json: the fake daemon is down
        (self.bin / "pueue").unlink()
        os.environ["PATH"] = str(self.bin)   # and no pueue at all
        self.assertIsNone(jobs.pueue_status())

    def test_config_flag(self) -> None:
        os.environ["WS_AGENT_PUEUE_CONFIG"] = "/x/pueue.yml"
        self.pueue_status({})
        jobs.pueue_status()
        self.assertEqual(self.pueue_calls()[-1][:3], ["-c", "/x/pueue.yml", "status"])

    def test_enqueue_argv(self) -> None:
        job = self.mkjob()
        tid = jobs.enqueue(job, resume=False)
        self.assertEqual(tid, 7)
        self.assertEqual(jobs.load(job.id).pueue_id, 7)
        call = self.pueue_calls()[-1]
        self.assertEqual(call[0], "add")
        self.assertIn("--print-task-id", call)
        self.assertEqual(call[call.index("--group") + 1], "agents")
        self.assertEqual(call[call.index("--label") + 1], f"ws-agent:{job.id}")
        self.assertEqual(call[call.index("--working-directory") + 1], str(jobs.job_dir(job.id)))
        cmd = call[call.index("--") + 1:]
        self.assertEqual(cmd[2:], ["agent", "_exec", job.id])
        self.assertTrue(cmd[1].endswith("ws.py"))
        jobs.enqueue(job, resume=True)
        self.assertEqual(self.pueue_calls()[-1][-1], "--resume")

    def test_enqueue_failure_raises(self) -> None:
        self.write(self.pq / "fail-add", "")
        with self.assertRaises(jobs.QueueError):
            jobs.enqueue(self.mkjob(), resume=False)

    def test_ensure_group(self) -> None:
        self.pueue_status({}, agents=False)
        jobs.ensure_group(1)
        self.assertEqual(self.pueue_calls()[-1], ["group", "add", "agents", "--parallel", "1"])
        self.pueue_status({}, parallel=2)
        jobs.ensure_group(1)
        self.assertEqual(self.pueue_calls()[-1], ["parallel", "1", "--group", "agents"])
        self.pueue_status({}, parallel=1)
        n = len(self.pueue_calls())
        jobs.ensure_group(1)
        self.assertEqual(len(self.pueue_calls()), n + 1)   # only the status read

    def test_kill_then_remove(self) -> None:
        job = self.mkjob(pueue_id=4)
        self.write(self.pq / "fail-kill", "")   # already finished: kill fails, remove still runs
        jobs.kill(job)
        self.assertEqual([c[0] for c in self.pueue_calls()[-2:]], ["kill", "remove"])
        self.assertEqual(self.pueue_calls()[-1][-1], "4")

    def test_pause_resume(self) -> None:
        jobs.pause()
        jobs.resume()
        self.assertEqual(self.pueue_calls()[-2:], [["pause", "--group", "agents"], ["start", "--group", "agents"]])

    def test_duplicate(self) -> None:
        tasks = {3: "Running"}
        a = self.mkjob(prompt_sha="X", pueue_id=3)
        self.assertEqual(jobs.duplicate("~/src/proj", "X", jobs.all_jobs(), tasks).id, a.id)  # type: ignore[union-attr]
        self.assertIsNone(jobs.duplicate("~/src/other", "X", jobs.all_jobs(), tasks))
        self.assertIsNone(jobs.duplicate("~/src/proj", "Y", jobs.all_jobs(), tasks))

    def test_duplicate_ignores_finished(self) -> None:
        closed = self.mkjob(prompt_sha="X", pueue_id=3, closed=True)
        failed = self.mkjob(prompt_sha="X", pueue_id=4)
        self.exit_json(failed, 1)
        self.assertIsNone(jobs.duplicate("~/src/proj", "X", jobs.all_jobs(), {3: "Running", 4: "Success"}))
        done = self.mkjob(prompt_sha="X", pueue_id=5)
        self.exit_json(done, 0)   # succeeded but not yet reviewed and closed: still a duplicate
        self.assertEqual(jobs.duplicate("~/src/proj", "X", jobs.all_jobs(), {5: "Success"}).id, done.id)  # type: ignore[union-attr]
        del closed

    def test_overlaps(self) -> None:
        active = self.mkjob(paths=["src/a.c"], pueue_id=3)
        self.mkjob(paths=["src/a.c"], pueue_id=4, cancelled=True)
        found = jobs.overlaps("~/src/proj", ["src/*.c"], jobs.all_jobs(), {3: "Running", 4: "Running"})
        self.assertEqual([j.id for j in found], [active.id])
        self.assertEqual(jobs.overlaps("~/src/other", ["src/*.c"], jobs.all_jobs(), {3: "Running"}), [])
        self.assertEqual(jobs.overlaps("~/src/proj", ["docs/x.md"], jobs.all_jobs(), {3: "Running"}), [])
        self.assertEqual(jobs.overlaps("~/src/proj", [], jobs.all_jobs(), {3: "Running"}), [])

    def test_load_prefix(self) -> None:
        a = self.mkjob(id="abc123")
        self.mkjob(id="abd456")
        self.assertEqual(jobs.load("abc").id, a.id)
        with self.assertRaises(KeyError):
            jobs.load("ab")
        with self.assertRaises(KeyError):
            jobs.load("zzz")

    def test_new_id_unique(self) -> None:
        ids = {jobs.new_id() for _ in range(50)}
        self.assertEqual(len(ids), 50)
        self.assertTrue(all(len(i) == 6 and int(i, 16) >= 0 for i in ids))

    def test_save_load_roundtrip(self) -> None:
        job = self.mkjob(base={"url": "file:///r/trunk", "rev": "4"}, paths=["a"], warnings=["w"], attempts=2)
        back = jobs.load(job.id)
        self.assertEqual(back, job)
        self.assertEqual([j.id for j in jobs.all_jobs()], [job.id])


@unittest.skipUnless(shutil.which("pueued") and shutil.which("pueue"), "pueue not installed")
class RealPueue(AgentScratch):
    """The adapter against a real pueued with its own config and socket (never the user's)."""

    def setUp(self) -> None:
        super().setUp()
        (self.bin / "pueue").unlink()   # the real client this time
        cfg = self.root / "pueue.yml"
        self.write(cfg, f"shared:\n  pueue_directory: {self.root / 'pd'}\n  runtime_directory: {self.root / 'pr'}\n"
                        f"  unix_socket_path: {self.root / 'p.sock'}\n")
        (self.root / "pr").mkdir()   # pueued creates its pueue_directory, not its runtime_directory
        os.environ["WS_AGENT_PUEUE_CONFIG"] = str(cfg)
        self.daemon = subprocess.Popen(["pueued", "-c", str(cfg)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            if (self.root / "p.sock").exists():
                break
            time.sleep(0.1)

    def tearDown(self) -> None:
        subprocess.run(["pueue", "-c", os.environ["WS_AGENT_PUEUE_CONFIG"], "shutdown"], capture_output=True)
        try:
            self.daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.daemon.kill()
        super().tearDown()

    def test_group_enqueue_status_kill(self) -> None:
        jobs.ensure_group(1)
        jobs.pause()   # nothing may actually run: the task stays queued
        job = jobs.Job(id=jobs.new_id(), title="t", repo="~/src/proj", vcs="git", base={"commit": "c"}, prompt_sha="s",
                       paths=[], created="2026-11-06T00:00:00+00:00", session_id="", timeout="2h")
        jobs.save(job)
        tid = jobs.enqueue(job, resume=False)
        q = jobs.pueue_status()
        assert q is not None
        self.assertEqual(q.tasks.get(tid), "Queued")
        self.assertEqual((q.group, q.parallel, q.queued), ("Paused", 1, 1))
        self.assertEqual(jobs.state(jobs.load(job.id), q.tasks), "queued")
        jobs.kill(jobs.load(job.id))
        q = jobs.pueue_status()
        assert q is not None
        self.assertNotIn(tid, q.tasks)


if __name__ == "__main__":
    unittest.main()
