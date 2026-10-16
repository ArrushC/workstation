-- actions.lua: what the keys, the mouse, the + button and the command palette do (keys.lua
-- binds them), links and quick-select patterns, and file links opening in helix. Exports
-- every action keys.lua binds.

local wezterm = require 'wezterm'
local wsl = require 'wsl'
local domains = require 'domains'
local sshconfig = require 'sshconfig'
local status = require 'status'

local act = wezterm.action
local here, flash = wsl.here, status.flash

local M = {}

M.launcher = act.ShowLauncherArgs({ flags = 'FUZZY|LAUNCH_MENU_ITEMS|DOMAINS' })

-- Where a new tab or split from this pane starts. An SSH tab's runs its ssh again, so it
-- opens on the same host (the launcher's attaches the same zellij session, as another
-- client); with `no_ssh` it is the default shell here instead, in the directory its ssh
-- started from (home once ssh has exited). Otherwise WezTerm's default (the pane's domain
-- and directory), except that a WSL pane whose directory isn't one in the distro starts
-- in its home. Before the shell's first OSC 7, and inside zellij (which keeps OSC 7 to
-- itself), WezTerm knows only wsl.exe's Windows directory (/mnt/c/Users/<you> in Linux);
-- after an ssh the OSC 7 path is on the other host, which wsl.exe can't enter (it prints
-- an error and starts in /).
local function spawn_from(pane, no_ssh)
  local s = domains.ssh_of(pane)
  if s and no_ssh then
    local info = pane:get_foreground_process_info()
    local cwd = info and info.cwd
    return { domain = here, cwd = (cwd and cwd ~= '') and cwd or wezterm.home_dir }
  elseif s then
    return { args = s.argv, domain = here }
  end
  local domain = pane:get_domain_name() or ''
  if domain:find('^WSL:') then
    local cwd = pane:get_current_working_dir()
    local path = cwd and cwd.file_path or ''
    if path == '' or path:find('^/%a:') or domains.wsl_remote(cwd, (domain:gsub('^WSL:', '')), pane:get_title()) then
      return { domain = { DomainName = domain }, cwd = '~' }
    end
  end
  return { domain = 'CurrentPaneDomain' }
end

-- Ctrl+Shift+T and the tab bar's + (left-click).
M.new_tab = wezterm.action_callback(function(window, pane)
  window:perform_action(act.SpawnCommandInNewTab(spawn_from(pane)), pane)
end)

-- Ctrl+Alt+T: the same, except that an SSH tab's is a local shell, not another ssh.
M.new_local_tab = wezterm.action_callback(function(window, pane)
  window:perform_action(act.SpawnCommandInNewTab(spawn_from(pane, true)), pane)
end)

-- Alt+Shift+D / R: `how` is SplitVertical (down) or SplitHorizontal (right).
local function split(how)
  return wezterm.action_callback(function(window, pane)
    window:perform_action(act[how](spawn_from(pane)), pane)
  end)
end
M.split_down = split('SplitVertical')
M.split_right = split('SplitHorizontal')

-- Copy only when something is selected, so the notice never claims an empty copy.
M.copy = wezterm.action_callback(function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if sel and sel ~= '' then
    window:perform_action(act.CopyTo('Clipboard'), pane)
    flash(window, pane, 'Copied')
  end
end)

-- After a mouse selection completes (it copies): say so, unless it was a plain click.
M.copied_notice = wezterm.action_callback(function(window, pane)
  local sel = window:get_selection_text_for_pane(pane)
  if sel and sel ~= '' then
    flash(window, pane, 'Copied')
  end
end)

