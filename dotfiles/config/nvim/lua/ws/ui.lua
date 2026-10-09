local util = require('ws.util')

-- Catppuccin Mocha with the fleet's mauve accent (helix, zellij, starship, fzf).
util.setup('catppuccin', function(cat)
  cat.setup({
    flavour = 'mocha',
    term_colors = true,
    auto_integrations = false, -- explicit list below; vim.pack has no plugin registry
    integrations = {
      blink_cmp = { style = 'bordered' },
      dap = true,
      fzf = true,
      gitsigns = true,
      indent_blankline = { enabled = true, scope_color = 'mauve' },
      mini = { enabled = true },
      native_lsp = { enabled = true, inlay_hints = { background = true } },
      treesitter = true,
    },
    custom_highlights = function(c)
      local accent = { fg = c.mauve }
      return {
        CursorLineNr = { fg = c.mauve, style = { 'bold' } },
        FloatBorder = accent,
        FloatTitle = { fg = c.mauve, style = { 'bold' } },
        WinSeparator = { fg = c.surface1 },
        MiniStatuslineModeNormal = { fg = c.mantle, bg = c.mauve, style = { 'bold' } },
        FzfLuaBorder = accent,
        FzfLuaTitle = { fg = c.mauve, style = { 'bold' } },
        BlinkCmpMenuBorder = accent,
        BlinkCmpDocBorder = accent,
        BlinkCmpSignatureHelpBorder = accent,
        MiniClueBorder = accent,
        MiniClueTitle = { fg = c.mauve, style = { 'bold' } },
      }
    end,
  })
  vim.cmd.colorscheme('catppuccin-mocha')
end)

util.setup('mini.icons', function(icons)
  icons.setup()
  icons.mock_nvim_web_devicons() -- for plugins that ask for nvim-web-devicons
end)

-- Statusline: mode, git, diagnostics, LSP; LSP progress (clangd indexing) on the right.
util.setup('mini.statusline', function(sl)
  sl.setup({
    content = {
      active = function()
        local mode, mode_hl = sl.section_mode({ trunc_width = 120 })
        local git = sl.section_git({ trunc_width = 40 })
        local diff = sl.section_diff({ trunc_width = 75 })
        local diagnostics = sl.section_diagnostics({ trunc_width = 75 })
        local lsp = sl.section_lsp({ trunc_width = 75 })
        local filename = sl.section_filename({ trunc_width = 140 })
        local fileinfo = sl.section_fileinfo({ trunc_width = 120 })
        local location = sl.section_location({ trunc_width = 75 })
        local search = sl.section_searchcount({ trunc_width = 75 })
        local progress = sl.is_truncated(100) and '' or vim.ui.progress_status()
        return sl.combine_groups({
          { hl = mode_hl, strings = { mode } },
          { hl = 'MiniStatuslineDevinfo', strings = { git, diff, diagnostics, lsp } },
          '%<',
          { hl = 'MiniStatuslineFilename', strings = { filename } },
          '%=',
          { hl = 'MiniStatuslineFilename', strings = { progress } },
          { hl = 'MiniStatuslineFileinfo', strings = { fileinfo } },
          { hl = mode_hl, strings = { search, location } },
        })
      end,
    },
  })
end)

-- Key hints after <Space>, g, z, [, ], <C-w>, registers and marks (which-key style).
util.later(function()
  util.setup('mini.clue', function(clue)
    clue.setup({
      triggers = {
        { mode = 'n', keys = '<Leader>' },
        { mode = 'x', keys = '<Leader>' },
        { mode = 'n', keys = 'g' },
        { mode = 'x', keys = 'g' },
        { mode = 'n', keys = 'z' },
        { mode = 'x', keys = 'z' },
        { mode = 'n', keys = '[' },
        { mode = 'n', keys = ']' },
        { mode = 'n', keys = '<C-w>' },
        { mode = 'n', keys = "'" },
        { mode = 'n', keys = '`' },
        { mode = 'n', keys = '"' },
        { mode = 'x', keys = '"' },
        { mode = 'i', keys = '<C-r>' },
        { mode = 'c', keys = '<C-r>' },
      },
      clues = {
        { mode = 'n', keys = '<Leader>c', desc = '+code' },
        { mode = 'n', keys = '<Leader>d', desc = '+debug' },
        { mode = 'n', keys = '<Leader>g', desc = '+git' },
        { mode = 'n', keys = '<Leader>h', desc = '+hunk' },
        { mode = 'n', keys = '<Leader>m', desc = '+make' },
        { mode = 'n', keys = '<Leader>u', desc = '+toggle' },
        { mode = 'n', keys = '<Leader>x', desc = '+diagnostics' },
        clue.gen_clues.builtin_completion(),
        clue.gen_clues.g(),
        clue.gen_clues.marks(),
        clue.gen_clues.registers(),
        clue.gen_clues.windows(),
        clue.gen_clues.z(),
      },
      window = { delay = 300, config = { width = 'auto' } },
    })
  end)
end)

