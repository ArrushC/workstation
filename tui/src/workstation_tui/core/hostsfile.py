"""Parse hosts.conf (READ-ONLY — every write goes through manage-hosts; never raises).

Format (manage-hosts re-pads on save): one host per line,
`name  address  user  group`, whitespace-separated; blank lines and
full-line `#` comments allowed.
"""

from pathlib import Path

from pydantic import ValidationError

from workstation_tui.core.models import HostEntry


def parse_hosts_text(text: str) -> tuple[list[HostEntry], list[str]]:
    entries: list[HostEntry] = []
    errors: list[str] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 4:
            errors.append(f"line {lineno}: expected 4 fields, got {len(parts)}: {line!r}")
            continue
        try:
            entries.append(
                HostEntry(name=parts[0], address=parts[1], user=parts[2], group=parts[3])
            )
        except ValidationError as exc:
            errors.append(f"line {lineno}: {exc.errors()[0]['msg']}: {line!r}")
    return entries, errors


def read_hosts(repo_root: Path) -> tuple[list[HostEntry], list[str]]:
    try:
        text = (repo_root / "hosts.conf").read_text(encoding="utf-8")
    except OSError as exc:
        return [], [f"hosts.conf unreadable: {exc}"]
    except UnicodeDecodeError as exc:
        return [], [f"hosts.conf undecodable: {exc}"]
    return parse_hosts_text(text)
