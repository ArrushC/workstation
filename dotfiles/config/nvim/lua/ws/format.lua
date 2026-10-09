-- Formatting: conform.nvim, set up just after startup. clang-format
-- reads the project's .clang-format (found upward from the file, via
-- --assume-filename).
--
-- Format on save is ON only for C/C++ files inside a project that has a
-- .clang-format: that project asked for it. Elsewhere (foreign code, no style
-- file) saving never rewrites the file. <leader>cf formats on demand anywhere;
-- <leader>uf toggles format-on-save for the session; :w! style escape hatch:
-- `:noautocmd w`.
local M = {}
local util = require('ws.util')

local clang = { c = true, cpp = true, cuda = true, objc = true, objcpp = true, proto = true }

local conform ---@type table|false|nil
local function get()
  if conform == nil then
    conform = util.setup('conform', function(c)
      c.setup({
        formatters_by_ft = {
          c = { 'clang_format' },
          cpp = { 'clang_format' },
          cuda = { 'clang_format' },
          objc = { 'clang_format' },
          objcpp = { 'clang_format' },
          proto = { 'clang_format' },
          sh = { 'shfmt' },
          bash = { 'shfmt' },
          json = { 'jq' },
          -- everything else: the language server, if it formats (taplo, gopls, ...)
        },
        default_format_opts = { lsp_format = 'fallback' },
        notify_no_formatters = true,
      })
    end) or false
  end
  return conform or nil
end

--- 'formatexpr': gq formats with clang-format (Vim's own formatter for comments).
function M.formatexpr()
  local c = get()
  return c and c.formatexpr() or 1
end
vim.o.formatexpr = "v:lua.require'ws.format'.formatexpr()"

vim.api.nvim_create_autocmd('BufWritePre', {
  group = vim.api.nvim_create_augroup('ws.format', { clear = true }),
  desc = 'clang-format on save where the project has a .clang-format',
  callback = function(ev)
    if vim.g.autoformat == false or vim.b[ev.buf].autoformat == false or vim.g.ws_autosaving then
      return -- off, or an auto-save (ws.autocmds): only explicit writes format
    end
    if not clang[vim.bo[ev.buf].filetype] then
      return
    end
    if not vim.fs.root(ev.buf, { '.clang-format', '_clang-format' }) then
      return
    end
    local c = get()
    if c then
      c.format({ bufnr = ev.buf, timeout_ms = 1000 })
    end
  end,
})

vim.keymap.set({ 'n', 'x' }, '<leader>cf', function()
  local c = get()
  if c then
    c.format({ async = true })
  else
    vim.lsp.buf.format({ async = true })
  end
end, { desc = 'Format buffer/selection' })

vim.keymap.set('n', '<leader>uf', function()
  vim.g.autoformat = vim.g.autoformat == false
  vim.notify('format on save: ' .. (vim.g.autoformat and 'on (where .clang-format exists)' or 'off'))
end, { desc = 'Toggle format on save' })

util.later(get) -- configured before :ConformInfo or the first save

return M
