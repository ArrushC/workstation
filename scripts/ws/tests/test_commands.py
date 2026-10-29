"""Canonical commands delegate with intact arguments and preserve backend failures."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import shutil
import re
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

from helpers import REPO, Scratch
from wslib import backup, bench, cli, commands, core, history, resume, workflows, workspace


class Commands(Scratch):
    def test_mise_delegation_from_another_directory(self):
        for command, expected in (("edit", ["dot", "edit"]), ("diff", ["dot", "diff"]),
                                  ("status", ["dot", "status"]), ("record", ["dot", "add", "--changed"]),
                                  ("update", ["run", "update"])):
            with mock.patch.object(core, "run", return_value=subprocess.CompletedProcess([], 7)) as run:
                self.assertEqual(cli.main([command, "two words", "--flag"]), 7)
            self.assertEqual(run.call_args.args[0], ["mise", "-C", str(self.home), *expected, "two words", "--flag"])

    def test_windows_update_is_a_mise_task(self):
        with mock.patch.object(core, "IS_WINDOWS", True), mock.patch.object(core, "mise") as mise:
            commands.delegated("update", ["--skip", "tools"])
        mise.assert_called_once_with("run", "update-windows", "--skip", "tools", capture=False)

    def test_all_public_commands_complete_and_have_help(self):
        for cmd in cli.COMPLETED:
            with redirect_stdout(io.StringIO()) as out:
                cli.complete([cmd[:2]])
            self.assertIn(cmd, out.getvalue().splitlines())
        # Help for workflows must not invoke tools, open an editor, or write state.
        for cmd in ("runs", "bench", "resume", "backup", "services", "debug"):
            with mock.patch.object(core, "run", side_effect=AssertionError("help ran a command")), redirect_stdout(io.StringIO()):
                try:
                    code = cli.main([cmd, "--help"])
                except SystemExit as error:
                    code = error.code
                self.assertEqual(code, 0)


class Journal(Scratch):
    def test_latest_uses_creation_order_even_with_reverse_uuid_order(self):
        with mock.patch("wslib.history.uuid.uuid4", side_effect=[mock.Mock(hex="f" * 32), mock.Mock(hex="0" * 32)]):
            first = history.create("runs")
            history.save(first, {"id": first.name})
            second = history.create("runs")
            history.save(second, {"id": second.name})
        self.assertEqual(history.find("runs", "latest")[0], second)

    def invoke(self, *args, cwd=None):
        return subprocess.run([sys.executable, str(REPO / "scripts/ws/ws.py"), *args],
                              cwd=cwd or self.home, capture_output=True, text=True)

    def test_capture_exit_output_and_rerun_argv_in_original_directory(self):
        value = 'two words; $(touch nope) "quotes"'
        command = [sys.executable, "-c", "import os,sys; print(os.getcwd()); print(sys.argv[1]); sys.exit(7)", value]
        result = self.invoke("runs", "start", "--", *command)
        self.assertEqual(result.returncode, 7, result.stderr)
        record = history.records("runs")[0]
        self.assertEqual(record["argv"], command)
        self.assertEqual(record["exit_code"], 7)
        output = self.state / "runs" / record["id"] / "output.log"
        self.assertIn(value, output.read_text())
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.home / "nope").exists())
        self.assertIn(value, self.invoke("runs", "search", value, "--id", record["id"]).stdout)
        result = self.invoke("runs", "rerun", record["id"], cwd=self.root)
        self.assertEqual(result.returncode, 7)
        self.assertIn(str(self.home), result.stdout)
        self.assertEqual(len(history.records("runs")), 2)

    def test_missing_program_is_recorded_and_bad_ids_cannot_escape_store(self):
        result = self.invoke("runs", "start", "--", "/no/such/program")
        self.assertEqual(result.returncode, 127)
        self.assertEqual(history.records("runs")[0]["exit_code"], 127)
        self.assertNotEqual(self.invoke("runs", "show", "../../outside").returncode, 0)

    def test_failed_filter_and_stale_process(self):
        self.invoke("runs", "start", "--", sys.executable, "-c", "pass")
        self.invoke("runs", "start", "--", sys.executable, "-c", "raise SystemExit(3)")
        found = json.loads(self.invoke("runs", "list", "--failed", "--json").stdout)
        self.assertEqual([r["exit_code"] for r in found], [3])
        record = {"status": "running", "host": history.context(self.home)["host"], "pid": 999999999}
        self.assertEqual(history.status(record), "interrupted")


class Workflows(Scratch):
    def test_service_worktrees_get_different_endpoints(self):
        paths = [self.root / "project", self.root / "other"]
        endpoints = []
        for path in paths:
            (path / ".git").mkdir(parents=True)
            with mock.patch("pathlib.Path.cwd", return_value=path), mock.patch.object(core, "run") as run:
                run.return_value.returncode = 0
                workflows.main(["up", "-D"], command="services")
            args = run.call_args.args[0]
            self.assertEqual(args[:5], ["mise", "exec", "process-compose", "--", "process-compose"])
            self.assertIn("--use-uds", args)
            self.assertEqual(args[-2:], ["up", "-D"])
            endpoints.append(args[args.index("--unix-socket") + 1])
        self.assertNotEqual(*endpoints)

    def test_debug_check_stops_when_recording_fails(self):
        with mock.patch.object(core, "which", return_value="/usr/bin/rr"), mock.patch.object(core, "run") as run:
            run.return_value.returncode = 2
            self.assertEqual(workflows.main(["check"], command="debug"), 2)
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:2], ["rr", "record"])

    def test_resume_note_and_reopen_use_existing_workspace(self):
        path = self.home / "projects" / "example"
        (path / ".git").mkdir(parents=True)
        with mock.patch.object(workspace, "discover", return_value=[workspace.describe(path)]):
            self.assertEqual(resume.main([str(path), "--note", "Investigate the flaky test"]), 0)
            with mock.patch.object(workspace, "open_project", return_value=0) as opened:
                self.assertEqual(resume.main([str(path), "--cd"]), 0)
        self.assertEqual(opened.call_args.args[0].path, path)
        self.assertTrue(opened.call_args.kwargs["cd_only"])
        self.assertIn("flaky", resume.note_path(workspace.describe(path)).read_text())

    def test_benchmark_comparison_refuses_unrelated_hosts(self):
        ids = []
        for host, mean in (("one", 2.0), ("two", 1.0)):
            path = history.create("bench")
            history.save(path, {"id": path.name, "host": host, "platform": "linux", "cwd": str(self.home),
                                "command": "mise run build", "revision": "abc", "dirty": False,
                                "result": {"mean": mean, "stddev": 0.01}})
            ids.append(path.name)
        self.assertEqual(bench.main(["compare", *ids]), 2)
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(bench.main(["compare", *ids, "--allow-mismatch"]), 0)
        self.assertIn("-50.00%", out.getvalue())


class Backups(Scratch):
    def configure_backup(self):
        data = self.home / "notes with spaces"
        data.mkdir()
        self.write(core.config_dir() / "backup.toml",
                   f'repository = "{self.root}/backup"\npaths = [{json.dumps(str(data))}]\nexclude = ["node_modules"]\n')
        return data

    def test_backup_requires_explicit_configuration(self):
        for key in ("RESTIC_REPOSITORY", "RESTIC_REPOSITORY_FILE"):
            os.environ.pop(key, None)
        with mock.patch.object(core, "run", side_effect=AssertionError("must not run restic")):
            self.assertEqual(backup.main(["run"]), 2)

    def test_backup_delegates_paths_and_failure_to_mise_restic(self):
        path = self.configure_backup()
        with mock.patch.object(core, "run") as run:
            run.return_value.returncode = 3
            self.assertEqual(backup.main(["run", "--dry-run"]), 3)
        args = run.call_args.args[0]
        self.assertEqual(args[:7], ["mise", "-C", str(self.home), "exec", "restic", "--", "restic"])
        self.assertEqual(args[-6:], ["backup", "--dry-run", "--exclude", "node_modules", "--", str(path)])

    def test_restore_refuses_nonempty_target(self):
        self.configure_backup()
        target = self.root / "restore"
        self.write(target / "keep", "valuable")
        with mock.patch.object(core, "run", side_effect=AssertionError("must not restore")):
            self.assertEqual(backup.main(["restore", "latest", "--target", str(target)]), 2)
        self.assertEqual((target / "keep").read_text(), "valuable")

    def test_verify_uses_disposable_target_and_propagates_failure(self):
        self.configure_backup()
        with mock.patch.object(core, "run") as run:
            run.return_value.returncode = 9
            self.assertEqual(backup.main(["verify", "latest", "--include", "/notes"]), 9)
        args = run.call_args.args[0]
        self.assertIn("--verify", args)
        self.assertIn("/notes", args)
        self.assertFalse(Path(args[args.index("--target") + 1]).exists())


@unittest.skipUnless(shutil.which("pwsh"), "PowerShell not installed")
class PowerShell(Scratch):
    def setUp(self):
        super().setUp()
        source = (REPO / "dotfiles/windows/Documents/PowerShell/Microsoft.PowerShell_profile.ps1.tera").read_text()
        definitions = []
        for name in ("ws", "wse", "wsd", "wss", "wsr", "wsu", "wsa", "wsh"):
            found = re.search(rf"^function {name} \{{(?:[^\n]*\}}|\n.*?^\}})", source, re.M | re.S)
            assert found
            definitions.append(found.group())
        definitions.append(source[source.index("Register-ArgumentCompleter -CommandName ws"):].split("\n}\n", 1)[0] + "\n}\n")
        self.profile = self.write(self.root / "profile.ps1", "\n".join(definitions))
        self.fake("mise", f'''case " $* " in
  *" which python "*) echo '{sys.executable}' ;;
  *" dot status --json "*) echo '{{"files":[{{"target":"~/.zshrc","mode":"copy","state":"differs"}}]}}' ;;
  *" dot edit "*) printf '%s\\n' "$@"; exit 7 ;;
  *) printf '%s\\n' "$@" ;;
esac''')

    def ps(self, text):
        env = dict(os.environ, USERPROFILE=str(self.home), WORKSTATION_REPO=str(REPO))
        return subprocess.run(["pwsh", "-NoProfile", "-Command", f". '{self.profile}'; {text}"],
                              env=env, capture_output=True, text=True, timeout=60)

    def test_status_objects_and_exit_code(self):
        result = self.ps("ws status | ConvertTo-Json -Compress; wse 'two words'; Write-Output ('exit=' + $LASTEXITCODE)")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"state":"differs"', result.stdout)
        self.assertIn("two words\nexit=7", result.stdout)

    def test_completion(self):
        result = self.ps("(TabExpansion2 'ws up' 5).CompletionMatches.CompletionText")
        self.assertIn("update", result.stdout, result.stderr)

    def test_windows_update_passes_flags_to_mise(self):
        # -Pulled skips network and exercises the actual Windows task's argument binding.
        env = dict(os.environ, USERPROFILE=str(self.home))
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(REPO / "scripts/update.ps1"),
                                 "-Pulled", "--skip", "tools"], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["-C", str(self.home), "bootstrap", "--only", "dotfiles,tools", "--yes", "--skip", "tools"])
