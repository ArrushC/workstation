local group = vim.api.nvim_create_augroup('ws.autocmds', { clear = true })
local au = function(event, opts)
  opts.group = group
  vim.api.nvim_create_autocmd(event, opts)
end

au('TextYankPost', {
  desc = 'Flash yanked text',
  callback = function()
    vim.hl.on_yank({ timeout = 150 })
  end,
})

au('BufReadPost', {
  desc = 'Reopen a file at the last cursor position',
  callback = function(ev)
    local ft = vim.bo[ev.buf].filetype
    if ft == 'gitcommit' or ft == 'gitrebase' or vim.b[ev.buf].ws_last_loc then
      return
    end
    vim.b[ev.buf].ws_last_loc = true
    local mark = vim.api.nvim_buf_get_mark(ev.buf, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(ev.buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

au({ 'FocusGained', 'TermClose', 'TermLeave' }, {
  desc = 'Reload files changed outside Neovim',
  callback = function()
    if vim.o.buftype ~= 'nofile' then
      vim.cmd('checktime')
    end
  end,
})

au('VimResized', { desc = 'Equalize splits', command = 'tabdo wincmd =' })

au('FileType', {
  desc = 'Close helper windows with q',
  pattern = { 'help', 'qf', 'checkhealth', 'man', 'lspinfo', 'dap-float', 'nvim-pack' },
  callback = function(ev)
    vim.bo[ev.buf].buflisted = false
    vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = ev.buf, silent = true, nowait = true })
  end,
})

au('FileType', {
  desc = 'Prose: wrap, spell, no rulers',
  pattern = { 'markdown', 'text', 'gitcommit' },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.spell = true
    vim.opt_local.colorcolumn = vim.bo.filetype == 'gitcommit' and '51,73' or ''
  end,
})
