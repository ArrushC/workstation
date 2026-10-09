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

-- Auto-save, as helix's `auto-save = true` (save on focus lost), plus on
-- leaving a buffer, since buffers switch inside Neovim. Only modified,
-- writable file buffers are written, and never formatted (ws.format skips
-- while ws_autosaving): explicit :w and <C-s> format. <leader>ua toggles;
-- `vim.g.autosave = false` in lua/ws/local.lua turns it off for a host.
au({ 'FocusLost', 'BufLeave' }, {
  desc = 'Auto-save modified file buffers',
  callback = function(ev)
    if vim.g.autosave == false then
      return
    end
    local bufs = ev.event == 'FocusLost' and vim.api.nvim_list_bufs() or { ev.buf }
    vim.g.ws_autosaving = true
    for _, b in ipairs(bufs) do
      local bo = vim.bo[b]
      if
        vim.api.nvim_buf_is_loaded(b)
        and bo.modified
        and bo.buftype == ''
        and bo.modifiable
        and not bo.readonly
        and vim.api.nvim_buf_get_name(b) ~= ''
      then
        vim.api.nvim_buf_call(b, function()
          vim.cmd('silent! lockmarks update')
        end)
      end
    end
    vim.g.ws_autosaving = false
  end,
})

-- Sessions per working directory (what persistence.nvim does): saved on exit,
-- restored on demand with <leader>qs; <leader>qd skips saving this one.
local session_dir = vim.fn.stdpath('state') .. '/sessions/'
vim.o.sessionoptions = 'buffers,curdir,folds,tabpages,winsize'

local M = {}
function M.session_file()
  return session_dir .. vim.fn.getcwd():gsub('[/\\:]', '%%') .. '.vim'
end

--- Save the session for the current directory (when a file is open). The
--- side panels are closed first: a session cannot restore them, so ws.ide
--- remembers and reopens them itself.
function M.save_session()
  if vim.g.ws_session == false or #vim.api.nvim_list_uis() == 0 then
    return -- opted out, or headless (provisioning, scripts)
  end
  local ide = package.loaded['ws.ide']
  if ide then
    pcall(ide.before_session_save)
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and vim.bo[b].buftype == '' and vim.api.nvim_buf_get_name(b) ~= '' then
      vim.fn.mkdir(session_dir, 'p')
      vim.cmd('silent! mksession! ' .. vim.fn.fnameescape(M.session_file()))
      return
    end
  end
end

au('VimLeavePre', { desc = 'Save the session for this directory', callback = M.save_session })

return M
