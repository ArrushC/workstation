"""The baseline store's own failures: an index it can't use (damaged, another format version,
unreadable) is kept and reported, never overwritten unseen; a blob that is missing or altered
is no baseline; and stores in several processes never lose each other's updates. (The
pre-apply hook and backup sets are test_backups.py's.)"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

from helpers import WS, Scratch

from wslib import baseline, dotfiles
from wslib.dotfiles import NOBASE


class Damage(Scratch):
    def setUp(self) -> None:
        super().setUp()
        self.store_root = self.state / "dotfiles"
        self.index = self.store_root / "baseline.json"

    def store(self) -> tuple[baseline.Store, str]:
        err = io.StringIO()
        with redirect_stderr(err):
            s = baseline.Store()
        return s, err.getvalue()

    def saved(self, store: baseline.Store) -> tuple[bool, str]:
        err = io.StringIO()
        with redirect_stderr(err):
            ok = store.save()
        return ok, err.getvalue()

    def test_a_damaged_index_is_reported_kept_and_replaced(self) -> None:
        good = baseline.Store()
        good.record("old", b"old content\n", "~/old", "t")
        self.assertTrue(good.save())
        old_blob = self.store_root / "blobs" / baseline.sha(b"old content\n")
        self.index.write_text('{"version": 1, "files": {"old": ')  # cut off mid-write
        damaged = self.index.read_bytes()
        store, err = self.store()
        self.assertIn(str(self.index), err)
        self.assertIn("can't be used (not JSON", err)
        self.assertIn("baseline.json.damaged-", err)
        self.assertEqual((store.files, store.content("old"), store.read_only), ({}, None, False))
        store.record("new", b"new\n", "~/new", "t")
        ok, err = self.saved(store)
        self.assertTrue(ok)
        kept = sorted(self.store_root.glob("baseline.json.damaged-*"))
        self.assertEqual(len(kept), 1)
        self.assertIn(str(kept[0]), err)
        self.assertEqual(kept[0].read_bytes(), damaged)  # kept as it was
        self.assertEqual(list(json.loads(self.index.read_text())["files"]), ["new"])
        self.assertTrue(old_blob.exists())  # its records can't be read: every blob is kept
        kept[0].unlink()
        again = baseline.Store()
        again.record("newer", b"newer\n", "~/newer", "t")
        again.save()
        self.assertFalse(old_blob.exists())  # cleaned up once the kept index is gone

    def test_every_shape_ws_cant_use_counts_as_damaged(self) -> None:
        sha = "0" * 64
        for text in ("[]", "{}", '{"version": "1", "files": {}}', '{"version": 1}', '{"version": 1, "files": []}',
                     '{"version": 1, "files": {"k": {"sha256": "nothex", "entry": "~/k"}}}',
                     f'{{"version": 1, "files": {{"k": {{"sha256": "{sha}"}}}}}}', "\xff\xfe not utf-8"):
            with self.subTest(text):
                self.write(self.index, text.encode("latin-1"))
                store, err = self.store()
                self.assertIn("can't be used", err)
                self.assertFalse(store.read_only)  # its next save keeps it and starts afresh

    def test_another_format_version_is_read_only(self) -> None:
        doc = {"version": 2, "home": str(self.home), "files": {"k": {"sha256": "1" * 64, "entry": "~/k", "v2": True}}}
        self.write(self.index, json.dumps(doc))
        before = self.index.read_bytes()
        store, err = self.store()
        self.assertIn("is format version 2, and this ws reads version 1", err)
        self.assertIn("read-only", err)
        self.assertTrue(store.read_only)
        self.assertFalse(store.record("x", b"x", "~/x", "t"))
        store.forget("k")
        self.assertTrue(store.save())  # nothing to save
        self.assertEqual(self.index.read_bytes(), before)
        self.assertEqual(list(self.store_root.glob("baseline.json.damaged-*")), [])

    def test_a_newer_format_written_meanwhile_is_not_overwritten(self) -> None:
        store = baseline.Store()
        store.record("x", b"x", "~/x", "t")
        self.write(self.index, json.dumps({"version": 2, "home": str(self.home), "files": {}}))
        before = self.index.read_bytes()
        ok, err = self.saved(store)
        self.assertFalse(ok)
        self.assertIn("baselines not saved", err)
        self.assertEqual(self.index.read_bytes(), before)

    @unittest.skipIf(os.name == "nt" or os.geteuid() == 0, "POSIX permissions, not root")
    def test_an_unreadable_index_is_read_only(self) -> None:
        baseline.core.private_dir(self.store_root)  # already private: nothing to tighten
        self.write(self.index, json.dumps({"version": 1, "files": {}}), 0o000)
        store, err = self.store()
        self.assertIn(f"can't read {self.index}", err)
        self.assertTrue(store.read_only)

    def test_a_missing_or_altered_blob_is_no_baseline(self) -> None:
        st = self.entries({"target": "~/.rc", "source": "dotfiles/rc"})
        self.write(self.repo / "dotfiles/rc", "one\n")
        live = self.write(self.home / ".rc", "one\n")
        store = baseline.Store()
        dotfiles.record_agreed(dotfiles.load(store, status_doc=st), store, "t")
        blob = self.store_root / "blobs" / baseline.sha(b"one\n")
        self.write(live, "one\nlocal\n")
        for what, damage in (("missing", blob.unlink), ("altered", lambda: blob.write_bytes(b"something else\n"))):
            with self.subTest(what):
                if not blob.exists():
                    blob.write_bytes(b"one\n")
                damage()
                item, = dotfiles.load(baseline.Store(), status_doc=st).items
                self.assertEqual((item.has_base, item.cls), (False, NOBASE))  # not "edited here"
        # Recording the same content again puts the blob back.
        self.write(live, "one\n")
        store = baseline.Store()
        dotfiles.record_agreed(dotfiles.load(store, status_doc=st), store, "t")
        self.assertEqual(blob.read_bytes(), b"one\n")


class Concurrency(Scratch):
    def test_two_stores_keep_each_others_updates(self) -> None:
        seed = baseline.Store()
        seed.record("gone", b"gone", "~/gone", "t")
        seed.save()
        a, b = baseline.Store(), baseline.Store()
        a.record("from a", b"a", "~/a", "t")
        a.forget("gone")
        b.record("from b", b"b", "~/b", "t")
        self.assertTrue(a.save())
        self.assertTrue(b.save())  # b loaded before a saved, and keeps a's changes
        final = baseline.Store()
        self.assertEqual(sorted(final.files), ["from a", "from b"])
        self.assertEqual((final.content("from a"), final.content("from b")), (b"a", b"b"))
        self.assertEqual(sorted(b.files), ["from a", "from b"])  # and now sees them

    def test_one_stores_cleanup_spares_anothers_unsaved_blob(self) -> None:
        a, b = baseline.Store(), baseline.Store()
        a.record("k", b"pending in a", "~/k", "t")  # not on disk until a saves
        b.record("other", b"b", "~/b", "t")
        b.save()  # removes every blob its merged index doesn't use
        a.save()
        self.assertEqual(baseline.Store().content("k"), b"pending in a")

    def test_no_lock_is_held_between_load_and_save(self) -> None:
        # A reconcile waiting at a prompt holds changes, not the lock: a hook still saves.
        waiting = baseline.Store()
        waiting.record("k", b"k", "~/k", "t")
        hook = baseline.Store()
        hook.record("h", b"h", "~/h", "t")
        with mock.patch.object(baseline, "LOCK_TIMEOUT", 0.2):
            self.assertTrue(hook.save())
        self.assertTrue(waiting.save())
        self.assertEqual(sorted(baseline.Store().files), ["h", "k"])

    def test_a_held_lock_makes_save_wait_then_give_up_keeping_the_changes(self) -> None:
        holder, store = baseline.Store(), baseline.Store()
        store.record("k", b"k", "~/k", "t")
        err = io.StringIO()
        with mock.patch.object(baseline, "LOCK_TIMEOUT", 0.2), holder._locked(), redirect_stderr(err):
            self.assertFalse(store.save())
        self.assertIn("baselines not saved: another ws held", err.getvalue())
        self.assertFalse((self.state / "dotfiles/baseline.json").exists())
        self.assertTrue(store.save())  # still pending: saved once the lock is free
        self.assertEqual(baseline.Store().content("k"), b"k")

    def test_processes_saving_at_once_lose_nothing(self) -> None:
        script = f"""import sys
sys.path.insert(0, {str(WS)!r})
from wslib import baseline
who = sys.argv[1]
for i in range(40):
    s = baseline.Store()
    s.record(f"{{who}}-{{i}}", f"{{who}} {{i}}".encode(), "~/x", "t")
    assert s.save()
"""
        procs = [subprocess.Popen([sys.executable, "-c", script, w]) for w in ("p", "q", "r", "s")]
        self.assertEqual([p.wait(timeout=120) for p in procs], [0, 0, 0, 0])
        final = baseline.Store()
        self.assertEqual(len(final.files), 160)  # without the lock about 60 survive
        for key in final.files:
            who, i = key.split("-")
            self.assertEqual(final.content(key), f"{who} {i}".encode())


if __name__ == "__main__":
    unittest.main()
