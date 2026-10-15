---
name: project-wezterm-unfocused-cursor-hollow
description: WezTerm hard-codes a hollow block cursor outside the focused window's active pane; no config keeps the bar. The user would prefer a bar but chose to leave it (2026-10-15).
metadata:
  type: project
---

WezTerm's renderer (`wezterm-gui/src/termwindow/render/mod.rs`, `compute_cell_fg_bg`: `_shape if
!focused_and_active => Some(CursorShape::SteadyBlock)`) draws every cursor outside the focused
window's active pane as a steady hollow box in the `cursor_border` colour, whatever
`default_cursor_style` says. Checked on upstream main e2a98e1b8af1 (2026-10-10): no option, and
`window:set_config_overrides` can't help because the shape is forced after the style is read.
Only `cursor_thickness` (the box's sides are ~1.5x it; see #79) and `cursor_border` affect it.

**Why:** on 2026-10-15 the user said they'd prefer a constant bar. The routes were an upstream PR
adding an opt-in "keep the shape when unfocused" setting (recommended; public, from their account),
a self-built patched WezTerm (rejected: a rebuild pipeline for one line), or hiding the box with
`cursor_border` = background. They chose to leave it as it is for now.

**How to apply:** don't re-investigate a config-only fix. If they raise it again, start from the
upstream PR (it needs their go-ahead); the other two routes were already weighed. Related:
[[project-wezterm-render-webgpu-120fps]], [[project-wezterm-no-gui-calls-at-load]].
