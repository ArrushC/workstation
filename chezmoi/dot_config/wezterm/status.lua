-- =============================================================================
-- status.lua — right status line: domain · zellij · line count · battery ·
-- time, plus the "Copied!" badge (the 'copied' event handler lives here)
-- =============================================================================

local wezterm = require 'wezterm'

local M = {}

function M.apply(config)
  local appearance  = require 'appearance'
  local mocha       = appearance.mocha
  local host_accent = appearance.host_accent

  -- ---------------------------------------------------------------------------
  -- Right status line — domain · zellij session · battery · time
  -- ---------------------------------------------------------------------------
  -- Fires ~1×/second. Adapts to window width: drops the zellij blob, then the
  -- battery, then the time icon as columns shrink. The retro bar lays this
  -- block out flush against the right edge automatically; tabs sit on the
  -- left and the gap between them is bar bg (the minimal-retro look).
  --
  -- The zellij session name mirrors the hardcoded 'main' from zellij_attach_cmd
  -- in domains.lua — keep both in sync if you change it.

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
    -- Fully charged = zero information — hide the module. Still shown while
    -- charging (progress) or actively discharging (drain rate matters).
    if b.state == 'Full' or (pct >= 100 and b.state ~= 'Discharging') then
      return nil
    end
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

  -- group_thousands(10234) -> '10,234'. Lua has no built-in digit grouping.
  -- Non-negative integers only (line counts), so no sign handling.
  local function group_thousands(n)
    local s   = tostring(math.floor(n))
    local rev = s:reverse():gsub('(%d%d%d)', '%1,')  -- comma after every 3 digits
    local out = rev:reverse():gsub('^,', '')         -- un-reverse, drop leading comma
    return out
  end

  -- Active-pane line-count for the right status. Returns a display string, or nil
  -- when the module should be HIDDEN: dimensions unavailable, window too narrow,
  -- the pane is on the alternate screen (Zellij/helix/less/htop — no scrollback),
  -- or there's no real scrollback yet (total <= rows-on-screen; also covers a
  -- fresh shell). WezTerm exposes no live scroll offset and update-status doesn't
  -- fire on scroll, so 'rows' is the viewport HEIGHT, never a scrolled range.
  --   '↕ 10,234 · 38 rows'        cursor on the last line (at a shell prompt)
  --   '↕ 9,800/10,234 · 38 rows'  a main-screen program moved the cursor up
  local function format_line_status(pane, dim_info, cols)
    if not dim_info then return nil end
    if cols < 100 then return nil end
    if pane:is_alt_screen_active() then return nil end
    local total = dim_info.scrollback_rows or 0
    local rows  = dim_info.viewport_rows or 0
    if total <= rows then return nil end
    -- Cursor line within the buffer; nil cursor/scrollback_top → stay at total
    -- (the no-position form below). pos == total at a prompt; < total only when
    -- a main-screen program has moved the cursor up.
    local pos = total
    local cur = pane:get_cursor_position()
    if cur and dim_info.scrollback_top then
      pos = math.max(1, math.min(total, cur.y - dim_info.scrollback_top + 1))
    end
    if pos < total then
      return string.format('↕ %s/%s · %d rows',
        group_thousands(pos), group_thousands(total), rows)
    end
    return string.format('↕ %s · %d rows', group_thousands(total), rows)
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

    -- Modal-state badge — copy mode / search overlay / resize mode are
    -- otherwise invisible. window:active_key_table() reports the built-in
    -- modal tables ('copy_mode' / 'search_mode') plus the custom
    -- 'resize_pane' table (ALT+SHIFT+S, keys.lua). Read on the ~1s status
    -- tick; up to a tick of latency to appear/clear — same cadence as the
    -- whole bar.
    local key_table = window:active_key_table()
    if key_table == 'copy_mode' then
      table.insert(parts, { text = 'COPY', fg = mocha.yellow, bold = true })
    elseif key_table == 'search_mode' then
      table.insert(parts, { text = 'SEARCH', fg = mocha.sky, bold = true })
    elseif key_table == 'resize_pane' then
      table.insert(parts, { text = 'RESIZE', fg = mocha.teal, bold = true })
    end

    local domain = pane:get_domain_name()
    -- Show domain + zellij:main in the right status ONLY for SSH-domain tabs.
    -- Local tabs ('local') and WSL tabs ('WSL:<distro>') skip this block:
    -- local tabs have nothing meaningful to show, and WSL surfaces its distro
    -- name via the tab title (format-tab-title) — repeating it next to
    -- battery/time is redundant noise. WSL also has no zellij wrap so
    -- 'zellij:main' would be a lie there.
    if domain and domain ~= 'local' and not domain:find('^WSL:') then
      -- Same accent as the tab (host_accent shares the HOST_ACCENTS bucket) —
      -- the status bar and tab bar agree on which host you're looking at.
      table.insert(parts, { text = domain, fg = host_accent(domain) })
      if cols >= 130 then
        table.insert(parts, { text = 'zellij:main' })
      end
    end

    local line_status = format_line_status(pane, dim_info, cols)
    if line_status then
      table.insert(parts, { text = line_status })
    end

    if cols >= 80 then
      local bat = format_battery()
      if bat then table.insert(parts, { text = bat }) end
    end

    if cols >= 60 then
      table.insert(parts, { text = time_icon() .. ' ' .. wezterm.strftime('%a %H:%M') })
    else
      table.insert(parts, { text = wezterm.strftime('%H:%M') })
    end

    -- Tighter separator (' · ' instead of '  │  ') in a dim color so the bar
    -- doesn't dominate visually. The fancy tab bar font (JetBrainsMono Nerd Font Mono Medium)
    -- rendered the heavy '│' with too much weight against the lighter labels.
    local FG     = mocha.text
    local FG_DIM = mocha.overlay0
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
        { Foreground = { Color = mocha.green } },
        { Attribute = { Intensity = 'Bold' } },
        { Text = badge },
        { Attribute = { Intensity = 'Normal' } },
        { Text = string.rep(' ', right) },
      })
    else
      window:set_right_status(wezterm.format(items))
    end
  end

  wezterm.on('update-right-status', render_right_status)

  -- Emitted by act.EmitEvent 'copied' in the copy keybindings (CTRL+SHIFT+C,
  -- CTRL+SHIFT+A). Re-renders the right status immediately so the badge appears
  -- without waiting for the next ~1s update-right-status tick.
  wezterm.on('copied', function(window, pane)
    copied_at[window:window_id()] = os.time()
    render_right_status(window, pane)
  end)
end

return M
