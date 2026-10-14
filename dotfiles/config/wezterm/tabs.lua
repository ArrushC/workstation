-- tabs.lua: the tab bar's titles. Each tab shows a mark (bell, progress, unseen output), a
-- glyph, its number and a name; an SSH tab takes its host's name and colour.

local wezterm = require 'wezterm'
local appearance = require 'appearance'
local domains = require 'domains'

local M = {}

local mocha = appearance.mocha

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
  local s = live and domains.ssh_of(live)
  local glyph, title, host
  if s then
    glyph, title, host = glyphs.ssh, s.host, s.host
  elseif domain:find('^WSL:') then
    local distro = domain:gsub('^WSL:', '')
    host = domains.wsl_remote(p.current_working_dir, distro, p.title)
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

function M.apply(_)
  -- Bell marks live in wezterm.GLOBAL: they last until the tab is viewed, and every reload
  -- (each config save) starts a fresh Lua VM. Keys are strings and the table is assigned
  -- back, as GLOBAL stores a serialised copy.
  wezterm.on('bell', function(_, pane)
    local marks = wezterm.GLOBAL.bell_panes or {}
    marks[tostring(pane:pane_id())] = true
    wezterm.GLOBAL.bell_panes = marks
  end)

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
      local c = wezterm.color.parse(appearance.accent(host))
      if tab.is_active then
        bg, fg = appearance.accent(host), mocha.crust
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
      mark_fg = appearance.accent(host)
    end
    local lead = mark and (' ' .. mark .. ' ') or ' '
    local prefix = string.format('%s %d: ', glyph, n)
    local room = math.max(1, max_width - wezterm.column_width(lead) - wezterm.column_width(prefix) - 1)
    local items = { { Background = { Color = bg } } }
    if mark then
      -- In its own colour on the active tab too, so an error % doesn't pass for progress;
      -- in the text colour only where that colour is the tab's fill.
      table.insert(items, { Foreground = { Color = (tab.is_active and mark_fg == bg) and fg or mark_fg } })
    end
    table.insert(items, { Text = lead })
    table.insert(items, { Foreground = { Color = fg } })
    if tab.is_active then
      table.insert(items, { Attribute = { Intensity = 'Bold' } })
    end
    table.insert(items, { Text = prefix .. wezterm.truncate_right(title, room) .. ' ' })
    return items
  end)
end

return M
