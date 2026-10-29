"""Hyperfine owns timing; ws keeps the results and their revision/host context."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import core, history


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="ws bench", description="Keep hyperfine measurements with Git and machine metadata.")
    sub = p.add_subparsers(dest="action", required=True)
    run = sub.add_parser("run", help="benchmark a quoted shell command, e.g. ws bench run 'mise run build'")
    run.add_argument("command")
    run.add_argument("--label", default="")
    run.add_argument("--runs", type=int, default=10)
    run.add_argument("--warmup", type=int, default=1)
    listing = sub.add_parser("list")
    listing.add_argument("--json", action="store_true")
    compare = sub.add_parser("compare")
    compare.add_argument("baseline")
    compare.add_argument("candidate", nargs="?", default="latest")
    compare.add_argument("--allow-mismatch", action="store_true", help="compare different hosts, directories or commands")
    a = p.parse_args(argv)
    try:
        if a.action == "run":
            if a.runs < 2 or a.warmup < 0:
                return core.die("--runs must be >= 2 and --warmup >= 0", 2)
            path = history.create("bench")
            data = {**history.context(Path.cwd()), "id": path.name, "label": a.label, "command": a.command,
                    "runs": a.runs, "warmup": a.warmup, "status": "running"}
            history.save(path, data)
            result = path / "hyperfine.json"
            # A quoted command is intentionally shell syntax, as in hyperfine itself.
            code = core.run(["mise", "exec", "hyperfine", "--", "hyperfine", "--runs", str(a.runs),
                             "--warmup", str(a.warmup), "--export-json", str(result), "--", a.command],
                            capture=False).returncode
            data.update(status="finished", exit_code=code, ended=core.now_iso())
            if code == 0:
                data["result"] = json.loads(result.read_text(encoding="utf-8"))["results"][0]
            history.save(path, data)
            print(f"ws bench: {path.name}")
            return code
        if a.action == "list":
            items = history.records("bench")
            if a.json:
                print(json.dumps(items, indent=2))
            else:
                for r in items:
                    mean = r.get("result", {}).get("mean")
                    timing = f"{mean:.4f}s" if mean is not None else f"exit={r.get('exit_code', '?')}"
                    print(f"{r['id']}  {timing}  {r.get('revision', '')[:10]}  {r['host']}  {r['label']}  {r['command']}")
            return 0
        _, before = history.find("bench", a.baseline)
        _, after = history.find("bench", a.candidate)
        differences = [key for key in ("host", "platform", "cwd", "command") if before[key] != after[key]]
        if differences and not a.allow_mismatch:
            return core.die("comparison differs in " + ", ".join(differences) + "; use --allow-mismatch to compare explicitly", 2)
        if "result" not in before or "result" not in after:
            return core.die("both benchmarks must have completed successfully", 2)
        old, new = before["result"]["mean"], after["result"]["mean"]
        print(f"{before['id']}: {old:.6f}s\n{after['id']}: {new:.6f}s")
        if old > 0:
            print(f"Mean elapsed time: {(new / old - 1) * 100:+.2f}% (negative is faster)")
        print("Compare the recorded spread as well as the mean; this is not a significance test.")
        for r in (before, after):
            print(f"  {r['id']}: stddev={r['result'].get('stddev')}  revision={r['revision']}  dirty={r['dirty']}")
        return 0
    except (OSError, ValueError, KeyError) as error:
        return core.die(str(error))
