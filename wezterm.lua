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
-- wezterm.on('gui-startup', function(cmd)
--   local _, _, window = wezterm.mux.spawn_window(cmd or {})

--   for i, domain in ipairs(ssh_domains) do
--     if i == 1 then
--       -- First tab uses the initial window
--       window:active_tab():set_title(domain.name)
--     else
--       -- Subsequent VMs get their own tab
--       window:spawn_tab({
--         domain = { DomainName = domain.name },
--       })
--     end
--   end
-- end)

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

-- Cursor — vertical bar (I-beam) instead of block
config.default_cursor_style = 'SteadyBar'

-- ---------------------------------------------------------------------------
-- Per-host tab color
-- ---------------------------------------------------------------------------
-- Stable hash from the SSH domain name → HSL hue, so each VM gets a distinct
-- and consistent tab color. Cheap visual guard against typing into the wrong
-- VM. Pulls names from ssh_domains, so any host added via manage-hosts +
-- sync gets coloured automatically — no extra auto-managed block needed.
local function host_hue(name)
  local h = 0
  for i = 1, #name do
    h = (h * 131 + name:byte(i)) % 360
  end
  return h
end

local function host_colors(name, is_active)
  local hue = host_hue(name)
  local sat = is_active and 0.55 or 0.35
  local lit = is_active and 0.42 or 0.28
  local bg  = wezterm.color.from_hsla(hue, sat, lit, 1.0)
  local fg  = wezterm.color.from_hsla(hue, 0.15, 0.96, 1.0)
  return tostring(bg), tostring(fg)
end

wezterm.on('format-tab-title', function(tab, _tabs, _panes, _config, _hover, _max_width)
  local pane   = tab.active_pane
  local domain = pane.domain_name or ''

  local host
  for _, d in ipairs(ssh_domains) do
    if d.name == domain then host = d.name break end
  end

  local title = tab.tab_title
  if title == nil or #title == 0 then
    title = host or pane.title or ''
  end
  local label = string.format(' %d: %s ', tab.tab_index + 1, title)

  if host then
    local bg, fg = host_colors(host, tab.is_active)
    return {
      { Background = { Color = bg } },
      { Foreground = { Color = fg } },
      { Text = label },
    }
  end
  return label
end)

-- ---------------------------------------------------------------------------
-- SSH domains
-- ---------------------------------------------------------------------------
config.ssh_domains = ssh_domains

-- ---------------------------------------------------------------------------
-- Host quick-picker — fuzzy-find a VM and open a tab into it
-- ---------------------------------------------------------------------------
-- Bound to CTRL|SHIFT+H below. Choices are derived from ssh_domains, so
-- every host added via manage-hosts.{sh,ps1} --add becomes pickable after
-- the next sync + config reload.
local function host_picker_choices()
  local choices = {}
  for _, domain in ipairs(ssh_domains) do
    table.insert(choices, {
      label = string.format('%s  (%s@%s)', domain.name, domain.username, domain.remote_address),
      id    = domain.name,
    })
  end
  return choices
end

local pick_host = act.InputSelector {
  title    = 'Connect to VM',
  fuzzy    = true,
  choices  = host_picker_choices(),
  action   = wezterm.action_callback(function(window, pane, id, _label)
    if not id then return end
    window:perform_action(act.SpawnTab { DomainName = id }, pane)
  end),
}

