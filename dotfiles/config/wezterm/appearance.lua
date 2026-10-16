-- appearance.lua: colours, font, window chrome, rendering, cursor, bell, scrollback, TERM,
-- and the one-line behaviour settings (notifications, closing, keyboard protocol, drops,
-- images). Exports M.mocha (the palette) and M.accent (a host's colour).

local wezterm = require 'wezterm'

local M = {}

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
M.mocha = mocha

-- A stable Mocha accent per host name, so each machine keeps its colour.
local accents = { mocha.blue, mocha.mauve, mocha.sky, mocha.green, mocha.yellow, mocha.peach, mocha.red, mocha.teal }
function M.accent(host)
  local h = 0
  for i = 1, #host do
    h = (h * 131 + host:byte(i)) % 65521
  end
  return accents[h % #accents + 1]
end

function M.apply(config)
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

  -- A soft blink: the bar holds, fades out late in its 500 ms, stays dark, then fades back.
  -- WezTerm reads a CubicBezier's four numbers as the weights of a one-dimensional cubic,
  -- not CSS's handles, so { 0, 0, 0, 1 } is t^3 (the default, 'Linear', is 3t^2 - 2t^3: a
  -- constant pulse), and 'Ease', 'EaseIn' and 'EaseInOut' start each fade a quarter or more
  -- of the way in, a visible jump. Every cursor move restarts the cycle, so the bar stays
  -- solid while you type. Nushell asks for this blinking bar too (config.nu.tera); an app
  -- that asks for a steady shape (helix in insert mode) gets one.
  config.default_cursor_style = 'BlinkingBar'
  config.cursor_blink_rate = 500
  config.cursor_blink_ease_in = { CubicBezier = { 0.0, 0.0, 0.0, 1.0 } }
  config.cursor_blink_ease_out = { CubicBezier = { 0.0, 0.0, 0.0, 1.0 } }
  -- In a window that isn't focused, or a pane that isn't active, WezTerm draws a hollow box
  -- instead, with sides 1.5 times this thickness (rounded down to whole pixels). 1.5pt is
  -- 2 px at 100% scaling, so the box's sides took 6 of the 8 px cell and it looked like a
  -- bar split by a black line. 1pt keeps it a box at 100%, and is 2 px from 150%.
  config.cursor_thickness = '1pt'

  -- No title bar. RESIZE keeps the thin resize frame, so Win+arrow snap, drag-to-edge snap
  -- and minimize still work ('NONE' loses them). Move the window with Ctrl+Shift+drag
  -- (WezTerm's default) or Win+drag (keys.lua's mouse bindings). The tab bar sits at the
  -- bottom, terminal-font style, with the status footer on its right.
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
  -- entry) and probe a host before ssh sends it; the SSH launch entries (domains.lua) check
  -- on the host; and the Windows shells switch to it, because Windows has no terminfo
  -- database and Neovim there falls back to a bare 'ansi' entry for a TERM it doesn't know.
  config.term = 'wezterm'

  -- Behaviour ---------------------------------------------------------------------------
  -- OSC 9 / 777 toasts only for panes you aren't looking at. Windows shows them once
  -- wezterm-nightly.ps1 has registered the org.wezfurlong.wezterm toast id.
  config.notification_handling = 'SuppressFromFocusedPane'
  config.switch_to_last_active_tab_when_closing_tab = true
  config.unzoom_on_switch_pane = true
  -- Closing a tab (Ctrl+Shift+W, keys.lua, or a middle-click on it) or the window never
  -- asks. A middle-click has no setting of its own: WezTerm asks unless this hook calls
  -- every process in the tab safe to close, and the window close uses the same check.
  config.window_close_confirmation = 'NeverPrompt'
  wezterm.on('mux-is-process-stateful', function()
    return false
  end)
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
end

return M
