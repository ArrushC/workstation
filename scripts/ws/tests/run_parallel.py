"""Run the ws tests one TestCase class per worker process, and say what was skipped.

`python -m unittest discover` runs the 600-odd tests in one process, one after another;
most of the time is subprocess-heavy agent tests that share nothing (each builds its own
scratch home). test-ws.sh runs this instead. Output: failures in unittest's own format,
then one `skipped N: <reason>` line per reason, then `Ran N tests (K skipped)`. Exit 1
on any failure or error, or when nothing ran.

    python run_parallel.py [-j N] [name ...]      # names as unittest takes them
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import io
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def classes(suite: unittest.TestSuite) -> list[str]:
    """Every `module.Class` in the suite, in discovery order. A module that failed to import
    comes back as unittest's `_FailedTest` stand-in, which is kept by its full test id."""
    seen: dict[str, None] = {}
    stack = [suite]
    while stack:
        item = stack.pop()
        if isinstance(item, unittest.TestSuite):
            stack.extend(reversed(list(item)))
        elif type(item).__module__.startswith("unittest."):
            seen[item.id()] = None
        else:
            seen[f"{type(item).__module__}.{type(item).__qualname__}"] = None
    return list(seen)


def run(name: str) -> tuple[str, int, list[str], str, bool]:
    """Run one name in this (worker) process: (name, tests run, skip reasons, report, ok)."""
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    out = io.StringIO()
    try:
        suite = unittest.defaultTestLoader.loadTestsFromName(name)
        result = unittest.TextTestRunner(stream=out, verbosity=0).run(suite)
    except BaseException as e:  # a worker must report, never vanish  # noqa: BLE001
        return name, 0, [], f"ERROR: {name}\n{type(e).__name__}: {e}\n", False
    return name, result.testsRun, [r for _, r in result.skipped], out.getvalue(), result.wasSuccessful()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", "--jobs", type=int, default=int(os.environ.get("WS_TEST_JOBS") or 0))
    ap.add_argument("names", nargs="*")
    args = ap.parse_args(argv)
    sys.path.insert(0, str(HERE))
    loader = unittest.defaultTestLoader
    if args.names:
        suite = unittest.TestSuite(loader.loadTestsFromName(n) for n in args.names)
    else:
        suite = loader.discover(str(HERE), pattern="test_*.py", top_level_dir=str(HERE))
    names = classes(suite)
    jobs = args.jobs if args.jobs > 0 else min(8, os.cpu_count() or 1)
    if jobs == 1 or len(names) < 2:
        results = [run(n) for n in names]
    else:
        # spawn, not fork: a worker starts from a clean interpreter, as a lone
        # `python -m unittest <name>` would, whatever the tests above it patched.
        import multiprocessing

        with concurrent.futures.ProcessPoolExecutor(jobs, mp_context=multiprocessing.get_context("spawn")) as pool:
            results = list(pool.map(run, names))
    ran = sum(r[1] for r in results)
    skips = collections.Counter(reason for r in results for reason in r[2])
    failed = [r for r in results if not r[4]]
    for name, _, _, report, _ in failed:
        print(f"--- {name}")
        print(report.rstrip())
    for reason, n in sorted(skips.items()):
        print(f"skipped {n}: {reason}")
    total = sum(skips.values())
    print(f"Ran {ran} tests ({total} skipped)")
    if failed:
        print(f"FAILED ({len(failed)} of {len(names)} test classes)")
        return 1
    if not ran:
        print("FAILED (no tests ran)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
