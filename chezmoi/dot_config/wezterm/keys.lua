-- =============================================================================
-- keys.lua — config.keys + config.mouse_bindings (actions come from
-- actions.lua / wsl.lua; this file owns only the bindings)
-- =============================================================================

local wezterm = require 'wezterm'
local act     = wezterm.action

local M = {}

function M.apply(config)
  local actions = require 'actions'
  local wsl     = require 'wsl'

  local smart_new_tab       = actions.smart_new_tab
  local pick_host           = actions.pick_host
  local pick_tab            = actions.pick_tab
  local reconnect_ssh_pane  = actions.reconnect_ssh_pane
  local rename_tab          = actions.rename_tab
  local copy_all_scrollback = actions.copy_all_scrollback
  local copy_and_announce   = actions.copy_and_announce
  local scrollback_to_helix = actions.scrollback_to_helix
  local show_help           = actions.show_help
  local quick_ssh_ip        = actions.quick_ssh_ip
  local quick_open_hx       = actions.quick_open_hx
  local quick_yank_sha      = actions.quick_yank_sha
  local split_down          = actions.split_down
  local split_right         = actions.split_right
  local pane_picker         = actions.pane_picker
  local new_window_action   = wsl.new_window_action

  -- ---------------------------------------------------------------------------
  -- Keybinds
  -- ---------------------------------------------------------------------------
  -- Zellij owns Ctrl+p and pane management inside the session.
  -- Wezterm handles window/tab creation at the OS level.
  -- Mouse: drag-then-release on left button completes the selection AND, if
  -- non-empty, writes to clipboard + flashes the "Copied!" badge. The Up event
  -- also fires on plain clicks; copy_and_announce no-ops on empty selection, so
  -- there's no spurious badge. We don't override Shift-Up or double/triple-click
  -- streaks — those keep their default behavior (link-open, word/line select).
  -- Mouse bindings layer over defaults, so other mouse actions are preserved.
  config.mouse_bindings = {
    {
      event = { Up = { streak = 1, button = 'Left' } },
      action = act.Multiple {
        act.CompleteSelection 'PrimarySelection',
        copy_and_announce,
      },
    },
    -- CTRL+click hyperlink-open binding (pattern from the canonical recipe at
    -- wezterm.org/recipes/hyperlinks.html).
    --
    -- Why it's needed: WezTerm's default mods=NONE Up+Left binding is the
    -- *composite* action `CompleteSelectionOrOpenLinkAtMouseCursor` — it opens a
    -- hyperlink under the cursor when no selection is in progress, otherwise
    -- completes the selection. The no-mods override above replaces that composite
    -- with plain `CompleteSelection` + copy_and_announce, which removes the
    -- link-open fallthrough that lived inside the composite default.
    --
    -- There is NO default mods='CTRL' binding for OpenLinkAtMouseCursor (the
    -- wezterm.org/config/mouse.html page incorrectly lists one — the source at
    -- wezterm-gui/src/inputmap.rs disagrees, verified at 20240203 + nightly main 2026-07-16).
    -- Restating CTRL+click explicitly here restores link-open behaviour without
    -- giving up the copy-on-release UX from the no-mods override above.
    --
    -- The paired CTRL+Down→Nop suppresses the click-down event when CTRL is
    -- held, so a CTRL+click on a hyperlink doesn't start a stray selection on
    -- press, and doesn't leak into mouse-aware TUI apps (zellij/helix/vim with
    -- mouse-mode on inside an SSH pane).
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      action = act.Nop,
    },
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      action = act.OpenLinkAtMouseCursor,
    },
    -- SHIFT+click — open the hyperlink under the mouse. The stock SHIFT+Down
    -- default is ExtendSelectionToMouseCursor(Cell), which means the SHIFT+Up
    -- composite (CompleteSelectionOrOpenLinkAtMouseCursor) ALWAYS sees a live
    -- selection and takes the complete-selection branch — the link-open branch
    -- was unreachable (verified against inputmap.rs at 20240203 + nightly
    -- main 2026-07-16). Overriding Down to START a fresh selection instead of extending
    -- makes a plain shift-click arrive at Up with an EMPTY selection → the
    -- link opens. Shift+drag still selects: Down anchors, the untouched
    -- SHIFT+Drag default extends, Up completes + copies (copy_and_announce
    -- re-copy is harmless; it no-ops when the selection is empty).
    -- SHIFT is the point: it's the bypass_mouse_reporting_modifier (default,
    -- unchanged), so this is the ONE modifier that reaches WezTerm's own mouse
    -- handling inside mouse-reporting panes (Zellij/Helix) — the CTRL+click
    -- binding above never fires there. Accepted loss: shift-click-to-EXTEND an
    -- existing selection (niche; drag selection covers it).
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'SHIFT',
      action = act.SelectTextAtMouseCursor 'Cell',
    },
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'SHIFT',
      action = act.Multiple {
        act.CompleteSelectionOrOpenLinkAtMouseCursor 'ClipboardAndPrimarySelection',
        copy_and_announce,
      },
    },
    -- Window drag-to-move — required since window_decorations='RESIZE' removed
    -- the OS title bar (and the bottom retro tab bar is not a drag area). The
    -- two bindings are the canonical pair from wezterm.org's window_decorations
    -- docs; SUPER is the Windows key. StartWindowDrag hands off to the OS move
    -- loop, so drag-to-screen-edge snapping keeps working.
    {
      event = { Drag = { streak = 1, button = 'Left' } },
      mods = 'CTRL|SHIFT',
      action = act.StartWindowDrag,
    },
    {
      event = { Drag = { streak = 1, button = 'Left' } },
      mods = 'SUPER',
      action = act.StartWindowDrag,
    },
    -- CTRL+triple-click — select ONE command's entire output as a unit
    -- (SemanticZone, via the OSC 133 marks from the managed rcs). The Up half
    -- completes the selection and auto-copies via copy_and_announce, mirroring
    -- the plain drag-release copy UX above. Plain triple-click keeps its
    -- default line-select. Inert where no marks exist (Zellij tabs).
    {
      event = { Down = { streak = 3, button = 'Left' } },
      mods = 'CTRL',
      action = act.SelectTextAtMouseCursor 'SemanticZone',
    },
    {
      event = { Up = { streak = 3, button = 'Left' } },
      mods = 'CTRL',
      action = act.Multiple {
        act.CompleteSelection 'PrimarySelection',
        copy_and_announce,
      },
    },
  }

  config.keys = {
    -- New window — plain SpawnWindow, or the distro-first picker on a
    -- 2+-distro machine (new_window_action from wsl.lua).
    { key = 'n', mods = 'CTRL|SHIFT', action = new_window_action },

    -- New tab in current domain. Uses smart_new_tab (actions.lua) so
    -- WSL tabs without OSC 7 cwd-tracking land in ~ instead of inheriting
    -- wezterm's Windows-side cwd.
    { key = 't', mods = 'CTRL|SHIFT', action = smart_new_tab },

    -- Fuzzy-pick a host and open it in a new tab (J = jump)
    { key = 'j', mods = 'CTRL|SHIFT', action = pick_host },

    -- Reconnect the current SSH pane after a broken pipe (F5 = refresh).
    -- Spawns a new tab against the same domain; Zellij reattaches the remote
    -- session via default_prog. Dead tab is left open for scrollback.
    { key = 'F5', mods = 'CTRL|SHIFT', action = reconnect_ssh_pane },

    -- Show keybind + host cheatsheet
    { key = 'h', mods = 'CTRL|SHIFT', action = show_help },

    -- Close tab — no confirmation prompt (user preference). Low-risk: SSH-domain
    -- tabs run inside a remote Zellij session that survives the tab and
    -- reattaches via the host picker / CTRL+SHIFT+F5.
    { key = 'w', mods = 'CTRL|SHIFT', action = act.CloseCurrentTab { confirm = false } },

    -- Switch tabs
    { key = 'Tab',       mods = 'CTRL',       action = act.ActivateTabRelative(1) },
    { key = 'Tab',       mods = 'CTRL|SHIFT', action = act.ActivateTabRelative(-1) },

    -- Tab switcher — fuzzy list with explicit tab index + domain in label
    { key = 's', mods = 'CTRL|SHIFT', action = pick_tab },

    -- Rename current tab — prompts for a new title; submit empty to clear
    -- and revert to the auto-generated name.
    { key = 'e', mods = 'CTRL|SHIFT', action = rename_tab },

    -- Copy/paste. copy_and_announce is selection-aware: it only writes to the
    -- clipboard (and shows the badge) if there's actually a selection, so a
    -- bare keypress with nothing selected is a no-op. Bound to both CTRL+SHIFT+C
    -- and the legacy CTRL+Insert.
    { key = 'c',      mods = 'CTRL|SHIFT', action = copy_and_announce },
    { key = 'Insert', mods = 'CTRL',       action = copy_and_announce },
    { key = 'v',      mods = 'CTRL|SHIFT', action = act.PasteFrom 'Clipboard' },

    -- Dump scrollback to a temp file and open it in Helix (local/WSL panes;
    -- SSH panes toast — Zellij owns their scrollback). O = open.
    { key = 'o', mods = 'CTRL|SHIFT', action = scrollback_to_helix },

    -- Copy entire scrollback to clipboard (enters copy mode, selects all, copies, exits)
    { key = 'a', mods = 'CTRL|SHIFT', action = copy_all_scrollback },

    -- Scroll-to-prompt — jump the scrollback prompt-by-prompt using the OSC 133
    -- marks the managed rcs emit (dot_zshrc.tmpl / dot_bashrc.tmpl). Overrides
    -- the default CTRL|SHIFT+Up/Down pane-navigation assignments, which Zellij
    -- makes redundant here (it owns panes inside SSH tabs; the Left/Right
    -- defaults are separately released to the SHELL — see the
    -- DisableDefaultAssignment block below). Works in WSL/local/raw-ssh panes;
    -- inert inside Zellij tabs (the alt screen owns that buffer).
    { key = 'UpArrow',   mods = 'CTRL|SHIFT', action = act.ScrollToPrompt(-1) },
    { key = 'DownArrow', mods = 'CTRL|SHIFT', action = act.ScrollToPrompt(1) },

    -- QuickSelect action bindings (actions.lua): I = IP → SSH, G = goto
    -- file:line in Helix, Y = yank SHA into the prompt.
    { key = 'i', mods = 'CTRL|SHIFT', action = quick_ssh_ip },
    { key = 'g', mods = 'CTRL|SHIFT', action = quick_open_hx },
    { key = 'y', mods = 'CTRL|SHIFT', action = quick_yank_sha },

    -- Panes (local/WSL tabs — Zellij owns panes inside SSH tabs). ALT+SHIFT
    -- layer: D/R split (Zellij pane-mode mnemonics), arrows navigate.
    -- CTRL+SHIFT+Z restates the built-in zoom default so the cheatsheet and
    -- this config stay the source of truth; CTRL+SHIFT+Q = letter overlay.
    { key = 'd', mods = 'SHIFT|ALT', action = split_down },
    { key = 'r', mods = 'SHIFT|ALT', action = split_right },
    { key = 'z', mods = 'CTRL|SHIFT', action = act.TogglePaneZoomState },
    { key = 'q', mods = 'CTRL|SHIFT', action = pane_picker },
    { key = 'LeftArrow',  mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Left' },
    { key = 'RightArrow', mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Right' },
    { key = 'UpArrow',    mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Up' },
    { key = 'DownArrow',  mods = 'SHIFT|ALT', action = act.ActivatePaneDirection 'Down' },

    -- Release CTRL+SHIFT+←/→ back to the SHELL. The build's defaults bind
    -- them to ActivatePaneDirection, and a bound chord is consumed even with
    -- a single pane — which silently shadowed the zsh shift-select
    -- word-extend (README §prompt-keys) in EVERY pane since that feature
    -- landed. Pane nav lives on ALT+SHIFT+arrows above; CTRL+SHIFT+Up/Down
    -- stay ScrollToPrompt overrides (they never reached the shell either way).
    { key = 'LeftArrow',  mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },
    { key = 'RightArrow', mods = 'CTRL|SHIFT', action = act.DisableDefaultAssignment },

    -- Font size
    { key = '=', mods = 'CTRL', action = act.IncreaseFontSize },
    { key = '-', mods = 'CTRL', action = act.DecreaseFontSize },
    { key = '0', mods = 'CTRL', action = act.ResetFontSize },

    -- Reload config
    { key = 'r', mods = 'CTRL|SHIFT', action = act.ReloadConfiguration },

    -- Release Win+Arrow back to the OS for window snap (wezterm's defaults
    -- bind these to pane navigation, but zellij owns panes inside SSH tabs
    -- and CTRL+TAB handles tab switching here).
    { key = 'LeftArrow',  mods = 'SUPER', action = act.DisableDefaultAssignment },
    { key = 'RightArrow', mods = 'SUPER', action = act.DisableDefaultAssignment },
    { key = 'UpArrow',    mods = 'SUPER', action = act.DisableDefaultAssignment },
    { key = 'DownArrow',  mods = 'SUPER', action = act.DisableDefaultAssignment },
  }

  -- Jump to tab by number — ALT+1..9. README.html's keybind table already
  -- documents 1..9; this loop makes the config match it (was 1..4).
  for i = 1, 9 do
    table.insert(config.keys, {
      key = tostring(i), mods = 'ALT', action = act.ActivateTab(i - 1),
    })
  end

  -- ALT+0 — jump back to the previously active tab. The keyboard complement
  -- to switch_to_last_active_tab_when_closing_tab above: "check something,
  -- jump back" without closing anything.
  table.insert(config.keys, { key = '0', mods = 'ALT', action = act.ActivateLastTab })

  -- Feedback for CTRL+SHIFT+R and silent auto-reloads on file save: a brief
  -- toast confirms the new config actually loaded (a Lua error surfaces
  -- WezTerm's own error window instead — so silence means it didn't apply).
  -- The first fire per window is (or may be) window creation, not a reload;
  -- swallow it so launching WezTerm doesn't toast. If live testing shows the
  -- event does NOT fire at creation, the cost is one swallowed toast on the
  -- first real reload per window — acceptable; re-check live and simplify if so.
  local config_reload_seen = {}
  wezterm.on('window-config-reloaded', function(window, _pane)
    local wid = window:window_id()
    if not config_reload_seen[wid] then
      config_reload_seen[wid] = true
      return
    end
    window:toast_notification('WezTerm', 'Config reloaded', nil, 1500)
  end)
end

return M
