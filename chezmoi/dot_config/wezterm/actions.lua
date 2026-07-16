-- =============================================================================
-- actions.lua — bespoke actions and overlays: host picker, SSH reconnect,
-- smart new-tab (+ "+"-button), open-uri routing, tab switcher, help,
-- copy helpers, scrollback→Helix, QuickSelect bindings, pane management,
-- command-palette mirror. Exports every action value keys.lua binds.
-- =============================================================================

local wezterm = require 'wezterm'
local act     = wezterm.action

local M = {}

function M.apply(config)
  local ssh_domains      = require 'hosts'
  local ssh_domain_names = (require 'domains').ssh_domain_names

  -- Extra quick-select atoms (CTRL+SHIFT+Space) — APPENDED to the built-in
  -- URL/path/hash patterns, not replacing them: IPv4 addresses (the
  -- 10.21.x.x host fleet) and #NN PR/issue refs.
  config.quick_select_patterns = {
    [[\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b]],
    [[#\d+]],
  }

  -- Hyperlink rules — the built-in defaults (URLs, mailto:, file://) plus one
  -- custom rule: bare #NN issue/PR refs link into the workstation repo
  -- (GitHub auto-redirects /issues/NN → /pull/NN when NN is a PR). \B# keeps
  -- word#12 unlinked; the trailing \b can't fire inside hex colors (#1e1e2e:
  -- \d+ eats "1" but hits "e" — a word char — so there's no boundary and no
  -- match). Deliberately NO bare owner/repo rule: in path-heavy output every
  -- makefile/versions.mk would light up as a GitHub link. Open with
  -- SHIFT+click (works in Zellij panes too) or CTRL+click (plain panes).
  config.hyperlink_rules = wezterm.default_hyperlink_rules()
  table.insert(config.hyperlink_rules, {
    regex  = [[\B#(\d+)\b]],
    format = 'https://github.com/ArrushC/workstation/issues/$1',
  })

  -- Switching panes while one is zoomed un-zooms instead of silently swapping
  -- the zoomed content — pairs with the CTRL+SHIFT+Z zoom toggle.
  config.unzoom_on_switch_pane = true

  -- ---------------------------------------------------------------------------
  -- Host quick-picker — fuzzy-find a host and open a tab into it
  -- ---------------------------------------------------------------------------
  -- Bound to CTRL|SHIFT+J below (J = jump). Choices are derived from
  -- ssh_domains, so every host added via manage-hosts.{sh,ps1} --add becomes
  -- pickable after the next sync + config reload.
  local function host_picker_choices()
    local choices = {}
    for _, domain in ipairs(ssh_domains) do
      table.insert(choices, {
        label = string.format('%s  (%s@%s)', domain.name, domain.username, domain.remote_address),
        id    = domain.name,
      })
    end
    return choices
  end

  local pick_host = act.InputSelector {
    title    = 'Connect to host',
    fuzzy    = true,
    choices  = host_picker_choices(),
    action   = wezterm.action_callback(function(window, pane, id, _label)
      if not id then return end
      window:perform_action(act.SpawnTab { DomainName = id }, pane)
    end),
  }

  -- ---------------------------------------------------------------------------
  -- SSH pane reconnect — recovery half of the broken-pipe self-healing
  -- ---------------------------------------------------------------------------
  -- Bound to CTRL|SHIFT+F5 below. When an SSH connection dies (broken pipe,
  -- NAT drop, server-alive timeout), the pane goes zombie. One keystroke
  -- spawns a fresh tab against the same domain; Zellij's attach --create
  -- (in default_prog) reattaches the existing remote session, so the user
  -- lands back where they were. Prevention half lives in ~/.ssh/config
  -- (ServerAliveInterval=30, ServerAliveCountMax=3) — chezmoi source at
  -- private_dot_ssh/private_config.
  --
  -- The dead tab is intentionally left open: its scrollback is useful for
  -- diagnosing the disconnect. Close it with CTRL+SHIFT+W when done.
  --
  -- Gated on ssh_domain_names (the lookup domains.lua builds alongside its
  -- default_prog loop), NOT merely "non-local": a bare non-local check also passes WSL
  -- domains, so pressing CTRL+SHIFT+F5 inside a WSL pane opened a second WSL
  -- tab and called it a reconnect (fixed 2026-07-16).
  local reconnect_ssh_pane = wezterm.action_callback(function(window, pane)
    local domain = pane:get_domain_name() or ''
    if not ssh_domain_names[domain] then
      window:toast_notification('WezTerm',
        'Current pane is not a configured SSH domain — nothing to reconnect', nil, 3000)
      return
    end
    window:perform_action(act.SpawnTab { DomainName = domain }, pane)
  end)

  -- ---------------------------------------------------------------------------
  -- Smart new-tab — honors WSL default_cwd when cwd isn't otherwise tracked
  -- ---------------------------------------------------------------------------
  -- Bound to CTRL|SHIFT+T below. The naive `act.SpawnTab 'CurrentPaneDomain'`
  -- inherits the current pane's cwd if known, otherwise falls back to
  -- wezterm's own cwd (typically /mnt/c/Users/<windows-user> on Windows
  -- launches) — which means our `default_cwd = '~'` on WSL domains gets
  -- ignored for every tab after the first.
  --
  -- Fix: for WSL panes that don't have a tracked cwd (no OSC 7 from the
  -- shell), do a "fresh" SpawnTab into the SAME named domain — wezterm
  -- then uses the domain's default_cwd='~', passes that LITERAL '~' to
  -- wsl.exe via --cd, and wsl.exe expands it inside the distro to
  -- /home/<wsluser>. This mirrors the pick_host pattern further up.
  --
  -- DO NOT replace this with `act.SpawnCommandInNewTab { cwd = '~' }`:
  -- wezterm tilde-expands cwd ON THE WINDOWS HOST SIDE before passing
  -- to wsl.exe, so `cwd = '~'` becomes `C:\Users\<windows-user>`, which
  -- wsl.exe then interprets as `/mnt/c/Users/<windows-user>`. Same
  -- basename as the WSL home, so it looks superficially right but lands
  -- you in the Windows-mounted-into-WSL path instead of $HOME — which
  -- is exactly the bug this callback exists to fix.
  --
  -- For WSL panes that DO have a tracked cwd (chezmoi-applied bashrc
  -- emits OSC 7 — see __wezterm_osc7 in dot_bashrc.tmpl), defer to the
  -- default inheritance so `cd /tmp` then CTRL+SHIFT+T lands in /tmp.
  -- For non-WSL panes (local PowerShell, SSH), the default action
  -- already does the right thing — Zellij owns SSH session state
  -- regardless of cwd.
  local smart_new_tab = wezterm.action_callback(function(window, pane)
    local domain = pane:get_domain_name() or ''
    if domain:find('^WSL:') and not pane:get_current_working_dir() then
      window:perform_action(act.SpawnTab { DomainName = domain }, pane)
    else
      window:perform_action(act.SpawnTab 'CurrentPaneDomain', pane)
    end
  end)

  -- The tab bar's "+" button follows the keyboard bindings instead of the
  -- built-in default (which spawns into the default domain, skipping
  -- smart_new_tab's WSL cwd handling — the same operation behaved differently
  -- by mouse vs CTRL+SHIFT+T; fixed 2026-07-16). Left = smart_new_tab,
  -- Middle = host picker (CTRL+SHIFT+J's pick_host), Right returns nothing so
  -- the built-in launcher menu is preserved.
  wezterm.on('new-tab-button-click', function(window, pane, button, _default_action)
    if button == 'Left' then
      window:perform_action(smart_new_tab, pane)
      return false
    end
    if button == 'Middle' then
      window:perform_action(pick_host, pane)
      return false
    end
    -- Right: keep the default launcher.
  end)

  -- ---------------------------------------------------------------------------
  -- Hyperlink clicks — route OSC 8 file:// URIs into helix in a new tab
  -- ---------------------------------------------------------------------------
  -- Triggered by clicks on OSC 8 hyperlinks emitted by `eza --hyperlink`
  -- (the l/la/ll/lt/lta/ltl aliases) and anything else that produces file://
  -- URIs. Routing depends on the SOURCE pane's domain:
  --   • SSH pane    → SpawnCommandInNewTab on the SAME ssh_domain with
  --                   `hx <path>` as args. The args override the per-domain
  --                   default_prog (zellij_attach_cmd) — the editor is a
  --                   one-shot, not a long-running session that needs Zellij's
  --                   crash-recovery wrap. The path is already a remote path
  --                   (eza ran on the remote host), so it resolves correctly
  --                   on the reconnected SSH side.
  --   • WSL pane    → SpawnCommandInNewTab on the SAME wsl_domain with
  --                   `hx <path>` args. wsl.exe runs the command inside the
  --                   distro, so the Linux path is interpreted correctly.
  --   • Local pane  → defer to OS default. On Windows that's `start <uri>`,
  --                   which opens with the file extension's default app.
  --                   helix isn't always on local Windows PATH, so leaving
  --                   this branch alone avoids spawning a broken tab.
  -- Non-file:// URIs (https://, mailto:, etc.) always defer to the default.
  -- Returning false suppresses the default; returning nil/nothing keeps it.
  --
  -- Parsed with wezterm.url.parse, NOT string surgery: OSC 8 file:// URIs
  -- percent-encode spaces/Unicode/#/% (eza emits `some%20file.c`), and a
  -- gsub-stripped URI passed the encoded form to hx verbatim (fixed
  -- 2026-07-16). Url.file_path both drops the emitting host's name and
  -- percent-decodes the path (per the wezterm.url docs example:
  -- 'file://myhost/some/path%20with%20spaces' → '/some/path with spaces').
  -- pcall guards against malformed URIs from misbehaving programs.
  wezterm.on('open-uri', function(window, pane, uri)
    local ok, parsed = pcall(wezterm.url.parse, uri)
    if not ok or parsed.scheme ~= 'file' then return end
    local domain = pane:get_domain_name() or ''
    if domain == '' or domain == 'local' then return end
    window:perform_action(
      act.SpawnCommandInNewTab {
        domain = { DomainName = domain },
        args   = { 'hx', parsed.file_path },
      },
      pane
    )
    return false
  end)

  -- ---------------------------------------------------------------------------
  -- Tab switcher — fuzzy list with explicit tab index + domain
  -- ---------------------------------------------------------------------------
  -- The built-in ShowLauncher renumbers entries after fuzzy filtering, so the
  -- "1, 2, 3..." jump keys aren't the same as the actual tab positions. This
  -- custom InputSelector keeps the real tab index in the label, so the order
  -- you type matches the order in the tab bar.
  local pick_tab = wezterm.action_callback(function(window, pane)
    local active_id = window:active_tab():tab_id()
    local choices = {}
    for i, tab in ipairs(window:mux_window():tabs()) do
      local active = tab:active_pane()
      local title  = (active:get_title() or ''):gsub('^%s+', ''):gsub('%s+$', '')
      local domain = active:get_domain_name() or ''
      local marker = (tab:tab_id() == active_id) and '● ' or '  '
      local label
      if domain ~= '' and domain ~= 'local' then
        label = string.format('%s%d. %s  [%s]', marker, i, title, domain)
      else
        label = string.format('%s%d. %s', marker, i, title)
      end
      table.insert(choices, { label = label, id = tostring(tab:tab_id()) })
    end

    window:perform_action(act.InputSelector {
      title   = 'Switch tab',
      fuzzy   = true,
      choices = choices,
      action  = wezterm.action_callback(function(inner_win, _inner_pane, id, _label)
        if not id then return end
        local target = tonumber(id)
        for _, t in ipairs(inner_win:mux_window():tabs()) do
          if t:tab_id() == target then
            t:activate()
            return
          end
        end
      end),
    }, pane)
  end)

  -- ---------------------------------------------------------------------------
  -- Help / cheatsheet — fuzzy-searchable list of keybinds + aliases + hosts
  -- ---------------------------------------------------------------------------
  -- Bound to CTRL|SHIFT+H. Keybind / alias / function rows are informational
  -- (no-op on selection); host rows actually launch the host in a new tab so
  -- the help doubles as a launcher. Esc dismisses.
  --
  -- Bash aliases and functions are only active inside SSH'd host tabs (defined
  -- in chezmoi/home/dot_bashrc.tmpl). Keep this in sync with that file when
  -- adding/renaming aliases — there's no runtime introspection across SSH.
  local function help_choices()
    local rows = {
      -- Wezterm: tabs
      { label = 'key   CTRL+SHIFT+T     New local tab',                       id = '' },
      { label = 'key   CTRL+SHIFT+W     Close current tab (no confirm)',      id = '' },
      { label = 'key   CTRL+SHIFT+E     Rename current tab',                  id = '' },
      { label = 'key   CTRL+TAB         Next tab',                            id = '' },
      { label = 'key   CTRL+SHIFT+TAB   Previous tab',                        id = '' },
      { label = 'key   ALT+1..9         Jump directly to tab 1-9',            id = '' },
      { label = 'key   ALT+0            Return to previously active tab',     id = '' },
      { label = 'key   CTRL+SHIFT+S     Tab switcher (fuzzy list)',           id = '' },
      { label = 'note  + button         Left: new tab · middle: host picker · right: launcher', id = '' },
      -- Wezterm: window
      { label = 'key   CTRL+SHIFT+N     New window (WSL distro picker if 2+ distros)', id = '' },
      { label = 'key   CTRL+SHIFT+drag  Move window (no title bar to grab)',  id = '' },
      { label = 'key   WIN+drag         Move window (same as CTRL+SHIFT+drag)', id = '' },
      { label = 'key   F11              Toggle fullscreen',                   id = '' },
      -- Wezterm: hosts
      { label = 'key   CTRL+SHIFT+J     Open SSH host picker',                id = '' },
      { label = 'key   CTRL+SHIFT+F5    Reconnect current SSH pane (new tab, Zellij reattaches)', id = '' },
      { label = 'key   CTRL+SHIFT+H     Show this help',                      id = '' },
      -- Wezterm: WSL
      { label = 'note  WSL on launch    Picker shows if 2+ WSL distros installed', id = '' },
      -- Wezterm: editing
      { label = 'key   CTRL+SHIFT+C     Copy selection',                      id = '' },
      { label = 'key   CTRL+SHIFT+V     Paste from clipboard',                id = '' },
      { label = 'key   CTRL+SHIFT+A     Copy entire scrollback to clipboard', id = '' },
      { label = 'key   CTRL+SHIFT+O     Open scrollback in Helix (local/WSL tabs)', id = '' },
      { label = 'key   CTRL+SHIFT+↑/↓   Jump to previous/next prompt (WSL/local tabs)', id = '' },
      { label = 'key   CTRL+3×click     Select a command\'s whole output + copy (WSL/local tabs)', id = '' },
      { label = 'key   SHIFT+click      Open link under mouse (the one modifier that works inside Zellij/Helix panes)', id = '' },
      { label = 'note  #NN refs         Clickable → github.com/ArrushC/workstation PR/issue', id = '' },
      { label = 'note  tab markers      ● unseen output · 󰂞 bell rang (background tabs; clear on view)', id = '' },
      { label = 'note  footer ↕        Active tab line count: total · rows on screen (cursor line when a program moves it; hidden in full-screen apps)', id = '' },
      -- Built-in WezTerm defaults (not bound in config.keys) surfaced here
      -- for discoverability:
      { label = 'key   CTRL+SHIFT+F     Search scrollback',                   id = '' },
      { label = 'key   CTRL+SHIFT+Space Quick-select URLs/paths/hashes/IPs/#refs', id = '' },
      { label = 'key   CTRL+SHIFT+I     Quick-select an IP → open SSH to it', id = '' },
      { label = 'key   CTRL+SHIFT+G     Quick-select file:line → open in Helix', id = '' },
      { label = 'key   CTRL+SHIFT+Y     Quick-select a git SHA → paste into prompt', id = '' },
      -- Wezterm: panes (local/WSL tabs; Zellij owns panes inside SSH tabs)
      { label = 'key   ALT+SHIFT+D/R    Split pane down / right (local/WSL tabs)', id = '' },
      { label = 'key   ALT+SHIFT+arrows Move between panes', id = '' },
      { label = 'key   CTRL+SHIFT+Z     Toggle pane zoom', id = '' },
      { label = 'key   CTRL+SHIFT+Q     Pane picker (letter overlay)', id = '' },
      { label = 'note  CTRL+SHIFT+←/→   Reaches the shell now — zsh word-extend selection works', id = '' },
      { label = 'note  drag & drop      Dropping a file pastes its quoted path', id = '' },
      { label = 'note  images           yazi/imgcat previews render inline (not through Zellij)', id = '' },
      { label = 'key   CTRL+SHIFT+U     Character/emoji picker',              id = '' },
      { label = 'key   CTRL+SHIFT+L     Debug overlay (Lua REPL + logs)',     id = '' },
      { label = 'key   CTRL+SHIFT+P     Command palette',                     id = '' },
      -- Wezterm: font
      { label = 'key   CTRL+=           Increase font size',                  id = '' },
      { label = 'key   CTRL+-           Decrease font size',                  id = '' },
      { label = 'key   CTRL+0           Reset font size',                     id = '' },
      -- Wezterm: config
      { label = 'key   CTRL+SHIFT+R     Reload wezterm config',               id = '' },

      -- Bash aliases (host tabs only) — git
      { label = 'alias gs               git status',                          id = '' },
      { label = 'alias ga               git add',                             id = '' },
      { label = 'alias gc               git commit',                          id = '' },
      { label = 'alias gp               git push',                            id = '' },
      { label = 'alias gl               git log --oneline --graph --decorate', id = '' },
      { label = 'alias gd               git diff',                            id = '' },
      { label = 'alias gco              git checkout',                        id = '' },
      { label = 'alias gbr              git branch',                          id = '' },
      -- Bash aliases — chezmoi
      { label = 'alias cz               chezmoi',                             id = '' },
      { label = 'alias cza              chezmoi apply',                       id = '' },
      { label = 'alias cze              chezmoi edit',                        id = '' },
      { label = 'alias czd              chezmoi diff',                        id = '' },
      { label = 'alias czu              chezmoi update',                      id = '' },
      { label = 'alias czs              chezmoi status',                      id = '' },
      -- Bash aliases — navigation
      { label = "alias ..               cd ..",                               id = '' },
      { label = "alias ...              cd ../..",                            id = '' },
      { label = 'alias l                eza listing (dirs first, icons)',                            id = '' },
      { label = 'alias la               eza -a (+hidden, dirs first, icons)',                        id = '' },
      { label = 'alias ll               eza -lah --git --time-style=long-iso (long + clickable paths)', id = '' },
      { label = 'alias lt               eza --tree --level=2 (depth-2 peek)',                        id = '' },
      { label = 'alias lta              eza --tree --level=2 -a --git-ignore (+hidden, skip ignored)', id = '' },
      { label = 'alias ltl              eza --tree --level=2 -lh --git (tree + long + clickable)',   id = '' },
      { label = 'note  hyperlinks       Click a file:// in ll/ltl → opens in hx in a new tab (same domain)', id = '' },
      -- Bash aliases — tools
      { label = 'alias notes            nb',                                  id = '' },
      { label = 'alias preview          glow',                                id = '' },
      { label = 'alias zj               zellij',                              id = '' },
      { label = 'alias zjl              zellij list-sessions',                id = '' },
      { label = 'alias zja              zellij attach',                       id = '' },

      -- Bash functions (host tabs only)
      { label = 'fn    clear            clear screen AND scrollback (full reset; footer count resets)', id = '' },
      { label = 'fn    hide             soft clear — keeps scrollback so history survives (scroll up)', id = '' },
      { label = 'fn    fh               fzf history search (Ctrl+R enhanced)', id = '' },
      { label = 'fn    fcd [dir]        fzf cd into any subdirectory',        id = '' },
      { label = 'fn    fssh             fzf ssh — pick from ~/.ssh/config',   id = '' },
      { label = 'fn    zs [name]        zellij attach --create (default: main)', id = '' },
      { label = 'fn    n [text]         nb add (or list when no args)',       id = '' },
      { label = 'fn    nf               fzf-pick a note in $NB_DIR + glow it', id = '' },

      -- zoxide built-ins
      { label = 'cmd   z <pat>          zoxide jump to a known dir',          id = '' },
      { label = 'cmd   zi               zoxide interactive fuzzy jump',       id = '' },
    }
    for _, d in ipairs(ssh_domains) do
      table.insert(rows, {
        label = string.format('host  %-20s %s@%s', d.name, d.username, d.remote_address),
        id    = 'host:' .. d.name,
      })
    end
    return rows
  end

  local show_help = act.InputSelector {
    title    = 'Wezterm shortcuts (Esc to dismiss; pick a host to launch it)',
    fuzzy    = true,
    choices  = help_choices(),
    action   = wezterm.action_callback(function(window, pane, id, _label)
      if not id or id == '' then return end
      local host = id:match('^host:(.+)$')
      if host then
        window:perform_action(act.SpawnTab { DomainName = host }, pane)
      end
    end),
  }

  -- Selection-aware copy: writes to clipboard ONLY if there's a non-empty
  -- selection, then fires the badge. Used for every keyboard + mouse copy path
  -- so the badge can't appear on a click with no selection or an empty Ctrl-C.
  -- For scrollback-all (CTRL+SHIFT+A) we skip this helper since the action chain
  -- explicitly creates a selection — we already know there's content to copy.
  -- The badge itself is status.lua's job: emitting 'copied' runs its handler
  -- immediately (the same path copy_all_scrollback below already uses), so
  -- the badge still appears without waiting for the ~1s status tick.
  local copy_and_announce = wezterm.action_callback(function(window, pane)
    local sel = window:get_selection_text_for_pane(pane)
    if not sel or #sel == 0 then return end
    window:perform_action(act.CopyTo 'Clipboard', pane)
    window:perform_action(act.EmitEvent 'copied', pane)
  end)

  -- ---------------------------------------------------------------------------
  -- Scrollback → Helix — dump the pane's scrollback to a temp file, open in hx
  -- ---------------------------------------------------------------------------
  -- Bound to CTRL|SHIFT+O below (O = open); also in the command palette.
  -- Complements CTRL+SHIFT+A (copy to clipboard): same text, but landed in an
  -- editor with search/jump instead. Routing mirrors the open-uri handler:
  --   • local pane → hx.exe (on the User PATH via the portable Helix install)
  --     opening the Windows temp path.
  --   • WSL pane   → hx inside the SAME distro, opening the /mnt/c translation
  --     of that temp path (Lua io runs on the Windows side, so the file is
  --     written under %TEMP% either way).
  --   • SSH pane   → toast and bail: WezTerm's buffer for an SSH+Zellij tab is
  --     just the alt screen; Zellij owns the real scrollback there.
  -- Per-pane filename, overwritten on reuse; cleanup is OS temp policy's job.
  local scrollback_to_helix = wezterm.action_callback(function(window, pane)
    local domain = pane:get_domain_name() or ''
    local is_wsl = domain:find('^WSL:') ~= nil
    if domain ~= 'local' and not is_wsl then
      window:toast_notification('WezTerm',
        'Zellij owns scrollback in SSH tabs — use its search there', nil, 4000)
      return
    end
    local dims   = pane:get_dimensions()
    local nlines = (dims and dims.scrollback_rows) or 10000
    local text   = pane:get_lines_as_text(nlines)
    local tmp    = (os.getenv('TEMP') or os.getenv('TMP') or '.')
      .. '\\wezterm-scrollback-' .. pane:pane_id() .. '.txt'
    local f, err = io.open(tmp, 'w')
    if not f then
      window:toast_notification('WezTerm',
        'Scrollback dump failed: ' .. tostring(err), nil, 4000)
      return
    end
    f:write(text)
    f:close()
    local path = tmp
    if is_wsl then
      -- C:\Users\me\...\x.txt → /mnt/c/Users/me/.../x.txt
      path = tmp:gsub('\\', '/'):gsub('^(%a):', function(drive)
        return '/mnt/' .. drive:lower()
      end)
    end
    window:perform_action(
      act.SpawnCommandInNewTab {
        domain = { DomainName = domain },
        args   = { 'hx', path },
      },
      pane
    )
  end)

  -- Rename current tab — extracted to a named value so the CTRL+SHIFT+E
  -- keybind and the command-palette entry share one definition.
  local rename_tab = act.PromptInputLine {
    description = 'New tab title (empty = reset):',
    action = wezterm.action_callback(function(window, _pane, line)
      if line == nil then return end  -- Esc cancels
      window:active_tab():set_title(line)
    end),
  }

  -- Copy entire scrollback — extracted for the same keybind/palette sharing.
  local copy_all_scrollback = act.Multiple {
    act.ActivateCopyMode,
    act.CopyMode 'MoveToScrollbackTop',
    act.CopyMode { SetSelectionMode = 'Cell' },
    act.CopyMode 'MoveToScrollbackBottom',
    act.CopyTo 'Clipboard',
    act.CopyMode 'Close',
    act.EmitEvent 'copied',
  }

  -- ---------------------------------------------------------------------------
  -- QuickSelect action bindings — Enter DOES something with the selection
  -- ---------------------------------------------------------------------------
  -- Pattern-restricted QuickSelect overlays whose action consumes the selection
  -- instead of just copying it (the plain CTRL+SHIFT+Space overlay keeps its
  -- copy behavior). Each `label` names the action in the overlay footer.
  -- Extracted to locals so config.keys and the command palette share one
  -- definition (rename_tab precedent).

  -- CTRL+SHIFT+I — pick an IPv4 from the screen, open SSH to it. A managed
  -- host (remote_address match in ssh_domains) opens as its domain tab, so
  -- Zellij attaches via the per-domain default_prog; any other IP gets a plain
  -- `ssh <ip>` in the CURRENT pane's domain (WSL/local both carry an ssh
  -- client; from an SSH pane it chains a hop from that host).
  local quick_ssh_ip = act.QuickSelectArgs {
    label    = 'open SSH to IP',
    patterns = { [[\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b]] },
    action   = wezterm.action_callback(function(window, pane)
      local ip = window:get_selection_text_for_pane(pane)
      if not ip or #ip == 0 then return end
      for _, d in ipairs(ssh_domains) do
        if d.remote_address == ip then
          window:perform_action(act.SpawnTab { DomainName = d.name }, pane)
          return
        end
      end
      window:perform_action(act.SpawnCommandInNewTab {
        domain = 'CurrentPaneDomain',
        args   = { 'ssh', ip },
      }, pane)
    end),
  }

  -- CTRL+SHIFT+G — pick a file:line[:col] (compiler error, grep -n, stack
  -- trace) and open it in Helix at that position (hx accepts file:line:col
  -- directly). Same-domain spawn mirrors the open-uri handler: WSL → hx in
  -- the distro, SSH → one-shot hx tab on that host, local → portable hx.exe.
  -- Relative paths resolve because SpawnCommandInNewTab inherits the pane's
  -- OSC 7-tracked cwd.
  local quick_open_hx = act.QuickSelectArgs {
    label    = 'open in Helix',
    patterns = { [[[\w./~_-]+:\d+(?::\d+)?]] },
    action   = wezterm.action_callback(function(window, pane)
      local sel = window:get_selection_text_for_pane(pane)
      if not sel or #sel == 0 then return end
      window:perform_action(act.SpawnCommandInNewTab {
        domain = 'CurrentPaneDomain',
        args   = { 'hx', sel },
      }, pane)
    end),
  }

  -- CTRL+SHIFT+Y — pick a git SHA (7–40 hex chars) and type it into the
  -- prompt: no clipboard round-trip for `git show <pick>` flows. All-digit
  -- runs of 7+ (ports, sizes) match too — visual noise in the overlay, not a
  -- correctness issue (you pick the label you want).
  local quick_yank_sha = act.QuickSelectArgs {
    label    = 'paste into prompt',
    patterns = { [[\b[0-9a-f]{7,40}\b]] },
    action   = wezterm.action_callback(function(window, pane)
      local sel = window:get_selection_text_for_pane(pane)
      if not sel or #sel == 0 then return end
      pane:send_text(sel)
    end),
  }

  -- ---------------------------------------------------------------------------
  -- Local pane management — splits, nav, zoom, picker
  -- ---------------------------------------------------------------------------
  -- Zellij owns panes inside SSH tabs; these cover local/WSL tabs, which
  -- previously had no ergonomic pane story at all. Split mnemonics match
  -- Zellij's pane mode (d = down, r = right) so muscle memory transfers;
  -- pane NAV lives on the same ALT+SHIFT layer (arrows).
  local split_down  = act.SplitVertical   { domain = 'CurrentPaneDomain' }
  local split_right = act.SplitHorizontal { domain = 'CurrentPaneDomain' }
  local pane_picker = act.PaneSelect {}

  -- Custom actions mirrored into the command palette (CTRL+SHIFT+P). Without
  -- this the palette lists only built-ins — a misleading "second surface" that
  -- omits every bespoke binding. Entries reuse the SAME action values as
  -- config.keys, so the two can't drift.
  wezterm.on('augment-command-palette', function(_window, _pane)
    return {
      { brief = 'Connect to host (fuzzy)',  action = pick_host },
      { brief = 'Switch tab (fuzzy)',       action = pick_tab },
      { brief = 'Reconnect SSH pane',       action = reconnect_ssh_pane },
      { brief = 'Rename current tab',       action = rename_tab },
      { brief = 'Copy entire scrollback',   action = copy_all_scrollback },
      { brief = 'Open scrollback in Helix', action = scrollback_to_helix },
      { brief = 'Help / cheatsheet',        action = show_help },
      { brief = 'QuickSelect: IP → open SSH',     action = quick_ssh_ip },
      { brief = 'QuickSelect: file:line → Helix', action = quick_open_hx },
      { brief = 'QuickSelect: SHA → prompt',      action = quick_yank_sha },
      { brief = 'Split pane down',  action = split_down },
      { brief = 'Split pane right', action = split_right },
      { brief = 'Pane picker',      action = pane_picker },
    }
  end)

  M.pick_host           = pick_host
  M.pick_tab            = pick_tab
  M.reconnect_ssh_pane  = reconnect_ssh_pane
  M.smart_new_tab       = smart_new_tab
  M.rename_tab          = rename_tab
  M.copy_all_scrollback = copy_all_scrollback
  M.copy_and_announce   = copy_and_announce
  M.scrollback_to_helix = scrollback_to_helix
  M.show_help           = show_help
  M.quick_ssh_ip        = quick_ssh_ip
  M.quick_open_hx       = quick_open_hx
  M.quick_yank_sha      = quick_yank_sha
  M.split_down          = split_down
  M.split_right         = split_right
  M.pane_picker         = pane_picker
end

return M
