"""Quick-stats remote script + never-raise parser for HostStatsScreen.

`stats_command` builds the ssh argv that runs `STATS_REMOTE_SCRIPT` on a
`HostEntry` — a single BatchMode ssh, hardened the same way as
`fleet.probe_setup` (`--` precedes the destination so a "-"-leading
user/address from hosts.conf can't be option-parsed by ssh). The remote
script itself is POSIX sh, degrades every probe to a `missing` value on
failure, and never exits non-zero on a partial host — callers can always
run it and always get *some* text back to feed `parse_stats`.

`parse_stats` is the pure counterpart: it never raises on any input,
including empty text, garbled non-UTF8-looking junk, or a decoded remote
script's stderr leaking into stdout. Unknown keys and lines without a
space are silently ignored; the `===...===` section markers are purely
informational (all keys are globally unique, so no key->field mapping
needs section context).
"""

from dataclasses import dataclass

from workstation_tui.core.models import HostEntry

# Verbatim POSIX-sh remote probe script (spec §2, task-4 brief). Do not
# "improve" it — tested against EL9 remotes as-is. The chezmoi PATH
# fallback ($HOME/.local/bin/chezmoi) exists because non-interactive prod
# ssh doesn't source rc PATH.
STATS_REMOTE_SCRIPT = """\
echo '===vitals==='
echo "uptime $(uptime 2>/dev/null || echo missing)"
echo "mem $(free -m 2>/dev/null | awk 'NR==2 {print $3"/"$2"MB"}' || echo missing)"
echo "disk $(df -P / 2>/dev/null | awk 'NR==2 {print $3"/"$2" ("$5")"}' || echo missing)"
echo "kernel $(uname -sr 2>/dev/null || echo missing)"
echo "os $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo missing)"
echo '===workstation==='
repo="$HOME/.local/share/chezmoi"
if [ -d "$repo" ]; then
  echo "repo present"
  echo "commit $(git -C "$repo" log -1 --format='%h %cr' 2>/dev/null || echo missing)"
  echo "branch $(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo missing)"
  echo "dirty $(git -C "$repo" status --porcelain 2>/dev/null | wc -l)"
else
  echo "repo absent"
fi
stampdir="$HOME/.local/share/workstation-install"
newest=$(ls -t "$stampdir" 2>/dev/null | head -1)
if [ -n "$newest" ]; then
  echo "stamp $(stat -c %Y "$stampdir/$newest" 2>/dev/null || echo missing)"
else
  echo "stamp missing"
fi
cz="$(command -v chezmoi || echo "$HOME/.local/bin/chezmoi")"
echo "drift $("$cz" status 2>/dev/null | wc -l | tr -d ' ' || echo missing)"
echo '===session==='
echo "users $(who 2>/dev/null | wc -l | tr -d ' ' || echo missing)"
echo "names $(who 2>/dev/null | awk '{print $1}' | sort -u | tr '\\n' ' ' || echo missing)"
echo '===tools==='
echo "chezmoi $("$cz" --version 2>/dev/null | head -1 || echo missing)"
echo "git $(git --version 2>/dev/null || echo missing)"
echo "make $(make --version 2>/dev/null | head -1 || echo missing)"
"""


def stats_command(entry: HostEntry) -> list[str]:
    """Build the ssh argv that runs `STATS_REMOTE_SCRIPT` on `entry`.

    Same hardening as `fleet.probe_setup`: BatchMode (never prompts), a
    short ConnectTimeout, and `--` before the destination so a
    "-"-leading user/address can't be option-parsed by ssh.
    """
    return [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--",
        f"{entry.user}@{entry.address}", STATS_REMOTE_SCRIPT,
    ]


@dataclass
class HostStats:
    """Parsed quick-stats for one host — every field optional; a probe
    that failed remotely (or a host that's simply too old/minimal to
    answer it) degrades to None rather than a partial/garbled value."""

    uptime: str | None = None
    mem: str | None = None
    disk: str | None = None
    kernel: str | None = None
    os: str | None = None
    repo_present: bool | None = None
    commit: str | None = None
    branch: str | None = None
    dirty: str | None = None
    stamp_epoch: str | None = None
    drift: str | None = None
    users: str | None = None
    names: str | None = None
    tool_chezmoi: str | None = None
    tool_git: str | None = None
    tool_make: str | None = None


# key -> HostStats field name, for the plain `key value` lines. "repo" is
# handled separately (its value is "present"/"absent", mapped to a bool).
_KEY_TO_FIELD = {
    "uptime": "uptime",
    "mem": "mem",
    "disk": "disk",
    "kernel": "kernel",
    "os": "os",
    "commit": "commit",
    "branch": "branch",
    "dirty": "dirty",
    "stamp": "stamp_epoch",
    "drift": "drift",
    "users": "users",
    "names": "names",
    "chezmoi": "tool_chezmoi",
    "git": "tool_git",
    "make": "tool_make",
}


def parse_stats(text: str) -> HostStats:
    """Parse `STATS_REMOTE_SCRIPT` output into a `HostStats`.

    Never raises, on any input: empty/None-ish text, decoded binary
    junk, lines with no space, unrecognized keys, or a `===...===`
    section marker are all tolerated and simply contribute nothing.
    `===...===` markers switch a tracked "current section" but it's
    informational only — every key below is globally unique, so no
    key->field mapping needs section context to disambiguate.
    """
    stats = HostStats()
    if not text:
        return stats

    try:
        lines = text.splitlines()
    except Exception:
        return stats

    section = None
    for line in lines:
        try:
            if not isinstance(line, str):
                continue
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("===") and stripped.endswith("==="):
                section = stripped
                continue
            if " " not in stripped:
                continue
            key, _, rest = stripped.partition(" ")
            value = rest.strip()

            if key == "repo":
                if value == "present":
                    stats.repo_present = True
                elif value == "absent":
                    stats.repo_present = False
                continue

            field = _KEY_TO_FIELD.get(key)
            if field is None:
                continue
            if not value or value == "missing":
                continue
            setattr(stats, field, value)
        except Exception:
            continue

    return stats
