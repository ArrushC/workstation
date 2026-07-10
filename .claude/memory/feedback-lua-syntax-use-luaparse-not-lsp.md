---
name: feedback-lua-syntax-use-luaparse-not-lsp
description: For verifying Lua (e.g. wezterm.lua) syntax in this repo, use a luaparse check, not the LSP tool.
metadata:
  type: feedback
---

When verifying Lua syntax in this repo (e.g. edits to `chezmoi/dot_config/wezterm/wezterm.lua`), use a **luaparse**-based syntax check, **not** the LSP tool. The user explicitly instructed "do not use LSPs for this" during the wezterm local-Nushell-default change (2026-06-26), and the earlier wezterm-line-count-footer feature likewise stood up a luaparse harness instead of using LSP.

**Why:** The host's global CLAUDE.md defaults to LSP-first, but for these Lua config edits that default is overridden — `lua-language-server` adds false-positive noise (e.g. "undefined global `wezterm`") and was a source of friction this session (subagents dispatched to use the LSP tool stalled/errored twice and had to be stopped). A plain parser gives a clean pass/fail with no environment fuss.

**How to apply:** Run `node /tmp/lua-syntax-check/check.js <file>` → prints `SYNTAX OK` / exit 0 on valid Lua, `SYNTAX ERROR` / non-zero otherwise. The harness lives under `/tmp` (ephemeral — recreate if gone): a `package.json` depending on `luaparse` ^0.3.1, plus a `check.js` that reads the file and calls `luaparse.parse(src, { luaVersion: '5.3' })`. `node` is available on this host. Don't reach for the LSP tool for Lua syntax verification unless the user asks. See also [[feedback-skip-redundant-final-review]] for the related subagent-driven-development workflow trims the user prefers.
