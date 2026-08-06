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
