---
name: workstation-lsp
description: Internal marker for the workstation's local LSP-server plugin. It registers installed language servers (bash, yaml, json, css, html, toml, markdown, python, c/c++, go, rust, typescript) with Claude Code's LSP tool via .lsp.json. Not a user-invocable skill — do not invoke it.
---

# workstation-lsp (internal)

This directory is a Claude Code **skills-dir plugin** whose only purpose is to
register the workstation toolbelt's installed language servers with Claude Code's
`LSP` tool (see the sibling `.lsp.json`). It exposes no user-facing skill behavior.

- **Server binaries** come from mise (`config.dev.toml`, installed by
  `mise bootstrap` / `./bootstrap.sh --dev`; plus clangd from the C/C++ dnf
  group). This plugin only *registers* them; it installs nothing.
- **Diagnostics** are on by default; to silence one server, add `"diagnostics": false`
  to its entry in `.lsp.json`.
- Source of truth is chezmoi: `chezmoi/private_dot_claude/skills/workstation-lsp/`.
