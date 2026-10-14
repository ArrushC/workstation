-- WezTerm's config, loaded straight from the Windows checkout
-- (dotfiles/config/wezterm/wezterm.lua): WEZTERM_CONFIG_FILE names this file, so no copy is
-- deployed, and a save here or in a module, or a wsu pull, reloads every window
-- (Ctrl+Shift+R forces it).
--
-- Windows installs WezTerm's nightly build per-user (scripts/wezterm-nightly.ps1, run after
-- every tools phase, which also keeps its Start Menu shortcut, registers its toast id, sets
-- WEZTERM_CONFIG_FILE and puts the wezterm CLI on the User PATH).
-- It sits beside Warp (the primary terminal) and Windows Terminal (the default one):
-- Catppuccin Mocha with the mauve accent, JetBrainsMono NFM 10.5, Nushell through mise's
-- shim, no title bar, and the tab bar at the bottom with a status footer on its right.
-- Ctrl+Shift+H lists every key.
--
-- This file links the modules beside it, each owning its settings and event handlers,
-- applied in this order (a later one uses an earlier one's exports):
--   appearance.lua  colours, font, chrome, rendering, scrollback, TERM, one-line behaviour
--   wsl.lua         Nushell, the launcher's shell entries, WSL domains
--   domains.lua     SSH: the launcher's host entries, finding and naming a tab's host
--   status.lua      the status footer and its notices (flash)
--   tabs.lua        tab titles: marks, glyphs, names, host colours
--   actions.lua     what keys, mouse, + and the palette do; links; file links in helix
--   keys.lua        key and mouse bindings, the cheatsheet, the command palette
--
-- WezTerm runs Lua 5.4; scripts/check-invariants.sh (check_wezterm_config) runs these files
-- and their event handlers under LuaJIT with a stand-in wezterm module, so keep to Lua 5.1
-- syntax and give each new wezterm.* call a stand-in there. Never call wezterm.gui.* at
-- load: before the GUI exists it deadlocks WezTerm, and pcall can't catch a hang.

local wezterm = require 'wezterm'

-- WezTerm searches ~/.config/wezterm and ~/.wezterm for modules, not this file's folder
-- (config/src/lua.rs, nightly e2a98e1b), so put it first. Every required file is watched,
-- so saving a module reloads too.
package.path = (wezterm.config_file:gsub('[^/\\]+$', '')) .. '?.lua;' .. package.path

local config = wezterm.config_builder()

-- Updates come from scripts/wezterm-nightly.ps1 (every wsu), not WezTerm's own check.
config.check_for_updates = false

require('appearance').apply(config)
require('wsl').apply(config)
require('domains').apply(config)
require('status').apply(config)
require('tabs').apply(config)
require('actions').apply(config)
require('keys').apply(config)

return config
