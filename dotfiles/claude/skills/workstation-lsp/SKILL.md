---
name: workstation-lsp
description: Internal marker for the workstation's local LSP-server plugin. It registers installed language servers (bash, yaml, json, css, html, toml, markdown, python, c/c++, go, rust, typescript) with Claude Code's LSP tool via .lsp.json. Not a user-invocable skill — do not invoke it.
---

# workstation-lsp (internal)

This directory is a Claude Code **skills-dir plugin** whose only purpose is to
register the workstation toolbelt's installed language servers with Claude Code's
`LSP` tool (see the sibling `.lsp.json`). It exposes no user-facing skill behavior.

- **Server binaries** come from mise (`config.toml`, installed by
  `mise bootstrap` / `./bootstrap.sh`). This plugin only *registers* them; it installs nothing.
- **Diagnostics** are on by default; to silence one server, add `"diagnostics": false`
  to its entry in `.lsp.json`.
- **C/C++** is clice (`clice serve`, mise's `github:clice-io/clice`), for every extension the
  official `clangd-lsp` plugin takes (`.hxx`, `.C` and `.H` too). That plugin would start
  a second server for the same files, so `settings.enforced.json` keeps it off.
- Source of truth is this repo's checkout: `dotfiles/claude/skills/workstation-lsp/` (deployed to `~/.claude/skills/workstation-lsp/` via mise dotfiles).
