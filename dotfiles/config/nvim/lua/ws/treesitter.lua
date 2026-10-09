-- Treesitter: nvim-treesitter `main` installs parsers and queries; Neovim
-- itself highlights and folds. Parsers compile locally, which needs the
-- tree-sitter CLI (mise: conda:tree-sitter-cli) and a C compiler. A host
-- without them keeps Neovim's bundled parsers (c, lua, vim, vimdoc, query,
-- markdown) and regex syntax for the rest.
local util = require('ws.util')
local M = {}

M.parsers = {
  'c', 'cpp', 'cmake', 'make', 'meson', 'ninja', 'doxygen', 'asm', 'printf', 'regex',
  'lua', 'luadoc', 'vim', 'vimdoc', 'query', 'bash', 'python', 'json', 'yaml', 'toml',
  'markdown', 'markdown_inline', 'diff', 'gitcommit', 'git_rebase', 'gitignore',
}

--- Why parsers cannot be built here, or nil when they can.
function M.missing_tools()
  local missing = {}
  if vim.fn.executable('tree-sitter') == 0 then
    table.insert(missing, 'tree-sitter CLI')
  end
  if vim.fn.executable('cc') == 0 and vim.fn.executable('gcc') == 0 and vim.fn.executable('clang') == 0 then
    table.insert(missing, 'a C compiler')
  end
  return #missing > 0 and table.concat(missing, ' and ') or nil
end

--- Install M.parsers and wait (provisioning: tasks/nvim-plugins).
function M.install_sync(timeout_ms)
  local ts = util.try('nvim-treesitter')
  if not ts then
    return false, 'nvim-treesitter is not installed'
  end
  local why = M.missing_tools()
  if why then
    return false, 'skipped parser builds, missing ' .. why
  end
  local done, ok = ts.install(M.parsers, { summary = true }):pwait(timeout_ms or 600000)
  return done and ok ~= false, nil
end

-- Highlight and fold any buffer whose parser is present (installed or bundled).
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('ws.treesitter', { clear = true }),
  callback = function(ev)
    local lang = vim.treesitter.language.get_lang(ev.match) or ev.match
    if not pcall(vim.treesitter.start, ev.buf, lang) then
      return
    end
    local win = vim.fn.bufwinid(ev.buf)
    if win ~= -1 then
      vim.wo[win][0].foldmethod = 'expr'
      vim.wo[win][0].foldexpr = 'v:lua.vim.treesitter.foldexpr()'
    end
  end,
})

-- Motions and swaps from nvim-treesitter-textobjects (helix-like names:
-- f function, t type/class, a argument). Selection (af, it, ...) is mini.ai's,
-- driven by this plugin's queries (ws.editing).
util.setup('nvim-treesitter-textobjects', function(to)
  to.setup({ move = { set_jumps = true } })
  local move = require('nvim-treesitter-textobjects.move')
  local swap = require('nvim-treesitter-textobjects.swap')
  for key, obj in pairs({ f = 'function', t = 'class', a = 'parameter' }) do
    local q = '@' .. obj .. '.outer'
    vim.keymap.set({ 'n', 'x', 'o' }, ']' .. key, function()
      move.goto_next_start(q, 'textobjects')
    end, { desc = 'Next ' .. obj })
    vim.keymap.set({ 'n', 'x', 'o' }, '[' .. key, function()
      move.goto_previous_start(q, 'textobjects')
    end, { desc = 'Previous ' .. obj })
  end
  vim.keymap.set('n', '<leader>cs', function()
    swap.swap_next('@parameter.inner')
  end, { desc = 'Swap argument with next' })
  vim.keymap.set('n', '<leader>cS', function()
    swap.swap_previous('@parameter.inner')
  end, { desc = 'Swap argument with previous' })
end)

vim.api.nvim_create_user_command('TSInstallAll', function()
  local why = M.missing_tools()
  if why then
    return vim.notify('Treesitter: cannot build parsers, missing ' .. why, vim.log.levels.WARN)
  end
  local ts = util.try('nvim-treesitter')
  if ts then
    ts.install(M.parsers, { summary = true })
  end
end, { desc = 'Install the configured treesitter parsers' })

return M
