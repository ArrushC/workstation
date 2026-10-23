-- keys.lua: the key and mouse bindings, the Ctrl+Shift+H cheatsheet built from them, and
-- the command palette's extra entries. The actions themselves are in actions.lua.

local wezterm = require 'wezterm'
local actions = require 'actions'

local act = wezterm.action

local M = {}

-- WezTerm defaults worth knowing, mouse gestures and what the status and tabs show.
local reference = {
  { 'Ctrl+Tab', 'Next tab (Ctrl+Shift+Tab: previous)' },
  { 'Ctrl+Shift+N', 'New window' },
  { 'Ctrl+Shift+Z', 'Toggle pane zoom' },
  { 'Ctrl+Shift+Alt+arrows', 'Resize the pane by one cell' },
  { 'Ctrl+Shift+F', 'Search the scrollback' },
  { 'Ctrl+Shift+X', 'Copy mode (COPY in the status)' },
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
  { 'tab bar', "The title bar: drag its free space to move the window, double-click it to maximize; minimize and close on its right" },
  { '+ on the tab bar', 'Click: new tab; middle-click: tab list; right-click: launcher' },
  { 'select', 'Selecting with the mouse copies (Copied in the status)' },
  { 'drop a file', 'Pastes its path, quoted' },
  { 'images', 'Show inline (yazi, wezterm imgcat), except inside zellij' },
  { '#123', "Links to this repository's issue or pull request 123" },
  { 'status', 'SSH host (zellij session), lines in the pane, battery, time; COPY / SEARCH / RESIZE in those modes' },
  { 'tab colours', "An SSH tab, or a WSL tab that ran ssh, takes its host's colour and name (its ~/.ssh/config.local alias); a WSL tab otherwise its distro's colour" },
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

function M.apply(config)
  local bindings -- set below the cheatsheet, which reads it when it opens

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

  -- WezTerm's own bindings use Ctrl+Shift, so zellij keeps Ctrl and Alt (Alt+0 aside: zellij
  -- binds Alt+1-9 to its tabs, not Alt+0). Each entry carries
  -- its cheatsheet line (Ctrl+Shift+H), so the two can't drift; `chord` names a group.
  -- The pane keys are Warp's and Windows Terminal's (README's tables).
  bindings = {
    { 'CTRL|ALT', 'l', actions.launcher, 'Launcher: shells, WSL, SSH hosts (zellij)' },
    { 'CTRL|ALT', 's', actions.ssh_hosts, 'SSH hosts: connect, add, edit or delete one (~/.ssh/config.local)' },
    { 'CTRL|SHIFT', 't', actions.new_tab, "New tab: this tab's domain and directory, or its SSH host again" },
    { 'CTRL|ALT', 't', actions.new_local_tab, 'New tab, never over ssh: from an SSH tab, a local shell' },
    { 'ALT|SHIFT', 'D', actions.split_down, 'Split pane down' },
    { 'ALT|SHIFT', 'R', actions.split_right, 'Split pane right' },
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
    { 'CTRL|SHIFT', 'c', actions.copy, 'Copy the selection', chord = 'Ctrl+Shift+C / Ctrl+Insert' },
    { 'CTRL', 'Insert', actions.copy },
    { 'CTRL|SHIFT', 'a', actions.copy_scrollback, 'Copy the whole scrollback' },
    { 'CTRL|SHIFT', 'e', actions.rename_tab, 'Rename the tab' },
    { 'CTRL|SHIFT', 'g', actions.open_in_helix, 'Quick select a file:line, open it in helix' },
    { 'CTRL|SHIFT', 'y', actions.paste_sha, 'Quick select a commit SHA, paste it at the prompt' },
    { 'CTRL|SHIFT', 'w', act.CloseCurrentTab({ confirm = false }), 'Close the tab' },
    { 'CTRL|SHIFT', 's', actions.switch_tab, 'Switch tab (fuzzy, real numbers)' },
    { 'ALT', '0', act.ActivateLastTab, 'Back to the previous tab (underlined in the tab bar)' },
    { 'CTRL|SHIFT', 'q', act.PaneSelect({}), 'Pick a pane by letter' },
    { 'ALT|SHIFT', 'S', actions.resize_mode, 'Resize mode: arrows, Esc or Enter ends it' },
    { 'CTRL|SHIFT', 'F5', actions.reconnect, 'Reconnect an SSH tab (new tab; zellij reattaches)' },
    { 'CTRL|SHIFT', 'o', actions.scrollback_in_helix, 'The scrollback in helix' },
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
  local copy_on_release = act.Multiple({ act.CompleteSelection('ClipboardAndPrimarySelection'), actions.copied_notice })
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
      action = act.Multiple({ act.CompleteSelectionOrOpenLinkAtMouseCursor('ClipboardAndPrimarySelection'), actions.copied_notice }),
    },
    -- Ctrl+triple-click: one command's whole output, from the prompt marks the shells send
    -- (zsh, bash and Nushell; not inside zellij).
    { event = { Down = { streak = 3, button = 'Left' } }, mods = 'CTRL', action = act.SelectTextAtMouseCursor('SemanticZone') },
    { event = { Up = { streak = 3, button = 'Left' } }, mods = 'CTRL', action = copy_on_release },
    -- Ctrl+Shift+drag moves the window from anywhere by default; Win+drag too.
    { event = { Drag = { streak = 1, button = 'Left' } }, mods = 'SUPER', action = act.StartWindowDrag },
  }

  -- The command palette (Ctrl+Shift+P) lists the custom actions too, as the same values.
  wezterm.on('augment-command-palette', function()
    return {
      { brief = 'Cheatsheet: keys and launch entries', action = cheatsheet },
      { brief = 'Rename the tab', action = actions.rename_tab },
      { brief = 'Copy the whole scrollback', action = actions.copy_scrollback },
      { brief = 'Quick select: file:line into helix', action = actions.open_in_helix },
      { brief = 'Quick select: commit SHA into the prompt', action = actions.paste_sha },
      { brief = 'Reconnect the SSH tab', action = actions.reconnect },
      { brief = 'SSH hosts: connect, add, edit or delete', action = actions.ssh_hosts },
      { brief = 'Open the scrollback in helix', action = actions.scrollback_in_helix },
      { brief = 'Switch tab (fuzzy)', action = actions.switch_tab },
      { brief = 'Split pane down', action = actions.split_down },
      { brief = 'Split pane right', action = actions.split_right },
      { brief = 'Pick a pane by letter', action = act.PaneSelect({}) },
      { brief = 'Resize panes (arrows; Esc or Enter ends it)', action = actions.resize_mode },
    }
  end)
end

return M
