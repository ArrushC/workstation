"""The inbox (wslib/agent_inbox): candidates a source found that wait for the person, and the
fixed admission rules (wslib/agent_admit) every candidate passes before triage or a job."""

from __future__ import annotations

import datetime as dt
import hashlib
import unittest

from agent_helpers import AgentScratch

from wslib import agent_admit, agent_inbox, core, jobs
from wslib import agent_registry as reg

SVN_BASE = {"url": "file:///r/trunk", "repos_root": "file:///r", "rev": "5"}


def cand(cid: str = "svn:u-1:5", **kw: object) -> agent_inbox.Candidate:
    fields: dict[str, object] = {"cid": cid, "source": "svn", "repo": "~/src/proj", "explicit": False, "author": "alice",
                                 "title": "r5 by alice: fix", "text": "fix the parser", "base": dict(SVN_BASE),
                                 "prompt": "Review r5."}
    fields.update(kw)
    return agent_inbox.Candidate(**fields)  # type: ignore[arg-type]


class InboxScratch(AgentScratch):
    def job(self, origin: str, created: str | None = None) -> jobs.Job:
        j = jobs.Job(id=jobs.new_id(), title="t", repo="~/src/proj", vcs="svn", base=dict(SVN_BASE), prompt_sha="x",
                     paths=[], created=created or core.now_iso(), session_id="", timeout="2h", origin=origin)
        jobs.save(j)
        return j


class Inbox(InboxScratch):
    def test_add_is_idempotent_per_cid(self) -> None:
        first = agent_inbox.add(cand(), {"decision": "ask", "reason": "unsure"})
        self.assertEqual(first.id, hashlib.sha256(b"svn:u-1:5").hexdigest()[:10])
        self.assertEqual((first.cid, first.status, first.job), ("svn:u-1:5", "open", ""))
        again = agent_inbox.add(cand(title="changed"), None)
        self.assertEqual(again.id, first.id)
        self.assertEqual(again.candidate["title"], "r5 by alice: fix")
        self.assertEqual(again.decision, {"decision": "ask", "reason": "unsure"})
        self.assertEqual(len(agent_inbox.items(all_=True)), 1)
        d = core.state_dir() / "agent-inbox"
        self.assertEqual(d.stat().st_mode & 0o777, 0o700)   # log messages and comments stay private
        self.assertEqual((d / f"{first.id}.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(agent_inbox.get(first.id).as_candidate(), cand())

    def test_items_filter_and_status(self) -> None:
        a = agent_inbox.add(cand("svn:u-1:5"), None)
        b = agent_inbox.add(cand("gh:o/r:c9", source="github", repo="~/src/other"), None)
        agent_inbox.resolve(b, "dismissed")
        self.assertEqual([i.id for i in agent_inbox.items()], [a.id])
        self.assertEqual({i.id for i in agent_inbox.items(all_=True)}, {a.id, b.id})
        self.assertEqual([i.id for i in agent_inbox.items("~/src/other", all_=True)], [b.id])
        self.assertEqual(agent_inbox.items("~/src/other"), [])
        agent_inbox.resolve(a, "accepted", "abc123")
        got = agent_inbox.get(a.id[:4])
        self.assertEqual((got.status, got.job), ("accepted", "abc123"))
        self.assertEqual(agent_inbox.get("svn:u-1:5").id, a.id)   # the cid works too
        for bad in ("zzzz", ""):
            with self.assertRaises(KeyError):
                agent_inbox.get(bad)
        with self.assertRaises(ValueError):
            agent_inbox.resolve(a, "maybe")
        self.write(core.state_dir() / "agent-inbox" / "0000000000.json", "{not json")
        self.assertEqual({i.id for i in agent_inbox.items(all_=True)}, {a.id, b.id})   # a damaged file is skipped

    def test_seen_by_inbox_or_job_origin(self) -> None:
        self.assertFalse(agent_inbox.seen("svn:u-1:5"))
        agent_inbox.add(cand(), None)
        self.assertTrue(agent_inbox.seen("svn:u-1:5"))
        self.assertFalse(agent_inbox.seen("svn:u-1:6"))
        self.job(origin="svn:u-1:6")
        self.assertTrue(agent_inbox.seen("svn:u-1:6"))


class Admit(InboxScratch):
    def test_admit_rules(self) -> None:
        entry = reg.Repo(path=self.home / "src" / "proj", vcs="svn")
        c = cand()
        self.assertIsNone(agent_admit.admit(c, entry, "observe", ()))   # svn: no authors means anyone
        self.assertIn("no longer allowed", agent_admit.admit(c, None, "observe", ()) or "")
        self.assertIn("off", agent_admit.admit(c, entry, "off", ()) or "")
        self.assertIn("alice", agent_admit.admit(c, entry, "act", ("bob",)) or "")
        self.assertIsNone(agent_admit.admit(c, entry, "act", ("bob", "alice")))
        g = cand("gh:o/r:c9", source="github", author="Alice", explicit=True)
        self.assertIn("login", agent_admit.admit(g, entry, "observe", ()) or "")   # github needs logins
        self.assertIsNone(agent_admit.admit(g, entry, "observe", ("alice",)))   # logins ignore case
        agent_inbox.add(c, None)
        self.assertIn("seen", agent_admit.admit(c, entry, "observe", ()) or "")

        now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        yesterday = (now - dt.timedelta(days=1)).isoformat()
        for i in range(10):
            self.job(origin=f"svn:u-1:{100 + i}", created=yesterday)
        self.assertEqual(agent_admit.daily_count("svn:u-1"), 0)
        self.assertIsNone(agent_admit.admit(cand("svn:u-1:200"), entry, "observe", ()))
        for i in range(10):
            self.job(origin=f"svn:u-1:{300 + i}", created=now.isoformat())
        self.job(origin="svn:u-10:1")   # another repository whose uuid starts the same way
        self.assertEqual(agent_admit.daily_count("svn:u-1"), 10)
        self.assertIn("daily cap", agent_admit.admit(cand("svn:u-1:201"), entry, "observe", ()) or "")
        self.assertIsNone(agent_admit.admit(cand("svn:u-2:201"), entry, "observe", ()))   # another source


if __name__ == "__main__":
    unittest.main()
