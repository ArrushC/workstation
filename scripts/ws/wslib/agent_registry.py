"""The repositories queued agent jobs (`ws agent run`) may work in, and how: one per-host file,
~/.config/workstation/agents.toml, written only by `ws agent allow`/`disallow`.

Those two refuse inside a Claude Code session (CLAUDECODE=1): which repositories an
unattended agent may touch, and which engines (model providers) may read their code, is the
person's decision, made in their own terminal.

The writer keeps every table and key it doesn't know (a newer ws, or a hand edit), and never
overwrites a file it can't parse: it raises Unreadable instead. Readers treat such a file as
empty, so a session's hook keeps working with nothing allowed.
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import json
import os
import re
import tomllib
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from . import core

HEADER = "# ws-agent: repositories queued jobs may work in (per host). Edit with ws-agent allow/disallow.\n"
REFUSAL = ("ws-agent: a Claude Code session can't change which repositories jobs may use; "
           "run this in your own terminal")
KNOWN_ENGINES = ("claude", "codex")
DEFAULT_PARALLEL = 2


class Refused(Exception):
    pass


class Unreadable(Exception):
    """The registry exists but isn't valid TOML: writers refuse rather than overwrite it."""


MODES = ("off", "observe", "act")
# An SSH destination as `ws-agent fleet` passes it to ssh: an alias or user@host, never an option.
HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._-]*)?$")
_INTERVAL = re.compile(r"^\d+[smhd]?$")


@dataclass(frozen=True)
class Watch:
    """`[repo."<key>".watch]`: SVN URLs whose new revisions become candidates."""
    urls: tuple[str, ...]
    mode: str = "observe"
    authors: tuple[str, ...] = ()
    rules: tuple[str, ...] = ()
    interval: str = "5m"


@dataclass(frozen=True)
class GitHubSource:
    """`[repo."<key>".github]`: `/agent` comments by these logins on this github.com repository."""
    slug: str = ""
    mode: str = "observe"
    logins: tuple[str, ...] = ()


@dataclass(frozen=True)
class Repo:
    path: Path
    vcs: str
    commands: tuple[str, ...] = ()
    allowed_at: str = ""
    engines: tuple[str, ...] = ("claude",)
    checks: tuple[str, ...] = ()
    fix_rounds: int = 1
    review: str = ""
    network: bool = False
    watch: Watch | None = None
    github: GitHubSource | None = None


@dataclass(frozen=True)
class EngineSettings:
    parallel: int = 1
    model: str = ""


@dataclass(frozen=True)
class Settings:
    parallel: int = DEFAULT_PARALLEL
    engines: Mapping[str, EngineSettings] = field(default_factory=dict)
    hide: tuple[Path, ...] = ()
    desktop: bool = True
    fleet: tuple[str, ...] = ()   # SSH host aliases `ws-agent fleet` asks

    def engine(self, name: str) -> EngineSettings:
        return self.engines.get(name, EngineSettings())


def registry_path() -> Path:
    return core.config_dir() / "agents.toml"


def _key(root: Path) -> str:
    return core.tilde(root.resolve())


def _read_strict() -> dict[str, object]:
    try:
        text = registry_path().read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except OSError as e:
        raise Unreadable(f"ws-agent: can't read {core.tilde(registry_path())}: {e.strerror}") from e
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise Unreadable(f"ws-agent: {core.tilde(registry_path())} isn't valid TOML ({e}); "
                         "fix or remove it by hand: ws-agent won't overwrite it") from e


def _read() -> dict[str, object]:
    try:
        return _read_strict()
    except Unreadable:
        return {}


def _strings(value: object) -> tuple[str, ...]:
    return tuple(str(v) for v in value) if isinstance(value, list) else ()


def _mode(value: object) -> str:
    """A hand-written mode ws-agent doesn't know is read as off: never act on a typo."""
    return str(value) if str(value) in MODES else "off"


def _watch(t: object) -> Watch | None:
    if not isinstance(t, dict):
        return None
    interval = str(t.get("interval", "5m"))
    return Watch(_strings(t.get("urls", [])), _mode(t.get("mode", "observe")), _strings(t.get("authors", [])),
                 _strings(t.get("rules", [])), interval if _INTERVAL.match(interval) else "5m")


def _github(t: object) -> GitHubSource | None:
    if not isinstance(t, dict):
        return None
    return GitHubSource(str(t.get("slug", "")), _mode(t.get("mode", "observe")), _strings(t.get("logins", [])))


