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

-- Default shell for local tabs on Windows. Decision tree based on detected
-- WSL distros (parsed from `wsl.exe -l -v` by wezterm.default_wsl_domains()):
--   0 distros  → powershell.exe (Windows PowerShell 5.1, always present).
--   1 distro   → default_domain points at that distro; new tabs land in WSL.
--   2+ distros → powershell.exe placeholder + a one-shot picker fires on the
--                first update-status tick, replacing the placeholder with the
--                user-chosen distro. See gui-startup + update-status handlers
--                near the bottom of this file.
-- SSH-domain tabs still spawn `zellij attach --create main` via per-domain
-- default_prog — this only affects local (non-SSH) tabs.
local wsl_doms = {}
if wezterm.target_triple:find('windows') then
  wsl_doms = wezterm.default_wsl_domains()
  config.wsl_domains = wsl_doms
  if #wsl_doms == 1 then
    config.default_domain = wsl_doms[1].name
  else
    -- 0 or 2+: default to powershell. For 2+, picker replaces this on launch.
    config.default_prog = { 'powershell.exe', '-NoLogo' }
  end
end

config.color_scheme = 'Tokyo Night'
config.font         = wezterm.font('JetBrains Mono', { weight = 'Regular' })
config.font_size    = 10.5

-- Toggle between fancy (native GUI, proportional/custom font, top only,
-- frameless Chrome-style) and retro (terminal-cell, supports bottom
-- placement, supports the format-tab-title padding trick below, keeps
-- OS title bar). Flip this single flag to switch styles end-to-end.
local fancy_tabs                   = true

-- Window chrome — fancy mode uses INTEGRATED_BUTTONS|RESIZE for the Chrome
-- look: no OS title bar, WezTerm-drawn min/max/close buttons integrated into
-- the tab bar (colors via button_* in window_frame), resize border preserved.
-- (Pure 'RESIZE' alone leaves a more obvious gap where the OS title used to
-- be on Windows. 'NONE' eliminates the resize border too but breaks Win+Arrow
-- snap and minimize.) Retro keeps the OS title bar since the retro tab bar
-- sits at the bottom and there's no top chrome to host the buttons.
config.window_decorations          = fancy_tabs and 'INTEGRATED_BUTTONS|RESIZE' or 'TITLE | RESIZE'
config.window_background_opacity   = 1.0 -- 0.95
config.enable_tab_bar              = true
config.use_fancy_tab_bar           = fancy_tabs
-- tab_bar_at_bottom is only honored by the retro bar; fancy is always top.
config.tab_bar_at_bottom           = not fancy_tabs
config.hide_tab_bar_if_only_one_tab = false
-- Retro needs headroom for the format-tab-title padding (raise above the
-- default 16 to avoid clipping). Fancy auto-sizes tabs so a smaller cap
-- keeps the bar compact.
config.tab_max_width               = fancy_tabs and 32 or 100

