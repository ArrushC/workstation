-- ~/.wezterm.lua: WezTerm, managed by mise dotfiles (dotfiles/config/wezterm/wezterm.lua).
--
-- Windows installs WezTerm with winget (config.windows.toml). It sits beside Warp (the
-- primary terminal) and Windows Terminal (the default one) and looks and starts like them:
-- Catppuccin Mocha with the mauve accent, JetBrainsMono NFM 10.5 with a bar cursor, Nushell
-- through mise's shim, and in the launcher (Ctrl+Alt+L, Warp's key) the other shells,
-- AlmaLinux-9 (WSL) and one `SSH: <host>` entry per Host in ~/.ssh/config.local that
-- attaches zellij, as Warp's Tab Configs and Windows Terminal's SSH profiles do.
-- WezTerm reloads this file on save (Ctrl+Shift+R forces it). Edit the source with wse.
-- WezTerm runs Lua 5.4; scripts/check-invariants.sh (check_wezterm_config) runs this file
-- under LuaJIT with a stand-in for the wezterm module, so keep to Lua 5.1 syntax.

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()
local windows = wezterm.target_triple:find('windows') ~= nil

-- Updates come from winget (`mise bootstrap packages upgrade --manager winget`).
config.check_for_updates = false

-- Look -------------------------------------------------------------------------
-- WezTerm's built-in Catppuccin Mocha, with the tab bar in the fleet's mauve accent.
local scheme = wezterm.color.get_builtin_schemes()['Catppuccin Mocha']
scheme.tab_bar = {
  background = '#11111b',
  active_tab = { bg_color = '#cba6f7', fg_color = '#11111b' },
  inactive_tab = { bg_color = '#181825', fg_color = '#a6adc8' },
  inactive_tab_hover = { bg_color = '#313244', fg_color = '#cdd6f4' },
  new_tab = { bg_color = '#181825', fg_color = '#a6adc8' },
  new_tab_hover = { bg_color = '#313244', fg_color = '#cdd6f4' },
}
config.color_schemes = { ['Catppuccin Mocha (mauve)'] = scheme }
config.color_scheme = 'Catppuccin Mocha (mauve)'
config.use_fancy_tab_bar = false

-- bootstrap.ps1 installs JetBrainsMono Nerd Font Mono (family "JetBrainsMono NFM", the
-- name Windows Terminal uses); WezTerm's bundled JetBrains Mono and Nerd Font symbols
-- cover a host without it.
config.font = wezterm.font_with_fallback({ 'JetBrainsMono NFM', 'JetBrains Mono' })
config.font_size = 10.5
config.default_cursor_style = 'SteadyBar'
config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }
config.scrollback_lines = 100000
-- TERM stays WezTerm's default xterm-256color, the fleet's TERM (CLAUDE.md), so SSH
-- sessions find a terminfo entry on every host. OSC 52 copies reach the clipboard.

-- Shells ----------------------------------------------------------------------------
-- ~/.ssh/config.local's concrete Host aliases (patterns, negations and names that would
-- need quoting skipped), as bootstrap.ps1's Get-SshLauncherHosts reads them.
local function ssh_hosts()
  local hosts, seen = {}, {}
  local f = io.open(wezterm.home_dir .. '/.ssh/config.local', 'r')
  if not f then
    return hosts
  end
  for line in f:lines() do
    local list = line:match('^%s*[Hh][Oo][Ss][Tt]%s*=%s*(.+)$') or line:match('^%s*[Hh][Oo][Ss][Tt]%s+(.+)$')
    if list then
      list = list:gsub('%s#.*$', '')
      for token in list:gmatch('%S+') do
        if not token:find('[%*%?!]') and token:match('^[%w%._@%-]+$') and not seen[token] then
          seen[token] = true
          table.insert(hosts, token)
        end
      end
    end
  end
  f:close()
  return hosts
end

config.launch_menu = {}
if windows then
  -- Nushell through mise's shim, as Windows Terminal's default profile starts it.
  local nu = (os.getenv('LOCALAPPDATA') or '') .. '\\mise\\shims\\nu.exe'
  local shim = io.open(nu, 'r')
  if shim then
    shim:close()
    config.default_prog = { nu }
    table.insert(config.launch_menu, { label = 'Nushell', args = { nu } })
  end
  table.insert(config.launch_menu, { label = 'PowerShell', args = { 'pwsh.exe', '-NoLogo' } })
  table.insert(config.launch_menu, { label = 'Windows PowerShell', args = { 'powershell.exe', '-NoLogo' } })
end
for _, host in ipairs(ssh_hosts()) do
  table.insert(config.launch_menu, {
    label = 'SSH: ' .. host,
    args = { 'ssh', '-t', host, 'zellij', 'attach', '--create', 'main' },
  })
end
-- No built-in SSH domains: by default WezTerm lists SSH: and SSHMUX: domains for every
-- ~/.ssh/config host, with its own SSH client, and SSHMUX: needs WezTerm on the server.
-- The entries above use the system's ssh, as the other terminals do.
config.ssh_domains = {}

-- Keys --------------------------------------------------------------------------------
-- WezTerm's own bindings use Ctrl+Shift, so zellij keeps Ctrl and Alt. Ctrl+Alt+L opens the
-- launcher (shells, WSL:AlmaLinux-9, SSH hosts), Warp's key for its Tab Configs. The pane
-- keys are Warp's and Windows Terminal's (README's tables): Alt+Shift+D / R split down /
-- right (zellij's d and r), Alt+Shift+arrows move between panes, Ctrl+Up/Down jump between
-- prompts. WezTerm's defaults already match the rest: Ctrl+Shift+Z zoom, Ctrl+= / - / 0
-- font size, Ctrl+Shift+F search, Ctrl+Shift+P palette. Copy/paste stays Ctrl+Shift+C / V
-- (selecting copies too), so Ctrl+V still reaches Neovim's block selection.
config.keys = {
  {
    key = 'l',
    mods = 'CTRL|ALT',
    action = act.ShowLauncherArgs({ flags = 'FUZZY|LAUNCH_MENU_ITEMS|DOMAINS' }),
  },
  { key = 'D', mods = 'ALT|SHIFT', action = act.SplitVertical({ domain = 'CurrentPaneDomain' }) },
  { key = 'R', mods = 'ALT|SHIFT', action = act.SplitHorizontal({ domain = 'CurrentPaneDomain' }) },
  { key = 'LeftArrow', mods = 'ALT|SHIFT', action = act.ActivatePaneDirection('Left') },
  { key = 'RightArrow', mods = 'ALT|SHIFT', action = act.ActivatePaneDirection('Right') },
  { key = 'UpArrow', mods = 'ALT|SHIFT', action = act.ActivatePaneDirection('Up') },
  { key = 'DownArrow', mods = 'ALT|SHIFT', action = act.ActivatePaneDirection('Down') },
  { key = 'UpArrow', mods = 'CTRL', action = act.ScrollToPrompt(-1) },
  { key = 'DownArrow', mods = 'CTRL', action = act.ScrollToPrompt(1) },
}

return config
