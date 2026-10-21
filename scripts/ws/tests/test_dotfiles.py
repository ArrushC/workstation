"""Reconcile: change classification, directory entries, templates, deletions, merges, backups
and the bootstrap hooks, on fixtures in a scratch home (mise stubbed; test_mise.py runs the
real one)."""

from __future__ import annotations

import io
import os
import random
import stat
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from helpers import Scratch

from wslib import baseline, diffs, dotfiles, reconcile
from wslib.dotfiles import BOTH, DELETED, LOCAL, MISSING, NOBASE, REMOVED, REPO, SYNC, UNKNOWN


# Content lines that look like a diff's own once tagged: "-- x" removed is "--- x".
TRICKY = ["-- x\n", "++ y\n", "--- z\n", "+++ w\n", "@@ -1 +1 @@\n", "dotfile differs: q\n", "\n", " \n"]


class Diffs(unittest.TestCase):
    def test_apply_unified_round_trips(self) -> None:
        rnd = random.Random(7)
        for _ in range(400):
            old = [rnd.choice([f"line {rnd.randint(0, 9)}\n"] * 3 + TRICKY) for _ in range(rnd.randint(0, 12))]
            new = list(old)
            for _ in range(rnd.randint(1, 4)):
                op = rnd.choice("aid")
                pos = rnd.randint(0, len(new))
                if op == "a" or not new:
                    new.insert(pos, rnd.choice([f"added {rnd.randint(0, 99)}\n", *TRICKY]))
                elif op == "d":
                    del new[min(pos, len(new) - 1)]
                else:
                    new[min(pos, len(new) - 1)] = rnd.choice(["changed\n", *TRICKY])
            a, b = "".join(old).encode(), "".join(new).encode()
            if rnd.random() < 0.3 and b:
                b = b.rstrip(b"\n")
            if rnd.random() < 0.3 and a:
                a = a.rstrip(b"\n")
            patch = diffs.unified(a, b, "current", "desired")
            if a == b:
                continue
            self.assertEqual(diffs.apply_unified(a, patch), b, patch)

    def test_mise_style_missing_file_and_mismatch(self) -> None:
        patch = "dotfile differs: ~/x\n  current: ~/x missing\n--- ~/x (current)\n+++ src (desired)\n@@ -0,0 +1,2 @@\n+a\n+b\n"
        self.assertEqual(diffs.apply_unified(b"", patch), b"a\nb\n")
        bad = "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-not this\n+x\n"
        self.assertIsNone(diffs.apply_unified(b"something else\n", bad))
        self.assertIsNone(diffs.apply_unified(b"x\n", "no hunks here"))

    def test_header_like_content(self) -> None:
        # mise's own output for a template changed from "-- old" to "-- new": the removal
        # reads "--- old", which once ended the hunk and left the old line in the render.
        patch = ("dotfile differs: ~/.conf\n  content differs: src -> ~/.conf\n--- ~/.conf (current)\n"
                 "+++ src (desired)\n@@ -1,3 +1,3 @@\n a\n--- old\n+-- new\n b\n")
        self.assertEqual(diffs.apply_unified(b"a\n-- old\nb\n", patch), b"a\n-- new\nb\n")
        for a, b in ((b"a\n", b"a\n++ added\n+++ more\n"),
                     (b"--- x\n+++ y\n@@ -1 +1 @@\ndotfile differs: z\n", b"kept\n"),
                     (b"x\n", b"--- x\n+++ y\n@@ -1 +1 @@\ndotfile differs: z\n")):
            patch = diffs.unified(a, b, "current", "desired")
            self.assertEqual(diffs.apply_unified(a, patch), b, patch)

    def test_incomplete_patches_are_refused(self) -> None:
        a, b = b"a\n-- old\nb\nc\n", b"a\n-- new\nb\nc\n"
        patch = diffs.unified(a, b, "current", "desired")
        whole = patch.splitlines(keepends=True)
        for cut in range(len(whole) - 1, 2, -1):  # every truncation inside the hunk
            self.assertIsNone(diffs.apply_unified(a, "".join(whole[:cut])), whole[:cut])
        self.assertIsNone(diffs.apply_unified(a, patch.replace("@@ -1,4 +1,4 @@", "@@ -1,5 +1,5 @@")))
        self.assertIsNone(diffs.apply_unified(a, patch.replace("@@ -1,4 +1,4 @@", "@@ -1,4 +2,4 @@")))
        self.assertIsNone(diffs.apply_unified(a, patch.replace(" b\n", "junk\n")))

    def test_crlf_lines_survive(self) -> None:
        a, b = b"one\r\ntwo\r\n", b"one\r\n2\r\n"
        self.assertEqual(diffs.apply_unified(a, diffs.unified(a, b, "a", "b")), b)

    def test_merge3(self) -> None:
        base = b"a\nb\nc\nd\ne\n"
        live = b"a\nB\nc\nd\ne\n"
        repo = b"a\nb\nc\nd\nE\n"
        merged, conflicts = diffs.merge3(live, base, repo, ("live", "base", "repo"))  # type: ignore[misc]
        self.assertEqual((merged, conflicts), (b"a\nB\nc\nd\nE\n", 0))
        merged, conflicts = diffs.merge3(b"a\nX\nc\nd\ne\n", base, b"a\nY\nc\nd\ne\n", ("live", "base", "repo"))  # type: ignore[misc]
        self.assertGreater(conflicts, 0)
        self.assertTrue(diffs.has_conflict_markers(merged))