def _repo(key: str, entry: Mapping[str, object]) -> Repo:
    engines = tuple(e for e in _strings(entry.get("engines", ["claude"])) if e in KNOWN_ENGINES) or ("claude",)
    rounds = entry.get("fix_rounds", 1)
    review = str(entry.get("review", ""))
    return Repo(core.expand(key), str(entry.get("vcs", "")), _strings(entry.get("commands", [])),
                str(entry.get("allowed_at", "")), engines, _strings(entry.get("checks", [])),
                rounds if isinstance(rounds, int) and not isinstance(rounds, bool) and rounds >= 0 else 1,
                review if review in engines else "", entry.get("network") is True,
                _watch(entry.get("watch")), _github(entry.get("github")))


def _repos(data: Mapping[str, object]) -> dict[str, Repo]:
    table = data.get("repo")
    return {k: _repo(k, v) for k, v in (table.items() if isinstance(table, dict) else []) if isinstance(v, dict)}


def _positive(value: object, default: int) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 1 else default


def _settings(data: Mapping[str, object]) -> Settings:
    queue = data.get("queue") if isinstance(data.get("queue"), dict) else {}
    engines_t = data.get("engines") if isinstance(data.get("engines"), dict) else {}
    sandbox = data.get("sandbox") if isinstance(data.get("sandbox"), dict) else {}
    notify = data.get("notify") if isinstance(data.get("notify"), dict) else {}
    assert isinstance(queue, dict) and isinstance(engines_t, dict) and isinstance(sandbox, dict) and isinstance(notify, dict)
    engines = {str(n): EngineSettings(_positive(t.get("parallel"), 1), str(t.get("model", "")))
               for n, t in engines_t.items() if isinstance(t, dict)}
    hide = tuple(core.expand(h) for h in _strings(sandbox.get("hide", [])))
    fleet_t = data.get("fleet") if isinstance(data.get("fleet"), dict) else {}
    assert isinstance(fleet_t, dict)
    fleet = tuple(h for h in _strings(fleet_t.get("hosts", [])) if HOST.match(h))
    return Settings(_positive(queue.get("parallel"), DEFAULT_PARALLEL), engines, hide, notify.get("desktop") is not False,
                    fleet)


def load() -> tuple[dict[str, Repo], int]:
    data = _read()
    return _repos(data), _settings(data).parallel


def settings() -> Settings:
    return _settings(_read())


def find(root: Path) -> Repo | None:
    return load()[0].get(_key(root))


def _guard() -> None:
    if os.environ.get("CLAUDECODE") == "1":
        raise Refused(REFUSAL)


# --- writing: a small TOML emitter that keeps what it doesn't know ---------------------------

_BARE = re.compile(r"^[A-Za-z0-9_-]+$")


def _str(s: str) -> str:
    """A TOML basic string. json's escapes are TOML's, except that ensure_ascii would write a
    character outside the BMP as a surrogate pair, which TOML rejects; keep it literal."""
    return json.dumps(s, ensure_ascii=False)


def _k(key: str) -> str:
    return key if _BARE.match(key) else _str(key)


def _value(v: object) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, (dt.datetime, dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, list):
        return "[" + ", ".join(_value(x) for x in v) + "]"
    if isinstance(v, dict):   # an inline table inside an array or value position
        return "{ " + ", ".join(f"{_k(str(k))} = {_value(x)}" for k, x in v.items()) + " }"
    return _str(str(v))


def _emit(table: Mapping[str, object], path: list[str], out: list[str]) -> None:
    scalars = [(k, v) for k, v in table.items() if not isinstance(v, dict)]
    tables = [(k, v) for k, v in table.items() if isinstance(v, dict)]
    if path and (scalars or not tables):
        out.append("\n[" + ".".join(_k(p) for p in path) + "]\n")
    out += [f"{_k(k)} = {_value(v)}\n" for k, v in scalars]
    for k, v in tables:
        assert isinstance(v, dict)
        _emit(v, [*path, k], out)


def _entry(r: Repo, old: Mapping[str, object]) -> dict[str, object]:
    known = {"vcs": r.vcs, "commands": list(r.commands), "allowed_at": r.allowed_at, "engines": list(r.engines),
             "checks": list(r.checks), "fix_rounds": r.fix_rounds, "review": r.review, "network": r.network}
    out: dict[str, object] = {**known, **{k: v for k, v in old.items() if k not in known and k not in ("watch", "github")}}
    for name, table in (("watch", None if r.watch is None else {
            "urls": list(r.watch.urls), "mode": r.watch.mode, "authors": list(r.watch.authors),
            "rules": list(r.watch.rules), "interval": r.watch.interval}),
            ("github", None if r.github is None else {
                "slug": r.github.slug, "mode": r.github.mode, "logins": list(r.github.logins)})):
        if table is not None:   # keys a newer ws wrote inside the table survive too
            prev = old.get(name)
            out[name] = {**(prev if isinstance(prev, dict) else {}), **table}
    return out


