"""Behavioral tests: publication, failure recovery, lock changes, concurrency and Windows renames."""
import importlib.util
import json
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from contextlib import redirect_stderr

spec = importlib.util.spec_from_file_location("tool_env", Path(__file__).with_name("tool-env.py"))
env = importlib.util.module_from_spec(spec)
spec.loader.exec_module(env)


def sharing_violation():
    """What os.replace raises on Windows while another process holds the file (WinError 5)."""
    error = PermissionError(13, "Access is denied")
    error.winerror = 5
    return error


class Environments(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "state"
        self.bin = self.base / "bin with spaces"
        self.source = self.base / "environments/lsp"
        self.source.mkdir(parents=True)
        (self.source / "package.json").write_text('{}')
        (self.source / "package-lock.json").write_text('{"version":1}')
        self.runtime = Path("/fake node/bin/node")
        self.calls = []
        self.cwds = []
        self.run_patch = patch.object(env, "run", self.fake_run)
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)
        self.repo_patch = patch.object(env, "REPO", self.base)
        self.repo_patch.start()
        self.addCleanup(self.repo_patch.stop)

    def fake_run(self, args, **kwargs):
        self.calls.append([str(a) for a in args])
        if "cwd" in kwargs:
            self.cwds.append(Path(kwargs["cwd"]))
        if "ci" in args:
            for name in env.LSP_BINS.values():
                p = kwargs["cwd"] / "node_modules" / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("// test fixture")

    def install(self, **kw):
        return env.install("lsp", self.root, self.bin, self.runtime, **kw)

    def snapshots(self):
        return {p.name: p.read_bytes() for p in self.bin.iterdir()}

    def tree(self):
        return sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*"))

    def test_repeat_reuses_generation_and_repairs_launcher(self):
        one = self.install()
        expected = self.snapshots()
        next(self.bin.iterdir()).unlink()
        self.assertEqual(one, self.install())
        self.assertEqual(expected, self.snapshots())
        self.assertEqual(1, sum("ci" in c for c in self.calls))
        self.assertIn("--ignore-scripts", next(c for c in self.calls if "ci" in c))

    def test_changed_lock_publishes_new_generation_and_keeps_old(self):
        one = self.install()
        (self.source / "package-lock.json").write_text('{"version":2}')
        two = self.install()
        self.assertNotEqual(one, two)
        self.assertTrue((one / ".complete").exists())
        self.assertEqual(two.name, json.loads((self.root / "current.json").read_text())["generation"])
        self.assertTrue(all(str(two) in p.read_text() for p in self.bin.iterdir()))

    def test_failed_install_keeps_working_launchers_and_retry_succeeds(self):
        one = self.install()
        before = self.snapshots()
        current = (self.root / "current.json").read_bytes()
        (self.source / "package-lock.json").write_text('{"version":2}')
        with patch.object(env, "run", side_effect=subprocess.CalledProcessError(1, ["npm", "ci"])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.install()
        self.assertEqual(before, self.snapshots())
        self.assertEqual(current, (self.root / "current.json").read_bytes())
        self.assertTrue(one.exists())
        self.assertNotEqual(one, self.install())

    def test_failed_smoke_does_not_publish(self):
        self.install()
        before = self.snapshots()
        with patch.object(env, "smoke", side_effect=RuntimeError("missing dependency")):
            with self.assertRaises(RuntimeError):
                self.install(rebuild=True)
        self.assertEqual(before, self.snapshots())

    def test_failed_publication_keeps_the_record_and_a_rerun_completes_it(self):
        one = self.install()
        (self.source / "package-lock.json").write_text('{"version":2}')
        real, written = env.launcher, []

        def fail_after_first(path, argv):
            if written:
                raise sharing_violation()
            written.append(path)
            real(path, argv)

        with patch.object(env, "launcher", fail_after_first):
            with self.assertRaises(PermissionError):
                self.install()
        self.assertEqual(one.name, json.loads((self.root / "current.json").read_text())["generation"])
        [two] = [p for p in self.root.iterdir() if p.is_dir() and p != one]
        self.assertTrue((two / ".complete").exists())
        self.assertEqual(1, sum(str(two) in p.read_text() for p in self.bin.iterdir()))
        self.assertEqual(two, self.install())
        self.assertEqual(two.name, json.loads((self.root / "current.json").read_text())["generation"])
        self.assertTrue(all(str(two) in p.read_text() for p in self.bin.iterdir()))
        self.assertEqual(2, sum("ci" in c for c in self.calls))

    def test_rebuild_new_path_is_not_relocated_and_is_reused(self):
        one = self.install()
        two = self.install(rebuild=True)
        self.assertNotEqual(one, two)
        self.assertEqual(two, self.install())

    @unittest.skipIf(env.WINDOWS, "flock behavior; Windows uses msvcrt")
    def test_concurrent_installer_refuses_before_work(self):
        with env.install_lock(self.root):
            with self.assertRaises(BlockingIOError):
                self.install()
        self.assertEqual([], self.calls)

    def test_python_uses_locked_sync_with_selected_runtime(self):
        p = self.base / "environments/python"
        p.mkdir()
        (p / "pyproject.toml").write_text('[project]\nname="test"')
        (p / "uv.lock").write_text('version=1')
        with patch.object(env, "smoke"):
            generation = env.install("python", self.root, self.bin, self.runtime, Path("/fake uv"))
        call = next(c for c in self.calls if "sync" in c)
        self.assertIn("--locked", call)
        self.assertNotIn("--upgrade", call)
        self.assertIn(str(self.runtime), call)
        self.assertIn(str(generation), call)

    def test_damaged_published_generation_is_rebuilt_beside_it(self):
        one = self.install()
        (one / "node_modules" / env.LSP_BINS["tsc"]).unlink()
        two = self.install()
        self.assertNotEqual(one, two)
        self.assertTrue(two.name.startswith(one.name + "-"))
        self.assertTrue(all(str(two) in p.read_text() for p in self.bin.iterdir()))
        self.assertEqual(2, sum("ci" in c for c in self.calls))

    def test_published_generation_without_marker_is_never_rebuilt_in_place(self):
        one = self.install()
        entry = one / "node_modules" / env.LSP_BINS["tsc"]
        (one / ".complete").unlink()
        two = self.install()
        self.assertNotEqual(one, two)
        self.assertTrue(entry.exists(), "the published tree was deleted")
        self.assertNotIn(one, self.cwds[1:], "npm ci ran inside the published generation")
        self.assertTrue((two / ".complete").exists())
        self.assertTrue(all(str(two) in p.read_text() for p in self.bin.iterdir()))

    def test_failed_rebuild_of_unmarked_published_generation_changes_nothing(self):
        one = self.install()
        (one / ".complete").unlink()
        before, tree = self.snapshots(), self.tree()
        current = (self.root / "current.json").read_bytes()
        with patch.object(env, "run", side_effect=subprocess.CalledProcessError(1, ["npm", "ci"])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.install()
        self.assertEqual(before, self.snapshots())
        self.assertEqual(current, (self.root / "current.json").read_bytes())
        self.assertEqual(tree, self.tree(), "the published generation changed or a partial one was left")

    def test_unrecorded_generation_the_launchers_run_is_not_rebuilt_in_place(self):
        one = self.install()
        (self.root / "current.json").unlink()
        (one / ".complete").unlink()
        entry = one / "node_modules" / env.LSP_BINS["tsc"]
        two = self.install()
        self.assertNotEqual(one, two)
        self.assertTrue(entry.exists())

    def test_failed_validation_publishes_nothing_and_leaves_no_partial_generation(self):
        self.install()
        before, tree = self.snapshots(), self.tree()
        with patch.object(env, "smoke", side_effect=RuntimeError("missing dependency")):
            with self.assertRaises(RuntimeError):
                self.install(rebuild=True)
        self.assertEqual(before, self.snapshots())
        self.assertEqual(tree, self.tree())

    def test_clean_keeps_only_the_published_generation(self):
        one = self.install()
        (self.root / "notes").mkdir()
        (self.source / "package-lock.json").write_text('{"version":2}')
        two = self.install()
        self.assertTrue(env.clean(self.root))
        self.assertFalse(one.exists())
        self.assertTrue((two / ".complete").exists())
        self.assertTrue((self.root / "notes").exists())
        self.assertTrue((self.root / "current.json").exists())

    def test_clean_reports_a_generation_it_could_not_remove(self):
        one = self.install()
        (self.source / "package-lock.json").write_text('{"version":2}')
        two = self.install()
        (self.source / "package-lock.json").write_text('{"version":3}')
        three = self.install()
        real_rmtree = env.shutil.rmtree

        def rmtree(path, *a, **kw):
            if Path(path) == one:
                raise PermissionError(13, "in use", str(path))
            return real_rmtree(path, *a, **kw)

        err = io.StringIO()
        with patch.object(env.shutil, "rmtree", rmtree), redirect_stderr(err):
            self.assertFalse(env.clean(self.root))
        self.assertTrue(one.exists())
        self.assertFalse(two.exists(), "one failure stopped the rest of the cleanup")
        self.assertTrue((three / ".complete").exists())
        self.assertIn(str(one), err.getvalue())

    def test_clean_without_a_published_generation_removes_nothing(self):
        one = self.install()
        (self.root / "current.json").unlink()
        with redirect_stderr(io.StringIO()):
            self.assertFalse(env.clean(self.root))
        self.assertTrue(one.exists())

    def test_without_clean_nothing_is_removed(self):
        one = self.install()
        (self.source / "package-lock.json").write_text('{"version":2}')
        self.install()
        self.assertTrue(one.exists())

    def test_status_reports_published_and_reclaimable(self):
        probe = self.bin / ("typescript-language-server" + (".cmd" if env.WINDOWS else ""))
        with patch.object(env, "prunable", return_value=0):
            self.assertEqual(1, env.status([("lsp", self.root, probe)]))
            one = self.install()
            self.assertEqual(0, env.status([("lsp", self.root, probe)]))
            (self.source / "package-lock.json").write_text('{"version":2}')
            self.install()
            self.assertEqual(2, env.status([("lsp", self.root, probe)]))
            # Rewritten as tool-env writes launchers, so the rename retry covers the Windows
            # scanner's hold on the file install() just wrote (a plain write_text has none).
            env.atomic_write(probe, f"exec node {one}/cli.mjs")
            self.assertEqual(1, env.status([("lsp", self.root, probe)]))
        with patch.object(env, "prunable", return_value=3):
            self.install()
            self.assertTrue(env.clean(self.root))
            self.assertEqual(2, env.status([("lsp", self.root, probe)]))

    def test_corrupt_record_is_rebuilt_not_a_traceback(self):
        self.install()
        (self.root / "current.json").write_text("{not json")
        self.install()
        self.assertEqual(1, sum("ci" in c for c in self.calls))

    def test_repeat_install_with_nothing_changed_renames_nothing(self):
        self.install()
        with patch.object(env.os, "replace", wraps=os.replace) as replace:
            self.install()
        self.assertEqual([], replace.call_args_list)

    @unittest.skipIf(env.WINDOWS, "POSIX exec bit")
    def test_unchanged_launcher_without_exec_bit_is_rewritten(self):
        self.install()
        tsc = self.bin / "tsc"
        tsc.chmod(0o644)
        self.install()
        self.assertTrue(os.access(tsc, os.X_OK))

    def test_rename_retries_a_transient_sharing_violation_on_windows(self):
        target = self.base / "launcher.cmd"
        calls, real_replace = [], os.replace

        def replace(src, dst):
            calls.append(dst)
            if len(calls) < 3:
                raise sharing_violation()
            return real_replace(src, dst)

        with patch.object(env, "WINDOWS", True), patch.object(env.os, "replace", replace):
            env.atomic_write(target, "new")
        self.assertEqual(3, len(calls))
        self.assertEqual("new", target.read_text())

    def test_rename_gives_up_after_the_retry_window(self):
        target = self.base / "launcher.cmd"
        target.write_text("old")
        with patch.object(env, "WINDOWS", True), patch.object(env, "REPLACE_RETRY_SECONDS", 0.05), \
                patch.object(env.os, "replace", side_effect=sharing_violation()) as replace:
            with self.assertRaises(PermissionError):
                env.atomic_write(target, "new")
        self.assertGreater(replace.call_count, 1)
        self.assertEqual("old", target.read_text())
        self.assertEqual(["launcher.cmd"], [p.name for p in self.base.iterdir() if p.is_file()])

    def test_rename_does_not_retry_other_errors_or_posix(self):
        target = self.base / "launcher.cmd"
        denied = PermissionError(13, "Permission denied")
        for windows, error in [(True, denied), (False, sharing_violation())]:
            with patch.object(env, "WINDOWS", windows), \
                    patch.object(env.os, "replace", side_effect=error) as replace:
                with self.assertRaises(PermissionError):
                    env.atomic_write(target, "new")
            self.assertEqual(1, replace.call_count, windows)

    @unittest.skipUnless(env.WINDOWS, "a real Windows sharing violation")
    def test_rename_over_a_briefly_held_target_succeeds_on_windows(self):
        # Python opens files without FILE_SHARE_DELETE, as the on-access scanner does, so a
        # rename onto the file fails while this handle is open. It closes during the first
        # retry's wait rather than on a timer, so a loaded machine can't race it.
        target = self.base / "launcher.cmd"
        target.write_text("old")
        held, real_sleep = open(target, "rb"), time.sleep
        self.addCleanup(held.close)

        def sleep(seconds):
            held.close()
            real_sleep(seconds)

        with patch.object(time, "sleep", sleep):
            env.atomic_write(target, "new")
        self.assertTrue(held.closed)
        self.assertEqual("new", target.read_text())

    @unittest.skipUnless(env.WINDOWS, "a real Windows sharing violation")
    def test_rename_over_a_target_held_too_long_fails_and_keeps_it_on_windows(self):
        target = self.base / "launcher.cmd"
        target.write_text("old")
        with open(target, "rb"), patch.object(env, "REPLACE_RETRY_SECONDS", 0.2):
            with self.assertRaises(PermissionError):
                env.atomic_write(target, "new")
        self.assertEqual("old", target.read_text())
        self.assertEqual(["launcher.cmd"], [p.name for p in self.base.iterdir() if p.is_file()])

    def test_windows_launcher_quotes_spaces_and_literal_percent(self):
        with patch.object(env, "WINDOWS", True):
            env.launcher(self.bin / "wpy", [r"C:\name with %percent%\python.exe"])
        self.assertEqual('@echo off\n"C:\\name with %%percent%%\\python.exe" %*\n',
                         (self.bin / "wpy.cmd").read_text())


class MainClean(unittest.TestCase):
    """`--clean` prunes runtimes only after every superseded generation is gone."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        base = Path(temp.name)
        self.calls = []
        node = base / "node/bin/node"
        patches = [
            patch.dict(os.environ, {"XDG_DATA_HOME": str(base), "LOCALAPPDATA": str(base)}),
            patch.object(env, "install", lambda *a, **kw: base / "published"),
            patch.object(env, "mise_which", lambda tool: node),
            patch.object(env, "run", lambda args, **kw: self.calls.append([str(a) for a in args])),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def main(self, *argv, clean_ok=(True, True)):
        results = iter(clean_ok)
        with patch.object(env, "clean", lambda root: next(results)), \
                patch.object(sys, "argv", ["tool-env.py", *argv]), redirect_stderr(io.StringIO()) as err:
            rc = env.main()
        self.err = err.getvalue()
        return rc

    def prunes(self):
        return sum(c[-2:] == ["prune", "--yes"] for c in self.calls)

    def test_failed_cleanup_exits_nonzero_and_skips_prune(self):
        for clean_ok in [(False, True), (True, False)]:
            self.calls.clear()
            self.assertEqual(1, self.main("all", "--clean", clean_ok=clean_ok))
            self.assertEqual(0, self.prunes(), clean_ok)
            self.assertIn("prune", self.err)

    def test_successful_cleanup_prunes_once(self):
        self.assertEqual(0, self.main("all", "--clean"))
        self.assertEqual(1, self.prunes())

    def test_one_environment_never_prunes(self):
        self.assertEqual(0, self.main("lsp", "--clean", clean_ok=(True,)))
        self.assertEqual(0, self.prunes())

    def test_only_a_failed_sync_reports_partial_publication(self):
        with patch.object(env, "install", side_effect=sharing_violation()):
            with self.assertRaises(SystemExit) as caught:
                self.main("lsp", "--clean", clean_ok=(True,))
        self.assertIn("Access is denied", caught.exception.code)
        self.assertIn("Some launchers may already have been updated. Rerun sync", caught.exception.code)
        self.assertEqual(0, self.prunes())
        failure = subprocess.CalledProcessError(1, ["mise", "which", "node"])
        with patch.object(env, "mise_which", side_effect=failure):
            with self.assertRaises(subprocess.CalledProcessError):
                self.main("status")


if __name__ == "__main__":
    unittest.main()
