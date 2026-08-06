"""Read tool version pins from makefile/versions.mk.

The pin contract (see versions.mk header): every pin is a top-of-line
`SOMENAME_VERSION := value` assignment. Anything else — comments, `=`
assignments, indented lines — is not a pin.
"""

import re
from pathlib import Path

_PIN_RE = re.compile(r"^([A-Z0-9_]+_VERSION)\s*:=\s*(\S+)", re.MULTILINE)


def parse_versions_text(text: str) -> dict[str, str]:
    return {m.group(1): m.group(2) for m in _PIN_RE.finditer(text)}


def read_versions(repo_root: Path) -> dict[str, str]:
    return parse_versions_text(
        (repo_root / "makefile" / "versions.mk").read_text(encoding="utf-8")
    )
