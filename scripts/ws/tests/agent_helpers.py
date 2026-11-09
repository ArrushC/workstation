"""Test utilities for `ws agent`: a scratch home whose `pueue` and `claude` are fakes, so no test
reaches the real queue or a real Claude Code session, plus git/SVN fixture repositories."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

from helpers import Scratch

HAVE_SVN = bool(shutil.which("svn") and shutil.which("svnadmin"))

# A pueue 4.0.4 `status --json`, as the real daemon printed it (captured 2026-11-06), cut to
# what ws agent reads and every field around it.
REAL_STATUS = {
    "tasks": {
        "0": {"id": 0, "label": "ws-agent:abc123", "group": "agents", "status": {"Done": {
            "enqueued_at": "2026-11-06T23:48:39.485229128Z", "start": "2026-11-06T23:48:39.675199294Z",
            "end": "2026-11-06T23:48:39.978862120Z", "result": "Success"}}},
        "1": {"id": 1, "label": None, "group": "agents", "status": {"Done": {
            "enqueued_at": "2026-11-06T23:48:39.494056936Z", "start": "2026-11-06T23:48:39.993473855Z",
            "end": "2026-11-06T23:48:40.314821674Z", "result": {"Failed": 1}}}},
        "2": {"id": 2, "label": None, "group": "agents", "status": {"Done": {
            "enqueued_at": "2026-11-06T23:48:39.503840462Z", "start": "2026-11-06T23:48:40.333018974Z",
            "end": "2026-11-06T23:48:41.557206448Z", "result": "Killed"}}},
        "3": {"id": 3, "label": None, "group": "agents", "status": {"Running": {
            "enqueued_at": "2026-11-06T23:48:39.514447418Z", "start": "2026-11-06T23:48:41.573050976Z"}}},
        "4": {"id": 4, "label": None, "group": "agents", "status": {"Stashed": {"enqueue_at": None}}},
        "5": {"id": 5, "label": None, "group": "agents", "status": {"Queued": {
            "enqueued_at": "2026-11-06T23:48:51.387887077Z"}}},
        "6": {"id": 6, "label": None, "group": "default", "status": {"Running": {
            "enqueued_at": "2026-11-06T23:48:51.387887077Z", "start": "2026-11-06T23:48:52.0Z"}}},
    },
    "groups": {"agents": {"status": "Running", "parallel_tasks": 1},
               "default": {"status": "Running", "parallel_tasks": 1}},
}

FAKE_PUEUE = r"""
d="$WS_FAKE_PUEUE"
( IFS=$'\x1f'; printf '%s\n' "$*" ) >>"$d/argv.log"
args=("$@")
[ "${args[0]}" = "-c" ] && args=("${args[@]:2}")
[ -f "$d/fail-${args[0]}" ] && { echo "fake pueue: ${args[0]} failed" >&2; exit 1; }
case "${args[0]}" in
status) [ -f "$d/status.json" ] || { echo "daemon down" >&2; exit 1; }; cat "$d/status.json" ;;
add) [ -f "$d/record-env" ] && env >"$d/add.env"; n=$(cat "$d/next" 2>/dev/null || echo 7); echo $((n + 1)) >"$d/next"; echo "$n" ;;
esac
exit 0
"""


# Every fake claude answers `claude auth status` (engines.select asks before each run) and only
# then does what the test set up.
CLAUDE_AUTH_OK = 'if [ "${1:-}" = auth ]; then echo \'{"loggedIn": true, "authMethod": "claude.ai"}\'; exit 0; fi\n'

# A fake `codex`: `login status` answers from $d/login (default logged in); `exec [resume <id>]`
# records argv/stdin/cwd, writes a session transcript, runs $d/script.sh, then prints Codex 0.166's
# JSONL events (thread.started, then turn.completed with the report in -o, or turn.failed with the
# JSON-string message in $d/fail.<n> for call n).
FAKE_CODEX = r"""
d="$WS_FAKE_CODEX"
if [ "${1:-}" = login ]; then cat "$d/login" 2>/dev/null || echo "Logged in using ChatGPT"; exit "$(cat "$d/login.rc" 2>/dev/null || echo 0)"; fi
echo x >>"$d/calls"
n=$(wc -l <"$d/calls" | tr -d ' ')
printf '%s\n' "$@" >"$d/argv"; cp "$d/argv" "$d/argv.$n"
cat >"$d/stdin"; cp "$d/stdin" "$d/stdin.$n"
pwd >"$d/cwd"
sid="T-$n" last="" prev=""
for a in "$@"; do
  case "$prev" in resume) sid="$a" ;; -o) last="$a" ;; esac
  prev="$a"
