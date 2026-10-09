-- Editing helpers. mini modules (one pin, already installed) instead of
-- separate plugins; set up just after startup.
local util = require('ws.util')

util.later(function()
  -- Auto-close (), [], {}, quotes in insert mode; typing the closer steps over it.
  util.setup('mini.pairs', function(pairs)
    pairs.setup({ modes = { insert = true, command = false, terminal = false } })
  end)

  -- Surround (kickstart's defaults): sa add, sd delete, sr replace, sf/sF find,
  -- sh highlight. `saiw)` wraps a word in (), `sd"` drops quotes, `sr)]` swaps.
  util.setup('mini.surround', function(surround)
    surround.setup()
  end)

  -- a/i text objects. Treesitter ones (queries from nvim-treesitter-textobjects),
  -- named as in helix: f function, t type/class, a argument, c comment,
  -- o loop/conditional/block; u function call. mini.ai adds the rest: brackets,
  -- quotes, `q`, `b`, and next/last forms (`cin(`, `dal"`) that also reach a
  -- target that is not under the cursor.
  util.setup('mini.ai', function(ai)
    local ts = ai.gen_spec.treesitter
    ai.setup({
      n_lines = 500,
      custom_textobjects = {
        f = ts({ a = '@function.outer', i = '@function.inner' }),
        t = ts({ a = '@class.outer', i = '@class.inner' }),
        a = ts({ a = '@parameter.outer', i = '@parameter.inner' }),
        c = ts({ a = '@comment.outer', i = '@comment.inner' }),
        o = ts({
          a = { '@conditional.outer', '@loop.outer', '@block.outer' },
          i = { '@conditional.inner', '@loop.inner', '@block.inner' },
        }),
        u = ai.gen_spec.function_call(),
      },
    })
  end)
end)

-- Doxygen comment for the function/class under the cursor, parameter names
-- filled in from treesitter (neogen; loaded on first use).
local neogen_ready = false
vim.keymap.set('n', '<leader>cn', function()
  if not neogen_ready then
    vim.cmd.packadd('neogen')
    local doxygen = { template = { annotation_convention = 'doxygen' } }
    local ok = util.setup('neogen', function(neogen)
      neogen.setup({ snippet_engine = 'nvim', languages = { c = doxygen, cpp = doxygen } })
    end)
    if not ok then
      return
    end
    neogen_ready = true
  end
  require('neogen').generate()
end, { desc = 'Doxygen comment (neogen)' })

-- Undo tree: Neovim 0.12's built-in :Undotree (optional package).
vim.keymap.set('n', '<leader>uu', function()
  vim.cmd.packadd('nvim.undotree')
  vim.cmd('Undotree')
end, { desc = 'Undo tree' })

-- Close buffers without closing their window (the bufferline stays sane).
vim.keymap.set('n', '<leader>qb', function()
  local br = util.try('mini.bufremove')
  if br then
    br.delete(0, false)
  else
    vim.cmd('bdelete')
  end
end, { desc = 'Close buffer (keep window)' })
vim.keymap.set('n', '<leader>qo', function()
  local cur = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= cur and vim.bo[b].buflisted and not vim.bo[b].modified then
      pcall(vim.api.nvim_buf_delete, b, {})
    end
  end
end, { desc = 'Close other (saved) buffers' })
