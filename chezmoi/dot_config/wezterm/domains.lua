-- =============================================================================
-- domains.lua — SSH-domain wiring: Zellij default_prog, name lookup,
-- hostname canonicalization. Exports: M.ssh_domain_names, M.canonical_host,
-- M.local_hostname
-- =============================================================================

local wezterm = require 'wezterm'

local M = {}

function M.apply(config)
  local ssh_domains = require 'hosts'

  -- ---------------------------------------------------------------------------
  -- Auto-launch Zellij on connect
  -- ---------------------------------------------------------------------------
  -- Attaches to (or creates) a session named 'main' automatically.
  local function zellij_attach_cmd()
    return { 'zellij', 'attach', '--create', 'main' }
  end

  -- Apply the Zellij command to each SSH domain, and build a name → true
  -- lookup so callbacks can tell a REAL SSH domain from every other non-local
  -- domain name (WSL:<distro>, or any future unix/tls/serial domain) — used by
  -- reconnect_ssh_pane (actions.lua) and format-tab-title (tabs.lua).
  local ssh_domain_names = {}
  for _, domain in ipairs(ssh_domains) do
    domain.default_prog = zellij_attach_cmd()
    ssh_domain_names[domain.name] = true
  end

  -- ---------------------------------------------------------------------------
  -- Startup workspace — open a tab per host on launch
  -- ---------------------------------------------------------------------------
  -- wezterm.on('gui-startup', function(cmd)
  --   local _, _, window = wezterm.mux.spawn_window(cmd or {})

  --   for i, domain in ipairs(ssh_domains) do
  --     if i == 1 then
  --       -- First tab uses the initial window
  --       window:active_tab():set_title(domain.name)
  --     else
  --       -- Subsequent hosts get their own tab
  --       window:spawn_tab({
  --         domain = { DomainName = domain.name },
  --       })
  --     end
  --   end
  -- end)

  -- This machine's hostname, lowercased. WSL distros share the Windows
  -- computer name by default (no hostname override in configs/wsl/wsl.conf),
  -- so a WSL pane's OWN shell reports this value in its OSC 7 — anything else
  -- showing up there means an ssh session is running inside the pane.
  local LOCAL_HOSTNAME = (wezterm.hostname() or ''):lower()

  -- Map a detected hostname (short or FQDN, any case) onto the matching
  -- ssh_domain name, so an ssh session running INSIDE a WSL/local pane hashes
  -- into the SAME HOST_ACCENTS bucket as a real SSH-domain tab to that host.
  -- Unmatched hosts pass through as-is — they still get a stable accent of
  -- their own, it just isn't shared with any domain tab.
  local function canonical_host(h)
    local short = (h:match('^([^%.]+)') or h):lower()
    for _, d in ipairs(ssh_domains) do
      local name = d.name:lower()
      if name == h:lower() or name == short then
        return d.name
      end
    end
    return h
  end

  -- ---------------------------------------------------------------------------
  -- SSH domains
  -- ---------------------------------------------------------------------------
  config.ssh_domains = ssh_domains

  -- ---------------------------------------------------------------------------
  -- SSH quick-connect function (call from wezterm CLI)
  -- ---------------------------------------------------------------------------
  -- Usage: wezterm connect rhel-dev-01
  -- This is already handled by ssh_domains above.

  M.ssh_domain_names = ssh_domain_names
  M.canonical_host   = canonical_host
  M.local_hostname   = LOCAL_HOSTNAME
end

return M
