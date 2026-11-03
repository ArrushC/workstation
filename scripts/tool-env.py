"""Install locked scripting/LSP environments without destroying the working generation.

One implementation for Linux and Windows. Mise owns the runtimes; uv and npm
own these dependency graphs. Launchers are published only after a smoke check.
Old generations remain available for rollback; cleanup is an explicit operation
(--clean). `status` reports what is published and what cleanup would reclaim.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parent.parent
WINDOWS = os.name == "nt"
LSP_BINS = {
    "bash-language-server": "bash-language-server/out/cli.js",
    "typescript-language-server": "typescript-language-server/lib/cli.mjs",
    "tsc": "typescript/bin/tsc",
    "tsserver": "typescript/bin/tsserver",
    "vscode-css-language-server": "vscode-langservers-extracted/bin/vscode-css-language-server",
    "vscode-html-language-server": "vscode-langservers-extracted/bin/vscode-html-language-server",
    "vscode-json-language-server": "vscode-langservers-extracted/bin/vscode-json-language-server",
    "vscode-markdown-language-server": "vscode-langservers-extracted/bin/vscode-markdown-language-server",
    "vscode-eslint-language-server": "vscode-langservers-extracted/bin/vscode-eslint-language-server",
    "yaml-language-server": "yaml-language-server/bin/yaml-language-server",
}
GENERATION = re.compile(r"[0-9a-f]{20}(-[0-9a-f]{8})?")
# Windows on-access scanners (Check Point Endpoint on the Windows host) open a file the moment it
# is closed; a rename landing in that window fails with ERROR_ACCESS_DENIED (5) or
# ERROR_SHARING_VIOLATION (32) until the scan ends, milliseconds later. Retry only those,
# only on Windows, only this long: a longer hold is a real failure.
REPLACE_RETRY_SECONDS = 1.0


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def mise_which(tool):
    return Path(run(["mise", "-C", Path.home(), "which", tool], capture_output=True,
                    text=True).stdout.strip())


@contextmanager
def install_lock(root):
    root.mkdir(parents=True, exist_ok=True)
    with (root / ".install.lock").open("a+b") as stream:
        if WINDOWS:
            import msvcrt
            stream.seek(0)
            stream.write(b"0")
            stream.flush()
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            if WINDOWS:
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def replace(source, target):
    deadline = time.monotonic() + REPLACE_RETRY_SECONDS
    delay = 0.01
    while True:
        try:
            return os.replace(source, target)
        except PermissionError as error:
            if (not WINDOWS or getattr(error, "winerror", None) not in (5, 32)
                    or time.monotonic() >= deadline):
                raise
        time.sleep(delay)
        delay = min(delay * 2, 0.1)


def atomic_write(path, text, executable=False):
    """Replace path with text, unless it already holds exactly that (no needless rename)."""
    try:
        if path.read_bytes() == text.encode("utf-8") and (not executable or os.access(path, os.X_OK)):
            return
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".workstation-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        if executable:
            os.chmod(temp, 0o755)
        replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def launcher(path, argv):
    if WINDOWS:
        # Batch expands percent signs even inside quotes.
        command = " ".join('"' + str(a).replace('%', '%%') + '"' for a in argv)
        atomic_write(path.with_suffix(".cmd"), "@echo off\r\n" + command + " %*\r\n")
    else:
        atomic_write(path, "#!/bin/sh\nexec " + shlex.join([str(a) for a in argv]) + ' "$@"\n', True)


def published(root):
    """current.json's record, or {} when there is none (or it can't be read)."""
    try:
        record = json.loads((root / "current.json").read_text())
    except (OSError, ValueError):
        return {}
    return record if isinstance(record, dict) else {}


def superseded(root, keep):
    """Generation directories other than `keep` (complete or not)."""
    if not root.is_dir():
        return []
    return [p for p in root.iterdir() if p.is_dir() and GENERATION.fullmatch(p.name) and p.name != keep]


def remove(path):
    try:
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    except OSError as error:
        # Usually a process still running from it (Windows); the next --clean retries.
        print(f"tool-env: could not remove {path}: {error}", file=sys.stderr)
        return False
    print(f"removed {path}")
    return True


def clean(root):
    """Delete every generation but the published one; False if any is left behind."""
    with install_lock(root):
        keep = published(root).get("generation")
        if not keep or not (root / keep / ".complete").is_file():
            print(f"tool-env: nothing published in {root}; removed nothing", file=sys.stderr)
            return False
        # A list, not a generator: one failure must not stop the other removals.
        return all([remove(path) for path in superseded(root, keep)])


def build(kind, generation, source, files, runtime, uv, key):
    """Install into a new directory; on any failure remove it again (nothing points at it)."""
    generation.mkdir(parents=True)  # never an existing directory: never rebuild in place
    try:
        for name in files:
            shutil.copyfile(source / name, generation / name)
        if kind == "python":
            env = dict(os.environ, UV_PROJECT_ENVIRONMENT=str(generation / ".venv"),
                       UV_PYTHON_DOWNLOADS="never")
            run([uv, "sync", "--locked", "--no-dev", "--python", runtime,
                 "--project", generation], env=env)
        else:
            npm = runtime.parent / ("node_modules/npm/bin/npm-cli.js" if WINDOWS
                                    else "../lib/node_modules/npm/bin/npm-cli.js")
            run([runtime, npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=generation)
        smoke(kind, generation, runtime)
        atomic_write(generation / ".complete", key + "\n")
    except BaseException:
        shutil.rmtree(generation, ignore_errors=True)
        raise


def install(kind, root, bindir, runtime, uv=None, rebuild=False):
    source = REPO / "environments" / kind
    files = ["pyproject.toml", "uv.lock"] if kind == "python" else ["package.json", "package-lock.json"]
    digest = hashlib.sha256(str(runtime).encode() + Path(__file__).read_bytes())
    for name in files:
        digest.update((source / name).read_bytes())
    key = digest.hexdigest()[:20]

    def fresh():
        return root / (key + "-" + uuid.uuid4().hex[:8])

    with install_lock(root):
        current = root / "current.json"
        old = published(root)
        generation = fresh() if rebuild else root / key
        if not rebuild and old.get("key") == key and old.get("generation"):
            generation = root / old["generation"]
        if (generation / ".complete").exists():
            try:
                smoke(kind, generation, runtime)
            except (OSError, RuntimeError, subprocess.CalledProcessError):
                print(f"{kind}: {generation} failed its check; building a fresh generation", file=sys.stderr)
                generation = fresh()
        elif generation.exists():
            # Unmarked, but the launchers may still run it (a published generation
            # that lost its marker or record): leave it, build beside it.
            generation = fresh()
        if not (generation / ".complete").exists():
            # Launchers move only after this passes. Never move a venv: its
            # console-script shebangs contain the generation's absolute path.
            build(kind, generation, source, files, runtime, uv, key)
        if kind == "python":
            bins = generation / ".venv" / ("Scripts" if WINDOWS else "bin")
            python = bins / ("python.exe" if WINDOWS else "python")
            launcher(bindir / "wpy", [python])
            for name in ["textual", "typer"]:
                launcher(bindir / name, [bins / (name + ".exe" if WINDOWS else name)])
        else:
            for name, relative in LSP_BINS.items():
                launcher(bindir / name, [runtime, generation / "node_modules" / relative])
        atomic_write(current, json.dumps({"key": key, "generation": generation.name}) + "\n")
        print(f"{kind}: locked environment ready at {generation}")
        return generation


def smoke(kind, generation, runtime):
    if kind == "python":
        python = generation / ".venv" / ("Scripts/python.exe" if WINDOWS else "bin/python")
        run([python, "-c", "import textual, textual_dev, click, rich, httpx, pydantic, typer, polars, duckdb"])
    else:
        for relative in LSP_BINS.values():
            if not (generation / "node_modules" / relative).is_file():
                raise RuntimeError(f"Missing language server entry point: {relative}")
        run([runtime, generation / "node_modules/typescript-language-server/lib/cli.mjs", "--version"])
        run([runtime, generation / "node_modules/typescript/bin/tsc", "--version"])


def prunable():
    out = subprocess.run(["mise", "-C", str(Path.home()), "prune", "--dry-run"],
                         capture_output=True, text=True)
    return sum(" is prunable:" in line for line in (out.stdout + out.stderr).splitlines())


def status(envs):
    """One line for health: 0 ok, 1 a missing/unpublished environment, 2 cleanup available."""
    problems, notes, reclaim = [], [], 0
    for kind, root, probe in envs:
        generation = published(root).get("generation")
        if not generation or not (root / generation / ".complete").is_file():
            problems.append(f"{kind}: nothing published")
            continue
        try:
            linked = generation in probe.read_text(encoding="utf-8", errors="replace")
        except OSError:
            linked = False
        if not linked:
            problems.append(f"{kind}: {probe.name} does not run {generation}")
            continue
        reclaim += len(superseded(root, generation))
        notes.append(f"{kind} {generation[:8]}")
    runtimes = prunable()
    reclaim += runtimes
    line = ", ".join(problems + notes)
    if reclaim:
        line += f"; --clean would remove {reclaim} superseded item(s), {runtimes} of them runtimes"
    print(line)
    return 1 if problems else 2 if reclaim else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["all", "python", "lsp", "status"], default="all", nargs="?")
    parser.add_argument("--rebuild", action="store_true", help="Build a new generation from the same lock")
    parser.add_argument("--clean", action="store_true",
                        help="After a successful sync, delete superseded generations; with all, then "
                             "mise prune unless a deletion failed (exit 1)")
    args = parser.parse_args()
    base = (Path(os.environ["LOCALAPPDATA"]) / "workstation" if WINDOWS else
            Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")))
    python_root = base / ("python-env" if WINDOWS else "workstation-python")
    python_bin = base / "bin" if WINDOWS else Path.home() / ".local/bin"
    lsp_root = base / "workstation-lsp"
    suffix = ".cmd" if WINDOWS else ""
    if args.kind == "status":
        node = mise_which("node")
        return status([("python", python_root, python_bin / ("wpy" + suffix)),
                       ("lsp", lsp_root, node.parent / ("typescript-language-server" + suffix))])
    roots = []
    try:
        if args.kind in ["all", "python"]:
            install("python", python_root, python_bin, mise_which("python"), mise_which("uv"), args.rebuild)
            roots.append(python_root)
        if args.kind in ["all", "lsp"]:
            node = mise_which("node")
            # Keep the existing command locations exposed by mise's Node bins and
            # shims. Only launchers live there; dependencies have their own lock and
            # generations, and updating them never reinstalls the runtime.
            install("lsp", lsp_root, node.parent, node, rebuild=args.rebuild)
            run(["mise", "-C", Path.home(), "reshim"])
            roots.append(lsp_root)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        # Each launcher is replaced atomically, the set is not: a failed write can leave
        # earlier launchers on the new, checked generation while current.json names the old.
        sys.exit(f"tool-env: {error}\ntool-env: Sync failed; existing generations are retained. "
                 "Some launchers may already have been updated. Rerun sync to complete publication.")
    if not args.clean:
        return 0
    # Every root, even after a failure, so one stuck generation doesn't block the rest.
    if not all([clean(root) for root in roots]):
        print("tool-env: cleanup incomplete; skipped mise prune, so the generations still on disk "
              "keep their runtimes. Retry --clean once nothing runs from them.", file=sys.stderr)
        return 1
    if args.kind == "all":
        # Both environments now run on the current runtimes, so older ones are unused.
        try:
            run(["mise", "-C", Path.home(), "prune", "--yes"])
        except subprocess.CalledProcessError as error:
            print(f"tool-env: mise prune exited {error.returncode} (a runtime in use?); retry later",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"tool-env: {error}")
