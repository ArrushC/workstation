"""wslib.agent_registry: the per-host list of repositories queued agent jobs may work in."""

from __future__ import annotations

import os
import tomllib
import unittest
from pathlib import Path

from helpers import Scratch

from wslib import agent_registry as reg


class Registry(Scratch):
    def setUp(self) -> None:
        super().setUp()
        os.environ.pop("CLAUDECODE", None)
        self.wc = self.home / "src" / "foo"
        self.wc.mkdir(parents=True)

    def test_allow_roundtrip(self) -> None:
        r = reg.allow(self.wc, "svn", ["make *"])
        self.assertEqual(r.vcs, "svn")
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual(found.commands, ("make *",))
        self.assertEqual(found.path, self.wc)
        self.assertTrue(found.allowed_at)
        repos, parallel = reg.load()
        self.assertEqual(list(repos), ["~/src/foo"])
        self.assertEqual(parallel, 2)   # the default: two jobs at a time, one per engine
        data = tomllib.loads(reg.registry_path().read_text(encoding="utf-8"))
        self.assertEqual(data["repo"]["~/src/foo"]["vcs"], "svn")

    def test_find_unknown(self) -> None:
        self.assertIsNone(reg.find(self.wc))

    def test_keeps_queue_table(self) -> None:
        self.write(reg.registry_path(), "[queue]\nparallel = 2\n")
        reg.allow(self.wc, "git", [])
        self.assertEqual(reg.load()[1], 2)

    def test_reallow_replaces_commands(self) -> None:
        reg.allow(self.wc, "svn", ["make *"])
        reg.allow(self.wc, "svn", ["ctest *"])
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual(found.commands, ("ctest *",))
        self.assertEqual(len(reg.load()[0]), 1)

    def test_disallow(self) -> None:
        reg.allow(self.wc, "svn", [])
        self.assertTrue(reg.disallow(self.wc))
        self.assertIsNone(reg.find(self.wc))
        self.assertFalse(reg.disallow(self.wc))

    def test_refused_inside_claude(self) -> None:
        reg.allow(self.wc, "svn", [])
        before = reg.registry_path().read_bytes()
        os.environ["CLAUDECODE"] = "1"
        other = self.home / "src" / "bar"
        other.mkdir()
        with self.assertRaises(reg.Refused):
            reg.allow(other, "git", [])
        with self.assertRaises(reg.Refused):
            reg.disallow(self.wc)
        self.assertEqual(reg.registry_path().read_bytes(), before)

    def test_quotes_survive(self) -> None:
        reg.allow(self.wc, "svn", ['make "a b"', "back\\slash"])
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual(found.commands, ('make "a b"', "back\\slash"))

    def test_outside_home_keeps_absolute_key(self) -> None:
        d = self.root / "outside"
        d.mkdir()
        reg.allow(d, "git", [])
        self.assertIn(str(d), reg.load()[0])
        self.assertIsNotNone(reg.find(d))

    def test_bad_parallel_falls_back(self) -> None:
        self.write(reg.registry_path(), "[queue]\nparallel = 0\n")
        self.assertEqual(reg.load()[1], 2)

    # --- v2: engines, checks, review, settings tables ------------------------------------

    def test_v2_fields_round_trip(self) -> None:
        reg.allow(self.wc, "svn", ["make *"], engines=("claude", "codex"), checks=("make test",), fix_rounds=0,
                  review="codex", network=True)
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual(found.engines, ("claude", "codex"))
        self.assertEqual(found.checks, ("make test",))
        self.assertEqual(found.fix_rounds, 0)
        self.assertEqual(found.review, "codex")
        self.assertIs(found.network, True)
        self.assertEqual(found.commands, ("make *",))

    def test_defaults(self) -> None:
        self.write(reg.registry_path(), '[repo."~/src/foo"]\nvcs = "svn"\ncommands = []\nallowed_at = "x"\n')
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual(found.engines, ("claude",))
        self.assertEqual(found.checks, ())
        self.assertEqual(found.fix_rounds, 1)
        self.assertEqual(found.review, "")
        self.assertIs(found.network, False)
        self.assertEqual(reg.settings().parallel, 2)
        self.assertEqual(reg.settings().engine("claude"), reg.EngineSettings(parallel=1, model=""))

    def test_settings_tables(self) -> None:
        self.write(reg.registry_path(), '[queue]\nparallel = 3\n\n[engines.codex]\nparallel = 1\nmodel = "o4"\n\n'
                                        '[sandbox]\nhide = ["/data/svn"]\n\n[notify]\ndesktop = false\n')
        st = reg.settings()
        self.assertEqual(st.parallel, 3)
        self.assertEqual(st.engine("codex"), reg.EngineSettings(parallel=1, model="o4"))
        self.assertEqual(st.engine("claude"), reg.EngineSettings())
        self.assertEqual(st.hide, (Path("/data/svn"),))
        self.assertIs(st.desktop, False)

    def test_unknown_tables_and_keys_survive_a_write(self) -> None:
        self.write(reg.registry_path(), '[future]\nx = 1\n\n[repo."~/src/foo"]\nvcs = "svn"\ncommands = []\n'
                                        'allowed_at = "x"\n\n[repo."~/src/foo".later]\nwhat = ["kept"]\n\n'
                                        '[repo."~/src/foo".watch]\nurls = ["^/trunk"]\nmode = "observe"\nnewer = 1\n')
        before = tomllib.loads(reg.registry_path().read_text(encoding="utf-8"))
        other = self.home / "src" / "bar"
        other.mkdir()
        reg.allow(other, "svn", [])
        after = tomllib.loads(reg.registry_path().read_text(encoding="utf-8"))
        self.assertEqual(after["future"], before["future"])
        self.assertEqual(after["repo"]["~/src/foo"]["later"], before["repo"]["~/src/foo"]["later"])
        watch = after["repo"]["~/src/foo"]["watch"]
        self.assertEqual((watch["urls"], watch["mode"], watch["newer"]), (["^/trunk"], "observe", 1))
        self.assertIn("~/src/bar", after["repo"])

    def test_unparseable_file_is_never_overwritten(self) -> None:
        self.write(reg.registry_path(), "[[bad\n")
        before = reg.registry_path().read_bytes()
        with self.assertRaises(reg.Unreadable):
            reg.allow(self.wc, "svn", [])
        with self.assertRaises(reg.Unreadable):
            reg.disallow(self.wc)
        self.assertEqual(reg.registry_path().read_bytes(), before)
        self.assertEqual(reg.load()[0], {})   # readers carry on with nothing allowed

    def test_non_bmp_and_unicode_keys_survive(self) -> None:
        d = self.home / "src" / "café"
        d.mkdir()
        reg.allow(d, "svn", ["echo 🚀 done"])
        reg.allow(self.wc, "svn", [])   # a second write re-reads and re-emits the first
        found = reg.find(d)
        assert found is not None
        self.assertEqual(found.commands, ("echo 🚀 done",))

    # --- sources (phase 2b) -----------------------------------------------------------------

    def test_watch_round_trip(self) -> None:
        reg.allow(self.wc, "svn", [])
        w = reg.Watch(urls=("^/trunk",), mode="act", authors=("bob",), rules=("Review src/net",), interval="10m")
        reg.set_watch(self.wc, w)
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual(found.watch, w)
        self.assertIsNone(found.github)
        data = tomllib.loads(reg.registry_path().read_text(encoding="utf-8"))
        self.assertEqual(data["repo"]["~/src/foo"]["watch"]["urls"], ["^/trunk"])
        reg.set_watch(self.wc, None)
        found = reg.find(self.wc)
        assert found is not None
        self.assertIsNone(found.watch)
        self.assertNotIn("watch", tomllib.loads(reg.registry_path().read_text(encoding="utf-8"))["repo"]["~/src/foo"])

    def test_github_round_trip(self) -> None:
        reg.allow(self.wc, "git", [])
        src = reg.GitHubSource(slug="ArrushC/proj", mode="observe", logins=("ArrushC",))
        reg.set_github(self.wc, src)
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual(found.github, src)
        reg.set_github(self.wc, None)
        found = reg.find(self.wc)
        assert found is not None
        self.assertIsNone(found.github)

    def test_allow_keeps_sources(self) -> None:
        reg.allow(self.wc, "svn", [])
        w = reg.Watch(urls=("^/trunk",))
        reg.set_watch(self.wc, w)
        reg.allow(self.wc, "svn", ["make *"])   # allow again with new rules
        found = reg.find(self.wc)
        assert found is not None
        self.assertEqual((found.watch, found.commands), (w, ("make *",)))

    def test_source_validation(self) -> None:
        reg.allow(self.wc, "svn", [])
        for bad in (reg.Watch(urls=("^/trunk",), mode="loud"), reg.Watch(urls=()),
                    reg.Watch(urls=("^/trunk",), interval="soon")):
            with self.assertRaises(ValueError, msg=bad):
                reg.set_watch(self.wc, bad)
        with self.assertRaises(ValueError):          # github on an svn repository
            reg.set_github(self.wc, reg.GitHubSource(slug="o/r", logins=("me",)))
        other = self.home / "src" / "g"
        other.mkdir()
        reg.allow(other, "git", [])
        with self.assertRaises(ValueError):          # a watch on a git repository
            reg.set_watch(other, reg.Watch(urls=("^/trunk",)))
        with self.assertRaises(ValueError):          # no github remote
            reg.set_github(other, reg.GitHubSource(slug="", logins=("me",)))
        with self.assertRaises(ValueError):          # nobody may trigger it
            reg.set_github(other, reg.GitHubSource(slug="o/r", logins=()))
        with self.assertRaises(KeyError):            # not allowed at all
            reg.set_watch(self.home / "src" / "nope", reg.Watch(urls=("^/trunk",)))

    def test_source_changes_refused_in_claude(self) -> None:
        reg.allow(self.wc, "svn", [])
        before = reg.registry_path().read_bytes()
        os.environ["CLAUDECODE"] = "1"
        with self.assertRaises(reg.Refused):
            reg.set_watch(self.wc, reg.Watch(urls=("^/trunk",)))
        with self.assertRaises(reg.Refused):
            reg.set_github(self.wc, None)
        self.assertEqual(reg.registry_path().read_bytes(), before)

    def test_review_must_be_an_allowed_engine(self) -> None:
        with self.assertRaises(ValueError):
            reg.allow(self.wc, "svn", [], engines=("claude",), review="codex")

    def test_unknown_engine_refused(self) -> None:
        with self.assertRaises(ValueError):
            reg.allow(self.wc, "svn", [], engines=("gpt-9",))
        with self.assertRaises(ValueError):
            reg.allow(self.wc, "svn", [], engines=())


if __name__ == "__main__":
    unittest.main()
