-- Plugins, managed by vim.pack (Neovim 0.12's built-in manager).
--
-- Pinning: nvim-pack-lock.json (next to init.lua, tracked in the mise repo)
-- records the exact commit of every plugin. `mise run nvim-plugins` (the final
-- hook; also run by `wsu`) or :PackInstall installs exactly those commits.
-- `version` below only says where
-- vim.pack.update() may move: a semver range where the plugin needs or
-- recommends release tags, otherwise the default branch.
--
-- Update: :PackUpdate, review the confirmation buffer, :write to apply, then
-- record the new lockfile with `wsr` and commit it.
local M = {}
local gh = function(repo)
  return 'https://github.com/' .. repo
end

-- Hooks must exist before the first vim.pack.add() to see installs.
vim.api.nvim_create_autocmd('PackChanged', {
  group = vim.api.nvim_create_augroup('ws.pack', { clear = true }),
  callback = function(ev)
    local name, kind = ev.data.spec.name, ev.data.kind
    if name == 'nvim-treesitter' and kind == 'update' then
      -- Parsers must match the queries of the new nvim-treesitter revision.
      if not ev.data.active then
        vim.cmd.packadd('nvim-treesitter')
      end
      pcall(function()
        require('ws.treesitter').missing_tools() -- Windows: points tree-sitter at the compiler
      end)
      pcall(vim.cmd, 'TSUpdate')
    end
  end,
})

local specs = {
  -- UI
  { src = gh('catppuccin/nvim'), name = 'catppuccin' },
  -- mini: icons, statusline, tabline, notify, clue, hipatterns, ai, pairs, surround, bufremove
  { src = gh('nvim-mini/mini.nvim'), version = 'stable' },
  { src = gh('lewis6991/gitsigns.nvim') },
  { src = gh('lukas-reineke/indent-blankline.nvim') },
  { src = gh('ibhagwan/fzf-lua') },
  { src = gh('stevearc/oil.nvim') },
  { src = gh('NMAC427/guess-indent.nvim') },
  -- Syntax
  { src = gh('nvim-treesitter/nvim-treesitter'), version = 'main' },
  { src = gh('nvim-treesitter/nvim-treesitter-textobjects'), version = 'main' },
  { src = gh('nvim-treesitter/nvim-treesitter-context') }, -- sticky function/class/namespace header
  -- LSP, completion, formatting
  { src = gh('neovim/nvim-lspconfig') }, -- server definitions only (lsp/*.lua)
  { src = gh('dchinmay2/clangd_extensions.nvim') }, -- :ClangdAST, type hierarchy, memory usage
  { src = gh('saghen/blink.cmp'), version = vim.version.range('1.*') }, -- tag => prebuilt fuzzy lib
  { src = gh('rafamadriz/friendly-snippets') },
  { src = gh('stevearc/conform.nvim') },
}

-- Installed with everything else, loaded on first use (ws.dap, ws.editing).
local on_demand = {
  { src = gh('mfussenegger/nvim-dap') },
  { src = gh('igorlfs/nvim-dap-view'), version = vim.version.range('1.*') },
  { src = gh('danymat/neogen') }, -- Doxygen comment from the declaration (<leader>cn)
}

-- Startup never touches the network. vim.pack installs every plugin that the
-- lockfile lists but the disk lacks on its first call, and when a clone fails
-- it also deletes that plugin from nvim-pack-lock.json (tested: an offline
-- start empties it). So vim.pack.add() runs only when every locked plugin is
-- on disk, or for an explicit install (:PackInstall, `mise run nvim-plugins`,
-- which sets g:ws_pack_install), and a failed install puts the lockfile back.
local plug_dir = vim.fn.stdpath('data') .. '/site/pack/core/opt/'
local lock_path = vim.fn.stdpath('config') .. '/nvim-pack-lock.json'

local function read(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local text = f:read('*a')
  f:close()
  return text
end

--- Locked plugins missing on disk, and the lockfile's text.
function M.missing_locked()
  local text = read(lock_path)
  local ok, lock = pcall(vim.json.decode, text or '')
  local missing = {}
  for name in pairs(ok and type(lock) == 'table' and lock.plugins or {}) do
    if not vim.uv.fs_stat(plug_dir .. name) then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  return missing, text
end

local function name_of(spec)
  return spec.name or spec.src:match('([^/]+)$')
end

--- vim.pack.add() both lists; restore the lockfile if an install failed.
local function add_all()
  local _, lock_text = M.missing_locked()
  local ok1, err1 = pcall(vim.pack.add, specs, { confirm = false })
  local ok2, err2 = pcall(vim.pack.add, on_demand, { confirm = false, load = function() end })
  if not (ok1 and ok2) then
    if lock_text then
      local f = assert(io.open(lock_path, 'w'))
      f:write(lock_text)
      f:close()
    end
    local err = tostring(not ok1 and err1 or err2)
    local failed = select(2, err:gsub('\n`', ''))
    vim.notify(
      ('vim.pack: %d plugin(s) failed to install (offline?); lockfile kept. Details: :messages'):format(failed),
      vim.log.levels.WARN
    )
    vim.api.nvim_echo({ { err } }, true, {}) -- full error in :messages history
    return false
  end
  M.added = true
  return true
end

local missing = M.missing_locked()
if #missing == 0 or vim.g.ws_pack_install then
  add_all()
else
  -- Load what is installed (as vim.pack.add would during init) and say what is not.
  for _, spec in ipairs(specs) do
    local name = name_of(spec)
    if vim.uv.fs_stat(plug_dir .. name) then
      vim.cmd.packadd({ name, bang = true })
    end
  end
  vim.schedule(function()
    vim.notify(
      ('%d plugin(s) not installed: %s\nRun :PackInstall (or `mise run nvim-plugins`), then restart.'):format(
        #missing,
        table.concat(missing, ', ')
      ),
      vim.log.levels.WARN
    )
  end)
end

vim.api.nvim_create_user_command('PackInstall', function()
  if add_all() then
    vim.notify('vim.pack: plugins installed at the lockfile revisions; restart Neovim (:restart)')
  end
end, { desc = 'Install plugins missing from disk (lockfile revisions)' })

-- The other commands touch vim.pack, whose first call would try (and on
-- failure, unlock) missing plugins: only after a complete vim.pack.add().
local function guarded(fn)
  return function(args)
    if not M.added then
      return vim.notify('plugins are missing: run :PackInstall first', vim.log.levels.WARN)
    end
    fn(args)
  end
end

vim.api.nvim_create_user_command('PackUpdate', guarded(function(args)
  vim.pack.update(#args.fargs > 0 and args.fargs or nil)
end), { nargs = '*', desc = 'Update plugins (review, then :write)' })

vim.api.nvim_create_user_command('PackStatus', guarded(function()
  vim.pack.update(nil, { offline = true })
end), { desc = 'Show installed plugins and pending changes, no network' })

vim.api.nvim_create_user_command('PackRestore', guarded(function()
  vim.pack.update(nil, { target = 'lockfile', force = true })
end), { desc = 'Check out the lockfile revisions (after a git pull)' })

vim.api.nvim_create_user_command('PackClean', guarded(function()
  local stale = vim
    .iter(vim.pack.get(nil, { info = false }))
    :filter(function(p)
      return not p.active
    end)
    :map(function(p)
      return p.spec.name
    end)
    :totable()
  if #stale == 0 then
    return vim.notify('vim.pack: nothing to remove')
  end
  vim.pack.del(stale)
  vim.notify('vim.pack: removed ' .. table.concat(stale, ', '))
end), { desc = 'Delete installed plugins no longer listed' })

return M