-- The whole scrollback, through copy mode. CopyMode 'Close' no longer scrolls to the
-- bottom on the nightly, hence the explicit ScrollToBottom.
M.copy_scrollback = act.Multiple({
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
M.rename_tab = wezterm.action_callback(function(window, pane)
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
M.reconnect = wezterm.action_callback(function(window, pane)
  local s = domains.ssh_of(pane)
  if not s then
    flash(window, pane, 'Not an SSH tab: nothing to reconnect', 'warn')
    return
  end
  window:perform_action(act.SpawnCommandInNewTab({ args = s.argv, domain = here }), pane)
end)

-- Ctrl+Alt+S: the SSH hosts in ~/.ssh/config.local (sshconfig.lua), the launcher's SSH
-- entries. Pick one to connect to it, edit it or delete it, or add one. Adding and editing
-- ask in turn for its name, its address ([user@]host[:port]) and a note (the comment under
-- its Host line), each prefilled; a bad answer is asked for again with the reason, and Esc
-- at any point saves nothing. Its block's other settings stay. A save reloads the config,
-- so the launcher lists the change at once; Warp's and Windows Terminal's SSH entries
-- follow at the next bootstrap.ps1.

local function trim(s)
  return s:match('^%s*(.-)%s*$')
end

-- Asks each step's question in turn (PromptInputLine), then calls done(window, pane, got)
-- with the answers. A step's check turns the line typed into its answer, or returns nil
-- and why not, which asks again with the line kept. Esc at any step ends it all.
local function ask(window, pane, steps, done, got, why, typed)
  got = got or {}
  local step = steps[#got + 1]
  if not step then
    return done(window, pane, got)
  end
  local description = step.ask(got)
  window:perform_action(
    act.PromptInputLine({
      description = why and (why .. '. ' .. description) or description,
      initial_value = typed or step.initial or '',
      action = wezterm.action_callback(function(win, p, line)
        if not line then
          return
        end
        local value, reason = step.check(line)
        if value == nil then
          return ask(win, p, steps, done, got, reason, line)
        end
        local more = {}
        for i, v in ipairs(got) do
          more[i] = v
        end
        table.insert(more, value)
        ask(win, p, steps, done, more)
      end),
    }),
    pane
  )
end

-- Writes the hosts file and reloads, so the launcher lists the change; the reload's notice
-- says what changed.
local function save_hosts(window, pane, old, new, notice)
  if new == old then
    flash(window, pane, 'No change')
    return
  end
  local ok, err = sshconfig.write(new)
  if not ok then
    flash(window, pane, 'Could not write ~/.ssh/config.local: ' .. tostring(err), 'warn')
    return
  end
  status.after_reload(notice)
  window:perform_action(act.ReloadConfiguration, pane)
end

-- Adds a host, or edits h.
local function edit_host(window, pane, h)
  local old = h and h.name
  local shared = h and #h.shared > 0 and (' (its block is also ' .. table.concat(h.shared, ', ') .. "'s)") or ''
  ask(window, pane, {
    {
      ask = function()
        return (old and ('Edit ' .. old) or 'New host') .. ': its name, typed after ssh and listed in the launcher as SSH: <name>'
      end,
      initial = old,
      check = function(line)
        local name = trim(line)
        local why = sshconfig.check_name(sshconfig.read(), name, old)
        if why then
          return nil, why
        end
        return name
      end,
    },
    {
      ask = function(got)
        return got[1] .. ': its address, [user@]host[:port], such as me@build01.corp or 10.0.0.9:2222' .. shared
      end,
      initial = h and sshconfig.address(h),
      check = sshconfig.parse_address,
    },
    {
      ask = function(got)
        return got[1] .. ': a note, shown beside it in this list (optional)'
      end,
      initial = h and h.note,
      check = trim,
    },
  }, function(win, p, got)
    local a = got[2]
    local fields = { name = got[1], hostname = a.hostname, user = a.user, port = a.port, note = got[3] }
    local text = sshconfig.read()
    local new, err
    if old then
      new, err = sshconfig.change(text, old, fields)
    else
      new, err = sshconfig.add(text, fields)
    end
    if not new then
      flash(win, p, err, 'warn')
      return
    end
    save_hosts(win, p, text, new, (old and 'Saved ' or 'Added ') .. got[1] .. ': ' .. sshconfig.address(fields))
  end)
end

local function delete_host(window, pane, h)
  local also = #h.shared > 0 and (' (' .. table.concat(h.shared, ', ') .. ' keeps its settings)') or ''
  window:perform_action(
    act.InputSelector({
      title = 'Delete ' .. h.name .. ' from ~/.ssh/config.local?' .. also,
      choices = { { id = 'no', label = 'No, keep it' }, { id = 'yes', label = 'Yes, delete ' .. h.name } },
      action = wezterm.action_callback(function(win, p, id)
        if id ~= 'yes' then
          return
        end
        local text = sshconfig.read()
        local new, err = sshconfig.remove(text, h.name)
        if not new then
          flash(win, p, err, 'warn')
          return
        end
        save_hosts(win, p, text, new, 'Deleted ' .. h.name)
      end),
    }),
    pane
  )
end

local function host_menu(window, pane, h)
  window:perform_action(
    act.InputSelector({
      title = h.name .. ': ' .. sshconfig.address(h),
      choices = {
        { id = 'connect', label = 'Connect, in a new tab' },
        { id = 'edit', label = 'Edit its name, address or note' },
        { id = 'delete', label = 'Delete it' },
      },
      action = wezterm.action_callback(function(win, p, id)
        if id == 'connect' then
          win:perform_action(act.SpawnCommandInNewTab({ args = domains.ssh_launch(h.name), domain = here }), p)
        elseif id == 'edit' then
          edit_host(win, p, h)
        elseif id == 'delete' then
          delete_host(win, p, h)
        end
      end),
    }),
    pane
  )
end

M.ssh_hosts = wezterm.action_callback(function(window, pane)
  local hosts = sshconfig.hosts(sshconfig.read())
  local width = 0
  for _, h in ipairs(hosts) do
    width = math.max(width, #h.name)
  end
  local choices = { { id = 'add', label = '+ Add a host' } }
  for i, h in ipairs(hosts) do
    local note = h.note and h.note ~= '' and ('  · ' .. h.note) or ''
    table.insert(choices, { id = tostring(i), label = h.name .. string.rep(' ', width - #h.name + 2) .. sshconfig.address(h) .. note })
  end
  window:perform_action(
    act.InputSelector({
      title = 'SSH hosts (~/.ssh/config.local)',
      fuzzy = true,
      fuzzy_description = 'A host to connect to, edit or delete, or Add: ',
      choices = choices,
      action = wezterm.action_callback(function(win, p, id)
        if id == 'add' then
          edit_host(win, p)
        elseif id then
          host_menu(win, p, hosts[tonumber(id)])
        end
      end),
    }),
    pane
  )
end)

-- Ctrl+Shift+O: the pane's scrollback in helix, in a new tab on the same machine (a temp
-- file, one per pane). An SSH tab's history is in zellij, which WezTerm only sees a screen
-- of; zellij's own edit-scrollback key opens it there.
M.scrollback_in_helix = wezterm.action_callback(function(window, pane)
  if domains.ssh_of(pane) then
    flash(window, pane, "zellij holds this tab's scrollback: use its edit-scrollback key", 'warn')
    return
  end
  local dims = pane:get_dimensions()
  local text = pane:get_lines_as_text(dims.scrollback_rows)
  local dir = os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp'
  local file = dir .. (wsl.windows and '\\' or '/') .. 'wezterm-scrollback-' .. pane:pane_id() .. '.txt'
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
    window:perform_action(act.SpawnCommandInNewTab({ args = wsl.wsl_hx(linux), domain = { DomainName = domain } }), pane)
  else
    local hx = wsl.windows and (os.getenv('LOCALAPPDATA') or '') .. '\\mise\\shims\\hx.exe' or 'hx'
    window:perform_action(act.SpawnCommandInNewTab({ args = { hx, file }, domain = here }), pane)
  end
end)

-- Ctrl+Shift+S: a fuzzy tab list that keeps each tab's real number (the launcher renumbers
-- what it filters), with the host or domain beside it.
M.switch_tab = wezterm.action_callback(function(window, pane)
  local active = window:active_tab():tab_id()
  local choices = {}
  for i, tab in ipairs(window:mux_window():tabs()) do
    local p = tab:active_pane()
    local s = domains.ssh_of(p)
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
M.resize_mode = act.ActivateKeyTable({ name = 'resize_pane', one_shot = false })

-- Quick selects that act on the pick. Both type into the pane as a paste, so the pane's
-- own shell does the work wherever it runs (Nushell, WSL zsh, a host through ssh and
-- zellij) and relative paths resolve against its directory. A pane showing a full-screen
-- app (zellij, an editor) gets the text without Enter, for you to check first.
M.open_in_helix = act.QuickSelectArgs({
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
M.paste_sha = act.QuickSelectArgs({
  label = 'paste into the prompt',
  patterns = { [[\b[0-9a-f]{7,40}\b]] },
  action = wezterm.action_callback(function(window, pane)
    local sel = window:get_selection_text_for_pane(pane)
    if sel and sel ~= '' then
      pane:paste(sel)
    end
  end),
})

function M.apply(config)
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

  -- file:// links (eza --hyperlink in the l/ll/lt aliases) open in helix, in a new tab on the
  -- machine that printed them: a WSL distro's in that distro, an SSH tab's over the same ssh
  -- (its options and destination, plus -t). A WSL tab that has ssh'd elsewhere can't reach
  -- the file, so it says so. Other links, and Windows paths, go to WezTerm's default.
  wezterm.on('open-uri', function(window, pane, uri)
    local ok, url = pcall(wezterm.url.parse, uri)
    if not ok or url.scheme ~= 'file' then
      return
    end
    local s = domains.ssh_of(pane)
    if s then
      local _, at = domains.ssh_dest(s.argv)
      local args = { s.argv[1], '-t' }
      for i = 2, at do
        table.insert(args, s.argv[i])
      end
      table.insert(args, 'hx ' .. domains.shq(url.file_path))
      window:perform_action(act.SpawnCommandInNewTab({ args = args, domain = here }), pane)
      return false
    end
    local domain = pane:get_domain_name() or ''
    if not domain:find('^WSL:') then
      return
    end
    local host = (url.host or ''):lower():match('^[^.]*') or ''
    if host ~= '' and host ~= 'localhost' and host ~= domains.local_host and host ~= domain:gsub('^WSL:', ''):lower() then
      flash(window, pane, 'That file is on ' .. url.host .. ': open it from an SSH tab there', 'warn')
      return false
    end
    window:perform_action(act.SpawnCommandInNewTab({ args = wsl.wsl_hx(url.file_path), domain = { DomainName = domain } }), pane)
    return false
  end)

  -- The tab bar's +: a click is Ctrl+Shift+T (WezTerm's own skips the WSL rule in
  -- spawn_from), a middle-click the tab list (Ctrl+Shift+S, where WezTerm does nothing), a
  -- right-click this config's launcher (Ctrl+Alt+L, fuzzy, rather than the plain one).
  wezterm.on('new-tab-button-click', function(window, pane, button)
    local action = ({ Left = M.new_tab, Middle = M.switch_tab, Right = M.launcher })[button]
    if action then
      window:perform_action(action, pane)
      return false
    end
  end)
end

return M
