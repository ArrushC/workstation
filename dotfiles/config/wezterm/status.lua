-- status.lua: the status on the tab bar's right, and the notices that briefly replace it
-- ("Copied", "Config reloaded"). Exports M.flash and M.after_reload.

local wezterm = require 'wezterm'
local appearance = require 'appearance'
local domains = require 'domains'

local M = {}

local mocha = appearance.mocha

-- Notices -------------------------------------------------------------------------------
-- A short coloured message in the status ("Copied", "Config reloaded"): WezTerm's
-- Lua has no overlay that neither takes focus nor writes into the pane. Seconds-long, so
-- they live in this VM; a reload only drops one that was about to expire anyway.
local notices = {}
local levels = { info = { fg = mocha.green, secs = 2 }, warn = { fg = mocha.peach, secs = 4 } }
local render_status

function M.flash(window, pane, text, level)
  local lv = levels[level] or levels.info
  notices[window:window_id()] = { text = text, fg = lv.fg, expires = os.time() + lv.secs }
  render_status(window, pane)
end

-- The notice for the reload a change is about to cause (Ctrl+Alt+S saving
-- ~/.ssh/config.local), shown in place of "Config reloaded" for the next few seconds. In
-- wezterm.GLOBAL, as the reload starts a new Lua VM.
function M.after_reload(text)
  wezterm.GLOBAL.reload_notice = { text = text, expires = os.time() + 5 }
end

-- Status ----------------------------------------------------------------------------------
-- The tab bar's right end, before the window buttons, refreshed every second: COPY /
-- SEARCH / RESIZE while those modes run, an SSH tab's host in its colour (and the zellij
-- session it attached) or the host a WSL tab has ssh'd to, the pane's line count, battery,
-- time. Parts drop out as the pane narrows.

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
  local s = domains.ssh_of(pane)
  local host = s and s.host
  local domain = pane:get_domain_name() or ''
  if not host and domain:find('^WSL:') then
    host = domains.wsl_remote(pane:get_current_working_dir(), (domain:gsub('^WSL:', '')), pane:get_title())
  end
  if host then
    table.insert(parts, { text = host, fg = appearance.accent(host) })
    if s and s.zellij and cols >= 130 then
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

  -- A live notice replaces the status, centred in at least its width so the tabs don't shift.
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

function M.apply(_)
  wezterm.on('update-status', render_status)

  wezterm.on('copied-scrollback', function(window, pane)
    M.flash(window, pane, 'Copied the scrollback')
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
    local n = wezterm.GLOBAL.reload_notice
    M.flash(window, pane, n and n.expires >= os.time() and n.text or 'Config reloaded')
  end)
end

return M
