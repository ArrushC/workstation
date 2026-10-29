"""Workstation commands that mise already implements; never duplicate its logic."""

from __future__ import annotations

from . import core

DOT_COMMANDS = {
    "edit": ("edit",), "diff": ("diff",), "status": ("status",),
    "record": ("add", "--changed"),
}


def delegated(command: str, args: list[str]) -> int:
    if command in DOT_COMMANDS:
        return core.mise("dot", *DOT_COMMANDS[command], *args, capture=False).returncode
    if command == "update":
        task = "update-windows" if core.IS_WINDOWS else "update"
        return core.mise("run", task, *args, capture=False).returncode
    raise ValueError(f"unknown delegated command: {command}")
