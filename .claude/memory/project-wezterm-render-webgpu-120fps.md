---
name: project-wezterm-render-webgpu-120fps
description: WezTerm render config is unconditional WebGpu + 120fps + HighPerformance on every host; the per-host 60fps-cap and OpenGL "optimizations" were perceived-latency regressions — do not re-add them.
metadata:
  type: project
---

In `chezmoi/dot_config/wezterm/wezterm.lua`, keep GPU rendering **simple and unconditional**: `config.front_end = 'WebGpu'`, `config.webgpu_power_preference = 'HighPerformance'`, `render_fps = 120` (feeds `max_fps` + `animation_fps`) — on **every** host. This is the config that ran snappily for ~7 weeks from 2026-05-06.

**Why:** Two per-host "optimizations" for the single Intel-iGPU @ 60Hz laptop `CBL-LT-PW0FW9T4` were tried and BOTH reverted (in #51) as user-reported sluggishness ("worse than Windows Terminal"), confirmed by live A/B on the machine:

- **#39/#40 capped `max_fps` to the 60Hz panel rate.** Wrong: capping `max_fps` to the refresh rate does NOT save input latency — a higher cap repaints the framebuffer sooner after a keypress, so the next vsync shows fresher content. 120fps feels markedly snappier than 60 even on a 60Hz panel (DARK-120 vs LIGHT-60 minimal-config A/B). The iGPU renders 120fps fine.
- **#42 switched the host to OpenGL** on the theory it's lower-latency than WebGpu on Intel iGPUs. True on Linux/Mesa, **false on Windows** — Intel's Windows GL driver is weak and WezTerm's GL backend can degrade toward software; the D3D12-backed WebGpu path is faster.

Hardware was confirmed healthy first (Meteor Lake iGPU, full D3D12, no software/WARP fallback — `dxdiag`), so neither was a driver problem.

**How to apply:**
- Do NOT re-introduce a per-host `max_fps` cap (e.g. a `LOW_POWER_60HZ_HOSTS` table) or an `OpenGL`/`Software` `front_end`. The in-file comment block carries the same guard.
- This is the THIRD time this block was re-litigated (#39→#40→#42→#51); resist "the panel is only 60Hz so cap fps" and "OpenGL is lighter on Intel" intuitions — both were measured wrong here.
- `front_end` and `webgpu_power_preference` are **startup-only** (need a full WezTerm restart); `max_fps`/`animation_fps` hot-reload (`CTRL+SHIFT+R`).
- On Windows the live config is the **Windows clone** WezTerm reads via `WEZTERM_CONFIG_FILE` — a separate checkout from the WSL repo; a fix in WSL doesn't reach the terminal until that clone is synced. Related: no `wezterm.gui.*` at config-load ([[project-wezterm-no-gui-calls-at-config-load]]).
