-- =============================================================================
-- wsl.lua — WSL distro detection, local default domain/shell, distro pickers.
-- Exports: M.new_window_action (CTRL+SHIFT+N; distro-first picker when 2+)
-- =============================================================================

local wezterm = require 'wezterm'
local act     = wezterm.action

local M = {}

function M.apply(config)
  -- nu_prog — resolve Nushell for local Windows tabs. Prefer the bootstrap.ps1
  -- portable install (%LOCALAPPDATA%\workstation\nu\nu.exe), fall back to a bare
  -- 'nu' on PATH (winget/scoop installs). Belt-and-suspenders like config.font_dirs
  -- below: an absolute path survives the bootstrap User-PATH-propagation race, and
  -- WezTerm does NOT tilde-/PATH-expand a missing absolute path, so we only return
  -- the absolute form when the file actually exists.
  local function nu_prog()
    local lad = os.getenv('LOCALAPPDATA')
    if lad then
      local nu = lad .. '\\workstation\\nu\\nu.exe'
      local f = io.open(nu, 'r')
      if f then f:close(); return { nu } end
    end
    return { 'nu' }
  end

  -- Local-domain shell + default domain for Windows. Two ORTHOGONAL settings:
  --   * config.default_prog   — what the LOCAL ('local') domain spawns. Set
  --     UNCONDITIONALLY to Nushell below, so an explicitly-opened local tab is
  --     never cmd.exe/PowerShell, whatever the WSL distro count.
  --   * config.default_domain — which domain new tabs/windows use by default.
  --     Pointed at the sole WSL distro when exactly one exists (WSL-first new
  --     tabs); left as 'local' (→ Nushell) otherwise.
  -- Decision tree based on detected WSL distros (parsed from `wsl.exe -l -v`
  -- by wezterm.default_wsl_domains()):
  --   0 distros  → default_domain stays 'local' → launch + new tabs = Nushell.
  --   1 distro   → default_domain points at that distro; launch/new tabs land
  --                in WSL, but a local tab still falls back to Nushell.
  --   2+ distros → a one-shot picker fires on the first update-status tick (see
  --                gui-startup + update-status near the bottom); the placeholder
  --                local tab it spawns is Nushell via default_prog.
  -- PowerShell is intentionally NOT the default anymore (it stays installed for
  -- .NET/COM tasks + the WSL2 notify hook — see bootstrap.ps1). SSH-domain tabs
  -- still spawn `zellij attach --create main` via per-domain default_prog — this
  -- block only affects local (non-SSH) tabs.
  local wsl_doms = {}
  if wezterm.target_triple:find('windows') then
    wsl_doms = wezterm.default_wsl_domains()
    -- Force every WSL tab to start in the WSL user's home directory (~).
    -- Without this, wezterm inherits its own cwd — typically
    -- /mnt/c/Users/<windows-user> when launched from a Start-menu shortcut —
    -- and the bash default prompt renders \W as the literal Windows-user
    -- folder name instead of substituting ~. The override is per-domain so
    -- it survives wezterm.default_wsl_domains() re-evaluation on each load.
    for _, d in ipairs(wsl_doms) do
      d.default_cwd = '~'
    end
    config.wsl_domains = wsl_doms
    -- Local domain ALWAYS runs Nushell (orthogonal to default_domain below), so
    -- an explicitly-opened local tab is never cmd.exe/PowerShell. nu_prog()
    -- resolves the portable %LOCALAPPDATA%\workstation\nu\nu.exe, else bare 'nu'.
    config.default_prog = nu_prog()
    if #wsl_doms == 1 then
      -- Exactly one distro → make it the default for launch + new tabs. The
      -- local domain still falls back to Nushell via default_prog above.
      config.default_domain = wsl_doms[1].name
    end
    -- 0 distros → default_domain stays 'local' (Nushell via default_prog).
    -- 2+ distros → gui-startup spawns a Nushell placeholder + the WSL picker.
  end

  -- ---------------------------------------------------------------------------
  -- WSL distro picker — used by the gui-startup handler when 2+ distros exist
  -- ---------------------------------------------------------------------------
  -- InputSelector listing every distro from wezterm.default_wsl_domains(). The
  -- action spawns the chosen distro as a new tab and (if a placeholder tab id
  -- was captured by gui-startup) closes the placeholder so the window ends with
  -- exactly one tab.
  local function wsl_picker_choices()
    local choices = {}
    for _, d in ipairs(wezterm.default_wsl_domains()) do
      table.insert(choices, {
        label = d.distribution or d.name,
        id    = d.name,
      })
    end
    return choices
  end

  local function build_wsl_picker(placeholder_tab_id)
    return act.InputSelector {
      title    = 'Pick a WSL distro',
      fuzzy    = true,
      choices  = wsl_picker_choices(),
      action   = wezterm.action_callback(function(window, pane, id, _label)
        if not id then return end  -- Esc cancels; placeholder stays as fallback
        -- Spawn chosen distro first (becomes active — 2 tabs in window)
        window:perform_action(act.SpawnTab { DomainName = id }, pane)
        -- Then activate the placeholder and close it. CloseCurrentTab acts on
        -- the active tab, so we activate by id first.
        if placeholder_tab_id then
          for _, t in ipairs(window:mux_window():tabs()) do
            if t:tab_id() == placeholder_tab_id then
              t:activate()
              window:perform_action(act.CloseCurrentTab { confirm = false }, pane)
              break
            end
          end
        end
      end),
    }
  end

  -- CTRL+SHIFT+N — new window. gui-startup fires ONCE per GUI process, so the
  -- launch-time WSL picker (below) can't cover windows spawned later; a plain
  -- SpawnWindow on a 2+-distro machine landed in the default domain — local
  -- Nushell — instead of any distro (fixed 2026-07-16). With 2+ distros, pick
  -- the distro FIRST, then spawn the window into it. 0/1 distros keep plain
  -- SpawnWindow: default_domain already points at the sole distro (or local).
  local new_window_action = act.SpawnWindow
  if #wsl_doms >= 2 then
    new_window_action = act.InputSelector {
      title   = 'New window: pick a WSL distro',
      fuzzy   = true,
      choices = wsl_picker_choices(),
      action  = wezterm.action_callback(function(window, pane, id, _label)
        if not id then return end  -- Esc cancels: no window
        window:perform_action(
          act.SpawnCommandInNewWindow { domain = { DomainName = id } },
          pane
        )
      end),
    }
  end

  -- ---------------------------------------------------------------------------
  -- Multi-distro WSL picker (deferred to first update-status tick)
  -- ---------------------------------------------------------------------------
  -- The "show picker before first tab" UX requires bridging gui-startup (no GUI
  -- Window yet) and update-status (GUI Window exists, ~1s after launch). We
  -- spawn the placeholder local tab (Nushell, via default_prog) in gui-startup,
  -- stash its tab id keyed by mux window id, then fire the picker from
  -- update-status — once per window.
  -- The existing update-status handler at render_right_status is a separate
  -- registration; WezTerm composes multiple handlers per event without conflict.
  local wsl_picker_pending = {}

  wezterm.on('gui-startup', function(cmd)
    if not wezterm.target_triple:find('windows') then return end
    if #wsl_doms < 2 then return end  -- 0 or 1 handled by default_prog/default_domain

    local tab, _, mux_window = wezterm.mux.spawn_window(cmd or {})
    wsl_picker_pending[mux_window:window_id()] = tab:tab_id()
  end)

  wezterm.on('update-status', function(window, pane)
    local wid = window:window_id()
    local placeholder_tab_id = wsl_picker_pending[wid]
    if not placeholder_tab_id then return end
    wsl_picker_pending[wid] = nil  -- one-shot per window
    window:perform_action(build_wsl_picker(placeholder_tab_id), pane)
  end)

  M.new_window_action = new_window_action
end

return M