-- ---------------------------------------------------------------------------
-- Tab switcher — fuzzy list with explicit tab index + domain
-- ---------------------------------------------------------------------------
-- The built-in ShowLauncher renumbers entries after fuzzy filtering, so the
-- "1, 2, 3..." jump keys aren't the same as the actual tab positions. This
-- custom InputSelector keeps the real tab index in the label, so the order
-- you type matches the order in the tab bar.
local pick_tab = wezterm.action_callback(function(window, pane)
  local active_id = window:active_tab():tab_id()
  local choices = {}
  for i, tab in ipairs(window:mux_window():tabs()) do
    local active = tab:active_pane()
    local title  = (active:get_title() or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local domain = active:get_domain_name() or ''
    local marker = (tab:tab_id() == active_id) and '● ' or '  '
    local label
    if domain ~= '' and domain ~= 'local' then
      label = string.format('%s%d. %s  [%s]', marker, i, title, domain)
    else
      label = string.format('%s%d. %s', marker, i, title)
    end
    table.insert(choices, { label = label, id = tostring(tab:tab_id()) })
  end

  window:perform_action(act.InputSelector {
    title   = 'Switch tab',
    fuzzy   = true,
    choices = choices,
    action  = wezterm.action_callback(function(inner_win, _inner_pane, id, _label)
      if not id then return end
      local target = tonumber(id)
      for _, t in ipairs(inner_win:mux_window():tabs()) do
        if t:tab_id() == target then
          t:activate()
          return
        end
      end
    end),
  }, pane)
end)

-- ---------------------------------------------------------------------------
-- Right status line — domain · zellij session · battery · time
-- ---------------------------------------------------------------------------
-- Fires ~1×/second. Domain + session are only shown when the active pane is
-- on a remote SSH domain. The zellij session name mirrors the hardcoded
-- 'main' from zellij_attach_cmd above — keep both in sync if you change it.
local function format_battery()
  local batteries = wezterm.battery_info()
  if not batteries or #batteries == 0 then return nil end
  local b = batteries[1]
  local pct = math.floor((b.state_of_charge or 0) * 100 + 0.5)
  local icon
  if b.state == 'Charging' then
    icon = '⚡'
  elseif pct <= 20 then
    icon = '🪫'
  else
    icon = '🔋'
  end
  return string.format('%s %d%%', icon, pct)
end

local function time_icon()
  local h = tonumber(wezterm.strftime('%H'))
  if     h >= 0  and h < 5  then return '🌌'  -- pre-dawn / early morning
  elseif h >= 5  and h < 7  then return '🌅'  -- dawn
  elseif h >= 7  and h < 12 then return '☀️'  -- morning
  elseif h >= 12 and h < 17 then return '🌞'  -- afternoon
  elseif h >= 17 and h < 20 then return '🌇'  -- dusk
  else                           return '🌙'  -- night (20-23)
  end
end

wezterm.on('update-right-status', function(window, pane)
  local parts = {}

  local domain = pane:get_domain_name()
  if domain and domain ~= 'local' then
    table.insert(parts, domain)
    table.insert(parts, 'zellij:main')
  end

  local bat = format_battery()
  if bat then table.insert(parts, bat) end

  table.insert(parts, time_icon() .. ' ' .. wezterm.strftime('%H:%M'))

  window:set_right_status(' ' .. table.concat(parts, '  │  ') .. ' ')

  -- Throttled session snapshot (≤ once per 2s) — fires from this tick because
  -- update-right-status is already running ~1×/sec and gives us a window obj.
  maybe_save_session(window)
end)

-- ---------------------------------------------------------------------------
-- Session persistence — save tabs/order/host/cwd, restore on next launch
-- ---------------------------------------------------------------------------
-- Saves the current window's tabs to session.json beside this config file,
-- then rebuilds them on the next gui-startup. SSH tabs reconnect to the same
-- domain (zellij re-attaches to 'main' via default_prog). Local tabs restore
-- their cwd if the shell emits OSC 7 (bash on RHEL does so via /etc/profile.d
-- defaults; PowerShell needs PSReadLine + a custom prompt).
--
-- Limitations: only the active window is tracked. Per-pane splits inside a
-- tab are not preserved — zellij owns those for SSH tabs anyway, and local
-- tabs typically have one pane.
local session_file = wezterm.config_dir .. '/session.json'
local last_save = 0

local function ssh_domain_exists(name)
  for _, d in ipairs(ssh_domains) do
    if d.name == name then return true end
  end
  return false
end

local function save_session(window)
  if not window then return end
  local ok, mux_window = pcall(function() return window:mux_window() end)
  if not ok or not mux_window then return end

  local active_id
  pcall(function() active_id = window:active_tab():tab_id() end)

  local tabs = {}
  local active_index = 1
  for i, tab in ipairs(mux_window:tabs()) do
    local pane = tab:active_pane()
    local cwd
    local cwd_url = pane:get_current_working_dir()
    if cwd_url then
      cwd = cwd_url.file_path
    end
    table.insert(tabs, {
      title  = tab:get_title() or '',
      domain = pane:get_domain_name() or 'local',
      cwd    = cwd,
    })
    if active_id and tab:tab_id() == active_id then
      active_index = i
    end
  end

  local f = io.open(session_file, 'w')
  if not f then return end
  f:write(wezterm.json_encode({ tabs = tabs, active = active_index }))
  f:close()
end

local function maybe_save_session(window)
  local now = os.time()
  if now - last_save < 2 then return end
  last_save = now
  save_session(window)
end

local function tab_spawn_args(t)
  local args = {}
  if t.domain and t.domain ~= 'local' and ssh_domain_exists(t.domain) then
    args.domain = { DomainName = t.domain }
  elseif t.cwd then
    args.cwd = t.cwd
  end
  return args
end

wezterm.on('gui-startup', function(cmd)
  -- Honour explicit CLI args (e.g. `wezterm connect <host>`) over restore.
  if cmd and cmd.args and #cmd.args > 0 then
    wezterm.mux.spawn_window(cmd)
    return
  end

  local f = io.open(session_file, 'r')
  if not f then
    wezterm.mux.spawn_window(cmd or {})
    return
  end
  local content = f:read('*a')
  f:close()

  local ok, session = pcall(wezterm.json_parse, content)
  if not ok or type(session) ~= 'table' or type(session.tabs) ~= 'table' or #session.tabs == 0 then
    wezterm.mux.spawn_window(cmd or {})
    return
  end

  local first = session.tabs[1]
  local first_tab, _, mux_window = wezterm.mux.spawn_window(tab_spawn_args(first))
  if first.title and #first.title > 0 then
    first_tab:set_title(first.title)
  end

  for i = 2, #session.tabs do
    local t = session.tabs[i]
    local new_tab, _, _ = mux_window:spawn_tab(tab_spawn_args(t))
    if new_tab and t.title and #t.title > 0 then
      new_tab:set_title(t.title)
    end
  end

  local all_tabs = mux_window:tabs()
  local idx = session.active or 1
  if idx >= 1 and idx <= #all_tabs then
    all_tabs[idx]:activate()
  end
end)

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

  -- Fuzzy-pick a VM and open it in a new tab
  { key = 'h', mods = 'CTRL|SHIFT', action = pick_host },

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

  -- Tab switcher — fuzzy list with explicit tab index + domain in label
  { key = 's', mods = 'CTRL|SHIFT', action = pick_tab },

  -- Rename current tab — prompts for a new title; submit empty to clear
  -- and revert to the auto-generated name. Force-saves immediately so the
  -- new title survives a quick close before the next throttled snapshot.
  {
    key = 'e', mods = 'CTRL|SHIFT',
    action = act.PromptInputLine {
      description = 'New tab title (empty = reset):',
      action = wezterm.action_callback(function(window, _pane, line)
        if line == nil then return end  -- Esc cancels
        window:active_tab():set_title(line)
        save_session(window)
      end),
    },
  },

  -- Copy/paste
  { key = 'c', mods = 'CTRL|SHIFT', action = act.CopyTo 'Clipboard' },
  { key = 'v', mods = 'CTRL|SHIFT', action = act.PasteFrom 'Clipboard' },

  -- Font size
  { key = '=', mods = 'CTRL', action = act.IncreaseFontSize },
  { key = '-', mods = 'CTRL', action = act.DecreaseFontSize },
  { key = '0', mods = 'CTRL', action = act.ResetFontSize },

  -- Reload config
  { key = 'r', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },

  -- Force-save session snapshot now (also auto-saved every ~2s)
  {
    key = 'p', mods = 'CTRL|SHIFT',
    action = wezterm.action_callback(function(window, _pane)
      save_session(window)
      window:toast_notification('wezterm', 'Session saved', nil, 2000)
    end),
  },
}

-- Pass through Ctrl+p to Zellij unmodified
config.key_tables = {}

-- ---------------------------------------------------------------------------
-- SSH quick-connect function (call from wezterm CLI)
-- ---------------------------------------------------------------------------
-- Usage: wezterm connect rhel-dev-01
-- This is already handled by ssh_domains above.

return config
