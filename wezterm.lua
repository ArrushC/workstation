-- =============================================================================
-- wezterm.lua — Windows config for remote RHEL dev
-- Place at: %USERPROFILE%\.config\wezterm\wezterm.lua
--   (or alongside wezterm.exe as wezterm.lua)
-- =============================================================================

local wezterm = require 'wezterm'
local act     = wezterm.action

-- ---------------------------------------------------------------------------
-- SSH Domains — auto-managed by scripts/manage-hosts.{sh,ps1}
-- ---------------------------------------------------------------------------
-- Edit hosts.conf at the repo root, then run:
--   ./scripts/manage-hosts.sh --sync       (Linux)
--   .\scripts\manage-hosts.ps1 -Sync       (Windows)
-- The block between HOSTS:START / HOSTS:END is replaced on every sync —
-- do not edit it by hand. `multiplexing = 'None'` lets Zellij own sessions.
-- HOSTS:START
local ssh_domains = {
  {
    name           = 'atc-cache-dev10',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'atc-cache-dev09',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
}
-- HOSTS:END

-- ---------------------------------------------------------------------------
-- Auto-launch Zellij on connect
-- ---------------------------------------------------------------------------
-- Attaches to (or creates) a session named 'main' automatically.
local function zellij_attach_cmd()
  return { 'zellij', 'attach', '--create', 'main' }
end

-- Apply the Zellij command to each SSH domain
for _, domain in ipairs(ssh_domains) do
  domain.default_prog = zellij_attach_cmd()
end

-- ---------------------------------------------------------------------------
-- Startup workspace — open a tab per VM on launch
-- ---------------------------------------------------------------------------
wezterm.on('gui-startup', function(cmd)
  local _, _, window = wezterm.mux.spawn_window(cmd or {})

  for i, domain in ipairs(ssh_domains) do
    if i == 1 then
      -- First tab uses the initial window
      window:active_tab():set_title(domain.name)
    else
      -- Subsequent VMs get their own tab
      window:spawn_tab({
        domain = { DomainName = domain.name },
      })
    end
  end
end)

-- ---------------------------------------------------------------------------
-- Appearance
-- ---------------------------------------------------------------------------
local config = wezterm.config_builder()

config.color_scheme = 'Tokyo Night'
config.font         = wezterm.font('JetBrains Mono', { weight = 'Regular' })
config.font_size    = 12.0

-- Window chrome
config.window_decorations          = 'TITLE' -- RESIZE
config.window_background_opacity   = 1.0 -- 0.95
config.enable_tab_bar              = true
config.use_fancy_tab_bar           = false
config.tab_bar_at_bottom           = true
config.hide_tab_bar_if_only_one_tab = false

-- Slightly padded inner margins
config.window_padding = {
  left   = 8,
  right  = 8,
  top    = 6,
  bottom = 6,
}

-- GPU rendering
config.front_end = 'WebGpu'

-- ---------------------------------------------------------------------------
-- SSH domains
-- ---------------------------------------------------------------------------
config.ssh_domains = ssh_domains

-- ---------------------------------------------------------------------------
-- Keybinds
-- ---------------------------------------------------------------------------
-- Zellij owns Ctrl+p and pane management inside the session.
-- Wezterm handles window/tab creation at the OS level.
config.keys = {
  -- New window
  { key = 'n', mods = 'CTRL|SHIFT', action = act.SpawnWindow },

  -- New local tab
  { key = 't', mods = 'CTRL|SHIFT', action = act.SpawnTab 'CurrentPaneDomain' },

  -- Close tab
  { key = 'w', mods = 'CTRL|SHIFT', action = act.CloseCurrentTab { confirm = true } },

  -- Switch tabs
  { key = 'Tab',       mods = 'CTRL',       action = act.ActivateTabRelative(1) },
  { key = 'Tab',       mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },

  -- Jump to tab by number
  { key = '1', mods = 'ALT', action = act.ActivateTab(0) },
  { key = '2', mods = 'ALT', action = act.ActivateTab(1) },
  { key = '3', mods = 'ALT', action = act.ActivateTab(2) },
  { key = '4', mods = 'ALT', action = act.ActivateTab(3) },

  -- Copy/paste
  { key = 'c', mods = 'CTRL|SHIFT', action = act.CopyTo 'Clipboard' },
  { key = 'v', mods = 'CTRL|SHIFT', action = act.PasteFrom 'Clipboard' },

  -- Font size
  { key = '=', mods = 'CTRL', action = act.IncreaseFontSize },
  { key = '-', mods = 'CTRL', action = act.DecreaseFontSize },
  { key = '0', mods = 'CTRL', action = act.ResetFontSize },

  -- Reload config
  { key = 'r', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },
}

-- Pass through Ctrl+p to Zellij unmodified
config.key_tables = {}

-- ---------------------------------------------------------------------------
-- SSH quick-connect function (call from wezterm CLI)
-- ---------------------------------------------------------------------------
-- Usage: wezterm connect rhel-dev-01
-- This is already handled by ssh_domains above.

return config
