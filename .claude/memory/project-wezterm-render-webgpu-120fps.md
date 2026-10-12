---
name: project-wezterm-render-webgpu-120fps
description: WezTerm renders with WebGpu + HighPerformance + max_fps 120 on every host; a 60 fps cap and OpenGL were each measured slower on this Intel laptop. Don't re-add them.
metadata:
  type: project
---

`dotfiles/config/wezterm/wezterm.lua` sets `front_end = 'WebGpu'`, `webgpu_power_preference =
'HighPerformance'` and `max_fps = 120` unconditionally (`animation_fps = 60` only paces blinks and
bell fades).

**Why:** the retired WezTerm setup (before 17a4148) tried two "optimisations" on the Intel-iGPU,
60 Hz laptop CBL-LT-PW0FW9T4, and both were A/B-measured as slower ("worse than Windows Terminal"):
- capping `max_fps` at the panel's 60 Hz: a higher cap repaints sooner after a key press, so the next
  vsync shows fresher content;
- OpenGL: on Windows, Intel's GL driver is weak; the D3D12-backed WebGpu path is faster.
That block was re-litigated three times (#39, #42, #51) before settling.

**How to apply:** don't add a per-host fps cap or an OpenGL/Software `front_end`. `front_end` and
`webgpu_power_preference` need a WezTerm restart; `max_fps` hot-reloads. Related:
[[project-wezterm-no-gui-calls-at-load]].
