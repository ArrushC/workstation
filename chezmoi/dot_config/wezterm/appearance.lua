-- =============================================================================
-- appearance.lua — colors, font, window chrome, GPU/fps, cursor, term
-- Exports: M.mocha (the palette), M.host_accent (per-host accent color)
-- =============================================================================

local wezterm = require 'wezterm'

local M = {}

function M.apply(config)
  -- Catppuccin Mocha palette — single source for every hardcoded chrome/tab/status
  -- color below. The 16-color ANSI palette + default bg/fg come from the built-in
  -- 'Catppuccin Mocha' color_scheme; this table only covers the surfaces WezTerm
  -- doesn't theme for us (window frame, tab bar, scrollbar, per-host tab accents,
  -- right-status text). Values are the canonical Catppuccin Mocha hexes.
  local mocha = {
    base     = '#1e1e2e',
    mantle   = '#181825',
    crust    = '#11111b',
    surface0 = '#313244',
    surface1 = '#45475a',
    surface2 = '#585b70',
    overlay0 = '#6c7086',
    text     = '#cdd6f4',
    blue     = '#89b4fa',
    mauve    = '#cba6f7',
    sky      = '#89dceb',
    green    = '#a6e3a1',
    yellow   = '#f9e2af',
    peach    = '#fab387',
    red      = '#f38ba8',
    teal     = '#94e2d5',
  }

  config.color_scheme = 'Catppuccin Mocha'
  config.font         = wezterm.font('JetBrainsMono Nerd Font Mono', { weight = 'Regular' })

  -- Belt-and-suspenders on Windows: also point at %LOCALAPPDATA%\Microsoft\Windows\Fonts\
  -- directly. install-nerd-fonts.ps1 (invoked from bootstrap.ps1) deposits the
  -- six Mono variants there + HKCU-registers them, but config.font_dirs guards
  -- against bootstrap ordering races where wezterm reads its config before the
  -- HKCU registration completes — the .ttf files are still accessible from the
  -- font_dirs path. No-op on Linux (Linux WezTerm uses fontconfig instead).
  if wezterm.target_triple:find('windows') then
    local localappdata = os.getenv('LOCALAPPDATA')
    if localappdata then
      config.font_dirs = { localappdata .. '\\Microsoft\\Windows\\Fonts' }
    end
  end
  config.font_size    = 10.5

  -- Toggle between fancy (native GUI, proportional/custom font, top only,
  -- frameless Chrome-style with integrated min/max/close) and retro
  -- (terminal-cell font, sits at the bottom, title-bar-less, reads
  -- as one continuous strip with the active tab as the only visible tile).
  -- Flip this single flag to switch styles end-to-end.
  local fancy_tabs                   = false

  -- Window chrome — no OS title bar in either mode. Fancy uses
  -- INTEGRATED_BUTTONS|RESIZE for the Chrome look: WezTerm-drawn min/max/close
  -- buttons integrated into the tab bar (colors via button_* in window_frame).
  -- Retro uses bare RESIZE: no title bar, no buttons, just the invisible thin
  -- resize frame — Win+Arrow snap, drag-to-edge snap, mouse resize, and
  -- Win+Down minimize all still work because the window is still a normal
  -- resizable window. Move it with CTRL+SHIFT+drag or WIN+drag (StartWindowDrag
  -- mouse bindings below) — there's no title bar to grab and the bottom retro
  -- tab bar is NOT a drag area. ('NONE' was considered for "completely
  -- borderless" and rejected: it drops the resize frame too, which breaks
  -- Win+Arrow snap, minimize, AND mouse resizing.)
  config.window_decorations          = fancy_tabs and 'INTEGRATED_BUTTONS|RESIZE' or 'RESIZE'
  config.enable_tab_bar              = true
  config.use_fancy_tab_bar           = fancy_tabs
  -- tab_bar_at_bottom is only honored by the retro bar; fancy is always top.
  config.tab_bar_at_bottom           = not fancy_tabs
  config.hide_tab_bar_if_only_one_tab = false

  -- Closing the WINDOW never prompts either — same rationale as the
  -- no-confirm tab close (CTRL+SHIFT+W): SSH tabs run inside remote Zellij
  -- sessions that survive and reattach; local/WSL shells hold no state worth
  -- a modal.
  config.window_close_confirmation = 'NeverPrompt'

  -- Update-check toast off — the WezTerm pin is maintained as weekly
  -- mirrored NIGHTLY snapshots (bootstrap.ps1 $PortableTools, bumped only by
  -- .github/workflows/wezterm-nightly.yml), so the update channel is the
  -- weekly PR + bootstrap re-run; against a rolling nightly the in-app toast
  -- is pure noise. (History: pinned stable 20240203 from 2026-05; nightly
  -- snapshot policy adopted 2026-07-16 — the stable pin stays until the
  -- first workflow-driven bump PR lands. Toast declined 2026-07-09,
  -- re-approved 2026-07-10, kept off under the nightly policy.)
  config.check_for_updates = false

  -- OSC 9 / OSC 777 escape-sequence toasts: suppress them for the pane
  -- you're looking at (you can already see it); background panes still
  -- toast. Governs ONLY escape-originated notifications — a channel nothing
  -- here emits on today, so this is dormant policy. ~/.claude/notify.sh's
  -- BurntToast + BEL channel is completely unaffected.
  config.notification_handling = 'SuppressFromFocusedPane'

  -- Kitty graphics protocol — off by default on this build. Enables inline
  -- image previews (yazi, wezterm imgcat) in local/WSL/raw-ssh panes. Known
  -- limit: NOT through Zellij tabs (no kitty-graphics passthrough there).
  config.enable_kitty_graphics = true

  -- Kitty keyboard protocol — honor enhanced-key-encoding requests from
  -- apps that ask for it (Helix gets disambiguated keys where the chain
  -- negotiates it; Zellij 0.41+ passes the protocol through). Opt-in per
  -- app at runtime, so panes whose programs never request it are untouched;
  -- in native ConPTY panes win32-input-mode takes precedence anyway
  -- (allow_win32_input_mode default true, deliberately kept). If a TUI
  -- misbehaves after this lands, flip this back first.
  config.enable_kitty_keyboard = true

  -- Drag-and-dropping a file onto the terminal pastes its path quoted
  -- (Windows-style double quotes — also valid in POSIX shells). The
  -- SpacesOnly default leaves parens/brackets in Windows paths unquoted.
  config.quote_dropped_files = 'WindowsAlwaysQuoted'

  -- Fancy-mode chrome (Catppuccin Mocha-matched). Ignored when use_fancy_tab_bar = false.
  -- Font is JetBrainsMono Nerd Font Mono (Medium weight) so the tab bar carries
  -- the terminal's identity but stays distinct from body text (which uses
  -- Regular weight of the same family). The retro tab bar inherits the main
  -- terminal font automatically, so JetBrainsMono Nerd Font Mono is applied in
  -- both modes without needing a separate retro override.
  config.window_frame = {
    font                            = wezterm.font { family = 'JetBrainsMono Nerd Font Mono', weight = 'Medium' },
    font_size                       = 10,
    -- Active bar sits slightly elevated above base (surface0) for separation;
    -- inactive drops down to mantle.
    active_titlebar_bg              = mocha.surface0,
    inactive_titlebar_bg            = mocha.mantle,
    active_titlebar_fg              = mocha.text,
    inactive_titlebar_fg            = mocha.overlay0,
    active_titlebar_border_bottom   = mocha.surface1,
    inactive_titlebar_border_bottom = mocha.crust,
    button_bg                       = mocha.surface0,
    button_fg                       = mocha.text,
    button_hover_bg                 = mocha.surface1,
    button_hover_fg                 = mocha.text,
  }

  -- Tab-bar surfaces (background behind tabs in retro mode + new-tab "+" button
  -- in both modes). Per-tab active/inactive/hover colors are driven by
  -- format-tab-title above for every tab, so we only need to style the chrome
  -- around them. Matches the window_frame palette so retro and fancy modes
  -- share the same visual language.
  config.colors = {
    tab_bar = {
      background        = mocha.base,
      -- Hide the thin tab-edge divider — the default color is a light gray that
      -- pops against the bar bg only when the adjacent surface lightens (e.g.
      -- when hovering the "+" button). Match the bar bg so it disappears in
      -- every state.
      inactive_tab_edge = mocha.base,
      new_tab           = { bg_color = mocha.base, fg_color = mocha.overlay0 },
      new_tab_hover     = { bg_color = mocha.surface1, fg_color = mocha.text },
    },
    -- Scrollbar thumb — visible against the Catppuccin Mocha bg without screaming
    scrollbar_thumb = mocha.surface2,
    -- Cursor — mauve identity, overriding the built-in Catppuccin Mocha scheme's
    -- default (rosewater) cursor. cursor_bg/cursor_border color the BlinkingBar
    -- (config.default_cursor_style below); cursor_fg only shows when the cursor
    -- renders as a block, so it's kept dark (crust) to keep any covered glyph
    -- legible. Pairs with the mauve active local tab in tabs.lua tab_colors.
    cursor_bg     = mocha.mauve,
    cursor_border = mocha.mauve,
    cursor_fg     = mocha.crust,
    -- Visual-bell flash color — peach: warm, attention-adjacent, and clearly
    -- distinct from the mauve cursor it momentarily replaces (config.visual_bell
    -- below targets CursorColor).
    visual_bell   = mocha.peach,
    -- Quick-select overlay (CTRL+SHIFT+Space/I/G/Y) — the stock label/match
    -- colors are an olive/green pair that ignores the Mocha chrome. Labels
    -- (the jump letters you type) go loud peach-on-crust — the same
    -- "attention" peach as the visual bell; matches lift onto surface1 with
    -- sky text, readable without shouting across a screenful of hits.
    -- Pairs with quick_select_remove_styling (actions.lua), which de-styles
    -- the pane so these are the only colors left. ColorSpec wrappers
    -- ({ Color = ... }) are the required shape, as for the label keys below.
    quick_select_label_bg = { Color = mocha.peach },
    quick_select_label_fg = { Color = mocha.crust },
    quick_select_match_bg = { Color = mocha.surface1 },
    quick_select_match_fg = { Color = mocha.sky },
    -- Copy mode (CTRL+SHIFT+A path; also X/V selections in the overlay) —
    -- the active selection region carries the mauve identity (cursor, active
    -- local tab); inactive highlight drops to a neutral surface. Last
    -- overlay-adjacent surface that still used stock colors.
    copy_mode_active_highlight_bg   = { Color = mocha.mauve },
    copy_mode_active_highlight_fg   = { Color = mocha.crust },
    copy_mode_inactive_highlight_bg = { Color = mocha.surface2 },
    copy_mode_inactive_highlight_fg = { Color = mocha.text },
    -- NIGHTLY-ONLY: label-row colors for the InputSelector overlays (host
    -- picker, tab switcher, help, WSL picker) and the launcher menu — the
    -- last two overlay surfaces that ignored the Mocha chrome. Matched to
    -- the command-palette treatment (crust bg / text fg) so every overlay
    -- reads as one system. ColorSpec wrappers ({ Color = ... }) are the
    -- required shape for these keys, unlike the plain-hex keys above.
    input_selector_label_bg = { Color = mocha.crust },
    input_selector_label_fg = { Color = mocha.text },
    launcher_label_bg       = { Color = mocha.crust },
    launcher_label_fg       = { Color = mocha.text },
  }

  -- Fuzzy-overlay chrome — the command palette (CTRL+SHIFT+P) AND every
  -- InputSelector overlay (host picker CTRL+SHIFT+J, tab switcher CTRL+SHIFT+S,
  -- help CTRL+SHIFT+H, WSL distro picker) render with these colors. Without
  -- them the overlays use WezTerm's stock dark-gray — the one surface that
  -- didn't match the Mocha chrome.
  config.command_palette_bg_color  = mocha.crust
  config.command_palette_fg_color  = mocha.text
  config.command_palette_font_size = 12.0

  -- Character/emoji picker (CTRL+SHIFT+U) — same Mocha treatment as the
  -- command palette above (stock is a #333333 gray box). Top-level options,
  -- not config.colors keys; font size matched to the palette's 12.0.
  config.char_select_bg_color  = mocha.crust
  config.char_select_fg_color  = mocha.text
  config.char_select_font_size = 12.0

  -- Scrollback depth — how many lines WezTerm retains per pane above the
  -- viewport. Default is 3500; 100,000 (~28× default) is deep enough for heavy
  -- build/log output while staying bounded. Memory is per-pane and allocated
  -- LAZILY as lines actually scroll off — the value is a ceiling, not an
  -- upfront cost, so an idle pane pays nothing.
  --
  -- Was 1,000,000 ("never lose output") until 2026-07-09: at ~100-200 bytes a
  -- line, long-lived busy panes accumulated ~745MB of committed memory over a
  -- 3-day session on the iGPU laptop and performance degraded until a restart
  -- (restart confirmed the cause live). Need a full capture instead of a deep
  -- buffer? CTRL+SHIFT+A copies the whole scrollback; CTRL+SHIFT+O dumps it
  -- into Helix.
  --
  -- Scope: this governs panes WezTerm renders directly — local WSL / PowerShell
  -- tabs and raw SSH output. Inside SSH tabs, Zellij owns its own scroll buffer
  -- while drawing its UI, so its internal scrollback is bounded by Zellij's
  -- scroll_buffer_size (see chezmoi/dot_config/zellij/config.kdl — kept matched
  -- at 100,000), NOT this.
  config.scrollback_lines = 100000

  -- Per-pane render caches — undocumented (no doc pages; fields verified in
  -- config/src/config.rs) but load-bearing for scroll smoothness: shaping,
  -- line-state, and quad data are computed per LINE and cached, and fast
  -- scrolling through a deep buffer (100k above) blows the default caches
  -- (1024 entries each; image cache 256) into worst-case re-shaping every
  -- frame (upstream discussion #3664). 4096 trades a few MB per pane for
  -- cache hits during heavy scroll; the image cache serves kitty-graphics
  -- panes (yazi previews). Name trap: the fourth one really is
  -- line_to_ele_shape_cache_size — "line_shape_cache_size" does not exist.
  -- To measure: temporarily set periodic_stat_logging (seconds) and watch
  -- the *.hit.rate lines in the log.
  config.shape_cache_size             = 4096
  config.line_state_cache_size        = 4096
  config.line_quad_cache_size         = 4096
  config.line_to_ele_shape_cache_size = 4096
  config.glyph_cache_image_cache_size = 1024

  -- Show the right-side scrollbar. It lives inside window_padding.right, so
  -- the right padding is bumped below to give it room without crowding text.
  config.enable_scroll_bar = true

  -- Slightly padded inner margins. Right padding is wider than the others so
  -- the scrollbar (enable_scroll_bar above) has room without sitting on the
  -- last column of text.
  config.window_padding = {
    left   = 8,
    right  = 16,
    top    = 6,
    bottom = 6,
  }

  -- NIGHTLY-ONLY: center the leftover pixel gap when the window size isn't
  -- an exact multiple of the cell size (snap/maximize almost never is) —
  -- stock behavior dumps the whole remainder on the right/bottom edge.
  -- use_resize_increments is NOT the fix here: documented X11/Wayland/macOS
  -- only, no effect on Windows.
  config.window_content_alignment = {
    horizontal = 'Center',
    vertical   = 'Center',
  }

  -- Initial window size in terminal cells. WezTerm's default is 80x24 —
  -- cramped on a modern display and below the 130-col threshold where the
  -- right status starts showing the zellij blob. 140x38 is a comfortable
  -- working size; snap/maximize from there as needed.
  config.initial_cols = 140
  config.initial_rows = 38

  -- GPU rendering. Static values only — NEVER call wezterm.gui.* (screens /
  -- enumerate_gpus) here: those need a GUI context that isn't ready at
  -- config-load and DEADLOCK WezTerm into an unresponsive window (a hang slips
  -- past pcall, which only catches throws). See #39→#40.
  --
  -- WebGpu (D3D12 on Windows) + 120fps + the HighPerformance adapter, on EVERY
  -- host. This is the simple config that ran snappily for ~7 weeks (from
  -- 2026-05-06). Two per-host "optimizations" were later tried on the single
  -- Intel-iGPU @ 60Hz laptop CBL-LT-PW0FW9T4 and BOTH reverted as perceived-
  -- latency REGRESSIONS (A/B-confirmed on that machine):
  --   * #39/#40 capped max_fps to the 60Hz panel rate, reasoning that frames
  --     above the refresh rate are wasted. They are NOT wasted for INPUT latency:
  --     a higher max_fps repaints the framebuffer sooner after a keypress, so the
  --     next vsync shows fresher content. 120fps feels markedly snappier than 60
  --     even on the 60Hz panel; the iGPU renders 120fps fine.
  --   * #42 switched it to OpenGL, reasoning OpenGL is lower-latency than WebGpu
  --     on Intel iGPUs (true on Linux/Mesa). On WINDOWS Intel's GL driver is weak
  --     and WezTerm's GL backend can degrade toward software, so the D3D12-backed
  --     WebGpu path is faster (the slowdown read as "worse than Windows Terminal",
  --     itself a DirectX app).
  -- DO NOT re-introduce a per-host max_fps cap or an OpenGL front_end here.
  -- (webgpu_power_preference='HighPerformance' is a no-op on a single-GPU box —
  -- only one adapter to pick — and selects the discrete GPU on multi-GPU hosts.
  -- 'LowPower' — prefer the iGPU — was considered and declined 2026-07-16:
  -- a no-op on today's single-GPU fleet, and any GPU-setting change here needs
  -- an A/B on real multi-GPU hardware first, per the history above.)
  config.front_end = 'WebGpu'
  config.webgpu_power_preference = 'HighPerformance'
  local render_fps = 120

  -- Redraw-rate cap — how often the surface repaints (scrolling, TUI updates,
  -- output churn). Matched to render_fps above.
  config.max_fps = render_fps

  -- TERM advertising — pair with the chezmoi-deployed wezterm terminfo
  -- (.chezmoiscripts/run_install-wezterm-terminfo.sh.tmpl). Setting
  -- TERM=wezterm lets apps query terminfo for Tc / Smulx / Setulc instead of
  -- inferring capabilities from the looser xterm-256color entry. PTYs
  -- inheriting this TERM: local WSL panes, SSH-domain panes (default_prog
  -- zellij attach), and any manual `ssh` from a local tab.
  --
  -- Pre-req: every target host must have ~/.terminfo/w/wezterm installed,
  -- compiled from chezmoi/dot_local/share/wezterm/wezterm.terminfo by the
  -- run_onchange script above. Verify per host via `infocmp wezterm`
  -- (must exit 0) after `czu && cza`. Hosts without the entry will error
  -- on first TUI launch with `Error opening terminal: wezterm` — recover
  -- with `cza` on that host (or `TERM=xterm-256color hx file` ad hoc).
  config.term = 'wezterm'

  -- Animation framerate — affects blinking cursor, blinking text, and visual
  -- bell easing only (NOT scrolling — terminals scroll by row, and NOT input
  -- repaint latency — that's max_fps above, which stays at render_fps).
  -- Default is 10, which makes blinks visibly choppy on a 60 Hz+ display.
  -- 60 keeps every transition smooth (the 75–150ms bell fades still get 4–9
  -- eased frames) at half the repaint cost of the old matched-to-max_fps 120:
  -- with a BlinkingBar cursor, animation_fps is what the GPU eases at around
  -- every blink, all day. Deliberately DECOUPLED from render_fps (2026-07-16;
  -- was matched at 120 — the #39/#40 latency findings above concern max_fps
  -- only and are untouched by this).
  config.animation_fps = 60

  -- Cursor — blinking vertical bar (I-beam). animation_fps above smooths the
  -- blink transitions; cursor_blink_rate sets the period in ms (default 800).
  -- 500ms gives a brisker blink — the classic terminal "fast blink" cadence
  -- without crossing into seizure territory. Pair with animation_fps=60 above
  -- so the on→off transition still eases rather than hard-flipping.
  config.default_cursor_style = 'BlinkingBar'
  config.cursor_blink_rate    = 500

  -- Bar width — the default derives from the font's underline thickness
  -- (~1px for JetBrainsMono at 10.5pt), which reads thin against the mauve
  -- accent. pt units are DPI-scaled: 1.5pt ≈ 2px on the 96-DPI panel and
  -- grows proportionally on high-DPI displays (a raw px value would not).
  config.cursor_thickness = '1.5pt'

  -- Blinking *text* (distinct from the cursor) has two cadences: text_blink_rate
  -- for SGR 5 (slow blink, default 500ms) and text_blink_rate_rapid for SGR 6
  -- (rapid blink, default 250ms). Set the rapid period explicitly so apps that
  -- emit SGR 6 get a defined fast blink; animation_fps=60 above eases the
  -- on→off transition. Lower toward ~150 for an even snappier blink.
  config.text_blink_rate_rapid = 250

  -- Visual bell — a brief cursor-color flash (mocha.peach via colors.visual_bell
  -- above) on BEL. Complements ~/.claude/notify.sh, which rings the terminal
  -- bell for Claude Code notifications: the flash gives a visible cue even with
  -- audio muted. The audible bell is deliberately left at its default — this is
  -- an ADDITION, not a replacement (notify.sh depends on BEL staying audible).
  -- Transitions are eased at animation_fps (60) like the cursor blink.
  config.visual_bell = {
    fade_in_function     = 'EaseIn',
    fade_in_duration_ms  = 75,
    fade_out_function    = 'EaseOut',
    fade_out_duration_ms = 150,
    target               = 'CursorColor',
  }

  -- ---------------------------------------------------------------------------
  -- Tab colors — Catppuccin Mocha accent palette + state variants
  -- ---------------------------------------------------------------------------
  -- Each SSH host gets a stable accent from this curated Catppuccin Mocha palette
  -- (8-bucket hash on the host name), so there's a cheap visual guard against
  -- typing into the wrong host. The per-state mapping lives in tab_colors
  -- in tabs.lua; this block just defines the palette + hash.
  local HOST_ACCENTS = {
    mocha.blue,    -- blue
    mocha.mauve,   -- mauve (magenta)
    mocha.sky,     -- sky (cyan)
    mocha.green,   -- green
    mocha.yellow,  -- yellow
    mocha.peach,   -- peach (orange)
    mocha.red,     -- red
    mocha.teal,    -- teal
  }

  local function host_hash(name)
    local h = 0
    for i = 1, #name do
      h = (h * 131 + name:byte(i)) % 65521
    end
    return h
  end

  -- Accent hex for a host name (HOST_ACCENTS bucket via host_hash); mauve for
  -- nil (local tabs) — the same mauve identity as the cursor + active local tab.
  -- Single source for tab_colors, the tab activity dot, and the right-status
  -- domain color.
  local function host_accent(host)
    if not host then return mocha.mauve end
    return HOST_ACCENTS[(host_hash(host) % #HOST_ACCENTS) + 1]
  end

  M.mocha       = mocha
  M.host_accent = host_accent
end

return M
