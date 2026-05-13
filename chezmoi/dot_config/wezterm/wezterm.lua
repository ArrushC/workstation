-- =============================================================================
-- wezterm.lua — Windows config for remote Linux dev
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
    name           = 'atc-cache-dev09',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'atc-cache-dev10',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'cache-apl',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'cache-bur1',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'dev-cache-qa1',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'dev-cache-qa2',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'dev-cache-qa3',
    remote_address = '***REMOVED-IP***',
    username       = 'arrush.chaturvedi',
    multiplexing   = 'None',
  },
  {
    name           = 'dev-cache-qa4',
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
-- Startup workspace — open a tab per host on launch
-- ---------------------------------------------------------------------------
-- wezterm.on('gui-startup', function(cmd)
--   local _, _, window = wezterm.mux.spawn_window(cmd or {})

--   for i, domain in ipairs(ssh_domains) do
--     if i == 1 then
--       -- First tab uses the initial window
--       window:active_tab():set_title(domain.name)
--     else
--       -- Subsequent hosts get their own tab
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

-- Window chrome — TITLE alone hides resize handles, which also blocks
-- Windows snap (Win+Arrow). Adding RESIZE keeps the title bar AND lets
-- the OS resize/snap the window.
config.window_decorations          = 'TITLE | RESIZE'
config.window_background_opacity   = 1.0 -- 0.95
config.enable_tab_bar              = true
config.use_fancy_tab_bar           = false
config.tab_bar_at_bottom           = true
config.hide_tab_bar_if_only_one_tab = false
-- Raise the per-tab cap so format-tab-title can pad labels to fill the bar
-- evenly. Without this the cap (default 16) would clip the padded labels.
config.tab_max_width               = 100

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
-- Stable hash from the SSH domain name → HSL hue, so each host gets a distinct
-- and consistent tab color. Cheap visual guard against typing into the wrong
-- host. Pulls names from ssh_domains, so any host added via manage-hosts +
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

-- Forward-declared upvalue: cell width of the right-status line. Assigned
-- by update-right-status (defined further down). Keeps the tab-bar layout
-- in sync with whatever the status line is actually rendering this tick.
local right_status_cells = 30

wezterm.on('format-tab-title', function(tab, all_tabs, panes, _config, _hover, max_width)
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

  -- Re-derive position from the live tabs array — tab.tab_index reflects the
  -- pre-close ordering after CloseCurrentTab and only refreshes on the next
  -- tab-switch. Walking all_tabs gives the true current position so the
  -- numbers in the bar reshuffle immediately on close.
  local idx = tab.tab_index + 1
  if all_tabs then
    for i, t in ipairs(all_tabs) do
      if t.tab_id == tab.tab_id then idx = i; break end
    end
  end
  local label = string.format(' %d: %s ', idx, title)

  -- Stretch tabs to fill the bar evenly. Use the widest pane's cell width as
  -- a proxy for window content width (single-pane tabs are the common case;
  -- with splits we still get a sensible upper bound). Reserve exactly the
  -- live right-status width (+ a small margin), then split the remainder
  -- across all tabs and pad the label centered to that width. Capped at
  -- max_width (= tab_max_width).
  local total_cols = 0
  for _, p in ipairs(panes) do
    if p.width and p.width > total_cols then total_cols = p.width end
  end
  if total_cols > 0 and #all_tabs > 0 then
    local reserved = right_status_cells + 4
    local available = math.max(8, total_cols - reserved)
    local target = math.floor(available / #all_tabs)
    target = math.min(target, max_width)
    local pad = target - #label
    if pad > 0 then
      local left = math.floor(pad / 2)
      label = string.rep(' ', left) .. label .. string.rep(' ', pad - left)
    end
  end

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
-- Host quick-picker — fuzzy-find a host and open a tab into it
-- ---------------------------------------------------------------------------
-- Bound to CTRL|SHIFT+J below (J = jump). Choices are derived from
-- ssh_domains, so every host added via manage-hosts.{sh,ps1} --add becomes
-- pickable after the next sync + config reload.
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
  title    = 'Connect to host',
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
-- Help / cheatsheet — fuzzy-searchable list of keybinds + aliases + hosts
-- ---------------------------------------------------------------------------
-- Bound to CTRL|SHIFT+H. Keybind / alias / function rows are informational
-- (no-op on selection); host rows actually launch the host in a new tab so
-- the help doubles as a launcher. Esc dismisses.
--
-- Bash aliases and functions are only active inside SSH'd host tabs (defined
-- in chezmoi/home/dot_bashrc.tmpl). Keep this in sync with that file when
-- adding/renaming aliases — there's no runtime introspection across SSH.
local function help_choices()
  local rows = {
    -- Wezterm: tabs
    { label = 'key   CTRL+SHIFT+T     New local tab',                       id = '' },
    { label = 'key   CTRL+SHIFT+W     Close current tab (with confirm)',    id = '' },
    { label = 'key   CTRL+SHIFT+E     Rename current tab',                  id = '' },
    { label = 'key   CTRL+TAB         Next tab',                            id = '' },
    { label = 'key   CTRL+SHIFT+TAB   Previous tab',                        id = '' },
    { label = 'key   ALT+1..4         Jump directly to tab 1-4',            id = '' },
    { label = 'key   CTRL+SHIFT+S     Tab switcher (fuzzy list)',           id = '' },
    -- Wezterm: window
    { label = 'key   CTRL+SHIFT+N     New window',                          id = '' },
    -- Wezterm: hosts
    { label = 'key   CTRL+SHIFT+J     Open SSH host picker',                id = '' },
    { label = 'key   CTRL+SHIFT+H     Show this help',                      id = '' },
    -- Wezterm: editing
    { label = 'key   CTRL+SHIFT+C     Copy selection',                      id = '' },
    { label = 'key   CTRL+SHIFT+V     Paste from clipboard',                id = '' },
    { label = 'key   CTRL+SHIFT+A     Copy entire scrollback to clipboard', id = '' },
    -- Wezterm: font
    { label = 'key   CTRL+=           Increase font size',                  id = '' },
    { label = 'key   CTRL+-           Decrease font size',                  id = '' },
    { label = 'key   CTRL+0           Reset font size',                     id = '' },
    -- Wezterm: config
    { label = 'key   CTRL+SHIFT+R     Reload wezterm config',               id = '' },

    -- Bash aliases (host tabs only) — git
    { label = 'alias gs               git status',                          id = '' },
    { label = 'alias ga               git add',                             id = '' },
    { label = 'alias gc               git commit',                          id = '' },
    { label = 'alias gp               git push',                            id = '' },
    { label = 'alias gl               git log --oneline --graph --decorate', id = '' },
    { label = 'alias gd               git diff',                            id = '' },
    { label = 'alias gco              git checkout',                        id = '' },
    { label = 'alias gbr              git branch',                          id = '' },
    -- Bash aliases — chezmoi
    { label = 'alias cz               chezmoi',                             id = '' },
    { label = 'alias cza              chezmoi apply',                       id = '' },
    { label = 'alias cze              chezmoi edit',                        id = '' },
    { label = 'alias czd              chezmoi diff',                        id = '' },
    { label = 'alias czu              chezmoi update',                      id = '' },
    { label = 'alias czs              chezmoi status',                      id = '' },
    -- Bash aliases — navigation
    { label = "alias ..               cd ..",                               id = '' },
    { label = "alias ...              cd ../..",                            id = '' },
    { label = 'alias ll               ls -lah --color=auto',                id = '' },
    { label = 'alias la               ls -A --color=auto',                  id = '' },
    { label = 'alias l                ls --color=auto',                     id = '' },
    -- Bash aliases — tools
    { label = 'alias notes            nb',                                  id = '' },
    { label = 'alias preview          glow',                                id = '' },
    { label = 'alias zj               zellij',                              id = '' },
    { label = 'alias zjl              zellij list-sessions',                id = '' },
    { label = 'alias zja              zellij attach',                       id = '' },

    -- Bash functions (host tabs only)
    { label = 'fn    fh               fzf history search (Ctrl+R enhanced)', id = '' },
    { label = 'fn    fcd [dir]        fzf cd into any subdirectory',        id = '' },
    { label = 'fn    fssh             fzf ssh — pick from ~/.ssh/config',   id = '' },
    { label = 'fn    zs [name]        zellij attach --create (default: main)', id = '' },
    { label = 'fn    n [text]         nb add (or list when no args)',       id = '' },
    { label = 'fn    nf               fzf-pick a note in $NB_DIR + glow it', id = '' },

    -- zoxide built-ins
    { label = 'cmd   z <pat>          zoxide jump to a known dir',          id = '' },
    { label = 'cmd   zi               zoxide interactive fuzzy jump',       id = '' },
  }
  for _, d in ipairs(ssh_domains) do
    table.insert(rows, {
      label = string.format('host  %-20s %s@%s', d.name, d.username, d.remote_address),
      id    = 'host:' .. d.name,
    })
  end
  return rows
end

local show_help = act.InputSelector {
  title    = 'Wezterm shortcuts (Esc to dismiss; pick a host to launch it)',
  fuzzy    = true,
  choices  = help_choices(),
  action   = wezterm.action_callback(function(window, pane, id, _label)
    if not id or id == '' then return end
    local host = id:match('^host:(.+)$')
    if host then
      window:perform_action(act.SpawnTab { DomainName = host }, pane)
    end
  end),
}

-- ---------------------------------------------------------------------------
-- Right status line — domain · zellij session · battery · time
-- ---------------------------------------------------------------------------
-- Fires ~1×/second. Adapts to window width: drops the zellij blob, then the
-- battery, then the time icon as columns shrink. The rendered length is
-- cached in right_status_cells so format-tab-title can reserve exactly that
-- much space at the right end of the bar instead of guessing.
--
-- The zellij session name mirrors the hardcoded 'main' from zellij_attach_cmd
-- above — keep both in sync if you change it. (right_status_cells is
-- forward-declared up by format-tab-title; we just assign to it here.)

local function display_width(s)
  if wezterm.column_width then return wezterm.column_width(s) end
  -- Fallback: byte length over-estimates because of multi-byte emoji/dividers,
  -- which means tabs reserve a bit too much space. Acceptable degradation.
  return #s
end

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
  local dim = pane:get_dimensions()
  local cols = (dim and dim.cols) or 80

  local parts = {}

  local domain = pane:get_domain_name()
  if domain and domain ~= 'local' then
    table.insert(parts, domain)
    if cols >= 130 then
      table.insert(parts, 'zellij:main')
    end
  end

  if cols >= 80 then
    local bat = format_battery()
    if bat then table.insert(parts, bat) end
  end

  if cols >= 60 then
    table.insert(parts, time_icon() .. ' ' .. wezterm.strftime('%H:%M'))
  else
    table.insert(parts, wezterm.strftime('%H:%M'))
  end

  local status = ' ' .. table.concat(parts, '  │  ') .. ' '
  window:set_right_status(status)
  right_status_cells = display_width(status)
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

  -- Fuzzy-pick a host and open it in a new tab (J = jump)
  { key = 'j', mods = 'CTRL|SHIFT', action = pick_host },

  -- Show keybind + host cheatsheet
  { key = 'h', mods = 'CTRL|SHIFT', action = show_help },

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
  -- and revert to the auto-generated name.
  {
    key = 'e', mods = 'CTRL|SHIFT',
    action = act.PromptInputLine {
      description = 'New tab title (empty = reset):',
      action = wezterm.action_callback(function(window, _pane, line)
        if line == nil then return end  -- Esc cancels
        window:active_tab():set_title(line)
      end),
    },
  },

  -- Copy/paste
  { key = 'c', mods = 'CTRL|SHIFT', action = act.CopyTo 'Clipboard' },
  { key = 'v', mods = 'CTRL|SHIFT', action = act.PasteFrom 'Clipboard' },

  -- Copy entire scrollback to clipboard (enters copy mode, selects all, copies, exits)
  {
    key = 'a', mods = 'CTRL|SHIFT',
    action = act.Multiple {
      act.ActivateCopyMode,
      act.CopyMode 'MoveToScrollbackTop',
      act.CopyMode { SetSelectionMode = 'Cell' },
      act.CopyMode 'MoveToScrollbackBottom',
      act.CopyTo 'Clipboard',
      act.CopyMode 'Close',
    },
  },

  -- Font size
  { key = '=', mods = 'CTRL', action = act.IncreaseFontSize },
  { key = '-', mods = 'CTRL', action = act.DecreaseFontSize },
  { key = '0', mods = 'CTRL', action = act.ResetFontSize },

  -- Reload config
  { key = 'r', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },

  -- Release Win+Arrow back to the OS for window snap (wezterm's defaults
  -- bind these to pane navigation, but zellij owns panes inside SSH tabs
  -- and CTRL+TAB handles tab switching here).
  { key = 'LeftArrow',  mods = 'SUPER', action = act.DisableDefaultAssignment },
  { key = 'RightArrow', mods = 'SUPER', action = act.DisableDefaultAssignment },
  { key = 'UpArrow',    mods = 'SUPER', action = act.DisableDefaultAssignment },
  { key = 'DownArrow',  mods = 'SUPER', action = act.DisableDefaultAssignment },
}

-- Pass through Ctrl+p to Zellij unmodified
config.key_tables = {}

-- ---------------------------------------------------------------------------
-- SSH quick-connect function (call from wezterm CLI)
-- ---------------------------------------------------------------------------
-- Usage: wezterm connect rhel-dev-01
-- This is already handled by ssh_domains above.

return config
