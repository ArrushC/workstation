"""The pickers with the real fzf, driven through a pty as a person would: previews render,
Enter picks, a change asks first (n cancels with nothing run, y runs it), alt-r records
from the reconcile list, and Esc leaves everything as it was. Skipped without fzf."""

from __future__ import annotations

import fcntl
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import termios
import time
import unittest

from helpers import REPO, Scratch

WS_PY = str(REPO / "scripts/ws/ws.py")
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b[=>]|\r")


class Tty:
    def __init__(self, argv: list[str], cwd: str | None = None) -> None:
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if cwd:
                os.chdir(cwd)
            os.execvp(argv[0], argv)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
        self.buf = b""
        self.pos = 0

    def expect(self, pattern: str, timeout: float = 15) -> str:
        """Wait for `pattern` in the screen text after the previous match."""
        end = time.time() + timeout
        while True:
            text = ANSI.sub(b"", self.buf).decode("utf-8", "replace")
            m = re.compile(pattern).search(text, self.pos)
            if m:
                self.pos = m.end()
                return m.group(0)
            if time.time() > end:
                raise AssertionError(f"timed out waiting for {pattern!r}; screen:\n" + text[self.pos:][-3000:])
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if r:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    chunk = b""
                self.buf += chunk

    def send(self, data: bytes) -> None:
        time.sleep(0.3)  # let fzf settle on the latest query
        os.write(self.fd, data)

    def wait(self) -> int:
        end = time.time() + 15
        while time.time() < end:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return os.waitstatus_to_exitcode(status)
            try:
                select.select([self.fd], [], [], 0.2)
                os.read(self.fd, 65536)
            except OSError:
                pass
        os.kill(self.pid, 9)
        raise AssertionError("still running")


@unittest.skipUnless(shutil.which("fzf"), "fzf not installed")
class Pickers(Scratch):
    def setUp(self) -> None:
        super().setUp()
        os.environ.pop("WS_NONINTERACTIVE")
        os.environ["TERM"] = "xterm-256color"
        self.log = self.root / "mise.log"

    def test_palette_asks_before_a_change(self) -> None:
        self.fake_mise(log=self.log)
        t = Tty([sys.executable, WS_PY, "rebuild", "python"])
        t.expect(r"Rebuild the Python env")
        t.expect(r"kind:\s+change")           # the preview says what kind of action it is
        t.send(b"\r")
        t.expect(r"run python-env --rebuild[\s\S]*Run it\? \[y/N\]")
        t.send(b"n\r")
        t.expect(r"cancelled: nothing ran")
        self.assertEqual(t.wait(), 0)
        self.assertNotIn("python-env", self.log.read_text() if self.log.exists() else "")
        t = Tty([sys.executable, WS_PY, "rebuild", "python"])
        t.expect(r"Rebuild the Python env")
        t.send(b"\r")
        t.expect(r"Run it\?")
        t.send(b"y\r")
        self.assertEqual(t.wait(), 0)
        self.assertIn(f"-C {self.home} run python-env --rebuild", self.log.read_text())

    def test_palette_escape(self) -> None:
        self.fake_mise(log=self.log)
        t = Tty([sys.executable, WS_PY])
        t.expect(r"Reconcile dotfiles")
        t.send(b"\x1b")
        self.assertEqual(t.wait(), 0)
        self.assertNotRegex(self.log.read_text() if self.log.exists() else "", r"dot (apply|add|diff)|run ")

    def test_reconcile_records_from_the_list(self) -> None:
        st = self.entries({"target": "~/.rc file", "source": "dotfiles/rc file"})
        src, live = self.repo / "dotfiles/rc file", self.home / ".rc file"
        self.write(src, "one\n")
        self.write(live, "one\n")
        from wslib import baseline, dotfiles

        store = baseline.Store()
        dotfiles.record_agreed(dotfiles.load(store, status_doc=st), store, "test")
        self.write(live, "one\nlive edit\n")
        self.fake_mise(st, log=self.log)
        t = Tty([sys.executable, WS_PY, "reconcile"])
        t.expect(r"local\s+~/\.rc file")
        t.expect(r"baseline: yes")            # the preview, with the local change below it
        t.expect(r"\+live edit")
        t.send(b"\x1br")                      # alt-r: record
        t.expect(r"record ~/\.rc file\? \[y/N\]")
        t.send(b"y\r")
        t.expect(r"done: record")
        t.expect(r"Press Enter")
        t.send(b"\r")
        t.expect(r"Nothing to reconcile")
        self.assertEqual(t.wait(), 0)
        self.assertEqual(src.read_text(), "one\nlive edit\n")

    def test_reconcile_escape_changes_nothing(self) -> None:
        st = self.entries({"target": "~/.rc", "source": "dotfiles/rc"})
        self.write(self.repo / "dotfiles/rc", "repo\n")
        self.write(self.home / ".rc", "live\n")
        self.fake_mise(st, log=self.log)
        t = Tty([sys.executable, WS_PY, "reconcile"])
        t.expect(r"\?\s+~/\.rc")
        t.expect(r"no baseline")
        t.send(b"\r")                          # into the action menu
        t.expect(r"edit: open the live file")
        t.send(b"\x1b")                        # back out of it
        t.expect(r"\?\s+~/\.rc")
        t.send(b"\x1b")                        # and out of the list
        self.assertEqual(t.wait(), 0)
        self.assertEqual(((self.home / ".rc").read_text(), (self.repo / "dotfiles/rc").read_text()), ("live\n", "repo\n"))

    def test_open_picks_a_project(self) -> None:
        proj = self.home / "projects/my app"
        proj.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(proj)], check=True)
        self.write(self.root / "cfg/projects.toml", f'roots = ["{proj.parent}"]\n')
        zlog = self.root / "zellij.log"
        self.fake("zellij", f'[ "$1" = list-sessions ] || printf "%s|%s\\n" "$PWD" "$*" >>"{zlog}"')
        self.fake_mise(log=self.log)
        os.environ["WS_NO_EXEC"] = "1"
        t = Tty([sys.executable, WS_PY, "open"])
        t.expect(r"my app")
        t.expect(r"session: my-app-[0-9a-f]{6} \(none yet: create\)")
        t.send(b"\r")
        self.assertEqual(t.wait(), 0)
        cwd, args = zlog.read_text().strip().split("|")
        self.assertEqual(cwd, str(proj.resolve()))
        self.assertRegex(args, r"^--session my-app-[0-9a-f]{6} --new-session-with-layout dev$")


if __name__ == "__main__":
    unittest.main()
