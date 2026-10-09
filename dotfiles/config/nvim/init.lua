-- ~/.config/nvim/init.lua — managed by mise dotfiles (dotfiles/config/nvim).
-- Neovim is a second editor next to helix ($EDITOR), tuned for C and C++.
-- Plugins: vim.pack (built in), pinned by nvim-pack-lock.json beside this file.
-- Nothing here downloads tools: clangd, gdb, lldb-dap, clang-format and the
-- language servers come from dnf and mise.

if vim.fn.has('nvim-0.12') == 0 then
  vim.api.nvim_echo({ { 'this config needs Neovim 0.12+ (vim.pack)', 'ErrorMsg' } }, true, {})
  return
end

vim.loader.enable() -- byte-compile and cache Lua modules
vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'

require('ws.options')
require('ws.clipboard')
require('ws.plugins') -- vim.pack.add; installs missing plugins from the lockfile
require('ws.ui')
require('ws.treesitter')
require('ws.lsp')
require('ws.completion')
require('ws.format')
require('ws.build')
require('ws.dap') -- nvim-dap loads on first use
require('ws.keymaps')
require('ws.autocmds')

-- Per-host additions: ~/.config/nvim/lua/ws/local.lua (untracked; the directory
-- copy leaves files it does not manage alone).
require('ws.util').try('ws.local')
