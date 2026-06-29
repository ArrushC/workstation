---
name: project-wezterm-no-gui-calls-at-config-load
description: Never call wezterm.gui.* (screens/enumerate_gpus) at config-parse time in wezterm.lua — it deadlocks WezTerm into a fully unresponsive window.
metadata:
  type: project
---

In `chezmoi/dot_config/wezterm/wezterm.lua`, **never call `wezterm.gui.*` functions (e.g. `wezterm.gui.screens()`, `wezterm.gui.enumerate_gpus()`) at config-parse / config-build time** (the top-level body that runs when the config loads). They require a GUI context that isn't ready at parse time and **DEADLOCK WezTerm into a completely unresponsive window**.

**Why:** A `pcall` does NOT save you — it only catches *thrown errors*, not a *hang/deadlock*. This bit hard: PR #39 added `screens()`/`enumerate_gpus()` at config-load to make `max_fps`/`webgpu_power_preference` adaptive; it froze WezTerm on launch. Recovery required force-killing `wezterm-gui.exe` (the deadlocked process can't even reload config). Fixed in #40.

**How to apply:**
- Resolve `max_fps` / `animation_fps` / `webgpu_power_preference` from **static** values or **safe non-GUI calls** at load. `wezterm.hostname()` IS safe at config-load (still used for `LOCAL_HOSTNAME` + host-accent hashing) if you ever need per-machine scoping. **NOTE:** the `LOW_POWER_60HZ_HOSTS` per-host render table this memory used to cite was **REMOVED in #51** — render settings are now unconditional `WebGpu` + 120fps + HighPerformance, because the per-host 60fps/OpenGL tuning was itself a perceived-latency regression. Don't re-add a hostname-keyed render table expecting it to help (see [[project_wezterm_render_webgpu_120fps]]).
- If you genuinely need live GPU/screen info, do it inside a GUI **event handler** (`gui-startup`, `window-config-reloaded`), never the top-level config body — and even then prefer `window:set_config_overrides()` over re-deriving core settings.
- The luaparse gate ([[feedback_lua_syntax_use_luaparse_not_lsp]]) catches *syntax*, not a runtime deadlock — there's no parse-time signal for this, so the rule above is the guard.