-- Fancy-mode chrome (Tokyo Night-matched). Ignored when use_fancy_tab_bar = false.
-- Font is JetBrains Mono Medium so the tab bar carries the terminal's identity
-- but stays distinct from body text (which uses Regular). The retro tab bar
-- inherits the main terminal font automatically, so JetBrains Mono is applied
-- in both modes without needing a separate retro override.
config.window_frame = {
  font                            = wezterm.font { family = 'JetBrains Mono', weight = 'Medium' },
  font_size                       = 10,
  -- Active bar sits slightly elevated above main bg (#1a1b26) for separation;
  -- inactive drops down to Tokyo Night bg_dark.
  active_titlebar_bg              = '#1f2335',
  inactive_titlebar_bg            = '#16161e',
  active_titlebar_fg              = '#c0caf5',
  inactive_titlebar_fg            = '#565f89',
  active_titlebar_border_bottom   = '#292e42',
  inactive_titlebar_border_bottom = '#15161e',
  button_bg                       = '#1f2335',
  button_fg                       = '#c0caf5',
  button_hover_bg                 = '#292e42',
  button_hover_fg                 = '#c0caf5',
}

-- Tab-bar surfaces (background behind tabs in retro mode + new-tab "+" button
-- in both modes). Per-tab active/inactive/hover colors are driven by
-- format-tab-title above for every tab, so we only need to style the chrome
-- around them. Matches the window_frame palette so retro and fancy modes
-- share the same visual language.
config.colors = {
  tab_bar = {
    background        = '#1a1b26',
    -- Hide the thin tab-edge divider — the default color is a light gray that
    -- pops against the bar bg only when the adjacent surface lightens (e.g.
    -- when hovering the "+" button). Match the bar bg so it disappears in
    -- every state.
    inactive_tab_edge = '#1a1b26',
    new_tab           = { bg_color = '#1a1b26', fg_color = '#565f89' },
    new_tab_hover     = { bg_color = '#292e42', fg_color = '#c0caf5' },
  },
}

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
-- Tab colors — Tokyo Night accent palette + state variants
-- ---------------------------------------------------------------------------
-- SSH hosts get a stable accent from this curated Tokyo Night palette
-- (8-bucket hash on the host name), so you have a cheap visual guard against
-- typing into the wrong host. Active tabs use the full accent for pop; hover
-- darkens slightly to indicate interactivity; inactive desaturates + darkens
-- to a subtle tint that still hints at the color so per-host distinction is
-- preserved when not focused.
--
-- Local tabs (no SSH-domain match) use neutral Tokyo Night surfaces matched
-- to the window_frame palette: bg_highlight when active, bg_dark when
-- inactive — flush with the chrome.
local HOST_ACCENTS = {
  '#7aa2f7',  -- blue
  '#bb9af7',  -- magenta
  '#7dcfff',  -- cyan
  '#9ece6a',  -- green
  '#e0af68',  -- yellow
  '#ff9e64',  -- orange
  '#f7768e',  -- red
  '#73daca',  -- teal
}

local function host_hash(name)
  local h = 0
  for i = 1, #name do
    h = (h * 131 + name:byte(i)) % 65521
  end
  return h
end

local function tab_colors(host, is_active, is_hover)
  if host then
    local accent = wezterm.color.parse(HOST_ACCENTS[(host_hash(host) % #HOST_ACCENTS) + 1])
    if is_active then
      return tostring(accent),                                '#15161e'
    elseif is_hover then
      return tostring(accent:darken(0.20)),                   '#1a1b26'
    end
    return   tostring(accent:desaturate(0.60):darken(0.55)),  '#a9b1d6'
  end
  -- Local tab — neutral Tokyo Night surfaces aligned with window_frame.
  if is_active then
    return '#292e42', '#c0caf5'
  elseif is_hover then
    return '#1f2335', '#c0caf5'
  end
  return '#16161e', '#565f89'
end

-- Forward-declared upvalue: cell width of the right-status line. Assigned
-- by update-right-status (defined further down). Keeps the tab-bar layout
-- in sync with whatever the status line is actually rendering this tick.
local right_status_cells = 30

wezterm.on('format-tab-title', function(tab, all_tabs, panes, _config, hover, max_width)
  local pane   = tab.active_pane
  local domain = pane.domain_name or ''
  local is_wsl = domain:find('^WSL:') ~= nil

  local host
  for _, d in ipairs(ssh_domains) do
    if d.name == domain then host = d.name break end
  end
  -- WSL: derive host from the distro segment so the HOST_ACCENTS hash is
  -- deterministic across renders. Without this, host was only set later via
  -- the user@host fallback once the shell got around to emitting its OSC
  -- title, which made coloring race with shell startup.
  if not host and is_wsl then
    host = domain:gsub('^WSL:', '')  -- e.g. "AlmaLinux-9"
  end
  -- Fallback: if not a WezTerm SSH-domain tab and not WSL, but the shell-set
  -- title is in "user@host[:cwd]" form (typical for manual `ssh <host>` from
  -- a local tab), extract the host so the tab still picks up the per-host
  -- accent.
  if not host then
    local detected = (pane.title or ''):match('^[%w%._%-]+@([%w%._%-]+)')
    if detected and #detected > 0 then host = detected end
  end

  -- Heuristic: a tab_title in "user@host[:cwd]" form was almost certainly set
  -- by the shell's PROMPT_COMMAND via OSC. Anything else (plain words, paths
  -- without @) is treated as a deliberate user rename via CTRL+SHIFT+E and
  -- preserved. We need this because WezTerm exposes a single tab_title field
  -- — shell-set and user-set are indistinguishable at the API level.
  local function looks_shell_set(t)
    return t and t:match('^[%w%._%-]+@[%w%._%-]+') ~= nil
  end

  local title = tab.tab_title
  if is_wsl then
    -- Always show "WSL:<distro>" unless the user has renamed the tab.
    -- Without this branch the title flickered between the domain (first
    -- render, tab_title empty) and the shell-set "user@<distro>:<cwd>"
    -- (later renders, after PROMPT_COMMAND fired).
    if title == nil or #title == 0 or looks_shell_set(title) then
      title = domain
    end
  elseif title == nil or #title == 0 then
    if host then
      title = host
    else
      -- Two cleanups, both no-ops when not applicable:
      --   1. Strip leading "user@" from SSH'd shell titles (PROMPT_COMMAND
      --      OSC escapes, e.g. "user@host:~"). The host + cwd are the useful
      --      bits; the username is implied by being logged in.
      --   2. Reduce a bare Windows .exe path to its basename, since cmd /
      --      powershell tabs come in titled with the full path
      --      (e.g. "C:\WINDOWS\system32\cmd.exe" → "cmd").
      title = (pane.title or '')
        :gsub('^[%w%._%-]+@', '')
        :gsub('^.*[\\/]([^\\/]+)%.[Ee][Xx][Ee]$', '%1')
    end
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

  -- Retro mode: stretch tabs to fill the bar evenly. Fancy mode auto-sizes
  -- tabs and uses a proportional font, so this padding only wastes space —
  -- skip it. (fancy_tabs is the module-scope flag set near use_fancy_tab_bar.)
  if not fancy_tabs then
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
  end

  -- Every tab (host or local) gets explicit bg/fg from tab_colors so active,
  -- hover, and inactive states are visually distinct. Active also gets bold.
  local bg, fg = tab_colors(host, tab.is_active, hover)
  local items = {
    { Background = { Color = bg } },
    { Foreground = { Color = fg } },
  }
  if tab.is_active then
    table.insert(items, { Attribute = { Intensity = 'Bold' } })
  end
  table.insert(items, { Text = label })
  return items
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
-- WSL distro picker — used by the gui-startup handler when 2+ distros exist
-- ---------------------------------------------------------------------------
-- InputSelector listing every distro from wezterm.default_wsl_domains(). The
-- action spawns the chosen distro as a new tab and (if a placeholder tab id
-- was captured by gui-startup) closes the placeholder so the window ends with
-- exactly one tab.
local function wsl_picker_choices()
  local choices = {}
  for _, d in ipairs(wezterm.default_wsl_domains()) do
    table.insert(choices, {
      label = d.distribution or d.name,
      id    = d.name,
    })
  end
  return choices
end

local function build_wsl_picker(placeholder_tab_id)
  return act.InputSelector {
    title    = 'Pick a WSL distro',
    fuzzy    = true,
    choices  = wsl_picker_choices(),
    action   = wezterm.action_callback(function(window, pane, id, _label)
      if not id then return end  -- Esc cancels; placeholder stays as fallback
      -- Spawn chosen distro first (becomes active — 2 tabs in window)
      window:perform_action(act.SpawnTab { DomainName = id }, pane)
      -- Then activate the placeholder and close it. CloseCurrentTab acts on
      -- the active tab, so we activate by id first.
      if placeholder_tab_id then
        for _, t in ipairs(window:mux_window():tabs()) do
          if t:tab_id() == placeholder_tab_id then
            t:activate()
            window:perform_action(act.CloseCurrentTab { confirm = false }, pane)
            break
          end
        end
      end
    end),
  }
end

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
    -- Wezterm: WSL
    { label = 'note  WSL on launch    Picker shows if 2+ WSL distros installed', id = '' },
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

-- "Copied!" badge: timestamps per-window, fires from the 'copied' event
-- emitted by the CTRL+SHIFT+C / CTRL+SHIFT+A bindings below. Visible for
-- COPIED_BADGE_DURATION seconds, then the next ~1s tick of update-right-status
-- removes it. The badge is rendered immediately on copy (not on the next
-- tick) by calling render_right_status from the 'copied' handler directly.
local copied_at = {}
local COPIED_BADGE_DURATION = 2

local function render_right_status(window, pane)
  local dim_info = pane:get_dimensions()
  local cols = (dim_info and dim_info.cols) or 80

  -- Each part: { text = string, fg = '#hex' (optional), bold = bool (optional) }
  local parts = {}

  local domain = pane:get_domain_name()
  -- Show domain + zellij:main in the right status ONLY for SSH-domain tabs.
  -- Local tabs ('local') and WSL tabs ('WSL:<distro>') skip this block:
  -- local tabs have nothing meaningful to show, and WSL surfaces its distro
  -- name via the tab title (format-tab-title) — repeating it next to
  -- battery/time is redundant noise. WSL also has no zellij wrap so
  -- 'zellij:main' would be a lie there.
  if domain and domain ~= 'local' and not domain:find('^WSL:') then
    table.insert(parts, { text = domain })
    if cols >= 130 then
      table.insert(parts, { text = 'zellij:main' })
    end
  end

  if cols >= 80 then
    local bat = format_battery()
    if bat then table.insert(parts, { text = bat }) end
  end

  if cols >= 60 then
    table.insert(parts, { text = time_icon() .. ' ' .. wezterm.strftime('%H:%M') })
  else
    table.insert(parts, { text = wezterm.strftime('%H:%M') })
  end

  -- Tighter separator (' · ' instead of '  │  ') in a dim color so the bar
  -- doesn't dominate visually. The fancy tab bar font (JetBrains Mono Medium)
  -- rendered the heavy '│' with too much weight against the lighter labels.
  local FG     = '#c0caf5'
  local FG_DIM = '#565f89'
  local SEP    = ' · '

  local items = {}
  local plain = ''  -- plain text only — for cell-width measurement

  if #parts > 0 then
    table.insert(items, { Text = ' ' })
    plain = ' '
  end

  for i, p in ipairs(parts) do
    if i > 1 then
      table.insert(items, { Foreground = { Color = FG_DIM } })
      table.insert(items, { Attribute = { Intensity = 'Normal' } })
      table.insert(items, { Text = SEP })
      plain = plain .. SEP
    end
    table.insert(items, { Foreground = { Color = p.fg or FG } })
    table.insert(items, { Attribute = { Intensity = p.bold and 'Bold' or 'Normal' } })
    table.insert(items, { Text = p.text })
    plain = plain .. p.text
  end

  if #parts > 0 then
    table.insert(items, { Text = ' ' })
    plain = plain .. ' '
  end

  local normal_w = display_width(plain)

  -- When a recent copy is active, replace the rendered text with the badge —
  -- but center-pad it to the SAME cell width as the normal status so the
  -- right-status block doesn't resize and the tab-bar layout doesn't shift.
  -- Width-measurement uses the normal width in both branches so format-tab-title
  -- reserves the same space throughout.
  local wid = window:window_id()
  if copied_at[wid] and (os.time() - copied_at[wid] < COPIED_BADGE_DURATION) then
    local badge   = '📋 Copied!'
    local badge_w = display_width(badge)
    local extra   = math.max(0, normal_w - badge_w)
    local left    = math.floor(extra / 2)
    local right   = extra - left
    window:set_right_status(wezterm.format {
      { Text = string.rep(' ', left) },
      { Foreground = { Color = '#9ece6a' } },
      { Attribute = { Intensity = 'Bold' } },
      { Text = badge },
      { Attribute = { Intensity = 'Normal' } },
      { Text = string.rep(' ', right) },
    })
  else
    window:set_right_status(wezterm.format(items))
  end

  right_status_cells = normal_w
end

wezterm.on('update-right-status', render_right_status)

-- Emitted by act.EmitEvent 'copied' in the copy keybindings (CTRL+SHIFT+C,
-- CTRL+SHIFT+A). Re-renders the right status immediately so the badge appears
-- without waiting for the next ~1s update-right-status tick.
wezterm.on('copied', function(window, pane)
  copied_at[window:window_id()] = os.time()
  render_right_status(window, pane)
end)

-- Selection-aware copy: writes to clipboard ONLY if there's a non-empty
-- selection, then fires the badge. Used for every keyboard + mouse copy path
-- so the badge can't appear on a click with no selection or an empty Ctrl-C.
-- For scrollback-all (CTRL+SHIFT+A) we skip this helper since the action chain
-- explicitly creates a selection — we already know there's content to copy.
local copy_and_announce = wezterm.action_callback(function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if not sel or #sel == 0 then return end
  window:perform_action(act.CopyTo 'Clipboard', pane)
  copied_at[window:window_id()] = os.time()
  render_right_status(window, pane)
end)

-- ---------------------------------------------------------------------------
-- Keybinds
-- ---------------------------------------------------------------------------
-- Zellij owns Ctrl+p and pane management inside the session.
-- Wezterm handles window/tab creation at the OS level.
-- Mouse: drag-then-release on left button completes the selection AND, if
-- non-empty, writes to clipboard + flashes the "Copied!" badge. The Up event
-- also fires on plain clicks; copy_and_announce no-ops on empty selection, so
-- there's no spurious badge. We don't override Shift-Up or double/triple-click
-- streaks — those keep their default behavior (link-open, word/line select).
-- Mouse bindings layer over defaults, so other mouse actions are preserved.
config.mouse_bindings = {
  {
    event = { Up = { streak = 1, button = 'Left' } },
    action = act.Multiple {
      act.CompleteSelection 'PrimarySelection',
      copy_and_announce,
    },
  },
}

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

  -- Copy/paste. copy_and_announce is selection-aware: it only writes to the
  -- clipboard (and shows the badge) if there's actually a selection, so a
  -- bare keypress with nothing selected is a no-op. Bound to both CTRL+SHIFT+C
  -- and the legacy CTRL+Insert.
  { key = 'c',      mods = 'CTRL|SHIFT', action = copy_and_announce },
  { key = 'Insert', mods = 'CTRL',       action = copy_and_announce },
  { key = 'v',      mods = 'CTRL|SHIFT', action = act.PasteFrom 'Clipboard' },

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
      act.EmitEvent 'copied',
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
-- Multi-distro WSL picker (deferred to first update-status tick)
-- ---------------------------------------------------------------------------
-- The "show picker before first tab" UX requires bridging gui-startup (no GUI
-- Window yet) and update-status (GUI Window exists, ~1s after launch). We
-- spawn the placeholder powershell tab in gui-startup, stash its tab id keyed
-- by mux window id, then fire the picker from update-status — once per window.
-- The existing update-status handler at render_right_status is a separate
-- registration; WezTerm composes multiple handlers per event without conflict.
local wsl_picker_pending = {}

wezterm.on('gui-startup', function(cmd)
  if not wezterm.target_triple:find('windows') then return end
  if #wsl_doms < 2 then return end  -- 0 or 1 handled by default_prog/default_domain

  local tab, _, mux_window = wezterm.mux.spawn_window(cmd or {})
  wsl_picker_pending[mux_window:window_id()] = tab:tab_id()
end)

wezterm.on('update-status', function(window, pane)
  local wid = window:window_id()
  local placeholder_tab_id = wsl_picker_pending[wid]
  if not placeholder_tab_id then return end
  wsl_picker_pending[wid] = nil  -- one-shot per window
  window:perform_action(build_wsl_picker(placeholder_tab_id), pane)
end)

-- ---------------------------------------------------------------------------
-- SSH quick-connect function (call from wezterm CLI)
-- ---------------------------------------------------------------------------
-- Usage: wezterm connect rhel-dev-01
-- This is already handled by ssh_domains above.

return config
