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
-- trouble-like lists, built in: every diagnostic of every buffer into quickfix
map('n', '<leader>xx', function()
  vim.diagnostic.setqflist({ title = 'Diagnostics', open = true })
end, { desc = 'Diagnostics (all buffers) to quickfix' })
-- todo-comments-like search for what mini.hipatterns highlights
map('n', '<leader>xt', fzf('grep', { search = [[\b(TODO|FIXME|HACK|BUG|XXX|NOTE)\b]], no_esc = true }),
  { desc = 'TODO/FIXME comments (project)' })

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
map('n', '<leader>ua', function()
  vim.g.autosave = vim.g.autosave == false
  vim.notify('auto-save: ' .. (vim.g.autosave and 'on' or 'off'))
end, { desc = 'Toggle auto-save' })
map('n', '<leader>uc', function()
  local ctx = util.try('treesitter-context')
  if ctx then
    ctx.toggle()
  end
end, { desc = 'Toggle sticky context' })
map('n', '<leader>un', function()
  if _G.MiniNotify then
    MiniNotify.show_history()
  end
end, { desc = 'Notification history' })

-- Sessions (ws.autocmds saves one per directory on exit)
map('n', '<leader>qs', function()
  local f = require('ws.autocmds').session_file()
  if vim.uv.fs_stat(f) then
    vim.cmd('silent! %bwipeout')
    vim.cmd('source ' .. vim.fn.fnameescape(f))
  else
    vim.notify('no saved session for ' .. vim.fn.getcwd(), vim.log.levels.WARN)
  end
end, { desc = 'Restore session (this directory)' })
map('n', '<leader>qd', function()
  vim.g.ws_session = false
  vim.notify('this session will not be saved')
end, { desc = "Don't save session on exit" })
map('n', '<leader>qq', '<cmd>confirm qall<cr>', { desc = 'Quit all' })
map('n', '<leader>ur', '<cmd>set relativenumber!<cr>', { desc = 'Toggle relative numbers' })
