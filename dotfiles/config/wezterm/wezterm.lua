-- WezTerm's config, loaded straight from the Windows checkout
-- (dotfiles/config/wezterm/wezterm.lua): WEZTERM_CONFIG_FILE names it, so no copy is
-- deployed, and a save here or a wsu pull reloads every window (Ctrl+Shift+R forces it).
--
-- Windows installs WezTerm's nightly build per-user (scripts/wezterm-nightly.ps1, run after
-- every tools phase, which also keeps its Start Menu shortcut, registers its toast id, sets
-- WEZTERM_CONFIG_FILE and puts the wezterm CLI on the User PATH).
-- It sits beside Warp (the primary terminal) and Windows Terminal (the default one):
-- Catppuccin Mocha with the mauve accent, JetBrainsMono NFM 10.5, Nushell through mise's
-- shim, no title bar, and the tab bar at the bottom with a status footer on its right.
-- Ctrl+Shift+H lists every key.
-- WezTerm runs Lua 5.4; scripts/check-invariants.sh (check_wezterm_config) runs this file
-- and its event handlers under LuaJIT with a stand-in wezterm module, so keep to Lua 5.1
-- syntax and give each new wezterm.* call a stand-in there. Never call wezterm.gui.* at
-- load: before the GUI exists it deadlocks WezTerm, and pcall can't catch a hang.

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()
local windows = wezterm.target_triple:find('windows') ~= nil

-- Updates come from scripts/wezterm-nightly.ps1 (every wsu), not WezTerm's own check.
config.check_for_updates = false

-- Look -------------------------------------------------------------------------------
local mocha = {
  base = '#1e1e2e',
  mantle = '#181825',
  crust = '#11111b',
  surface0 = '#313244',
  surface1 = '#45475a',
  surface2 = '#585b70',
  overlay0 = '#6c7086',
  text = '#cdd6f4',
  blue = '#89b4fa',
  mauve = '#cba6f7',
  sky = '#89dceb',
  teal = '#94e2d5',
  green = '#a6e3a1',
  yellow = '#f9e2af',
  peach = '#fab387',
  red = '#f38ba8',
}

-- WezTerm's built-in Catppuccin Mocha, with the fleet's mauve accent on the cursor and the
-- active tab, and Mocha colours on the surfaces the scheme leaves stock grey or olive: the
-- quick-select labels, copy mode, the launcher and the InputSelector overlays.
local scheme = wezterm.color.get_builtin_schemes()['Catppuccin Mocha']
scheme.cursor_bg = mocha.mauve
scheme.cursor_border = mocha.mauve
scheme.cursor_fg = mocha.crust
scheme.scrollbar_thumb = mocha.surface2
scheme.visual_bell = mocha.peach
scheme.tab_bar = {
  background = mocha.base,
  inactive_tab_edge = mocha.base,
  active_tab = { bg_color = mocha.mauve, fg_color = mocha.crust },
  inactive_tab = { bg_color = mocha.base, fg_color = mocha.overlay0 },
  inactive_tab_hover = { bg_color = mocha.surface1, fg_color = mocha.text },
  new_tab = { bg_color = mocha.base, fg_color = mocha.overlay0 },
  new_tab_hover = { bg_color = mocha.surface1, fg_color = mocha.text },
}
scheme.quick_select_label_bg = { Color = mocha.peach }
scheme.quick_select_label_fg = { Color = mocha.crust }
scheme.quick_select_match_bg = { Color = mocha.surface1 }
scheme.quick_select_match_fg = { Color = mocha.sky }
scheme.copy_mode_active_highlight_bg = { Color = mocha.mauve }
scheme.copy_mode_active_highlight_fg = { Color = mocha.crust }
scheme.copy_mode_inactive_highlight_bg = { Color = mocha.surface2 }
scheme.copy_mode_inactive_highlight_fg = { Color = mocha.text }
scheme.input_selector_label_bg = { Color = mocha.crust }
scheme.input_selector_label_fg = { Color = mocha.text }
scheme.launcher_label_bg = { Color = mocha.crust }
scheme.launcher_label_fg = { Color = mocha.text }
config.color_schemes = { ['Catppuccin Mocha (mauve)'] = scheme }
config.color_scheme = 'Catppuccin Mocha (mauve)'
config.command_palette_bg_color = mocha.crust
config.command_palette_fg_color = mocha.text
config.command_palette_font_size = 12.0
config.char_select_bg_color = mocha.crust
config.char_select_fg_color = mocha.text
config.char_select_font_size = 12.0

-- bootstrap.ps1 installs JetBrainsMono Nerd Font Mono (family "JetBrainsMono NFM", the
-- name Windows Terminal uses); WezTerm's bundled JetBrains Mono and Nerd Font symbols
-- cover a host without it.
config.font = wezterm.font_with_fallback({ 'JetBrainsMono NFM', 'JetBrains Mono' })
config.font_size = 10.5
config.default_cursor_style = 'BlinkingBar'
config.cursor_blink_rate = 500
config.cursor_thickness = '1.5pt'

-- No title bar. RESIZE keeps the thin resize frame, so Win+arrow snap, drag-to-edge snap
-- and minimize still work ('NONE' loses them). Move the window with Ctrl+Shift+drag
-- (WezTerm's default) or Win+drag (mouse bindings below). The tab bar sits at the bottom,
-- terminal-font style, with the status footer on its right.
config.window_decorations = 'RESIZE'
config.use_fancy_tab_bar = false
config.tab_bar_at_bottom = true
config.tab_max_width = 32
config.enable_scroll_bar = true
config.window_padding = { left = 8, right = 16, top = 6, bottom = 6 }
-- Split the leftover pixels when the window isn't a whole number of cells (snapped or
-- maximized windows rarely are) instead of leaving them all on the right and bottom.
config.window_content_alignment = { horizontal = 'Center', vertical = 'Center' }
config.initial_cols = 140
config.initial_rows = 38

