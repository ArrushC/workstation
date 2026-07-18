-- =============================================================================
-- tabs.lua — tab bar: per-host tab colors, bell/output markers,
-- format-tab-title
-- =============================================================================

local wezterm = require 'wezterm'

local M = {}

function M.apply(config)
  local appearance  = require 'appearance'
  local domains     = require 'domains'
  local mocha       = appearance.mocha
  local host_accent = appearance.host_accent
  local ssh_domain_names = domains.ssh_domain_names
  local canonical_host   = domains.canonical_host
  local LOCAL_HOSTNAME   = domains.local_hostname

  -- Closing a tab returns to the LAST-ACTIVE tab instead of the adjacent one —
  -- with a row of host tabs open, "check something, close it" lands back on
  -- the tab you were actually working in.
  config.switch_to_last_active_tab_when_closing_tab = true

  -- Cap tab labels at 32 cells in both modes. Retro no longer stretches tabs
  -- to fill the bar (see format-tab-title below) so the cap only matters for
  -- truncating absurdly long renames; 32 is plenty for "<idx>: <hostname>"
  -- against any name in hosts.conf without leaving a trail of dead space.
  -- format-tab-title honours the resulting max_width itself via
  -- wezterm.truncate_right, so over-long titles trim gracefully instead of
  -- being hard-clipped by the renderer.
  config.tab_max_width               = 32

  -- Inactive tabs match the bar bg (mocha.base — see config.colors.tab_bar in appearance.lua)
  -- so the bar reads as one continuous strip with the active tab as the only
  -- visible tile. The host accent still shows in inactive text, just muted —
  -- enough to keep the visual guard against typing into the wrong host without
  -- adding a row of competing color blocks. Hover lifts a darkened accent
  -- block, active fills with full accent. Progression: nothing → muted → full.
  local function tab_colors(host, is_active, is_hover)
    local BAR_BG = mocha.base
    if host then
      local accent = wezterm.color.parse(host_accent(host))
      if is_active then
        return tostring(accent),                                mocha.crust
      elseif is_hover then
        return tostring(accent:desaturate(0.50):darken(0.50)),  mocha.text
      end
      return   BAR_BG,                                          tostring(accent:desaturate(0.40):darken(0.10))
    end
    -- Local tab — neutral inactive/hover surfaces, but the ACTIVE local tab
    -- fills with mauve (mocha.crust fg, mirroring the SSH active treatment at
    -- line 367) so local panes carry the same mauve identity as the cursor.
    -- Inactive/hover stay on neutral surfaces so the local row still reads as
    -- "local" at rest. Note: mauve is also bucket #2 of the per-host SSH
    -- rotation (HOST_ACCENTS), so a mauve-bucket host's active tab and a local
    -- active tab share the mauve fill — the tab title text still distinguishes
    -- them, and the SSH rotation is deliberately left untouched.
    if is_active then
      return mocha.mauve, mocha.crust
    elseif is_hover then
      return mocha.surface1, mocha.text
    end
    return BAR_BG, mocha.overlay0
  end

  -- Bell markers — pane_id → true when BEL rang in that pane. format-tab-title
  -- clears the mark when it renders the tab as ACTIVE, so the glyph survives
  -- exactly until the tab is next viewed. Deliberately NO toast here:
  -- ~/.claude/notify.sh already fires a BurntToast Windows toast + this same
  -- BEL for Claude Code notifications — a WezTerm toast would double-notify.
  -- The tab marker is the visual channel; notify.sh keeps toast + audio.
  --
  -- Marks live in wezterm.GLOBAL, not a module local: their lifetime is
  -- INDEFINITE (until the tab is viewed), and every config reload evaluates
  -- in a fresh Lua VM — a module-local table wiped all pending marks on any
  -- reload, which auto-fires exactly when a czu/cza sync or a config edit
  -- touches the tracked .lua files (the same VM-reset mechanism as the
  -- config-reloaded toast fix in keys.lua). tostring keys + reassign-after-
  -- mutate for serialization safety. Marks for long-dead panes linger for
  -- the process lifetime — a few bytes, accepted.
  wezterm.on('bell', function(_window, pane)
    local marks = wezterm.GLOBAL.bell_panes or {}
    marks[tostring(pane:pane_id())] = true
    wezterm.GLOBAL.bell_panes = marks
  end)

  -- Nerd Font glyphs (JetBrainsMono NF ships the md_/fa_ sets). Defensive
  -- fallbacks: a nil table key would crash string concat at render time.
  local nf = wezterm.nerdfonts or {}
  local GLYPH_BELL  = nf.md_bell    or '🔔'
  -- Domain-type glyphs for tab titles: what kind of thing the pane is talking
  -- to — an ssh session (domain tab OR embedded ssh detected in a WSL pane),
  -- a WSL distro shell, or the local Nushell.
  local GLYPH_SSH   = nf.md_ssh     or nf.fa_terminal or ''
  local GLYPH_WSL   = nf.fa_linux   or ''
  local GLYPH_LOCAL = nf.md_console or nf.fa_terminal or ''

  -- Activity marker for a tab — INACTIVE tabs only. '●' = unseen output since
  -- last viewed; bell glyph = BEL rang (Claude Code notify.sh, remote
  -- printf '\a', finished builds). Scans EVERY pane in the tab (tab.panes),
  -- not just the active one, so a bell/output in a background ALT+SHIFT+D/R
  -- split still marks the tab (was active-pane-only; fixed 2026-07-16).
  -- Rendering the tab as ACTIVE clears its panes' bell marks — the glyph
  -- survives exactly until the tab is next viewed. Bell outranks the dot (a
  -- bell also produces output). Known Zellij caveat: SSH+Zellij tabs redraw
  -- their UI, which can keep has_unseen_output permanently true — if live
  -- testing confirms, gate the DOT (never the bell) on non-SSH domains; see
  -- the spec's fallback plan.
  --
  -- Runs on every tab-bar redraw, so the wezterm.GLOBAL write-back happens
  -- ONLY when a mark was actually cleared (dirty) — never unconditionally
  -- per render. The GLYPH_BELL early return can't lose a write: dirty is
  -- only ever set in the is_active branch, and is_active is constant for
  -- the whole loop, so the early return is unreachable once dirty is true.
  local function activity_marker(tab)
    local marks  = wezterm.GLOBAL.bell_panes or {}
    local dirty  = false
    local unseen = false
    for _, p in ipairs(tab.panes or {}) do
      local key = tostring(p.pane_id)
      if tab.is_active then
        if marks[key] then
          marks[key] = nil
          dirty = true
        end
      elseif marks[key] then
        return GLYPH_BELL
      elseif p.has_unseen_output then
        unseen = true
      end
    end
    if dirty then wezterm.GLOBAL.bell_panes = marks end
    return unseen and '●' or nil
  end

  wezterm.on('format-tab-title', function(tab, all_tabs, panes, _config, hover, max_width)
    local pane   = tab.active_pane
    local domain = pane.domain_name or ''
    local is_wsl = domain:find('^WSL:') ~= nil

    local host = ssh_domain_names[domain] and domain or nil
    -- WSL: detect ssh sessions running INSIDE the pane, else fall back to the
    -- distro segment so the HOST_ACCENTS hash is deterministic across renders.
    --
    -- Detection: every chezmoi-managed host's rc emits OSC 7
    -- (file://<hostname><cwd>) on each prompt — see __wezterm_osc7 in
    -- dot_zshrc.tmpl / dot_bashrc.tmpl — so while an `ssh <managed-host>` is
    -- live inside a WSL pane, the pane's tracked cwd carries the REMOTE
    -- hostname. When that hostname is neither this machine (WSL shares the
    -- Windows computer name) nor the distro, the tab is colored + titled as
    -- the remote host, canonicalized via canonical_host so it lands in the
    -- same accent bucket as a real SSH-domain tab. Secondary signal: a
    -- shell-set "user@host" title (distro-default PROMPT_COMMANDs emit these
    -- even where OSC 7 isn't deployed). Self-reverting: after `exit`, the
    -- local shell's next prompt re-emits a local OSC 7 / local title.
    local wsl_remote_host
    if not host and is_wsl then
      local distro = domain:gsub('^WSL:', '')  -- e.g. "AlmaLinux-9"
      local detected
      local cwd = pane.current_working_dir
      if cwd then
        -- tostring() handles both the Url object (20240203+) and plain-string
        -- forms of current_working_dir.
        detected = tostring(cwd):match('^file://([^/]+)/')
      end
      if not detected then
        detected = (pane.title or ''):match('^[%w%._%-]+@([%w%._%-]+)')
      end
      if detected then
        local short = (detected:match('^([^%.]+)') or detected):lower()
        if detected:lower() ~= LOCAL_HOSTNAME
          and short ~= LOCAL_HOSTNAME
          and short ~= distro:lower() then
          wsl_remote_host = canonical_host(detected)
        end
      end
      host = wsl_remote_host or distro
    end
    -- Fallback: if not a WezTerm SSH-domain tab and not WSL, but the shell-set
    -- title is in "user@host[:cwd]" form (typical for manual `ssh <host>` from
    -- a local tab), extract the host so the tab still picks up the per-host
    -- accent (canonicalized into the domain's bucket when it's a managed host).
    if not host then
      local detected = (pane.title or ''):match('^[%w%._%-]+@([%w%._%-]+)')
      if detected and #detected > 0 then host = canonical_host(detected) end
    end

    -- Heuristic: a tab_title in "user@host[:cwd]" form was almost certainly set
    -- by the shell's PROMPT_COMMAND via OSC. Anything else (plain words, paths
    -- without @) is treated as a deliberate user rename via CTRL+SHIFT+E and
    -- preserved. We need this because WezTerm exposes a single tab_title field
    -- — shell-set and user-set are indistinguishable at the API level.
    local function looks_shell_set(t)
      return t and t:match('^[%w%._%-]+@[%w%._%-]+') ~= nil
    end

    local title = tab.tab_title
    if is_wsl then
      -- Show "WSL:<distro>" — or the remote host name while an embedded ssh
      -- session is live (wsl_remote_host above) — unless the user has renamed
      -- the tab. Without this branch the title flickered between the domain
      -- (first render, tab_title empty) and the shell-set "user@<distro>:<cwd>"
      -- (later renders, after PROMPT_COMMAND fired).
      if title == nil or #title == 0 or looks_shell_set(title) then
        title = wsl_remote_host or domain
      end
    elseif title == nil or #title == 0 then
      if host then
        title = host
      else
        -- Two cleanups, both no-ops when not applicable:
        --   1. Strip leading "user@" from SSH'd shell titles (PROMPT_COMMAND
        --      OSC escapes, e.g. "user@host:~"). The host + cwd are the useful
        --      bits; the username is implied by being logged in.
        --   2. Reduce a bare Windows .exe path to its basename, since cmd /
        --      powershell tabs come in titled with the full path
        --      (e.g. "C:\WINDOWS\system32\cmd.exe" → "cmd").
        title = (pane.title or '')
          :gsub('^[%w%._%-]+@', '')
          :gsub('^.*[\\/]([^\\/]+)%.[Ee][Xx][Ee]$', '%1')
      end
    end

    -- Re-derive position from the live tabs array — tab.tab_index reflects the
    -- pre-close ordering after CloseCurrentTab and only refreshes on the next
    -- tab-switch. Walking all_tabs gives the true current position so the
    -- numbers in the bar reshuffle immediately on close.
    local idx = tab.tab_index + 1
    if all_tabs then
      for i, t in ipairs(all_tabs) do
        if t.tab_id == tab.tab_id then idx = i; break end
      end
    end
    -- Activity marker — bell / unseen-output glyph across ALL of this tab's
    -- panes; see activity_marker above.
    local marker = activity_marker(tab)

    -- ConEmu OSC 9;4 progress (nightly exposes it as a plain PaneInformation
    -- field — nil-safe on any build). Rendered in the marker slot for ANY tab
    -- including the active one (a running command's progress is exactly what
    -- you want to see). Priority: bell > progress > unseen dot — progress
    -- supersedes "something happened" with "something is happening". Emitters
    -- today are mostly Windows-side (winget et al.); inert through Zellij.
    local marker_fg
    if marker ~= GLYPH_BELL then
      local progress = tab.active_pane.progress or 'None'
      if progress ~= 'None' then
        if type(progress) == 'table' and progress.Percentage ~= nil then
          marker    = string.format('%d%%', progress.Percentage)
          marker_fg = mocha.green
        elseif type(progress) == 'table' and progress.Error ~= nil then
          marker    = string.format('%d%%', progress.Error)
          marker_fg = mocha.red
        elseif progress == 'Indeterminate' then
          marker    = '~'
          marker_fg = mocha.peach
        end
      end
    end

    -- Domain-type glyph: ssh (incl. embedded ssh inside a WSL pane — the
    -- wsl_remote_host detection above), WSL distro shell, or local.
    local glyph
    if is_wsl then
      glyph = wsl_remote_host and GLYPH_SSH or GLYPH_WSL
    elseif host then
      glyph = GLYPH_SSH
    else
      glyph = GLYPH_LOCAL
    end
    -- Honour max_width: truncate the title so the whole cell (leading
    -- marker/space + glyph/index prefix + title + trailing space) fits the
    -- width WezTerm actually grants this tab (tab_max_width-capped; the
    -- handler runs a second time with the real constrained width when the
    -- bar is full). Without this, long manual renames / shell titles were
    -- hard-clipped by the renderer, eating the trailing space (fixed
    -- 2026-07-16). truncate_right keeps the head — the informative end of
    -- "<idx>: <hostname>" labels.
    local prefix  = string.format('%s %d: ', glyph, idx)
    local leading = marker and (' ' .. marker .. ' ') or ' '
    local suffix  = ' '
    local available = math.max(1,
      max_width
        - wezterm.column_width(leading)
        - wezterm.column_width(prefix)
        - wezterm.column_width(suffix))
    local label = prefix .. wezterm.truncate_right(title, available) .. suffix

    -- No stretch-to-fill padding here. Tabs stay compact, left-aligned, with
    -- the right status (battery · time) anchored at the far right and bare
    -- bar bg between them. That gap is the minimal-retro signature — it's
    -- how tmux/screen status lines have looked since forever and it gives
    -- the battery + time modules visual breathing room.

    -- Every tab (host or local) gets explicit bg/fg from tab_colors so active,
    -- hover, and inactive states are visually distinct. Active also gets bold.
    local bg, fg = tab_colors(host, tab.is_active, hover)
    local items = { { Background = { Color = bg } } }
    -- Leading space + optional marker; the marker carries its own fg (host
    -- accent for the dot, peach for the bell, green/red for progress) against
    -- the tab bg.
    if marker then
      local mfg = marker_fg
        or ((marker == GLYPH_BELL) and mocha.peach or host_accent(host))
      table.insert(items, { Foreground = { Color = mfg } })
    end
    table.insert(items, { Text = leading })
    table.insert(items, { Foreground = { Color = fg } })
    if tab.is_active then
      table.insert(items, { Attribute = { Intensity = 'Bold' } })
    end
    -- Alt+0 target — underline the previously-active tab (is_last_active is
    -- a nightly PaneInformation-style field; nil-safe read elsewhere). The
    -- quietest possible marker: no glyph, no color, just an underline on the
    -- one tab ALT+0 would jump to.
    if not tab.is_active and tab.is_last_active then
      table.insert(items, { Attribute = { Underline = 'Single' } })
    end
    table.insert(items, { Text = label })
    return items
  end)
end

return M
