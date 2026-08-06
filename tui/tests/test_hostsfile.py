from pathlib import Path

from workstation_tui.core.hostsfile import parse_hosts_text, read_hosts

SAMPLE = """\
# fleet
atc-cache-dev09   ***REMOVED-IP***      arrush.chaturvedi  dev_machine
cache-apl         ***REMOVED-IP***     arrush.chaturvedi  prod_machine

short-line 10.0.0.1
bad-group   10.0.0.2   user   staging_machine
"""


def test_parse_hosts_text() -> None:
    entries, errors = parse_hosts_text(SAMPLE)
    assert [(e.name, e.group) for e in entries] == [
        ("atc-cache-dev09", "dev_machine"),
        ("cache-apl", "prod_machine"),
    ]
    assert entries[0].address == "***REMOVED-IP***"
    assert entries[0].user == "arrush.chaturvedi"
    assert len(errors) == 2  # short line + invalid group


def test_read_hosts_against_real_repo(repo_root: Path) -> None:
    entries, errors = read_hosts(repo_root)
    assert errors == []
    assert len(entries) >= 2
    assert all(e.group in ("dev_machine", "prod_machine") for e in entries)


def test_read_hosts_missing_file(tmp_path: Path) -> None:
    entries, errors = read_hosts(tmp_path)  # no hosts.conf here
    assert entries == []
    assert len(errors) == 1
    assert "hosts.conf" in errors[0]


def test_read_hosts_undecodable(tmp_path: Path) -> None:
    (tmp_path / "hosts.conf").write_bytes(b"\xff\xfe\x00bad")
    entries, errors = read_hosts(tmp_path)
    assert entries == []
    assert len(errors) == 1
