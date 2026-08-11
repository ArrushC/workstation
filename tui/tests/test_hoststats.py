from workstation_tui.core.hoststats import (
    STATS_REMOTE_SCRIPT,
    HostStats,
    parse_stats,
    stats_command,
)
from workstation_tui.core.models import HostEntry

E = HostEntry(name="a", address="127.0.0.1", user="u", group="dev_machine")


def test_stats_command_argv_exact() -> None:
    """`--` precedes the destination (hosts.conf entries bypass host-form
    validation, so a "-"-leading user/address would otherwise be
    option-parsed by ssh) and the remote script is the final single arg,
    matching fleet.py's probe_setup argv shape."""
    cmd = stats_command(E)
    assert cmd == [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "--",
        "u@127.0.0.1", STATS_REMOTE_SCRIPT,
    ]
    assert cmd[5] == "--"
    assert cmd[6] == "u@127.0.0.1"
    assert cmd[7] == STATS_REMOTE_SCRIPT
    assert len(cmd) == 8


# Realistic multi-section sample text, as the remote script would emit it
# for a fully-set-up dev host.
SAMPLE_TEXT = """\
===vitals===
uptime  10:15:01 up 3 days,  2:14,  1 user,  load average: 0.10, 0.05, 0.01
mem 1234/7951MB
disk 12345678/98765432 (13%)
kernel Linux 5.14.0-427.el9.x86_64
os Rocky Linux 9.4 (Blue Onyx)
===workstation===
repo present
commit a1b2c3d 2 hours ago
branch main
dirty 3
stamp 1733356800
drift 0
===session===
users 2
names alice bob
===tools===
chezmoi chezmoi version 2.48.0, commit abc123
git git version 2.45.0
make GNU Make 4.3
"""


def test_parse_stats_happy_path_every_field() -> None:
    stats = parse_stats(SAMPLE_TEXT)
    assert stats.uptime == (
        "10:15:01 up 3 days,  2:14,  1 user,  load average: 0.10, 0.05, 0.01"
    )
    assert stats.mem == "1234/7951MB"
    assert stats.disk == "12345678/98765432 (13%)"
    assert stats.kernel == "Linux 5.14.0-427.el9.x86_64"
    assert stats.os == "Rocky Linux 9.4 (Blue Onyx)"
    assert stats.repo_present is True
    assert stats.commit == "a1b2c3d 2 hours ago"
    assert stats.branch == "main"
    assert stats.dirty == "3"
    assert stats.stamp_epoch == "1733356800"
    assert stats.drift == "0"
    assert stats.users == "2"
    assert stats.names == "alice bob"
    assert stats.tool_chezmoi == "chezmoi version 2.48.0, commit abc123"
    assert stats.tool_git == "git version 2.45.0"
    assert stats.tool_make == "GNU Make 4.3"


def test_parse_stats_partial_vitals_only_others_none() -> None:
    text = """\
===vitals===
uptime up 1 day
mem 100/2000MB
"""
    stats = parse_stats(text)
    assert stats.uptime == "up 1 day"
    assert stats.mem == "100/2000MB"
    assert stats.disk is None
    assert stats.kernel is None
    assert stats.os is None
    assert stats.repo_present is None
    assert stats.commit is None
    assert stats.branch is None
    assert stats.dirty is None
    assert stats.stamp_epoch is None
    assert stats.drift is None
    assert stats.users is None
    assert stats.names is None
    assert stats.tool_chezmoi is None
    assert stats.tool_git is None
    assert stats.tool_make is None


def test_parse_stats_repo_absent_git_fields_stay_none() -> None:
    text = """\
===workstation===
repo absent
stamp missing
drift 0
"""
    stats = parse_stats(text)
    assert stats.repo_present is False
    assert stats.commit is None
    assert stats.branch is None
    assert stats.dirty is None
    assert stats.stamp_epoch is None
    assert stats.drift == "0"


def test_parse_stats_garbled_binary_junk_never_raises() -> None:
    junk_inputs = [
        "",
        "\x00\x01\xff garbage �",
        "no-spaces-anywhere-on-this-line",
        "===only-a-section-marker===",
        "\n\n\n   \n",
        "key-with-no-value-but-trailing-space ",
        "\ud800 lone surrogate style junk",
        "a b c d e f g h i j k l m n o p",
    ]
    for junk in junk_inputs:
        stats = parse_stats(junk)
        assert isinstance(stats, HostStats)

    empty = parse_stats("")
    assert empty == HostStats()

    none_like = parse_stats("   \n\t \n")
    assert none_like.uptime is None
    assert none_like.repo_present is None


def test_parse_stats_missing_values_map_to_none() -> None:
    text = """\
===vitals===
uptime missing
mem missing
disk missing
kernel missing
os missing
===workstation===
repo absent
===session===
users missing
names missing
===tools===
chezmoi missing
git missing
make missing
"""
    stats = parse_stats(text)
    assert stats.uptime is None
    assert stats.mem is None
    assert stats.disk is None
    assert stats.kernel is None
    assert stats.os is None
    assert stats.repo_present is False
    assert stats.users is None
    assert stats.names is None
    assert stats.tool_chezmoi is None
    assert stats.tool_git is None
    assert stats.tool_make is None


def test_parse_stats_dirty_and_drift_numeric_strings_preserved() -> None:
    text = """\
===workstation===
repo present
dirty 12
drift 7
"""
    stats = parse_stats(text)
    assert stats.dirty == "12"
    assert isinstance(stats.dirty, str)
    assert stats.drift == "7"
    assert isinstance(stats.drift, str)