class Model(Scratch):
    def load(self, status: dict[str, object]) -> dotfiles.Model:
        return dotfiles.load(baseline.Store(), status_doc=status)

    def item(self, status: dict[str, object], key: str) -> dotfiles.Item:
        found = [i for i in self.load(status).items if i.key == key]
        self.assertEqual(len(found), 1, f"{key} in {[i.key for i in self.load(status).items]}")
        return found[0]

    def record_all(self, status: dict[str, object]) -> None:
        store = baseline.Store()
        dotfiles.record_agreed(dotfiles.load(store, status_doc=status), store, "test")

    # --- a file entry --------------------------------------------------------------

    def test_file_entry_classes(self) -> None:
        st = self.entries({"target": "~/.rc file", "source": "dotfiles/rc file"})
        src, live = self.repo / "dotfiles/rc file", self.home / ".rc file"
        self.write(src, "one\n")
        self.assertEqual(self.item(st, ".rc file").cls, MISSING)
        self.write(live, "one\nlocal\n")
        it = self.item(st, ".rc file")
        self.assertEqual(it.cls, NOBASE)  # no baseline: never guess the side
        self.assertIn("no baseline", it.why)
        self.write(live, "one\n")
        self.record_all(st)  # in sync: baselined
        self.assertEqual(self.item(st, ".rc file").cls, SYNC)
        self.write(live, "one\nlocal\n")
        self.assertEqual(self.item(st, ".rc file").cls, LOCAL)
        self.write(live, "one\n")
        self.write(src, "one\nrepo\n")
        self.assertEqual(self.item(st, ".rc file").cls, REPO)
        self.write(live, "one\nlocal\n")
        self.assertEqual(self.item(st, ".rc file").cls, BOTH)
        live.unlink()
        it = self.item(st, ".rc file")
        self.assertEqual(it.cls, BOTH)
        self.assertIn("deleted here", it.why)
        self.write(src, "one\n")
        self.assertEqual(self.item(st, ".rc file").cls, DELETED)

    # --- a directory entry -----------------------------------------------------------

    def dir_status(self) -> dict[str, object]:
        d = self.repo / "dotfiles/conf"
        self.write(d / "a.toml", "a\n")
        self.write(d / "sub dir/b file.kdl", "b\n")
        self.write(d / ".vendor", "provenance\n")
        self.write(d / "nested/inner.txt", "owned by the nested entry\n")
        return self.entries({"target": "~/.config/app", "source": "dotfiles/conf", "exclude": [".vendor", ".gitkeep", "nested"]})

    def test_directory_entry_is_per_file(self) -> None:
        st = self.dir_status()
        app = self.home / ".config/app"
        self.write(app / "a.toml", "a\n")
        self.write(app / "sub dir/b file.kdl", "b\n")
        self.write(app / "unmanaged.txt", "mine\n")       # never deployed: not ours
        self.write(app / "nested/inner.txt", "edited\n")  # excluded: another entry's
        keys = sorted(i.key for i in self.load(st).items)
        self.assertEqual(keys, [".config/app/a.toml", ".config/app/sub dir/b file.kdl"])
        self.record_all(st)
        self.write(app / "sub dir/b file.kdl", "b edited\n")
        it = self.item(st, ".config/app/sub dir/b file.kdl")
        self.assertEqual(it.cls, LOCAL)
        self.assertTrue(it.in_dir)
        p = reconcile.plan(it, "record")
        self.assertEqual([w.path for w in p.writes], [self.repo / "dotfiles/conf/sub dir/b file.kdl"])
        self.assertTrue(reconcile.execute(p, baseline.Store(), quiet=True))
        self.assertEqual((self.repo / "dotfiles/conf/sub dir/b file.kdl").read_text(), "b edited\n")
        # The rest of the source directory is untouched, and nothing unmanaged came in.
        self.assertFalse((self.repo / "dotfiles/conf/unmanaged.txt").exists())
        self.assertEqual((self.repo / "dotfiles/conf/.vendor").read_text(), "provenance\n")
        self.assertEqual((self.repo / "dotfiles/conf/nested/inner.txt").read_text(), "owned by the nested entry\n")
        self.assertEqual(self.item(st, ".config/app/sub dir/b file.kdl").cls, SYNC)

    def test_apply_one_file_in_a_directory(self) -> None:
        st = self.dir_status()
        app = self.home / ".config/app"
        self.write(app / "a.toml", "a\n")
        self.write(app / "sub dir/b file.kdl", "b\n")
        self.record_all(st)
        self.write(app / "a.toml", "a local\n")
        self.write(self.repo / "dotfiles/conf/sub dir/b file.kdl", "b repo\n")
        it = self.item(st, ".config/app/sub dir/b file.kdl")
        self.assertEqual(it.cls, REPO)
        self.assertEqual(reconcile.actions_for(it)[0][0], "apply")
        p = reconcile.plan(it, "apply")
        self.assertEqual(p.mise_apply, "")  # never the whole directory
        self.assertTrue(reconcile.execute(p, baseline.Store(), quiet=True))
        self.assertEqual((app / "sub dir/b file.kdl").read_text(), "b repo\n")
        self.assertEqual((app / "a.toml").read_text(), "a local\n")  # the sibling's edit survives
        sets = baseline.backup_sets()
        self.assertEqual(len(sets), 1)
        (orig, dest, why, _), = sets[0][1]
        self.assertEqual(why, "")  # reconcile's own backup: the user chose to overwrite
        self.assertEqual(orig, str(app / "sub dir/b file.kdl"))
        self.assertEqual(open(dest).read(), "b\n")

    def test_removed_from_repo_and_deleted_locally(self) -> None:
        st = self.dir_status()
        app = self.home / ".config/app"
        self.write(app / "a.toml", "a\n")
        self.write(app / "sub dir/b file.kdl", "b\n")
        self.record_all(st)
        (self.repo / "dotfiles/conf/a.toml").unlink()
        it = self.item(st, ".config/app/a.toml")
        self.assertEqual(it.cls, REMOVED)
        p = reconcile.plan(it, "apply")
        self.assertEqual([(w.path, w.data) for w in p.writes], [(app / "a.toml", None)])
        reconcile.execute(p, baseline.Store(), quiet=True)
        self.assertFalse((app / "a.toml").exists())
        self.assertEqual(len(baseline.backup_sets()[0][1]), 1)  # the deleted copy is kept
        self.assertNotIn(".config/app/a.toml", [i.key for i in self.load(st).items])  # forgotten
        (app / "sub dir/b file.kdl").unlink()
        it = self.item(st, ".config/app/sub dir/b file.kdl")
        self.assertEqual(it.cls, DELETED)
        self.assertEqual([a for a, _ in reconcile.actions_for(it)], ["apply", "record", "skip"])
        p = reconcile.plan(it, "record")
        reconcile.execute(p, baseline.Store(), quiet=True)
        self.assertFalse((self.repo / "dotfiles/conf/sub dir/b file.kdl").exists())

    def test_merge_both_sides(self) -> None:
        st = self.entries({"target": "~/.gitconfig", "source": "dotfiles/gitconfig"})
        src, live = self.repo / "dotfiles/gitconfig", self.home / ".gitconfig"
        body = "".join(f"line {n}\n" for n in range(10))
        self.write(src, body)
        self.write(live, body)
        self.record_all(st)
        self.write(live, body.replace("line 1\n", "line 1 local\n"))
        self.write(src, body.replace("line 8\n", "line 8 repo\n"))
        it = self.item(st, ".gitconfig")
        self.assertEqual(it.cls, BOTH)
        self.assertEqual(reconcile.actions_for(it)[0][0], "merge")
        p = reconcile.plan(it, "merge")
        self.assertTrue(p.ok)
        self.assertEqual(p.warnings, [])
        self.assertTrue(reconcile.execute(p, baseline.Store(), quiet=True))
        want = body.replace("line 1\n", "line 1 local\n").replace("line 8\n", "line 8 repo\n")
        self.assertEqual((live.read_text(), src.read_text()), (want, want))
        self.assertEqual(self.item(st, ".gitconfig").cls, SYNC)

    def test_merge_conflict_never_writes_markers_unattended(self) -> None:
        st = self.entries({"target": "~/.gitconfig", "source": "dotfiles/gitconfig"})
        src, live = self.repo / "dotfiles/gitconfig", self.home / ".gitconfig"
        self.write(src, "a\nb\nc\n")
        self.write(live, "a\nb\nc\n")
        self.record_all(st)
        self.write(live, "a\nLIVE\nc\n")
        self.write(src, "a\nREPO\nc\n")
        p = reconcile.plan(self.item(st, ".gitconfig"), "merge")
        self.assertTrue(any("conflict" in w for w in p.warnings))
        # The command line refuses to resolve conflicts without a terminal.
        import argparse

        args = argparse.Namespace(list=False, json=False, record=None, apply=None, merge=[str(live)],
                                  yes=True, backups=False)
        self.fake_mise(st)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(reconcile.main(args), 1)
        self.assertEqual(live.read_text(), "a\nLIVE\nc\n")
        self.assertEqual(src.read_text(), "a\nREPO\nc\n")

    # --- templates ---------------------------------------------------------------------

    def template_status(self, state: str = "differs") -> dict[str, object]:
        self.write(self.repo / "dotfiles/zshrc.tera", "# {{ vars.name }}\nalias a=b\n")
        return self.entries({"target": "~/.zshrc", "source": "dotfiles/zshrc.tera", "mode": "template", "state": state})

    def test_template_rendered_from_mises_diff(self) -> None:
        st = self.template_status()
        live = self.write(self.home / ".zshrc", "# me\nalias a=b\nalias local=1\n")
        diff = ("dotfile differs: ~/.zshrc\n  content differs: src -> ~/.zshrc\n--- ~/.zshrc (current)\n"
                "+++ src (desired)\n@@ -1,3 +1,2 @@\n # me\n alias a=b\n-alias local=1\n")
        self.fake_mise(st, diff)
        it = self.item(st, ".zshrc")
        self.assertEqual(it.intended, b"# me\nalias a=b\n")
        self.assertEqual(it.cls, NOBASE)
        # A rendered file never goes over its template.
        p = reconcile.plan(it, "record")
        self.assertFalse(p.ok)
        self.assertIn("never copied over its template", " ".join(p.summary))
        self.assertNotIn("record", [a for a, _ in reconcile.actions_for(it)])
        self.assertEqual(reconcile.actions_for(it)[0][0], "edit")
        p = reconcile.plan(it, "apply")
        self.assertEqual(p.mise_apply, "~/.zshrc")  # mise renders it, not ws
        self.assertEqual(live.read_text(), "# me\nalias a=b\nalias local=1\n")
        self.assertEqual((self.repo / "dotfiles/zshrc.tera").read_text(), "# {{ vars.name }}\nalias a=b\n")

    def test_template_merge_keeps_the_template(self) -> None:
        st = self.template_status()
        store = baseline.Store()
        store.record(".zshrc", b"# me\nalias a=b\nx\ny\nz\n", "~/.zshrc", "test")
        store.save()
        self.write(self.home / ".zshrc", "# me\nalias a=b\nx\ny\nz\nlocal\n")
        diff = ("--- ~/.zshrc (current)\n+++ src (desired)\n@@ -1,6 +1,5 @@\n # me\n-alias a=b\n+alias a=c\n x\n y\n z\n-local\n")
        self.fake_mise(st, diff)
        it = self.item(st, ".zshrc")
        self.assertEqual(it.cls, BOTH)
        p = reconcile.plan(it, "merge")
        self.assertEqual([w.side for w in p.writes], ["live"])
        reconcile.execute(p, baseline.Store(), quiet=True)
        self.assertEqual((self.home / ".zshrc").read_text(), "# me\nalias a=c\nx\ny\nz\nlocal\n")
        self.assertEqual((self.repo / "dotfiles/zshrc.tera").read_text(), "# {{ vars.name }}\nalias a=b\n")
        self.assertEqual(baseline.Store().content(".zshrc"), b"# me\nalias a=c\nx\ny\nz\n")

    def test_unrenderable_template_is_said_not_guessed(self) -> None:
        st = self.template_status()
        self.write(self.home / ".zshrc", "something\n")
        self.fake_mise(st, "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-not what is live\n+x\n")
        it = self.item(st, ".zshrc")
        self.assertEqual(it.cls, UNKNOWN)

    # --- the hooks ---------------------------------------------------------------------

    def test_snapshot_backs_up_only_what_an_apply_would_lose(self) -> None:
        st = self.dir_status()
        app = self.home / ".config/app"
        self.write(app / "a.toml", "a\n")
        self.write(app / "sub dir/b file.kdl", "b\n")
        self.record_all(st)
        self.write(app / "a.toml", "a local\n")                                # a local edit
        self.write(self.repo / "dotfiles/conf/sub dir/b file.kdl", "b repo\n")  # repo only
        store = baseline.Store()
        b = dotfiles.snapshot(dotfiles.load(store, render_templates=False, status_doc=st), store)
        self.assertEqual([p for p, _ in b.saved], [app / "a.toml"])
        self.assertEqual(b.counts(), {baseline.LOCAL_EDIT: 1})

    def test_snapshot_without_a_baseline_says_so_once(self) -> None:
        # The first apply on a host has no baseline: a file that differs is backed up, but it may
        # just be the previous deploy, so it is never reported as a local edit.
        st = self.entries({"target": "~/.rc", "source": "dotfiles/rc"})
        self.write(self.repo / "dotfiles/rc", "new\n")
        self.write(self.home / ".rc", "previous deploy\n")
        store = baseline.Store()
        b = dotfiles.snapshot(dotfiles.load(store, render_templates=False, status_doc=st), store)
        self.assertEqual(b.counts(), {baseline.NO_BASELINE: 1})
        note = reconcile._recent_snapshot_note()
        self.assertIn("1 file(s) that differed from the repo with no baseline", note)
        self.assertNotIn("local edit", note)
        self.assertEqual(reconcile._recent_snapshot_note(), "")  # said once
        self.assertEqual([e[2] for e in baseline.backup_sets()[0][1]], [baseline.NO_BASELINE])

    def test_record_hook_skips_unrendered_templates_and_forgets_dropped_entries(self) -> None:
        st = self.template_status("differs")
        self.write(self.home / ".zshrc", "x\n")
        store = baseline.Store()
        store.record(".gone", b"old", "~/.gone", "test")
        store.save()
        self.fake_mise(st, "")
        model = dotfiles.load(store, render_templates=False, status_doc=st)
        dotfiles.record_agreed(model, store, "apply")
        store = baseline.Store()
        self.assertIsNone(store.get(".zshrc"))
        self.assertIsNone(store.get(".gone"))
        st = self.template_status("applied")
        dotfiles.record_agreed(dotfiles.load(store, render_templates=False, status_doc=st), store, "apply")
        self.assertEqual(baseline.Store().content(".zshrc"), b"x\n")

    def test_store_for_another_home_is_read_only(self) -> None:
        store = baseline.Store()
        store.record("a", b"1", "~/a", "t")
        store.save()
        os.environ["HOME"] = str(self.root / "other")
        other = baseline.Store()
        self.assertTrue(other.foreign)
        self.assertFalse(other.record("a", b"2", "~/a", "t"))
        os.environ["HOME"] = str(self.home)
        self.assertEqual(baseline.Store().content("a"), b"1")

    def readable(self, root: Path) -> dict[str, str]:
        """Everything under root that anyone but its owner could open, with its mode."""
        return {p.relative_to(root).as_posix(): f"{stat.S_IMODE(p.stat().st_mode):04o}"
                for p in (root, *root.rglob("*")) if p.stat().st_mode & 0o077}

    @unittest.skipIf(os.name == "nt", "POSIX permissions")
    def test_store_and_backups_are_private(self) -> None:
        # Blobs and backups copy files such as ~/.ssh/config: whatever the umask, nothing in
        # the store is readable by others, and a restore puts the original's mode back.
        self.addCleanup(os.umask, os.umask(0o022))
        secret = self.write(self.home / ".ssh/config", "Host x\n", 0o600)
        tool = self.write(self.home / ".local/bin/tool", "#!/bin/sh\n", 0o755)
        store = baseline.Store()
        store.record(".ssh/config", secret.read_bytes(), "~/.ssh/config", "test")
        store.save()
        backup = baseline.Backup("test", store.root)
        backup.save(secret)
        backup.save(tool)
        self.assertEqual(self.readable(store.root), {})
        entries = baseline.backup_sets()[0][1]
        self.assertEqual([(Path(o).name, m) for o, _, _, m in entries], [("config", "0600"), ("tool", "0755")])
        tool.unlink()
        hint = baseline.restore_hint(Path(entries[1][1]), tool, entries[1][3])
        subprocess.run(hint, shell=True, check=True)
        self.assertEqual((tool.read_text(), stat.S_IMODE(tool.stat().st_mode)), ("#!/bin/sh\n", 0o755))

    @unittest.skipIf(os.name == "nt", "POSIX permissions")
    def test_a_readable_store_is_tightened(self) -> None:
        # What an older ws wrote: 0755 directories, 0644 copies, a MANIFEST without modes.
        root = self.state / "dotfiles"
        self.write(root / "baseline.json", "{}", 0o644)
        self.write(root / "blobs/abc", "Host x\n", 0o644)
        self.write(root / "backups/20260101-000000-pre-apply/home/.ssh/config", "Host x\n", 0o644)
        self.write(root / "backups/20260101-000000-pre-apply/MANIFEST.tsv",
                   f"{self.home}/.ssh/config\t{root}/backups/20260101-000000-pre-apply/home/.ssh/config\tlocal edit\n", 0o644)
        for d in (root, *[p for p in root.rglob("*") if p.is_dir()]):
            d.chmod(0o755)
        baseline.Store()
        self.assertEqual(self.readable(root), {})
        (orig, _, why, mode), = baseline.backup_sets()[0][1]
        self.assertEqual((orig, why, mode), (f"{self.home}/.ssh/config", "local edit", ""))

    def test_cancelled_picker_changes_nothing(self) -> None:
        st = self.entries({"target": "~/.rc", "source": "dotfiles/rc"})
        self.write(self.repo / "dotfiles/rc", "repo\n")
        self.write(self.home / ".rc", "live\n")
        self.fake_mise(st)
        self.fake("fzf", "cat >/dev/null; exit 130")
        os.environ.pop("WS_NONINTERACTIVE")
        from unittest import mock

        with mock.patch("wslib.core.interactive", return_value=True):
            self.assertEqual(reconcile.Session(baseline.Store()).run(), 0)
        self.assertEqual((self.home / ".rc").read_text(), "live\n")
        self.assertEqual((self.repo / "dotfiles/rc").read_text(), "repo\n")
        self.assertEqual(baseline.backup_sets(), [])


if __name__ == "__main__":
    unittest.main()
