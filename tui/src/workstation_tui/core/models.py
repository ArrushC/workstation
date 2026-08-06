"""Shared pydantic models — the contract between core readers, CLI, and app."""

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel


class StampState(StrEnum):
    FRESH = "fresh"      # exact stamp for the pinned version exists
    STALE = "stale"      # a stamp exists, but only for another version
    MISSING = "missing"  # no stamp at all


class InventoryRow(BaseModel):
    """One `kind|name|version` row from `make inventory` (DOCTOR_ROWS)."""

    kind: Literal["scope", "user", "bespoke"]
    name: str
    version: str  # pin, "latest", "-", or "<ver>-<hash>" for hashed stamps


class ToolStatus(BaseModel):
    name: str
    kind: str
    version: str
    state: StampState


class HostEntry(BaseModel):
    """One padded row of hosts.conf: name, address, user, group."""

    name: str
    address: str
    user: str
    group: Literal["dev_machine", "prod_machine"]


class HostContext(BaseModel):
    """Host identity + capability flags, resolved once at startup."""

    os: Literal["linux", "windows"]
    is_wsl: bool
    group: str | None  # from `chezmoi data` .group; None when undetectable
    mode: Literal["dev", "prod"]
    has_make: bool
    has_chezmoi: bool
    has_systemctl: bool
    has_sudo: bool


class PendingChange(BaseModel):
    """One `XY path` row of `chezmoi status`."""

    code: str  # two-char chezmoi status code, e.g. "MM", " A"
    path: str


class Summary(BaseModel):
    """Dashboard rollup consumed by `workstation status` (and the Phase 3 dashboard)."""

    context: HostContext
    tools_total: int
    tools_fresh: int
    tools_stale: int
    tools_missing: int
    inventory_errors: list[str]
    dotfiles_pending: int
    dotfiles_errors: list[str]
    hosts_total: int
    hosts_dev: int
    hosts_prod: int
    hosts_errors: list[str]
