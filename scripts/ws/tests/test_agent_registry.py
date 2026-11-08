"""wslib.agent_registry: the per-host list of repositories queued agent jobs may work in."""

from __future__ import annotations

import os
import tomllib
import unittest

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
        self.assertEqual(parallel, 1)
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
        self.assertEqual(reg.load()[1], 1)


if __name__ == "__main__":
    unittest.main()
