from pathlib import Path

from workstation_tui.core.versions import parse_versions_text, read_versions

SAMPLE = """\
# comment line
EGET_VERSION := 1.3.4
FZF_VERSION      := 0.74.2
NB_VERSION       := latest
NOT_A_PIN = ignored        # `=` not `:=` — not the pin contract
  INDENTED_VERSION := 9.9  # indented — not a pin definition
"""


def test_parse_versions_text() -> None:
    pins = parse_versions_text(SAMPLE)
    assert pins == {
        "EGET_VERSION": "1.3.4",
        "FZF_VERSION": "0.74.2",
        "NB_VERSION": "latest",
    }


def test_read_versions_against_real_repo(repo_root: Path) -> None:
    pins = read_versions(repo_root)
    # Anchor on stable facts, not exact values: the file is large and pins move.
    assert len(pins) > 50
    assert "FZF_VERSION" in pins
    assert pins["CHEZMOI_VERSION"] == "latest"
    assert all(v and " " not in v for v in pins.values())
