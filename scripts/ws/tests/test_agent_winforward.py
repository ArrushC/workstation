"""dotfiles/windows/local/bin/ws-agent: on Windows (Git Bash: Claude Code's Bash tool and hooks)
`ws-agent` forwards to the WSL distribution the directory lives in. Run here with a fake wsl.exe
and the Windows directory given through WS_AGENT_WINPWD (Git Bash's `pwd -W`)."""

from __future__ import annotations

import os
import subprocess
import unittest

from helpers import REPO, Scratch

from wslib import agent

FORWARDER = REPO / "dotfiles" / "windows" / "local" / "bin" / "ws-agent"
FAKE_WSL = r"""printf '%s\n' "$@" >"$WS_FAKE_WSL/argv"
env >"$WS_FAKE_WSL/env"
echo "[orchestration] from wsl"
exit "$(cat "$WS_FAKE_WSL/rc" 2>/dev/null || echo 0)"
"""


class Forward(Scratch):
    def setUp(self) -> None:
        super().setUp()
        self.rec = self.root / "wsl-rec"
        self.rec.mkdir()
        os.environ["WS_FAKE_WSL"] = str(self.rec)
        self.fake("wsl.exe", FAKE_WSL)

    def run_fw(self, winpwd: str, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(FORWARDER), *args], capture_output=True, text=True, timeout=30,
                              env={**{k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "WSLENV")},
                                   "WS_AGENT_WINPWD": winpwd, **env})

    def argv(self) -> list[str]:
        return (self.rec / "argv").read_text().splitlines()

    def sent(self) -> list[str]:
        """The ws-agent arguments that crossed, decoded as ws-agent itself decodes them."""
        a = self.argv()
        self.assertEqual(a[a.index("ws-agent") + 1], "--argv-b64")
        return agent.decode_argv(a[a.index("ws-agent") + 2])

    def test_a_wsl_directory_runs_there(self) -> None:
        r = self.run_fw(r"\\wsl.localhost\AlmaLinux-9\home\me\src\foo", "context")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "[orchestration] from wsl"), r.stderr)
        a = self.argv()
        self.assertEqual(a[:5], ["-d", "AlmaLinux-9", "--cd", "/home/me/src/foo", "--"])
        self.assertEqual(a[5], "ws-agent")
        self.assertEqual(self.sent(), ["context"])
        env = (self.rec / "env").read_text()
        self.assertIn("MSYS_NO_PATHCONV=1", env)   # Git Bash must not rewrite /home/... into C:/...
        r = self.run_fw("//wsl$/Ubuntu/srv/x y", "ls", "--all")
        self.assertEqual(self.argv()[:4], ["-d", "Ubuntu", "--cd", "/srv/x y"])
        self.assertEqual(self.sent(), ["ls", "--all"])

    def test_outside_wsl_context_is_silent_and_other_commands_use_the_default_distro(self) -> None:
        r = self.run_fw(r"C:\Users\me\project", "context")
        self.assertEqual((r.returncode, r.stdout), (0, ""))    # no line: the session keeps tiers 1-2
        self.assertFalse((self.rec / "argv").exists())
        r = self.run_fw(r"C:\Users\me", "inbox")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("-d", self.argv())
        self.assertNotIn("--cd", self.argv())

    def test_a_windows_drive_repository_is_refused(self) -> None:
        for args in (("run", "--title", "t", "--prompt", "x", "--repo", r"C:\src\foo"), ("allow", "D:/src/foo")):
            r = self.run_fw(r"C:\Users\me", *args)
            self.assertEqual(r.returncode, 3, args)
            self.assertIn("WSL", r.stderr)
        self.assertFalse((self.rec / "argv").exists())

    def test_wsl_path_arguments_are_translated(self) -> None:
        self.run_fw(r"C:\Users\me", "run", "--title", "t", "--prompt-file",
                    r"\\wsl.localhost\AlmaLinux-9\home\me\p.md", "--repo", r"\\wsl.localhost\AlmaLinux-9\home\me\src\foo")
        a = self.argv()
        self.assertEqual(a[:2], ["-d", "AlmaLinux-9"])
        self.assertEqual(self.sent(), ["run", "--title", "t", "--prompt-file", "/home/me/p.md", "--repo",
                                       "/home/me/src/foo"])

    def test_a_prompt_crosses_untouched_by_any_shell(self) -> None:
        nasty = 'fix "it"; rm -rf ~ `id` $(id) \'x\' two  spaces\nand a line'
        self.run_fw(r"\\wsl.localhost\AlmaLinux-9\home\me", "run", "--title", "t", "--prompt", nasty)
        self.assertEqual(self.sent()[-1], nasty)
        words = self.argv()
        self.assertRegex(words[-1], r"^[A-Za-z0-9+/=]+$")   # all the login shell ever sees of it
        self.assertEqual(agent.main(["--argv-b64", "bm9wZQA="]), 2)   # decodes to ["nope"]: argparse refuses it

    def test_the_session_marker_crosses_and_the_exit_code_comes_back(self) -> None:
        self.write(self.rec / "rc", "3")
        r = self.run_fw(r"\\wsl.localhost\AlmaLinux-9\home\me", "allow", ".", CLAUDECODE="1")
        self.assertEqual(r.returncode, 3)
        a = self.argv()
        self.assertEqual(a[a.index("ws-agent") - 2:a.index("ws-agent")], ["env", "CLAUDECODE=1"])   # allow refuses there
        self.assertIn("CLAUDECODE/u", (self.rec / "env").read_text())

    def test_without_wsl_context_is_silent(self) -> None:
        (self.bin / "wsl.exe").unlink()
        path = f"{self.bin}{os.pathsep}/usr/bin{os.pathsep}/bin"
        r = self.run_fw(r"\\wsl.localhost\AlmaLinux-9\home\me", "context", PATH=path)
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        r = self.run_fw(r"\\wsl.localhost\AlmaLinux-9\home\me", "ls", PATH=path)
        self.assertEqual(r.returncode, 1)
        self.assertIn("wsl.exe", r.stderr)


if __name__ == "__main__":
    unittest.main()