done
mkdir -p "$HOME/.codex/sessions/2026/11/07" && : >"$HOME/.codex/sessions/2026/11/07/rollout-x-$sid.jsonl"
[ -f "$d/script.sh" ] && bash "$d/script.sh"
printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n' "$sid"
if [ -f "$d/fail.$n" ]; then
  m=$(cat "$d/fail.$n")
  printf '{"type":"error","message":%s}\n{"type":"turn.failed","error":{"message":%s}}\n' "$m" "$m"
  exit 1
fi
r=$(cat "$d/report" 2>/dev/null || echo '{"status":"done","summary":"codex did it","question":null,"tests":null,"notes":null}')
[ -n "$last" ] && printf '%s' "$r" >"$last"
printf '{"type":"turn.completed","usage":{}}\n'
exit 0
"""


# A fake `gh`: logs argv, and answers `gh api [-i] [--jq .a.b] <endpoint>` from $d/<endpoint
# without its query, / as _>.json (repos/o/r/issues/comments?since=… → repos_o_r_issues_comments.json);
# a missing file is a 404. -i prints headers as gh 2.102 does (status line \n, headers \r\n), with
# X-Poll-Interval from $d/poll-interval when that exists.
FAKE_GH = r"""
d="$WS_FAKE_GH"
( IFS=$'\x1f'; printf '%s\n' "$*" ) >>"$d/argv.log"
[ "${1:-}" = api ] || { echo "fake gh: only api" >&2; exit 1; }
shift
inc=0 jq="" ep=""
while [ $# -gt 0 ]; do
  case "$1" in
  -i | --include) inc=1 ;;
  -q | --jq) jq="$2"; shift ;;
  -X | --method | -H | --header | -f | -F | --field | --raw-field) shift ;;
  -*) ;;
  *) [ -z "$ep" ] && ep="$1" ;;
  esac
  shift
done
f="$d/$(printf '%s' "${ep%%\?*}" | tr '/' '_').json"
if [ ! -f "$f" ]; then
  [ "$inc" = 1 ] && printf 'HTTP/2.0 404 Not Found\n\r\n'
  echo '{"message":"Not Found","status":"404"}'
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
if [ "$inc" = 1 ]; then
  printf 'HTTP/2.0 200 OK\nContent-Type: application/json; charset=utf-8\r\n'
  [ -f "$d/poll-interval" ] && printf 'X-Poll-Interval: %s\r\n' "$(cat "$d/poll-interval")"
  printf '\r\n'
fi
if [ -n "$jq" ]; then
  python3 -c 'import json, sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].strip(".").split("."):
    v = v[k] if k else v
print(v)' "$f" "$jq"
else
  cat "$f"
