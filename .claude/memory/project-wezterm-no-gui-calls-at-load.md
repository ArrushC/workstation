---
name: project-wezterm-no-gui-calls-at-load
description: Never call wezterm.gui.* (screens, enumerate_gpus) in code that runs at config load (wezterm.lua or a module); it deadlocks WezTerm before the GUI exists, and pcall can't catch a hang.
metadata:
  type: project
---

In `dotfiles/config/wezterm/` (`wezterm.lua` and the modules it requires), never call `wezterm.gui.*` (e.g. `wezterm.gui.screens()`,
`wezterm.gui.enumerate_gpus()`) in the code that runs when the config loads. Those need a GUI that
doesn't exist yet and deadlock WezTerm into an unresponsive window that only a force-kill of
`wezterm-gui.exe` recovers.

**Why:** the retired WezTerm setup (removed in 17a4148, revived 2026-10-12) shipped exactly this in its
PR #39, to make `max_fps` adaptive per screen; WezTerm froze on launch and #40 reverted it. `pcall`
catches thrown errors, not hangs, and the lint harness (`check_wezterm_config`) runs a stand-in
module, so neither catches it.

**How to apply:** use static values at load. If live GUI facts are ever needed, read them inside an
event handler (`gui-startup`, `window-config-reloaded`) and apply them with
`window:set_config_overrides()`. Related: [[project-wezterm-render-webgpu-120fps]].
