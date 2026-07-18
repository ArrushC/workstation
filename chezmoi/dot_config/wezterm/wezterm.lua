-- =============================================================================
-- wezterm.lua — Windows config for remote Linux dev (entry point)
-- Loaded via the User-scope WEZTERM_CONFIG_FILE env var, which bootstrap.ps1
-- points straight at this file inside the chezmoi source (no copy is
-- deployed to %USERPROFILE%). The dir is chezmoi-ignored on Linux too —
-- Linux hosts run no WezTerm; this config lives in the repo only.
-- =============================================================================

local wezterm = require 'wezterm'

-- Make the sibling modules require-able BEFORE requiring any of them:
-- wezterm does NOT add the config file's own directory to package.path
-- (only ~/.config/wezterm, ~/.wezterm, and wezterm_modules next to the
-- exe — config/src/lua.rs, verified at 20240203 AND on nightly main
-- 2026-07-16; the pin policy is weekly nightly snapshots). On Windows
-- this config loads from the chezmoi repo via WEZTERM_CONFIG_FILE and
-- ~/.config/wezterm doesn't exist (the dir is chezmoi-ignored on every
-- OS), so without this prepend every sibling require fails. The gsub
-- keeps everything up to the last path separator, handling both / and \.
package.path = (wezterm.config_file:gsub('[^/\\]+$', '')) .. '?.lua;' .. package.path

local config = wezterm.config_builder()

-- Module map — each owns its config surface AND its event handlers, and is
-- applied in dependency order (later modules read earlier modules' exports):
--   hosts.lua      — ssh_domains data; the manage-hosts.{sh,ps1} sentinel
--                    block (HOSTS:START/END) lives THERE now
--   appearance.lua — palette/font/chrome/GPU/fps/cursor (exports mocha,
--                    host_accent)
--   domains.lua    — SSH-domain wiring: zellij default_prog, name lookup,
--                    canonical_host
--   wsl.lua        — WSL distro detection, default domain, distro pickers,
--                    new_window_action
--   tabs.lua       — tab bar: tab_colors, activity markers, format-tab-title
--   status.lua     — right status + in-window notices (M.flash; "Copied!"
--                    badge rides it)
--   actions.lua    — bespoke actions/overlays/open-uri/command palette
--   keys.lua       — config.keys + config.mouse_bindings
require('appearance').apply(config)
require('domains').apply(config)
require('wsl').apply(config)
require('tabs').apply(config)
require('status').apply(config)
require('actions').apply(config)
require('keys').apply(config)

return config
