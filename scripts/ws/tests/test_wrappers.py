"""The zsh and bash `ws` wrappers (zshrc.tera, bashrc.tera): run with a stub ws.py, they
apply a handed-back `cd` (paths with spaces), put a command on the prompt for the user
(zsh's buffer stack; bash's editable line, under a pty), pass ws's exit status through, and
hand wsa to `ws apply`.
Nushell's wrapper is covered by scripts/test-config-nu.sh."""

from __future__ import annotations

import os
import pty
import re
import select
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

from helpers import REPO, Scratch

STUB = """import os, sys
args = sys.argv[1:]
out = os.environ["WS_OUT"]
with open(out, "a") as fh:
    if args[:1] == ["cd"]:
        fh.write("cd\\t" + args[1] + "\\n")
    elif args[:1] == ["insert"]:
        fh.write("insert\\t" + args[1] + "\\n")
print("shell=" + os.environ.get("WS_SHELL", ""))
if args[:1] == ["apply"]:
    print("apply " + repr(args[1:]))
    sys.exit(7)  # a refusal or mise's own failure: the shell must see it
sys.exit(int(args[1]) if args[:1] == ["exit"] else 0)
"""


def functions(rc: Path, names: tuple[str, ...]) -> str:
    """The named functions' definitions, as written in the rc template."""
    text = rc.read_text(encoding="utf-8")
    out = []
    for n in names:
        m = re.search(rf"^{re.escape(n)}\(\) \{{(?: [^\n]*\}}\n|\n.*?^\}}\n)", text, re.S | re.M)  # one line, or a body
        assert m, f"{n} not in {rc}"
        out.append(m.group(0))
    return "\n".join(out)


class Wrappers(Scratch):
    def setUp(self) -> None:
        super().setUp()
        self.write(self.repo / "scripts/ws/ws.py", STUB)
        self.fake("mise", f'[ "$3" = which ] && echo "{sys.executable}"')
        self.target = self.root / "a dir with spaces"
        self.target.mkdir()

    def script(self, shell: str) -> Path:
        rc = REPO / "dotfiles" / f"{shell}rc.tera"
        return self.write(self.root / f"funcs.{shell}", functions(rc, ("python-cli", "ws", "wsh", "wsa")))

    def run_shell(self, shell: str, body: str) -> subprocess.CompletedProcess[str]:
        argv = [shell, "-f", "-c"] if shell == "zsh" else [shell, "--norc", "--noprofile", "-c"]
        return subprocess.run([*argv, f"source '{self.script(shell)}'\n{body}"], capture_output=True, text=True)

    @unittest.skipUnless(shutil.which("zsh"), "zsh not installed")
    def test_zsh(self) -> None:
        p = self.run_shell("zsh", f"ws cd '{self.target}'; pwd; ws insert 'wsa --yes'; read -z line; print -r -- \"buffer=$line\"; ws exit 3; echo rc=$?")
        self.assertEqual(p.stdout.splitlines(), ["shell=zsh", str(self.target), "shell=zsh", "buffer=wsa --yes",
                                                 "shell=zsh", "rc=3"], p.stderr)

    def test_wsa_is_ws_apply(self) -> None:
        # One program behind every shell's wsa; its arguments reach it as given.
        for shell in ("zsh", "bash") if shutil.which("zsh") else ("bash",):
            p = self.run_shell(shell, "wsa --force-dotfiles 'two words'; echo rc=$?")
            self.assertEqual(p.stdout.splitlines(), [f"shell={shell}", "apply ['--force-dotfiles', 'two words']", "rc=7"],
                             p.stderr)

    def test_bash_cd_and_status(self) -> None:
        p = self.run_shell("bash", f"ws cd '{self.target}'; pwd; ws exit 4; echo rc=$?")
        self.assertEqual(p.stdout.splitlines(), ["shell=bash", str(self.target), "shell=bash", "rc=4"], p.stderr)

    def test_bash_insert_is_an_editable_line(self) -> None:
        # bash has no print -z: the wrapper offers the command on an editable line, so it
        # runs only when the user presses Enter.
        marker = self.root / "ran"
        pid, fd = pty.fork()
        if pid == 0:
            os.execvp("bash", ["bash", "--norc", "--noprofile", "-c",
                               f"source '{self.script('bash')}'; ws insert \"touch '{marker}'\""])
        out = b""
        while b"$ " not in out:
            r, _, _ = select.select([fd], [], [], 10)
            if not r:
                break
            out += os.read(fd, 1024)
        self.assertFalse(marker.exists())  # offered, not run
        self.assertIn(b"touch", out)
        os.write(fd, b"\r")
        while True:
            r, _, _ = select.select([fd], [], [], 10)
            if not r:
                break
            try:
                if not os.read(fd, 1024):
                    break
            except OSError:
                break
        os.waitpid(pid, 0)
        self.assertTrue(marker.exists())


if __name__ == "__main__":
    unittest.main()
