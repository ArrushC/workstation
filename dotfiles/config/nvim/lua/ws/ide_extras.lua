-- IDE extras, each loaded on first use (ws.ide.pack), so none costs startup:
--   git:   diffview-plus   <leader>gd working-tree changes, <leader>gh file
--                          history, <leader>gH branch history; q closes
--   LSP:   glance          <leader>cd peek definition, <leader>cr peek references
--          nvim-lightbulb  a sign on lines with a code action (<leader>a)
--   lists: quicker         readable, editable quickfix (:Make, <leader>xx);
--                          > / < show and hide the lines around each entry
local util = require('ws.util')
local pack = require('ws.ide').pack
local map = vim.keymap.set
local api = vim.api

-- Git: dlyongemallo's maintained fork of sindrets/diffview.nvim (idle since 2024).
local function diffview(cmd)
  return function()
    local d = pack('diffview-plus.nvim', 'diffview', function(dv)
      local close = { 'n', 'q', '<cmd>DiffviewClose<cr>', { desc = 'Close diffview' } }
      dv.setup({
        enhanced_diff_hl = true,
        keymaps = { view = { close }, file_panel = { close }, file_history_panel = { close } },
      })
    end)
    if d then
      vim.cmd(cmd)
    end
  end
end
map('n', '<leader>gd', diffview('DiffviewOpen'), { desc = 'Diff working tree (diffview)' })
map('n', '<leader>gh', diffview('DiffviewFileHistory %'), { desc = 'File history (diffview)' })
map('n', '<leader>gH', diffview('DiffviewFileHistory'), { desc = 'Branch history (diffview)' })

-- LSP: peek (glance) and the code-action lightbulb, for buffers with a server.
local function glance(what)
  return function()
    local g = pack('glance.nvim', 'glance', function(gl)
      gl.setup({ border = { enable = true }, height = 20 })
    end)
    if g then
      g.open(what)
    end
  end
end

api.nvim_create_autocmd('LspAttach', {
  group = api.nvim_create_augroup('ws.ide_extras', { clear = true }),
  callback = function(ev)
    map('n', '<leader>cd', glance('definitions'), { buffer = ev.buf, desc = 'Peek definition' })
    map('n', '<leader>cr', glance('references'), { buffer = ev.buf, desc = 'Peek references' })
    pack('nvim-lightbulb', 'nvim-lightbulb', function(lb)
      lb.setup({
        autocmd = { enabled = true, updatetime = -1 }, -- on CursorHold, with our 'updatetime'
        sign = { enabled = true, text = '\u{f0335}', lens_text = '\u{f0335}' },
      })
    end)
  end,
})

-- Quickfix: quicker formats every list through 'quickfixtextfunc', so it is
-- set up right after startup, before the first :Make.
util.later(function()
  pack('quicker.nvim', 'quicker', function(q)
    q.setup({
      keys = {
        { '>', function() require('quicker').expand({ before = 2, after = 2, add_to_existing = true }) end, desc = 'Show context' },
        { '<', function() require('quicker').collapse() end, desc = 'Hide context' },
      },
    })
  end)
end)