fi
"""


def no_sandbox_ws(root: Path) -> Path:
    """A stand-in for ws.py that runs `ws.py agent ...` with ws-agent's job sandbox switched off,
    for tests whose _exec runs in another process (pueue, a killed executor) and whose fakes live
    under /tmp, which the real sandbox hides. The sandbox has its own tests (test_agent_sandbox)."""
    from helpers import WS
    p = root / "ws-no-sandbox.py"
    p.write_text(f"import sys\nsys.path.insert(0, {str(WS)!r})\nfrom wslib import agent_sandbox\n"
                 "agent_sandbox.wrap = lambda argv, **kw: list(argv)\nagent_sandbox.probe = lambda **kw: None\n"
                 "from wslib import agent\nsys.exit(agent.main(sys.argv[2:]))\n", encoding="utf-8")
    return p


def git(*args: str, cwd: Path) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "init.defaultBranch=main",
                           *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def svn(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(["svn", "--non-interactive", *args], cwd=cwd, check=True, capture_output=True,
                          text=True).stdout.strip()


class AgentScratch(Scratch):
    """Scratch plus: no Claude session markers in the environment, a logging fake pueue (whose
    `status --json` answers from status.json; absent means the daemon is down), and a fake
    claude that fails unless a test replaces it."""

    def setUp(self) -> None:
        super().setUp()
        for k in [k for k in os.environ if k == "CLAUDECODE" or k.startswith("CLAUDE_CODE_")]:
            os.environ.pop(k)
        for k in ("WS_AGENT_JOB", "WS_AGENT_PUEUE_CONFIG"):
            os.environ.pop(k, None)
        self.pq = self.root / "fake-pueue"
        self.pq.mkdir()
        os.environ["WS_FAKE_PUEUE"] = str(self.pq)
        self.fake("pueue", FAKE_PUEUE)
        self.fake("claude", 'echo "fake claude: not set up by this test" >&2; exit 97')
        self.fake("codex", 'echo "fake codex: not set up by this test" >&2; exit 97')

    # --- the fake queue ------------------------------------------------------------

    def pueue_status(self, tasks: dict[int, dict[str, object]] | None = None, *, group: str = "Running",
                     parallel: int = 1, agents: bool = True) -> None:
        """Answer `pueue status --json` with these tasks ({id: {"status": ...}}, group agents)."""
        doc: dict[str, object] = {"tasks": {str(i): {"id": i, "label": None, "group": "agents", **t}
                                            for i, t in (tasks or {}).items()},
                                  "groups": {"default": {"status": "Running", "parallel_tasks": 1}}}
        if agents:
            doc["groups"]["agents"] = {"status": group, "parallel_tasks": parallel}  # type: ignore[index]
        self.write(self.pq / "status.json", json.dumps(doc))

    def pueue_calls(self) -> list[list[str]]:
        log = self.pq / "argv.log"
        if not log.exists():
            return []
        return [line.split("\x1f") for line in log.read_text(encoding="utf-8").splitlines()]

    # --- fixture repositories -------------------------------------------------------

    def git_repo(self, name: str = "proj") -> Path:
        r = self.home / "src" / name
        r.mkdir(parents=True)
        git("init", "-q", cwd=r)
        self.write(r / "app.py", "def f():\n    return 1\n")
        git("add", "-A", cwd=r)
        git("commit", "-qm", "one", cwd=r)
        return r

    def svn_repo(self) -> tuple[str, Path]:
        """file:// repository with trunk/{a.txt, run.sh, sub/b.txt, logo.bin} and a checkout of trunk."""
        repo = self.root / "svnrepo"
        subprocess.run(["svnadmin", "create", str(repo)], check=True)
        url = repo.as_uri()
        seed = self.root / "seed"
        self.write(seed / "trunk" / "a.txt", "a\n")
        self.write(seed / "trunk" / "run.sh", "#!/bin/sh\necho run\n")
        self.write(seed / "trunk" / "sub" / "b.txt", "b\n")
        self.write(seed / "trunk" / "logo.bin", bytes(range(256)))
        (seed / "branches").mkdir()
        svn("import", str(seed), url, "-m", "seed")
        wc = self.home / "src" / "svnwc"
        svn("checkout", f"{url}/trunk", str(wc))
        return url, wc