def _write(data: dict[str, object], repos: dict[str, Repo]) -> None:
    old_table = data.get("repo") if isinstance(data.get("repo"), dict) else {}
    assert isinstance(old_table, dict)
    data = dict(data)
    entries: dict[str, object] = {}
    for k, r in sorted(repos.items()):
        prev = old_table.get(k)
        entries[k] = _entry(r, prev if isinstance(prev, dict) else {})
    data["repo"] = entries
    out = [HEADER]
    _emit(data, [], out)
    core.atomic_write(registry_path(), "".join(out).encode("utf-8"))


def allow(root: Path, vcs: str, commands: list[str] | tuple[str, ...], *, engines: tuple[str, ...] = ("claude",),
          checks: tuple[str, ...] = (), fix_rounds: int = 1, review: str = "", network: bool = False) -> Repo:
    _guard()
    if not engines or any(e not in KNOWN_ENGINES for e in engines):
        raise ValueError(f"ws-agent: engines must be some of {', '.join(KNOWN_ENGINES)} (got {', '.join(engines) or 'none'})")
    if review and review not in engines:
        raise ValueError(f"ws-agent: --review {review} isn't one of this repository's engines ({', '.join(engines)})")
    if fix_rounds < 0:
        raise ValueError("ws-agent: --fix-rounds can't be negative")
    data = _read_strict()
    repos = _repos(data)
    prev = repos.get(_key(root))
    repo = Repo(root.resolve(), vcs, tuple(commands), core.now_iso(), tuple(dict.fromkeys(engines)), tuple(checks),
                fix_rounds, review, network, prev.watch if prev else None, prev.github if prev else None)
    repos[_key(root)] = repo
    _write(data, repos)
    return repo


def _set_source(root: Path, **change: object) -> Repo:
    _guard()
    data = _read_strict()
    repos = _repos(data)
    key = _key(root)
    if key not in repos:
        raise KeyError(f"ws-agent: {key} isn't allowed for queued jobs; run 'ws-agent allow {key}' first")
    repo = dataclasses.replace(repos[key], **change)  # type: ignore[arg-type]
    repos[key] = repo
    _write(data, repos)
    return repo


def set_watch(root: Path, watch: Watch | None) -> Repo:
    """Watch these SVN URLs for new revisions (None stops watching). The person's own terminal only."""
    _guard()
    if watch is not None:
        found = find(root)
        if found is not None and found.vcs != "svn":
            raise ValueError(f"ws-agent: {_key(root)} is a {found.vcs} repository; only SVN URLs can be watched")
        if not watch.urls:
            raise ValueError("ws-agent: watch needs at least one --url (e.g. ^/trunk)")
        if watch.mode not in MODES:
            raise ValueError(f"ws-agent: --mode must be one of {', '.join(MODES)}")
        if not _INTERVAL.match(watch.interval):
            raise ValueError(f"ws-agent: --interval {watch.interval!r} isn't a duration like 5m")
    return _set_source(root, watch=watch)


def set_github(root: Path, src: GitHubSource | None) -> Repo:
    """Take `/agent` requests from these logins' comments (None stops it). The person's own terminal only."""
    _guard()
    if src is not None:
        found = find(root)
        if found is not None and found.vcs != "git":
            raise ValueError(f"ws-agent: {_key(root)} is a {found.vcs} repository; GitHub needs a git one")
        if not src.slug:
            raise ValueError(f"ws-agent: {_key(root)} has no github.com remote")
        if not src.logins:
            raise ValueError("ws-agent: name who may ask with --login (nobody can, otherwise)")
        if src.mode not in MODES:
            raise ValueError(f"ws-agent: --mode must be one of {', '.join(MODES)}")
    return _set_source(root, github=src)


def set_fleet(hosts: tuple[str, ...]) -> None:
    """The hosts `ws-agent fleet` asks over SSH. The person's own terminal only: the list says
    where this host runs commands."""
    _guard()
    for h in hosts:
        if not HOST.match(h):
            raise ValueError(f"ws-agent: {h!r} isn't an SSH host alias (letters, digits, . _ -, optionally user@)")
    data = _read_strict()
    old = data.get("fleet") if isinstance(data.get("fleet"), dict) else {}
    assert isinstance(old, dict)
    data = {**data, "fleet": {**old, "hosts": list(dict.fromkeys(hosts))}}
    _write(data, _repos(data))


def disallow(root: Path) -> bool:
    _guard()
    data = _read_strict()
    repos = _repos(data)
    if repos.pop(_key(root), None) is None:
        return False
    _write(data, repos)
    return True