-- TODO/FIXME/HACK/NOTE and #rrggbb highlighting in any buffer.
util.later(function()
  util.setup('mini.hipatterns', function(hp)
    local word = function(w, hl)
      return { pattern = '%f[%w]()' .. w .. '()%f[%W]', group = hl }
    end
    hp.setup({
      highlighters = {
        fixme = word('FIXME', 'MiniHipatternsFixme'),
        bug = word('BUG', 'MiniHipatternsFixme'),
        hack = word('HACK', 'MiniHipatternsHack'),
        xxx = word('XXX', 'MiniHipatternsHack'),
        todo = word('TODO', 'MiniHipatternsTodo'),
        note = word('NOTE', 'MiniHipatternsNote'),
        hex_color = hp.gen_highlighter.hex_color(),
      },
    })
  end)
end)

util.later(function()
  util.setup('gitsigns', function(gs)
    gs.setup({
      on_attach = function(buf)
        local map = function(lhs, rhs, desc, mode)
          vim.keymap.set(mode or 'n', lhs, rhs, { buffer = buf, desc = desc })
        end
        map(']h', function()
          gs.nav_hunk('next')
        end, 'Next hunk')
        map('[h', function()
          gs.nav_hunk('prev')
        end, 'Previous hunk')
        map('<leader>hs', gs.stage_hunk, 'Stage hunk')
        map('<leader>hr', gs.reset_hunk, 'Reset hunk')
        map('<leader>hS', gs.stage_buffer, 'Stage buffer')
        map('<leader>hR', gs.reset_buffer, 'Reset buffer')
        map('<leader>hp', gs.preview_hunk_inline, 'Preview hunk')
        map('<leader>hb', function()
          gs.blame_line({ full = true })
        end, 'Blame line')
        map('<leader>hB', gs.blame, 'Blame buffer')
        map('<leader>hd', gs.diffthis, 'Diff against index')
        map('ih', gs.select_hunk, 'Hunk', { 'o', 'x' })
      end,
    })
  end)
end)

util.setup('ibl', function(ibl)
  ibl.setup({
    indent = { char = '╎' }, -- helix's indent-guides character
    scope = { show_start = false, show_end = false },
    exclude = { filetypes = { 'help', 'oil', 'checkhealth', 'dap-view', 'dap-repl' } },
  })
end)

util.setup('guess-indent', function(gi)
  gi.setup({}) -- .editorconfig still wins: it is applied after this guess
end)

-- Files as an editable buffer: `-` opens the parent directory.
util.setup('oil', function(oil)
  oil.setup({
    default_file_explorer = true,
    columns = { 'icon' },
    view_options = { show_hidden = true },
    keymaps = { ['q'] = { 'actions.close', mode = 'n' } },
  })
end)

-- Picker: fzf-lua drives the fleet's fzf, fd, rg, bat and delta.
util.later(function()
  util.setup('fzf-lua', function(fzf)
    fzf.setup({
      'default-title',
      fzf_colors = true, -- derive fzf colours from catppuccin
      fzf_opts = { ['--layout'] = 'reverse', ['--info'] = 'inline-right' },
      winopts = { height = 0.85, width = 0.85, preview = { layout = 'flex', flip_columns = 140 } },
      defaults = { formatter = 'path.filename_first' },
      grep = { hidden = true },
      files = { hidden = true },
      lsp = { jump1 = true, includeDeclaration = false },
    })
    fzf.register_ui_select() -- code actions, dap pickers, vim.ui.select
  end)
end)