-- Rendering: D3D12-backed WebGpu at 120 fps on every host. Measured on this fleet's Intel
-- laptop: a 60 fps cap (the panel's rate) and OpenGL both felt slower than Windows
-- Terminal. A higher max_fps repaints sooner after a key press, so the next vsync shows it.
-- front_end and webgpu_power_preference need a WezTerm restart; the rest reload.
config.front_end = 'WebGpu'
config.webgpu_power_preference = 'HighPerformance'
config.max_fps = 120
-- Cursor blink and bell fades only; 60 keeps them smooth for half the repaints.
config.animation_fps = 60

-- BEL flashes the cursor peach; the audible bell stays, as ~/.claude/notify.sh relies on it.
config.visual_bell = {
  fade_in_function = 'EaseIn',
  fade_in_duration_ms = 75,
  fade_out_function = 'EaseOut',
  fade_out_duration_ms = 150,
  target = 'CursorColor',
}

-- One million lines per pane. A pane's buffer grows only as lines scroll off, but a busy
-- pane can hold hundreds of MB (the retired config measured ~745 MB over three days at
-- this depth); Ctrl+Shift+K clears one. zellij keeps its own buffer, so an SSH tab
-- running it scrolls there. The larger render caches keep fast scrolling through a deep
-- buffer from reshaping every line each frame.
config.scrollback_lines = 1000000
config.shape_cache_size = 4096
config.line_state_cache_size = 4096
config.line_quad_cache_size = 4096
config.line_to_ele_shape_cache_size = 4096
config.glyph_cache_image_cache_size = 1024

-- TERM=wezterm: its terminfo entry adds truecolour (Tc), undercurl (Smulx) and OSC 52
-- clipboard (Ms) over xterm-256color. Linux hosts compile it into ~/.terminfo
-- (tasks/wezterm-terminfo, the final hook); EL ships none system-wide. Where the entry is
-- missing, xterm-256color stands in: zshrc/bashrc switch to it, wrap sudo (root lacks the
-- entry) and probe a host before ssh sends it; the SSH launch entries below check on the
-- host; and the Windows shells switch to it, because Windows has no terminfo database and
-- Neovim there falls back to a bare 'ansi' entry for a TERM it doesn't know.
config.term = 'wezterm'

-- Behaviour -----------------------------------------------------------------------------
-- OSC 9 / 777 toasts only for panes you aren't looking at. Windows shows them once
-- wezterm-nightly.ps1 has registered the org.wezfurlong.wezterm toast id.
config.notification_handling = 'SuppressFromFocusedPane'
config.switch_to_last_active_tab_when_closing_tab = true
config.unzoom_on_switch_pane = true
-- Closing a tab (Ctrl+Shift+W) or the window never asks: an SSH tab's zellij session
-- survives and reattaches (launcher, Ctrl+Shift+F5), and a local shell holds nothing a
-- prompt would save.
config.window_close_confirmation = 'NeverPrompt'
-- Kitty's keyboard protocol for the apps that ask for it (helix gets unambiguous keys,
-- zellij passes it on); the rest are untouched. On Windows, ConPTY panes keep
-- win32-input-mode. If a TUI misbehaves after an update, turn this off first.
config.enable_kitty_keyboard = true
-- The pane picker's (Ctrl+Shift+Q) letters.
config.pane_select_fg_color = mocha.mauve
config.pane_select_bg_color = mocha.crust
-- Dropped files paste as a quoted path, which parentheses in Windows paths need.
config.quote_dropped_files = 'WindowsAlwaysQuoted'
-- Inline images (yazi previews, wezterm imgcat) in local, WSL and plain SSH panes; zellij
-- has no kitty-graphics passthrough.
config.enable_kitty_graphics = true

