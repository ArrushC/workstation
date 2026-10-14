-- wsl.lua: the local shells and WSL: Nushell as the default program, the launcher's shell
-- entries, and the WSL domains, which start in the distro's home. Exports M.windows (running
-- on Windows), M.here (the local domain) and M.wsl_hx (helix inside a distro).

local wezterm = require 'wezterm'

local M = {}

M.windows = wezterm.target_triple:find('windows') ~= nil

-- Launch entries run in the local domain: without it an entry picked from a WSL tab would
-- run inside Linux (pwsh.exe, the Windows ssh, Nushell's shim).
M.here = { DomainName = 'local' }

-- helix in a WSL distro: wsl.exe runs a spawned program without a login shell, so mise's
-- shims aren't on PATH yet.
function M.wsl_hx(path)
  return { 'sh', '-c', 'PATH="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"; exec hx "$1"', 'hx', path }
end

function M.apply(config)
  config.launch_menu = {}
  if not M.windows then
    return
  end
  -- Nushell through mise's shim, as Windows Terminal's default profile starts it.
  local nu = (os.getenv('LOCALAPPDATA') or '') .. '\\mise\\shims\\nu.exe'
  local shim = io.open(nu, 'r')
  if shim then
    shim:close()
    config.default_prog = { nu }
    table.insert(config.launch_menu, { label = 'Nushell', args = { nu }, domain = M.here })
  end
  table.insert(config.launch_menu, { label = 'PowerShell', args = { 'pwsh.exe', '-NoLogo' }, domain = M.here })
  table.insert(config.launch_menu, { label = 'Windows PowerShell', args = { 'powershell.exe', '-NoLogo' }, domain = M.here })
  table.insert(config.launch_menu, { label = 'cmd', args = { 'cmd.exe' }, domain = M.here })
  -- WSL tabs start in the distro's home: WezTerm hands this '~' to wsl.exe as is
  -- (`--cd ~`), which expands it inside Linux. New tabs and splits then follow the shell's
  -- OSC 7 (actions.lua's spawn_from).
  local wsl = wezterm.default_wsl_domains()
  for _, d in ipairs(wsl) do
    d.default_cwd = '~'
  end
  config.wsl_domains = wsl
end

return M
