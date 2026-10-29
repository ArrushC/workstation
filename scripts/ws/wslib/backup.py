"""Restic owns repositories, encryption and snapshots; ws supplies host preferences."""

from __future__ import annotations

import argparse
import os
import tempfile
import tomllib
from pathlib import Path

from . import core, ui

TEMPLATE = '''# Per-host backup settings. No backup runs until you configure and invoke it.
# Use RESTIC_REPOSITORY / RESTIC_PASSWORD_COMMAND / RESTIC_PASSWORD_FILE, or set
# repository and password_file below. Keep passwords out of this file.
# repository = "/path/to/backup-repository"
# password_file = "~/.config/restic/password"
# Select the notes, preferences and working directories you want protected.
paths = []
# paths = ["~/.nb", "~/.config/workstation", "~/projects/my-project"]
exclude = ["node_modules", ".venv", "__pycache__"]
'''


def settings() -> tuple[list[str], dict]:
    path = core.config_dir() / "backup.toml"
    data = tomllib.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    for key in ("repository", "password_file"):
        if key in data and not isinstance(data[key], str):
            raise ValueError(f"backup.toml: {key} must be a string")
    args: list[str] = []
    repository = data.get("repository") or os.environ.get("RESTIC_REPOSITORY")
    if not repository and not os.environ.get("RESTIC_REPOSITORY_FILE"):
        raise ValueError("choose a repository with ws backup config, or set RESTIC_REPOSITORY")
    if repository:
        args += ["--repo", str(core.expand(repository)) if repository.startswith("~") else repository]
    if data.get("password_file"):
        args += ["--password-file", str(core.expand(data["password_file"]))]
    for key in ("paths", "exclude"):
        if not isinstance(data.get(key, []), list) or not all(isinstance(v, str) for v in data.get(key, [])):
            raise ValueError(f"backup.toml: {key} must be an array of strings")
    return args, data


def restic(options: list[str], *args: str) -> int:
    return core.run(core.mise_argv("exec", "restic", "--", "restic", *options, *args), capture=False).returncode


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="ws backup", description="Configured restic backups, snapshot browsing and restore checks.")
    sub = p.add_subparsers(dest="action", required=True)
    sub.add_parser("config", help="create/open this host's backup preferences")
    sub.add_parser("init", help="initialize the explicitly configured repository")
    run = sub.add_parser("run", help="back up the configured paths")
    run.add_argument("--dry-run", action="store_true")
    snaps = sub.add_parser("snapshots", help="browse snapshots")
    snaps.add_argument("--json", action="store_true")
    ls = sub.add_parser("ls", help="browse paths in a snapshot")
    ls.add_argument("snapshot", nargs="?", default="latest")
    restore = sub.add_parser("restore", help="restore into a new or empty directory")
    restore.add_argument("snapshot")
    restore.add_argument("--target", required=True)
    restore.add_argument("--include", action="append", default=[])
    check = sub.add_parser("check", help="check repository integrity")
    check.add_argument("--read-data", action="store_true")
    verify = sub.add_parser("verify", help="restore a snapshot into temporary storage and verify its contents")
    verify.add_argument("snapshot", nargs="?", default="latest")
    verify.add_argument("--include", action="append", default=[], help="restrict the restore drill to selected paths")
    a = p.parse_args(argv)
    try:
        if a.action == "config":
            path = core.config_dir() / "backup.toml"
            if not path.exists():
                core.private_dir(path.parent)
                core.atomic_write(path, TEMPLATE.encode(), 0o600)
            return ui.edit([path])
        options, config = settings()
        if a.action == "run":
            paths = [core.expand(s).resolve() for s in config.get("paths", [])]
            if not paths:
                return core.die("select backup paths with ws backup config", 2)
            missing = [str(path) for path in paths if not path.exists()]
            if missing:
                return core.die("backup paths are missing: " + ", ".join(missing), 2)
            args = ["backup", *(["--dry-run"] if a.dry_run else [])]
            for pattern in config.get("exclude", []):
                args += ["--exclude", pattern]
            return restic(options, *args, "--", *map(str, paths))
        if a.action == "init":
            return restic(options, "init")
        if a.action == "snapshots":
            return restic(options, "snapshots", *(["--json"] if a.json else []))
        if a.action == "ls":
            return restic(options, "ls", "--", a.snapshot)
        if a.action == "check":
            return restic(options, "check", *(["--read-data"] if a.read_data else []))
        includes = [value for pattern in a.include for value in ("--include", pattern)]
        if a.action == "verify":
            with tempfile.TemporaryDirectory(prefix="ws-restore-check-") as target:
                code = restic(options, "restore", "--target", target, "--verify", *includes, "--", a.snapshot)
                if code == 0:
                    print("Restore check passed; temporary restored files removed.")
                return code
        target = core.expand(a.target).resolve()
        if target.exists() and (not target.is_dir() or any(target.iterdir())):
            return core.die("restore target must be a new or empty directory", 2)
        return restic(options, "restore", "--target", str(target), "--overwrite", "never", "--verify", *includes, "--", a.snapshot)
    except (OSError, ValueError, TypeError) as error:
        return core.die(str(error), 2)
