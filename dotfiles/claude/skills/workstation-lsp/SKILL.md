---
name: workstation-lsp
description: Internal marker for the workstation's local LSP-server plugin. It registers installed language servers (bash, yaml, json, css, html, toml, markdown, python, c/c++, go, rust, typescript) with Claude Code's LSP tool via .lsp.json. Not a user-invocable skill — do not invoke it.
---

# workstation-lsp (internal)

This directory is a Claude Code **skills-dir plugin** whose only purpose is to
register the workstation toolbelt's installed language servers with Claude Code's
`LSP` tool (see the sibling `.lsp.json`). It exposes no user-facing skill behavior.

- **Server binaries** come from mise (`config.toml`, installed by
  `mise bootstrap` / `./bootstrap.sh`; plus clangd from the
  C/C++ dnf group). This plugin only *registers* them; it installs nothing.
- **Diagnostics** are on by default; to silence one server, add `"diagnostics": false`
  to its entry in `.lsp.json`.
- **clangd** takes every extension the official `clangd-lsp` plugin does (`.hxx`, `.C`
  and `.H` too) and runs with clangd's default background index, so that plugin adds
  nothing but a second clangd: `settings.enforced.json` turns it off, and
  `check_claude_config` keeps it off.
- Source of truth is this repo's checkout: `dotfiles/claude/skills/workstation-lsp/` (deployed to `~/.claude/skills/workstation-lsp/` via mise dotfiles).