-- Links: WezTerm's defaults, plus #123 to this repository's issues and pull requests
-- (GitHub redirects an issue URL to the PR). \B# skips word#12; the trailing \b skips hex
-- colours such as #1e1e2e. Ctrl+click opens a link (a plain click ends a selection, which
-- is copied); Shift+click also works inside zellij, helix and other apps that take the mouse.
config.hyperlink_rules = wezterm.default_hyperlink_rules()
table.insert(config.hyperlink_rules, {
  regex = [[\B#(\d+)\b]],
  format = 'https://github.com/ArrushC/workstation/issues/$1',
})
-- Quick select (Ctrl+Shift+Space) adds IPv4 addresses and #123 references to its URLs,
-- paths and hashes, and greys the pane out so the labels stand out.
config.quick_select_patterns = { [[\b\d{1,3}(?:\.\d{1,3}){3}\b]], [[\B#\d+\b]] }
config.quick_select_remove_styling = true

-- Shells ----------------------------------------------------------------------------
-- ~/.ssh/config.local's concrete Host aliases (patterns, negations and names that would
-- need quoting skipped), as bootstrap.ps1's Get-SshLauncherHosts reads them, and a map
-- from each name a host goes by (the alias; its HostName, and that name's short form) to
-- its block's first alias.
local function ssh_config()
  local hosts, aliases, real = {}, {}, {}
  local f = io.open(wezterm.home_dir .. '/.ssh/config.local', 'r')
  if not f then
    return hosts, aliases, real
  end
  local block = {}
  for line in f:lines() do
    line = line:gsub('%s#.*$', '')
    local list = line:match('^%s*[Hh][Oo][Ss][Tt]%s*=%s*(.+)$') or line:match('^%s*[Hh][Oo][Ss][Tt]%s+(.+)$')
    local name = line:match('^%s*[Hh][Oo][Ss][Tt][Nn][Aa][Mm][Ee]%s*=%s*(%S+)') or line:match('^%s*[Hh][Oo][Ss][Tt][Nn][Aa][Mm][Ee]%s+(%S+)')
    if list then
      block = {}
      for token in list:gmatch('%S+') do
        if not token:find('[%*%?!]') and token:match('^[%w%._@%-]+$') then
          table.insert(block, token)
          if not aliases[token:lower()] then
            aliases[token:lower()] = token
            table.insert(hosts, token)
          end
        end
      end
    elseif line:find('^%s*[Mm][Aa][Tt][Cc][Hh][%s=]') then
      block = {}
    elseif name and block[1] and not name:find('%%') then
      name = name:lower()
      real[name] = real[name] or block[1]
      -- An address has no short form (10.0.0.9 isn't host "10").
      if name:find('%a') and not name:find(':') then
        local short = name:match('^[^.]*')
        real[short] = real[short] or block[1]
      end
    end
  end
  f:close()
  return hosts, aliases, real
end
local ssh_hosts, ssh_aliases, ssh_real = ssh_config()

-- The name a host goes by here: its alias, when the name (or its short form) is one or is
-- its HostName. So an SSH tab to dev10 and a WSL tab whose OSC 7 says atc-cache-dev10.corp
-- show the same name in the same colour. Other names pass through.
local function canonical(host)
  local h = host:lower()
  return ssh_aliases[h] or ssh_real[h] or ssh_real[h:match('^[^.]*')] or host
end

-- Launch entries run in the local domain: without it an entry picked from a WSL tab would
-- run inside Linux (pwsh.exe, the Windows ssh, Nushell's shim).
local here = { DomainName = 'local' }
config.launch_menu = {}
if windows then
  -- Nushell through mise's shim, as Windows Terminal's default profile starts it.
  local nu = (os.getenv('LOCALAPPDATA') or '') .. '\\mise\\shims\\nu.exe'
  local shim = io.open(nu, 'r')
  if shim then
    shim:close()
    config.default_prog = { nu }
    table.insert(config.launch_menu, { label = 'Nushell', args = { nu }, domain = here })
  end
  table.insert(config.launch_menu, { label = 'PowerShell', args = { 'pwsh.exe', '-NoLogo' }, domain = here })
  table.insert(config.launch_menu, { label = 'Windows PowerShell', args = { 'powershell.exe', '-NoLogo' }, domain = here })
  table.insert(config.launch_menu, { label = 'cmd', args = { 'cmd.exe' }, domain = here })
  -- WSL tabs start in the distro's home: WezTerm hands this '~' to wsl.exe as is
  -- (`--cd ~`), which expands it inside Linux. New tabs and splits then follow the shell's
  -- OSC 7 (spawn_from, below).
  local wsl = wezterm.default_wsl_domains()
  for _, d in ipairs(wsl) do
    d.default_cwd = '~'
  end
  config.wsl_domains = wsl
end
-- ssh sends TERM=wezterm with the pty; a host without that terminfo entry starts zellij
-- with xterm-256color instead.
local attach = 'infocmp wezterm >/dev/null 2>&1 || export TERM=xterm-256color; exec zellij attach --create main'
for _, host in ipairs(ssh_hosts) do
  table.insert(config.launch_menu, { label = 'SSH: ' .. host, args = { 'ssh', '-t', host, attach }, domain = here })
end
-- No built-in SSH domains: by default WezTerm lists SSH: and SSHMUX: domains for every
-- ~/.ssh/config host, with its own SSH client, and SSHMUX: needs WezTerm on the server.
-- The entries above use the system's ssh, as the other terminals do.
config.ssh_domains = {}

-- SSH tabs ----------------------------------------------------------------------------
-- The host an SSH tab is on: the destination of the ssh in front, read from its arguments
-- (the launcher's ssh, or one typed in Nushell or PowerShell), or for a WSL tab the host in
-- the OSC 7 that zshrc/bashrc send over ssh. It colours the tab, names it, shows in the
-- footer and drives Ctrl+Shift+F5 and file links. The last ssh seen in a pane is kept in
-- wezterm.GLOBAL, so Ctrl+Shift+F5 can rerun it once it has exited (and a reload keeps it).

-- ssh's options that take a value, as zshrc/bashrc's ssh wrapper skips them.
local ssh_value_flags = 'BbcDEeFIiJLlmOoPpQRSWw'

-- The destination argument and its index in argv, or nil.
local function ssh_dest(argv)
  local want = false
  for i = 2, #argv do
    local a = argv[i]
    if want then
      want = false
    elseif a:sub(1, 1) == '-' and #a > 1 then
      local rest = a:sub(2)
      for j = 1, #rest do
        if a ~= '--' and ssh_value_flags:find(rest:sub(j, j), 1, true) then
          want = j == #rest
          break
        end
      end
    else
      return a, i
    end
  end
end

-- The zellij session a remote command attaches (the launcher's `zellij attach --create
-- main`), or nil.
local function zellij_session(cmd)
  local rest = cmd:match('zellij%s+attach%s+(.*)$') or cmd:match('zellij%s+a%s+(.*)$')
  for word in (rest or ''):gmatch('[^%s;&|]+') do
    if word:sub(1, 1) ~= '-' then
      return word
    end
  end
end

-- { host, argv, dest, zellij } for a pane whose foreground program is ssh, or the last one
-- seen in it once ssh has exited; nil for a live local shell. `pane` is a Pane object.
local function ssh_of(pane)
  local id = tostring(pane:pane_id())
  local seen = wezterm.GLOBAL.ssh_panes or {}
  local info = pane:get_foreground_process_info()
  if not info then
    return seen[id]
  end
  local name = (info.name or ''):lower():gsub('%.exe$', '')
  local dest, at
  if name == 'ssh' and info.argv then
    dest, at = ssh_dest(info.argv)
  end
  if dest then
    local host = canonical((dest:gsub('^ssh://', ''):gsub('^.*@', ''):gsub(':%d+$', '')))
    if not seen[id] or seen[id].host ~= host then
      local session = zellij_session(table.concat(info.argv, ' ', at + 1))
      seen[id] = { host = host, argv = info.argv, dest = dest, zellij = session }
      wezterm.GLOBAL.ssh_panes = seen
    end
    return seen[id]
  end
  if seen[id] then
    seen[id] = nil
    wezterm.GLOBAL.ssh_panes = seen
  end
end

local local_host = (wezterm.hostname() or ''):lower():match('^[^.]*')

-- A WSL pane's remote host: the OSC 7 host when it is neither this machine nor the distro.
-- `cwd` is a pane's current_working_dir (a Url, or a string in PaneInformation).
local function wsl_remote(cwd, distro)
  local host = cwd and tostring(cwd):match('^file://([^/]+)/')
  local short = host and host:lower():match('^[^.]*')
  if short and short ~= '' and short ~= 'localhost' and short ~= local_host and short ~= distro:lower() then
    return canonical(host)
  end
end

-- A stable Mocha accent per host name, so each machine keeps its colour.
local accents = { mocha.blue, mocha.mauve, mocha.sky, mocha.green, mocha.yellow, mocha.peach, mocha.red, mocha.teal }
local function accent(host)
  local h = 0
  for i = 1, #host do
    h = (h * 131 + host:byte(i)) % 65521
  end
  return accents[h % #accents + 1]
end

-- Single-quoted for a POSIX shell on the far side of ssh.
local function shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- helix in a WSL distro: wsl.exe runs a spawned program without a login shell, so mise's
-- shims aren't on PATH yet.
local function wsl_hx(path)
  return { 'sh', '-c', 'PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"; exec hx "$1"', 'hx', path }
end

-- Notices -------------------------------------------------------------------------------
-- A short coloured message in the status footer ("Copied", "Config reloaded"): WezTerm's
-- Lua has no overlay that neither takes focus nor writes into the pane. Seconds-long, so
-- they live in this VM; a reload only drops one that was about to expire anyway.
local notices = {}
local levels = { info = { fg = mocha.green, secs = 2 }, warn = { fg = mocha.peach, secs = 4 } }
local render_status

local function flash(window, pane, text, level)
  local lv = levels[level] or levels.info
  notices[window:window_id()] = { text = text, fg = lv.fg, expires = os.time() + lv.secs }
  render_status(window, pane)
end

-- Actions -------------------------------------------------------------------------------
local launcher = act.ShowLauncherArgs({ flags = 'FUZZY|LAUNCH_MENU_ITEMS|DOMAINS' })

-- Where a new tab or split from this pane starts: WezTerm's default (the pane's domain and
-- directory), except that a WSL pane whose directory isn't one in the distro starts in
-- its home. Before the shell's first OSC 7, and inside zellij (which keeps OSC 7 to
-- itself), WezTerm knows only wsl.exe's Windows directory (/mnt/c/Users/<you> in Linux);
-- after an ssh the OSC 7 path is on the other host, which wsl.exe can't enter (it prints
-- an error and starts in /).
local function spawn_from(pane)
  local domain = pane:get_domain_name() or ''
  if domain:find('^WSL:') then
    local cwd = pane:get_current_working_dir()
    local path = cwd and cwd.file_path or ''
    if path == '' or path:find('^/%a:') or wsl_remote(cwd, (domain:gsub('^WSL:', ''))) then
      return { domain = { DomainName = domain }, cwd = '~' }
    end
  end
  return { domain = 'CurrentPaneDomain' }
end

-- Ctrl+Shift+T and the tab bar's + (left-click).
local new_tab = wezterm.action_callback(function(window, pane)
  window:perform_action(act.SpawnCommandInNewTab(spawn_from(pane)), pane)
end)

-- Alt+Shift+D / R: `how` is SplitVertical (down) or SplitHorizontal (right).
local function split(how)
  return wezterm.action_callback(function(window, pane)
    window:perform_action(act[how](spawn_from(pane)), pane)
  end)
end

-- Copy only when something is selected, so the notice never claims an empty copy.
local copy = wezterm.action_callback(function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if sel and sel ~= '' then
    window:perform_action(act.CopyTo('Clipboard'), pane)
    flash(window, pane, 'Copied')
  end
end)

-- After a mouse selection completes (it copies): say so, unless it was a plain click.
local copied_notice = wezterm.action_callback(function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if sel and sel ~= '' then
    flash(window, pane, 'Copied')
  end
end)

-- The whole scrollback, through copy mode. CopyMode 'Close' no longer scrolls to the
-- bottom on the nightly, hence the explicit ScrollToBottom.
local copy_scrollback = act.Multiple({
  act.ActivateCopyMode,
  act.CopyMode('MoveToScrollbackTop'),
  act.CopyMode({ SetSelectionMode = 'Cell' }),
  act.CopyMode('MoveToScrollbackBottom'),
  act.CopyTo('Clipboard'),
  act.CopyMode('Close'),
  act.ScrollToBottom,
  act.EmitEvent('copied-scrollback'),
})

-- Prefilled with the current name; an empty name goes back to the automatic title.
local rename_tab = wezterm.action_callback(function(window, pane)
  window:perform_action(
    act.PromptInputLine({
      description = 'Tab name (empty for the automatic title)',
      initial_value = window:active_tab():get_title(),
      action = wezterm.action_callback(function(win, _, line)
        if line then
          win:active_tab():set_title(line)
        end
      end),
    }),
    pane
  )
end)

-- Ctrl+Shift+F5: rerun a dead (or hung) SSH tab's ssh in a new tab; zellij reattaches
-- its session. The old tab stays for its scrollback.
local reconnect = wezterm.action_callback(function(window, pane)
  local s = ssh_of(pane)
  if not s then
    flash(window, pane, 'Not an SSH tab: nothing to reconnect', 'warn')
    return
  end
  window:perform_action(act.SpawnCommandInNewTab({ args = s.argv, domain = here }), pane)
end)

-- Ctrl+Shift+O: the pane's scrollback in helix, in a new tab on the same machine (a temp
-- file, one per pane). An SSH tab's history is in zellij, which WezTerm only sees a screen
-- of; zellij's own edit-scrollback key opens it there.
local scrollback_in_helix = wezterm.action_callback(function(window, pane)
  if ssh_of(pane) then
    flash(window, pane, "zellij holds this tab's scrollback: use its edit-scrollback key", 'warn')
    return
  end
  local dims = pane:get_dimensions()
  local text = pane:get_lines_as_text(dims.scrollback_rows)
  local dir = os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp'
  local file = dir .. (windows and '\\' or '/') .. 'wezterm-scrollback-' .. pane:pane_id() .. '.txt'
  local f, err = io.open(file, 'w')
  if not f then
    flash(window, pane, 'Could not write the scrollback: ' .. tostring(err), 'warn')
    return
  end
  f:write(text)
  f:close()
  local domain = pane:get_domain_name() or ''
  if domain:find('^WSL:') then
    -- C:\Users\me\...\x.txt is /mnt/c/Users/me/.../x.txt inside the distro.
    local linux = file:gsub('\\', '/'):gsub('^(%a):', function(d)
      return '/mnt/' .. d:lower()
    end)
    window:perform_action(act.SpawnCommandInNewTab({ args = wsl_hx(linux), domain = { DomainName = domain } }), pane)
  else
    local hx = windows and (os.getenv('LOCALAPPDATA') or '') .. '\\mise\\shims\\hx.exe' or 'hx'
    window:perform_action(act.SpawnCommandInNewTab({ args = { hx, file }, domain = here }), pane)
  end
end)

-- Ctrl+Shift+S: a fuzzy tab list that keeps each tab's real number (the launcher renumbers
-- what it filters), with the host or domain beside it.
local switch_tab = wezterm.action_callback(function(window, pane)
  local active = window:active_tab():tab_id()
  local choices = {}
  for i, tab in ipairs(window:mux_window():tabs()) do
    local p = tab:active_pane()
    local s = ssh_of(p)
    local where = s and s.host or (p:get_domain_name() or ''):gsub('^local$', '')
    local title = tab:get_title()
    if title == '' then
      title = p:get_title()
    end
    table.insert(choices, {
      id = tostring(tab:tab_id()),
      label = string.format('%s %d: %s%s', tab:tab_id() == active and '●' or ' ', i, title, where ~= '' and ('  [' .. where .. ']') or ''),
    })
  end
  window:perform_action(
    act.InputSelector({
      title = 'Switch tab',
      fuzzy = true,
      choices = choices,
      action = wezterm.action_callback(function(win, _, id)
        for _, t in ipairs(id and win:mux_window():tabs() or {}) do
          if tostring(t:tab_id()) == id then
            t:activate()
            return
          end
        end
      end),
    }),
    pane
  )
end)

-- Alt+Shift+S: resize mode. Arrows move the split 3 cells at a time until Esc or Enter;
-- the footer says RESIZE meanwhile. (Ctrl+Shift+Alt+arrows still move it by one.)
local resize_mode = act.ActivateKeyTable({ name = 'resize_pane', one_shot = false })
config.key_tables = {
  resize_pane = {
    { key = 'LeftArrow', action = act.AdjustPaneSize({ 'Left', 3 }) },
    { key = 'RightArrow', action = act.AdjustPaneSize({ 'Right', 3 }) },
    { key = 'UpArrow', action = act.AdjustPaneSize({ 'Up', 3 }) },
    { key = 'DownArrow', action = act.AdjustPaneSize({ 'Down', 3 }) },
    { key = 'Escape', action = act.PopKeyTable },
    { key = 'Enter', action = act.PopKeyTable },
  },
}

-- Quick selects that act on the pick. Both type into the pane as a paste, so the pane's
-- own shell does the work wherever it runs (Nushell, WSL zsh, a host through ssh and
-- zellij) and relative paths resolve against its directory. A pane showing a full-screen
-- app (zellij, an editor) gets the text without Enter, for you to check first.
local open_in_helix = act.QuickSelectArgs({
  label = 'open in helix',
  patterns = { [[[\w./~-]+:\d+(?::\d+)?]] },
  action = wezterm.action_callback(function(window, pane)
    local sel = window:get_selection_text_for_pane(pane)
    if sel and sel ~= '' then
      pane:paste('hx ' .. sel)
      if not pane:is_alt_screen_active() then
        pane:send_text('\r')
      end
    end
  end),
})
local paste_sha = act.QuickSelectArgs({
  label = 'paste into the prompt',
  patterns = { [[\b[0-9a-f]{7,40}\b]] },
  action = wezterm.action_callback(function(window, pane)
    local sel = window:get_selection_text_for_pane(pane)
    if sel and sel ~= '' then
      pane:paste(sel)
    end
  end),
})

-- Keys ----------------------------------------------------------------------------------
local bindings -- set below the cheatsheet, which reads it when it opens

-- WezTerm defaults worth knowing, mouse gestures and what the footer and tabs show.
local reference = {
  { 'Ctrl+Tab', 'Next tab (Ctrl+Shift+Tab: previous)' },
  { 'Ctrl+Shift+N', 'New window' },
  { 'Ctrl+Shift+Z', 'Toggle pane zoom' },
  { 'Ctrl+Shift+Alt+arrows', 'Resize the pane by one cell' },
  { 'Ctrl+Shift+F', 'Search the scrollback' },
  { 'Ctrl+Shift+X', 'Copy mode (COPY in the footer)' },
  { 'Ctrl+Shift+Space', 'Quick select: URLs, paths, hashes, IPs, #123' },
  { 'Ctrl+Shift+K', 'Clear the scrollback' },
  { 'Ctrl+Shift+V', 'Paste' },
  { 'Ctrl+Shift+P', 'Command palette' },
  { 'Ctrl+Shift+U', 'Character and emoji picker' },
  { 'Ctrl+= / - / 0', 'Font size bigger / smaller / reset' },
  { 'Ctrl+Shift+R', 'Reload this config' },
  { 'Ctrl+Shift+L', 'Debug overlay (Lua console, logs)' },
  { 'Alt+Enter', 'Full screen' },
  { 'Ctrl+click', 'Open a link (a file:// one in helix, on the machine it came from)' },
  { 'Shift+click', 'Open a link, also inside zellij and helix' },
  { 'Ctrl+triple-click', "Select one command's whole output and copy it" },
  { 'Ctrl+Shift+drag', 'Move the window (Win+drag too)' },
  { '+ on the tab bar', 'Click: new tab; middle-click: tab list; right-click: launcher' },
  { 'select', 'Selecting with the mouse copies (Copied in the footer)' },
  { 'footer', 'SSH host (zellij session), lines in the pane, battery, time; COPY / SEARCH / RESIZE in those modes' },
  { 'tab colours', 'An SSH tab takes its host colour and name (its ~/.ssh/config.local alias)' },
  { 'tab marks', "Bell rang, % progress, dot: output you haven't seen" },
}

local names = { LeftArrow = 'Left', RightArrow = 'Right', UpArrow = 'Up', DownArrow = 'Down' }
local function chord(mods, key)
  local out = {}
  for m in mods:gmatch('[^|]+') do
    table.insert(out, m:sub(1, 1) .. m:sub(2):lower())
  end
  table.insert(out, names[key] or key:upper())
  return table.concat(out, '+')
end

local function cheatsheet_rows()
  local rows = {}
  local function row(left, right, id)
    table.insert(rows, { label = string.format('%-26s %s', left, right), id = id })
  end
  for _, b in ipairs(bindings) do
    if b[4] then
      row(b.chord or chord(b[1], b[2]), b[4])
    end
  end
  for _, r in ipairs(reference) do
    row(r[1], r[2])
  end
  -- Enter on one of these opens it in a new tab.
  for i, item in ipairs(config.launch_menu) do
    row('launch', item.label, tostring(i))
  end
  return rows
end

local cheatsheet = wezterm.action_callback(function(window, pane)
  window:perform_action(
    act.InputSelector({
      title = 'WezTerm keys (type to filter; Enter on a launch row opens it)',
      fuzzy = true,
      choices = cheatsheet_rows(),
      action = wezterm.action_callback(function(win, p, id)
        local item = id and config.launch_menu[tonumber(id)]
        if item then
          win:perform_action(act.SpawnCommandInNewTab(item), p)
        end
      end),
    }),
    pane
  )
end)

-- WezTerm's own bindings use Ctrl+Shift, so zellij keeps Ctrl and Alt. Each entry carries
-- its cheatsheet line (Ctrl+Shift+H), so the two can't drift; `chord` names a group.
-- The pane keys are Warp's and Windows Terminal's (README's tables).
bindings = {
  { 'CTRL|ALT', 'l', launcher, 'Launcher: shells, WSL, SSH hosts (zellij)' },
  { 'CTRL|SHIFT', 't', new_tab, "New tab, in this tab's domain and directory" },
  { 'ALT|SHIFT', 'D', split('SplitVertical'), 'Split pane down' },
  { 'ALT|SHIFT', 'R', split('SplitHorizontal'), 'Split pane right' },
  { 'ALT|SHIFT', 'LeftArrow', act.ActivatePaneDirection('Left'), 'Move between panes', chord = 'Alt+Shift+arrows' },
  { 'ALT|SHIFT', 'RightArrow', act.ActivatePaneDirection('Right') },
  { 'ALT|SHIFT', 'UpArrow', act.ActivatePaneDirection('Up') },
  { 'ALT|SHIFT', 'DownArrow', act.ActivatePaneDirection('Down') },
  -- Ctrl+Shift too, as the retired config had them (WezTerm binds those to pane moves).
  { 'CTRL', 'UpArrow', act.ScrollToPrompt(-1), 'Previous / next prompt', chord = 'Ctrl(+Shift)+Up / Down' },
  { 'CTRL', 'DownArrow', act.ScrollToPrompt(1) },
  { 'CTRL|SHIFT', 'UpArrow', act.ScrollToPrompt(-1) },
  { 'CTRL|SHIFT', 'DownArrow', act.ScrollToPrompt(1) },
  -- WezTerm binds these to pane moves, which swallowed zsh's select-by-word.
  { 'CTRL|SHIFT', 'LeftArrow', act.DisableDefaultAssignment, 'Reach the shell (zsh selects by word)', chord = 'Ctrl+Shift+Left / Right' },
  { 'CTRL|SHIFT', 'RightArrow', act.DisableDefaultAssignment },
  { 'CTRL|SHIFT', 'c', copy, 'Copy the selection', chord = 'Ctrl+Shift+C / Ctrl+Insert' },
  { 'CTRL', 'Insert', copy },
  { 'CTRL|SHIFT', 'a', copy_scrollback, 'Copy the whole scrollback' },
  { 'CTRL|SHIFT', 'e', rename_tab, 'Rename the tab' },
  { 'CTRL|SHIFT', 'g', open_in_helix, 'Quick select a file:line, open it in helix' },
  { 'CTRL|SHIFT', 'y', paste_sha, 'Quick select a commit SHA, paste it at the prompt' },
  { 'CTRL|SHIFT', 'w', act.CloseCurrentTab({ confirm = false }), 'Close the tab (no prompt)' },
  { 'CTRL|SHIFT', 's', switch_tab, 'Switch tab (fuzzy, real numbers)' },
  { 'CTRL|SHIFT', 'q', act.PaneSelect({}), 'Pick a pane by letter' },
  { 'ALT|SHIFT', 'S', resize_mode, 'Resize mode: arrows, Esc or Enter ends it' },
  { 'CTRL|SHIFT', 'F5', reconnect, 'Reconnect an SSH tab (new tab; zellij reattaches)' },
  { 'CTRL|SHIFT', 'o', scrollback_in_helix, 'The scrollback in helix' },
  { 'CTRL|SHIFT', 'h', cheatsheet, 'This cheatsheet' },
}

config.keys = {}
for _, b in ipairs(bindings) do
  table.insert(config.keys, { mods = b[1], key = b[2], action = b[3] })
end

-- Mouse. Releasing a selection copies it and says "Copied" (a plain click selects nothing
-- and says nothing). That replaces the default release, which also opened a link under the
-- mouse, so Ctrl+click opens links; its press does nothing, so it starts no selection and
-- never reaches an app that takes the mouse.
local copy_on_release = act.Multiple({ act.CompleteSelection('ClipboardAndPrimarySelection'), copied_notice })
config.mouse_bindings = {
  { event = { Up = { streak = 1, button = 'Left' } }, mods = 'NONE', action = copy_on_release },
  { event = { Up = { streak = 2, button = 'Left' } }, mods = 'NONE', action = copy_on_release },
  { event = { Up = { streak = 3, button = 'Left' } }, mods = 'NONE', action = copy_on_release },
  { event = { Down = { streak = 1, button = 'Left' } }, mods = 'CTRL', action = act.Nop },
  { event = { Up = { streak = 1, button = 'Left' } }, mods = 'CTRL', action = act.OpenLinkAtMouseCursor },
  -- Shift is the modifier WezTerm keeps for itself in apps that take the mouse, so
  -- Shift+click is the link gesture inside zellij and helix. The default Shift+press
  -- extends a selection, so the release always completed it; starting a fresh one lets
  -- the release open the link.
  { event = { Down = { streak = 1, button = 'Left' } }, mods = 'SHIFT', action = act.SelectTextAtMouseCursor('Cell') },
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'SHIFT',
    action = act.Multiple({ act.CompleteSelectionOrOpenLinkAtMouseCursor('ClipboardAndPrimarySelection'), copied_notice }),
  },
  -- Ctrl+triple-click: one command's whole output, from the prompt marks the shells send
  -- (zsh, bash and Nushell; not inside zellij).
  { event = { Down = { streak = 3, button = 'Left' } }, mods = 'CTRL', action = act.SelectTextAtMouseCursor('SemanticZone') },
  { event = { Up = { streak = 3, button = 'Left' } }, mods = 'CTRL', action = copy_on_release },
  -- Ctrl+Shift+drag moves the window by default; Win+drag too, with no title bar to grab.
  { event = { Drag = { streak = 1, button = 'Left' } }, mods = 'SUPER', action = act.StartWindowDrag },
}

-- Status footer ---------------------------------------------------------------------------
-- Right of the tab bar, refreshed every second: COPY / SEARCH / RESIZE while those modes
-- run, an SSH tab's host in its colour (and the zellij session it attached), the pane's
-- line count, battery, time. Parts drop out as the pane narrows.

local function thousands(n)
  local s = tostring(math.floor(n)):reverse():gsub('(%d%d%d)', '%1,'):reverse()
  return (s:gsub('^,', ''))
end

-- Lines in the pane's buffer and the rows on screen. Hidden in a full-screen app (it has no
-- scrollback) and until the buffer outgrows the screen. WezTerm exposes no scroll offset, so
-- the first number is the cursor's line, shown only when a program has moved it up.
local function line_count(pane, dims)
  if not dims or (dims.cols or 0) < 100 or pane:is_alt_screen_active() then
    return nil
  end
  local total, rows = dims.scrollback_rows or 0, dims.viewport_rows or 0
  if total <= rows then
    return nil
  end
  local pos = total
  local cursor = pane:get_cursor_position()
  if cursor and dims.scrollback_top then
    pos = math.max(1, math.min(total, cursor.y - dims.scrollback_top + 1))
  end
  if pos < total then
    return string.format('↕ %s/%s · %d rows', thousands(pos), thousands(total), rows)
  end
  return string.format('↕ %s · %d rows', thousands(total), rows)
end

-- Hidden on mains power at full charge: nothing to know.
local function battery()
  local ok, list = pcall(wezterm.battery_info)
  local b = ok and list and list[1]
  if not b then
    return nil
  end
  local pct = math.floor((b.state_of_charge or 0) * 100 + 0.5)
  if b.state == 'Full' or (pct >= 100 and b.state ~= 'Discharging') then
    return nil
  end
  local icon = b.state == 'Charging' and '⚡' or (pct <= 20 and '🪫' or '🔋')
  return string.format('%s %d%%', icon, pct)
end

local function clock(cols)
  if cols < 60 then
    return wezterm.strftime('%H:%M')
  end
  local h = tonumber(wezterm.strftime('%H'))
  local icon = h < 5 and '🌌' or h < 7 and '🌅' or h < 12 and '☀️' or h < 17 and '🌞' or h < 20 and '🌇' or '🌙'
  return icon .. ' ' .. wezterm.strftime('%a %H:%M')
end

render_status = function(window, pane)
  local dims = pane:get_dimensions()
  local cols = (dims and dims.cols) or 80
  local parts = {}
  local mode = window:active_key_table()
  if mode == 'copy_mode' then
    table.insert(parts, { text = 'COPY', fg = mocha.yellow, bold = true })
  elseif mode == 'search_mode' then
    table.insert(parts, { text = 'SEARCH', fg = mocha.sky, bold = true })
  elseif mode == 'resize_pane' then
    table.insert(parts, { text = 'RESIZE', fg = mocha.teal, bold = true })
  end
  local s = ssh_of(pane)
  if s then
    table.insert(parts, { text = s.host, fg = accent(s.host) })
    if s.zellij and cols >= 130 then
      table.insert(parts, { text = 'zellij:' .. s.zellij })
    end
  end
  local lines = line_count(pane, dims)
  if lines then
    table.insert(parts, { text = lines })
  end
  local bat = cols >= 80 and battery()
  if bat then
    table.insert(parts, { text = bat })
  end
  table.insert(parts, { text = clock(cols) })

  local items, plain = { { Text = ' ' } }, ' '
  for i, p in ipairs(parts) do
    if i > 1 then
      table.insert(items, { Foreground = { Color = mocha.overlay0 } })
      table.insert(items, { Attribute = { Intensity = 'Normal' } })
      table.insert(items, { Text = ' · ' })
      plain = plain .. ' · '
    end
    table.insert(items, { Foreground = { Color = p.fg or mocha.text } })
    table.insert(items, { Attribute = { Intensity = p.bold and 'Bold' or 'Normal' } })
    table.insert(items, { Text = p.text })
    plain = plain .. p.text
  end
  table.insert(items, { Text = ' ' })
  plain = plain .. ' '

  -- A live notice replaces the footer, centred in at least its width so the tabs don't shift.
  local n = notices[window:window_id()]
  if n and os.time() < n.expires then
    local pad = math.max(0, wezterm.column_width(plain) - wezterm.column_width(n.text))
    local left = math.floor(pad / 2)
    items = {
      { Text = string.rep(' ', left) },
      { Foreground = { Color = n.fg } },
      { Attribute = { Intensity = 'Bold' } },
      { Text = n.text },
      { Attribute = { Intensity = 'Normal' } },
      { Text = string.rep(' ', pad - left) },
    }
  else
    notices[window:window_id()] = nil
  end
  window:set_right_status(wezterm.format(items))
end
wezterm.on('update-status', render_status)

-- Tabs ----------------------------------------------------------------------------------
-- "<glyph> <n>: <title>" with a mark in front: the bell glyph once BEL rang in a tab you
-- weren't looking at (cleared when you view it), the OSC 9;4 progress, or a dot for output
-- you haven't seen. Replacing the title also replaces WezTerm's progress spinner, so the
-- progress is drawn here (a static mark, no animation).
local nf = wezterm.nerdfonts or {}
local glyphs = {
  bell = nf.md_bell or '!',
  busy = nf.md_timer_sand or '~',
  ssh = nf.md_ssh or '>',
  wsl = nf.cod_terminal_linux or '$',
  shell = nf.md_console or '>',
}

-- Bell marks live in wezterm.GLOBAL: they last until the tab is viewed, and every reload
-- (each config save) starts a fresh Lua VM. Keys are strings and the table is assigned
-- back, as GLOBAL stores a serialised copy.
wezterm.on('bell', function(_, pane)
  local marks = wezterm.GLOBAL.bell_panes or {}
  marks[tostring(pane:pane_id())] = true
  wezterm.GLOBAL.bell_panes = marks
end)

local function tab_mark(tab)
  local marks = wezterm.GLOBAL.bell_panes or {}
  local cleared, bell, unseen = false, false, false
  for _, p in ipairs(tab.panes or {}) do
    local key = tostring(p.pane_id)
    if marks[key] and tab.is_active then
      marks[key] = nil
      cleared = true
    elseif marks[key] then
      bell = true
    elseif p.has_unseen_output and not tab.is_active then
      unseen = true
    end
  end
  if cleared then
    wezterm.GLOBAL.bell_panes = marks
  end
  if bell then
    return glyphs.bell, mocha.peach
  end
  local progress = tab.active_pane and tab.active_pane.progress
  if type(progress) == 'table' and progress.Percentage then
    return progress.Percentage .. '%', mocha.green
  elseif type(progress) == 'table' and progress.Error then
    return progress.Error .. '%', mocha.red
  elseif progress == 'Indeterminate' then
    return glyphs.busy, mocha.peach
  end
  if unseen then
    return '●', mocha.mauve
  end
end

-- What a tab shows: its glyph, its title and, for an SSH tab, its host. An SSH tab is named
-- after its host and takes the host's colour; a WSL tab after its distro, or the host it
-- has ssh'd to; any other tab after its pane's title without a "user@" prefix, a Windows
-- program's path cut to its name (C:\...\pwsh.exe becomes pwsh). A name set with
-- Ctrl+Shift+E wins over all of them.
local function tab_info(tab)
  local p = tab.active_pane or {}
  local domain = p.domain_name or ''
  local live = p.pane_id and wezterm.mux.get_pane(p.pane_id)
  local s = live and ssh_of(live)
  local glyph, title, host
  if s then
    glyph, title, host = glyphs.ssh, s.host, s.host
  elseif domain:find('^WSL:') then
    local distro = domain:gsub('^WSL:', '')
    host = wsl_remote(p.current_working_dir, distro)
    glyph, title = host and glyphs.ssh or glyphs.wsl, host or distro
  else
    glyph = glyphs.shell
    title = (p.title or ''):gsub('^[%w%._%-]+@', '')
    title = title:gsub('^.*[\\/]([^\\/]+)%.[Ee][Xx][Ee]$', '%1')
  end
  if tab.tab_title and tab.tab_title ~= '' then
    title = tab.tab_title
  end
  return glyph, title, host
end

wezterm.on('format-tab-title', function(tab, tabs, _, _, hover, max_width)
  -- The position in the live list: tab_index lags a close until the next switch.
  local n = tab.tab_index + 1
  for i, t in ipairs(tabs) do
    if t.tab_id == tab.tab_id then
      n = i
      break
    end
  end
  local glyph, title, host = tab_info(tab)
  -- Nothing, muted, full: an inactive SSH tab shows its host colour in the text, hover a
  -- dark block of it, the active tab the full colour. Other tabs use mauve the same way.
  local bg, fg = mocha.base, mocha.overlay0
  if host then
    local c = wezterm.color.parse(accent(host))
    if tab.is_active then
      bg, fg = accent(host), mocha.crust
    elseif hover then
      bg, fg = tostring(c:desaturate(0.5):darken(0.5)), mocha.text
    else
      fg = tostring(c:desaturate(0.4):darken(0.1))
    end
  elseif tab.is_active then
    bg, fg = mocha.mauve, mocha.crust
  elseif hover then
    bg, fg = mocha.surface1, mocha.text
  end
  local mark, mark_fg = tab_mark(tab)
  if mark == '●' and host then
    mark_fg = accent(host)
  end
  local lead = mark and (' ' .. mark .. ' ') or ' '
  local prefix = string.format('%s %d: ', glyph, n)
  local room = math.max(1, max_width - wezterm.column_width(lead) - wezterm.column_width(prefix) - 1)
  local items = { { Background = { Color = bg } } }
  if mark then
    table.insert(items, { Foreground = { Color = tab.is_active and fg or mark_fg } })
  end
  table.insert(items, { Text = lead })
  table.insert(items, { Foreground = { Color = fg } })
  if tab.is_active then
    table.insert(items, { Attribute = { Intensity = 'Bold' } })
  end
  table.insert(items, { Text = prefix .. wezterm.truncate_right(title, room) .. ' ' })
  return items
end)

-- file:// links (eza --hyperlink in the l/ll/lt aliases) open in helix, in a new tab on the
-- machine that printed them: a WSL distro's in that distro, an SSH tab's over the same ssh
-- (its options and destination, plus -t). A WSL tab that has ssh'd elsewhere can't reach
-- the file, so it says so. Other links, and Windows paths, go to WezTerm's default.
wezterm.on('open-uri', function(window, pane, uri)
  local ok, url = pcall(wezterm.url.parse, uri)
  if not ok or url.scheme ~= 'file' then
    return
  end
  local s = ssh_of(pane)
  if s then
    local _, at = ssh_dest(s.argv)
    local args = { s.argv[1], '-t' }
    for i = 2, at do
      table.insert(args, s.argv[i])
    end
    table.insert(args, 'hx ' .. shq(url.file_path))
    window:perform_action(act.SpawnCommandInNewTab({ args = args, domain = here }), pane)
    return false
  end
  local domain = pane:get_domain_name() or ''
  if not domain:find('^WSL:') then
    return
  end
  local host = (url.host or ''):lower():match('^[^.]*') or ''
  if host ~= '' and host ~= 'localhost' and host ~= local_host and host ~= domain:gsub('^WSL:', ''):lower() then
    flash(window, pane, 'That file is on ' .. url.host .. ': open it from an SSH tab there', 'warn')
    return false
  end
  window:perform_action(act.SpawnCommandInNewTab({ args = wsl_hx(url.file_path), domain = { DomainName = domain } }), pane)
  return false
end)

-- Events --------------------------------------------------------------------------------
wezterm.on('copied-scrollback', function(window, pane)
  flash(window, pane, 'Copied the scrollback')
end)

-- The tab bar's +: a click is Ctrl+Shift+T (WezTerm's own skips the WSL rule in
-- spawn_from), a middle-click the tab list (Ctrl+Shift+S, where WezTerm does nothing), a
-- right-click this config's launcher (Ctrl+Alt+L, fuzzy, rather than the plain one).
wezterm.on('new-tab-button-click', function(window, pane, button)
  local action = ({ Left = new_tab, Middle = switch_tab, Right = launcher })[button]
  if action then
    window:perform_action(action, pane)
    return false
  end
end)

-- A green "Config reloaded" confirms a save (or Ctrl+Shift+R) took; a Lua error opens
-- WezTerm's error window instead. The event also fires once as each window opens, which
-- stays quiet. The seen-set lives in wezterm.GLOBAL because each reload is a new Lua VM.
wezterm.on('window-config-reloaded', function(window, pane)
  local id = tostring(window:window_id())
  local seen = wezterm.GLOBAL.reload_seen or {}
  if not seen[id] then
    seen[id] = true
    wezterm.GLOBAL.reload_seen = seen
    return
  end
  flash(window, pane, 'Config reloaded')
end)

-- The command palette (Ctrl+Shift+P) lists the custom actions too, as the same values.
wezterm.on('augment-command-palette', function()
  return {
    { brief = 'Cheatsheet: keys and launch entries', action = cheatsheet },
    { brief = 'Rename the tab', action = rename_tab },
    { brief = 'Copy the whole scrollback', action = copy_scrollback },
    { brief = 'Quick select: file:line into helix', action = open_in_helix },
    { brief = 'Quick select: commit SHA into the prompt', action = paste_sha },
    { brief = 'Reconnect the SSH tab', action = reconnect },
    { brief = 'Open the scrollback in helix', action = scrollback_in_helix },
    { brief = 'Switch tab (fuzzy)', action = switch_tab },
    { brief = 'Pick a pane by letter', action = act.PaneSelect({}) },
    { brief = 'Resize panes (arrows; Esc or Enter ends it)', action = resize_mode },
  }
end)

return config
