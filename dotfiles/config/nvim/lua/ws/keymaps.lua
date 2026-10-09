-- Global keys. <Space> is leader; the pickers mirror helix's space mode
-- (f files, b buffers, / grep, s symbols, ' resume, y clipboard yank).
-- Run nvim inside zellij locked (Ctrl+G), as for helix: unlocked zellij takes
-- Ctrl+O/P/N/T/H/S/B/Q/G before Neovim sees them.
local util = require('ws.util')
local map = vim.keymap.set

local function fzf(name, opts)
  return function()
    local f = util.try('fzf-lua')
    if f then
      f[name](opts)
    else
      vim.notify('fzf-lua is not installed', vim.log.levels.WARN)
    end
  end
end

-- Pickers
map('n', '<leader>f', fzf('files'), { desc = 'Find files' })
map('n', '<leader>F', fzf('oldfiles', { cwd_only = true }), { desc = 'Recent files (project)' })
map('n', '<leader>b', fzf('buffers'), { desc = 'Buffers' })
map('n', '<leader>/', fzf('live_grep'), { desc = 'Grep project' })
map('n', '<leader>*', fzf('grep_cword'), { desc = 'Grep word under cursor' })
map('x', '<leader>*', fzf('grep_visual'), { desc = 'Grep selection' })
map('n', "<leader>'", fzf('resume'), { desc = 'Resume last picker' })
map('n', '<leader>j', fzf('jumps'), { desc = 'Jumplist' })
map('n', '<leader>?', fzf('keymaps'), { desc = 'Keymaps' })
map('n', '<leader>H', fzf('helptags'), { desc = 'Help' })
map('n', '<leader>gs', fzf('git_status'), { desc = 'Git status' })
map('n', '<leader>gc', fzf('git_bcommits'), { desc = 'Git log (buffer)' })
map('n', '<leader>xd', fzf('diagnostics_document'), { desc = 'Diagnostics (buffer)' })
map('n', '<leader>xD', fzf('diagnostics_workspace'), { desc = 'Diagnostics (workspace)' })
map('n', '<leader>xq', fzf('quickfix'), { desc = 'Quickfix list' })
map('n', '<leader>xl', vim.diagnostic.setloclist, { desc = 'Diagnostics to location list' })

-- lazygit in a new tab; closes with lazygit
map('n', '<leader>gg', function()
  vim.cmd('tabnew')
  vim.fn.jobstart({ 'lazygit' }, {
    term = true,
    on_exit = function()
      vim.schedule(function()
        pcall(vim.cmd, 'tabclose')
      end)
    end,
  })
  vim.cmd('startinsert')
end, { desc = 'lazygit' })

-- Files
map('n', '-', '<cmd>Oil<cr>', { desc = 'Parent directory (oil)' })
map('n', '<leader>e', '<cmd>Oil --float<cr>', { desc = 'File explorer (float)' })

-- Clipboard (OSC 52; see ws.clipboard)
map({ 'n', 'x' }, '<leader>y', '"+y', { desc = 'Yank to system clipboard' })
map('n', '<leader>Y', '"+y$', { desc = 'Yank to end of line to system clipboard' })

-- Editing
map('n', '<Esc>', '<cmd>nohlsearch<cr>')
map({ 'n', 'i', 'x' }, '<C-s>', '<cmd>write<cr><esc>', { desc = 'Save' })
map('x', '<', '<gv')
map('x', '>', '>gv')
map('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Leave terminal mode' })

-- Quickfix (build errors) and location list
map('n', ']q', '<cmd>cnext<cr>zz', { desc = 'Next quickfix' })
map('n', '[q', '<cmd>cprev<cr>zz', { desc = 'Previous quickfix' })

-- Toggles
map('n', '<leader>uh', function()
  vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = 0 }), { bufnr = 0 })
end, { desc = 'Toggle inlay hints' })
map('n', '<leader>ud', function()
  vim.diagnostic.enable(not vim.diagnostic.is_enabled())
end, { desc = 'Toggle diagnostics' })
map('n', '<leader>uv', function()
  local cfg = vim.diagnostic.config() or {}
  vim.diagnostic.config({
    virtual_lines = not cfg.virtual_lines and { current_line = true } or false,
    virtual_text = cfg.virtual_lines and { spacing = 2, source = 'if_many', prefix = '●' } or false,
  })
end, { desc = 'Toggle diagnostic virtual lines' })
map('n', '<leader>uw', '<cmd>set wrap!<cr>', { desc = 'Toggle wrap' })
map('n', '<leader>ur', '<cmd>set relativenumber!<cr>', { desc = 'Toggle relative numbers' })
