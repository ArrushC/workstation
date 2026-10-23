---
name: project-wezterm-integrated-title-bar-reverted
description: WezTerm's tab bar as the title bar (INTEGRATED_BUTTONS|RESIZE, bar at the top, minimize/close buttons) shipped in #107 and was reverted the same day; the user found it cramped, laggy to drag and slow. Don't re-propose it.
metadata:
  type: project
---

#107 (2026-10-23) moved WezTerm's retro tab bar to the top as the title bar:
`window_decorations = 'INTEGRATED_BUTTONS|RESIZE'`, `integrated_title_buttons = { 'Hide', 'Close' }`,
codicon buttons from `tab_bar_style`. Its revert restored the earlier chrome: `RESIZE`, with the
retro bar at the bottom and the status footer on its right.

**Why:** after using it on the Windows host, the user reported: "It feels small in height and the
spacing looks cramped", "The drag has a latency which makes window movements unsmooth", "It has
gone extremely slow", and asked to revert the whole change.

**How to apply:** don't suggest integrated title buttons or moving the tab bar to the top as a
title bar again. The retro bar is one terminal row tall, and no setting makes it taller. If a
custom frame ever comes back, measure responsiveness on the Windows host first. One lead, read
in WezTerm's source but never measured: with the retro bar, every mouse move over it runs
leave/enter on the bar item, and leaving re-runs `update_title` (so `format-tab-title` for every
tab, including tabs.lua's `domains.ssh_of` lookups) and repaints. A bar at the top is under
the mouse far more often. Related: [[project-wezterm-render-webgpu-120fps]].
