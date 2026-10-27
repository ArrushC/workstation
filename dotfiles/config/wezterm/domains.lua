-- domains.lua: SSH. The launcher's SSH entries (one per ~/.ssh/config.local host, attaching
-- zellij), no built-in SSH domains, and how a tab's host is found and named. Exports
-- M.ssh_launch, M.ssh_of, M.ssh_dest, M.wsl_remote, M.local_host and M.shq.

local wezterm = require 'wezterm'
local here = require('wsl').here
local sshconfig = require 'sshconfig'

local M = {}

-- ~/.ssh/config.local's concrete Host aliases (sshconfig.lua reads them, as bootstrap.ps1's
-- Get-SshLauncherHosts does), and a map from each name a host goes by (the alias; its
-- HostName, and that name's short form) to the alias.
local function ssh_config()
  local hosts, aliases, real = {}, {}, {}
  local list = sshconfig.hosts(sshconfig.read())
  for _, h in ipairs(list) do
    table.insert(hosts, h.name)
    aliases[h.name:lower()] = h.name
  end
  for _, h in ipairs(list) do
    local name = h.hostname and h.hostname:lower()
    if name and not name:find('%%') then
      real[name] = real[name] or h.name
      -- An address has no short form (10.0.0.9 isn't host "10").
      if name:find('%a') and not name:find(':') then
        local short = name:match('^[^.]*')
        real[short] = real[short] or h.name
      end
    end
  end
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

-- SSH tabs ----------------------------------------------------------------------------
-- The host an SSH tab is on: the destination of the ssh in front, read from its arguments
-- (the launcher's ssh, or one typed in Nushell or PowerShell). It colours the tab, names
-- it, shows in the footer, and drives new tabs and splits (another ssh to it),
-- Ctrl+Shift+F5 and file links. The last ssh seen in a pane is kept in wezterm.GLOBAL, so
-- Ctrl+Shift+F5 can rerun it once it has exited (and a reload keeps it). A WSL tab that has
-- run ssh itself (wsl_remote, below) gets the colour, name and footer only: its ssh runs
-- inside Linux, out of WezTerm's sight.

-- ssh's options that take a value, as zshrc/bashrc's ssh wrapper skips them.
local ssh_value_flags = 'BbcDEeFIiJLlmOoPpQRSWw'

-- The destination argument and its index in argv, or nil.
function M.ssh_dest(argv)
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
function M.ssh_of(pane)
  local id = tostring(pane:pane_id())
  local seen = wezterm.GLOBAL.ssh_panes or {}
  local info = pane:get_foreground_process_info()
  if not info then
    return seen[id]
  end
  local name = (info.name or ''):lower():gsub('%.exe$', '')
  local dest, at
  if name == 'ssh' and info.argv then
    dest, at = M.ssh_dest(info.argv)
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

M.local_host = (wezterm.hostname() or ''):lower():match('^[^.]*')

-- A WSL pane's remote host, or nil: the host in its OSC 7 (zshrc/bashrc send it over ssh),
-- else the one in a user@host[:dir] title (a host without this repo's rc files usually sets
-- one; zshrc/bashrc set this machine's back at each prompt under WezTerm), when that host
-- is neither this machine nor the distro. `cwd` is a pane's current_working_dir (a Url, or a
-- string in PaneInformation), `title` its title.
function M.wsl_remote(cwd, distro, title)
  local function remote(host)
    local short = host and host:lower():match('^[^.]*')
    if short and short ~= '' and short ~= 'localhost' and short ~= M.local_host and short ~= distro:lower() then
      return canonical(host)
    end
  end
  return remote(cwd and tostring(cwd):match('^file://([^/]+)/')) or remote((title or ''):match('^[%w%._%-]+@([%w%._%-]+)'))
end

-- Single-quoted for a POSIX shell on the far side of ssh.
function M.shq(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- An ssh WezTerm starts sends TERM=wezterm with the pty (WezTerm sets TERM after a spawn's
-- own variables, so a spawn can't change it), so its remote command starts with this: a
-- host without that terminfo entry switches to xterm-256color. Without it, zsh there draws
-- Backspace as a space, moving the cursor right.
local term_check = 'infocmp wezterm >/dev/null 2>&1 || export TERM=xterm-256color;'

-- The launcher's command for a host (Ctrl+Alt+S's Connect too): ssh -t, attaching zellij's
-- main session.
function M.ssh_launch(host)
  return { 'ssh', '-t', host, term_check .. ' exec zellij attach --create main' }
end

-- An SSH tab's ssh, run again from WezTerm (a new tab or split on its host, Ctrl+Shift+F5).
-- One typed in Nushell or PowerShell had TERM=xterm-256color (both switch to it), but run
-- from WezTerm it sends TERM=wezterm, so it checks first too: a remote command gets the
-- check in front, and none becomes -t, the check and a login shell. One that already
-- checks (the launcher's, or one run again before) stays as it is.
function M.ssh_again(argv)
  local _, at = M.ssh_dest(argv)
  if table.concat(argv, ' ', at + 1):find(term_check, 1, true) then
    return argv
  end
  local out = {}
  for i, a in ipairs(argv) do
    out[i] = a
  end
  if at < #argv then
    out[at + 1] = term_check .. ' ' .. argv[at + 1]
    return out
  end
  table.insert(out, 2, '-t')
  table.insert(out, term_check .. ' exec $SHELL -l')
  return out
end

function M.apply(config)
  for _, host in ipairs(ssh_hosts) do
    table.insert(config.launch_menu, { label = 'SSH: ' .. host, args = M.ssh_launch(host), domain = here })
  end
  -- No built-in SSH domains: by default WezTerm lists SSH: and SSHMUX: domains for every
  -- ~/.ssh/config host, with its own SSH client, and SSHMUX: needs WezTerm on the server.
  -- The entries above use the system's ssh, as the other terminals do.
  config.ssh_domains = {}
end

return M
