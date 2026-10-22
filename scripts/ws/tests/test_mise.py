"""End to end against the real mise (skipped without it), in a scratch HOME with its own
global config: the pre/post-dotfiles hooks keep the baseline and back up local edits, a
template's render comes from mise's own diff, and reconcile records, applies and refuses
as it should. Never touches the real home."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import unittest

from helpers import REPO, Scratch

WS_PY = REPO / "scripts/ws/ws.py"


@unittest.skipUnless(shutil.which("mise"), "mise not installed")
class RealMise(Scratch):
    def setUp(self) -> None:
        super().setUp()
        py = f"{sys.executable} {WS_PY}".replace("\\", "/")
        self.write(self.repo / "config.toml", f"""
[vars]
name = "Scratch Host"

[dotfiles]
"~/.app conf" = {{ source = "dotfiles/app conf", mode = "copy" }}
"~/.greeting" = {{ source = "dotfiles/greeting.tera", mode = "template" }}
"~/.config/tool" = {{ source = "dotfiles/tool", mode = "copy", exclude = [".vendor"] }}

[bootstrap.hooks]
pre-dotfiles = "{py} baseline snapshot"
post-dotfiles = "{py} baseline record"
""")
        self.write(self.repo / "dotfiles/app conf", "a = 1\n")
        self.write(self.repo / "dotfiles/greeting.tera", "hello {{ vars.name }}\nline two\n")
        self.write(self.repo / "dotfiles/tool/main.kdl", "main\n")
        self.write(self.repo / "dotfiles/tool/sub/extra file.kdl", "extra\n")
        self.write(self.repo / "dotfiles/tool/.vendor", "provenance\n")
        os.environ.update({"MISE_CONFIG_DIR": str(self.repo), "MISE_STATE_DIR": str(self.root / "mise-state"),
                           "MISE_CACHE_DIR": str(self.root / "mise-cache"), "MISE_YES": "1"})
        for k in ("MISE_ENV", "MISE_DATA_DIR"):
            os.environ.pop(k, None)

    def mise(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["mise", "-C", str(self.home), *args], capture_output=True, text=True, cwd=self.home)

    def ws(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(WS_PY), *args], capture_output=True, text=True, cwd=self.home)

    def listing(self) -> dict[str, str]:
        p = self.ws("reconcile", "--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        return {i["target"]: i["class"] for i in json.loads(p.stdout)["items"]}

    def test_end_to_end(self) -> None:
        p = self.mise("dot", "apply", "--force", "--yes")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual((self.home / ".greeting").read_text(), "hello Scratch Host\nline two\n")
        # The post-dotfiles hook recorded every deployed file.
        index = json.loads((self.state / "dotfiles/baseline.json").read_text())
        self.assertEqual(sorted(index["files"]), [".app conf", ".config/tool/main.kdl",
                                                  ".config/tool/sub/extra file.kdl", ".greeting"])
        self.assertEqual(self.listing(), {})

        # Local edits on each kind of entry, and an unmanaged file reconcile must ignore.
        self.write(self.home / ".app conf", "a = 2\n")
        self.write(self.home / ".greeting", "hello Scratch Host\nline two\nlocal line\n")
        self.write(self.home / ".config/tool/sub/extra file.kdl", "extra edited\n")
        self.write(self.home / ".config/tool/mine.kdl", "unmanaged\n")
        self.write(self.repo / "dotfiles/tool/main.kdl", "main from the repo\n")
        self.assertEqual(self.listing(), {"~/.app conf": "local edit", "~/.greeting": "local edit",
                                          "~/.config/tool/main.kdl": "repo change",
                                          "~/.config/tool/sub/extra file.kdl": "local edit"})

        # A template is never recorded; its render came from mise's diff.
        p = self.ws("reconcile", "--record", "~/.greeting", "--yes")
        self.assertEqual(p.returncode, 1)
        self.assertIn("never copied over its template", p.stdout)
        self.assertEqual((self.repo / "dotfiles/greeting.tera").read_text(), "hello {{ vars.name }}\nline two\n")

        # Record one file inside the directory entry; its siblings and the unmanaged file stay.
        p = self.ws("reconcile", "--record", "~/.config/tool/sub/extra file.kdl", "--yes")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual((self.repo / "dotfiles/tool/sub/extra file.kdl").read_text(), "extra edited\n")
        self.assertFalse((self.repo / "dotfiles/tool/mine.kdl").exists())
        self.assertEqual((self.home / ".config/tool/main.kdl").read_text(), "main\n")

        # A full apply overwrites local edits (as wsu's bootstrap does): the pre-dotfiles hook
        # backs them up first, and the post hook baselines the new state.
        p = self.mise("dot", "apply", "--yes")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("backed up 2 local edit(s)", p.stdout + p.stderr)
        self.assertEqual((self.home / ".app conf").read_text(), "a = 1\n")
        backups = self.ws("reconcile", "--backups").stdout
        self.assertIn("pre-apply", backups)
        self.assertIn(".app conf", backups)
        self.assertEqual(self.listing(), {})

        # Apply one template from the repo after a repo-side change.
        self.write(self.repo / "dotfiles/greeting.tera", "hello {{ vars.name }}\nline 2\n")
        self.assertEqual(self.listing(), {"~/.greeting": "repo change"})
        p = self.ws("reconcile", "--apply", "~/.greeting", "--yes")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual((self.home / ".greeting").read_text(), "hello Scratch Host\nline 2\n")
        self.assertEqual(self.listing(), {})

        # mise's diff of "-- old" -> "-- new" removes a line that reads "--- old": still a change.
        for line in ("-- old", "-- new"):
            self.write(self.repo / "dotfiles/greeting.tera", f"hello {{{{ vars.name }}}}\n{line}\n")
            self.assertEqual(self.listing(), {"~/.greeting": "repo change"})
            p = self.ws("reconcile", "--apply", "~/.greeting", "--yes")
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertEqual((self.home / ".greeting").read_text(), f"hello Scratch Host\n{line}\n")
        self.assertEqual(self.listing(), {})

    def test_wsa(self) -> None:
        # ws apply runs mise bootstrap --only dotfiles: its hooks baseline the deploy, and a
        # repo change applies without asking where a local edit refuses (no terminal here).
        p = self.ws("apply", "--force-dotfiles")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual((self.home / ".greeting").read_text(), "hello Scratch Host\nline two\n")
        self.write(self.repo / "dotfiles/app conf", "a = 2\n")
        self.write(self.repo / "dotfiles/greeting.tera", "hi {{ vars.name }}\nline two\n")
        p = self.ws("apply")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual((self.home / ".app conf").read_text(), "a = 2\n")
        self.assertEqual((self.home / ".greeting").read_text(), "hi Scratch Host\nline two\n")
        self.write(self.home / ".greeting", "hi Scratch Host\nline two\nmine\n")
        self.write(self.repo / "dotfiles/app conf", "a = 3\n")
        p = self.ws("apply")
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn("-mine", p.stdout)  # the template's local edit, from mise's own render
        self.assertIn("refusing", p.stderr)
        self.assertEqual((self.home / ".greeting").read_text(), "hi Scratch Host\nline two\nmine\n")
        self.assertEqual((self.home / ".app conf").read_text(), "a = 2\n")  # nothing applied


if __name__ == "__main__":
    unittest.main()
