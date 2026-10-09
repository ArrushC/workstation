local util = require('ws.util')

-- Catppuccin Mocha with the fleet's mauve accent (zellij tabs, starship, fzf
-- prompt), following helix's catppuccin_mocha where helix is explicit:
-- insert green, select (visual) lavender, active buffer tab mauve + underline,
-- curly diagnostic underlines. Opaque background, as helix draws `base` and the
-- terminals (WT, Warp) are opaque #1e1e2e anyway.
util.setup('catppuccin', function(cat)
  cat.setup({
    flavour = 'mocha',
    term_colors = true,
    -- Explicit list: auto-detection calls vim.pack.get(), which with plugins
    -- missing would start installs (see ws.plugins). A table entry is applied
    -- only with `enabled = true`. Treesitter, LSP and semantic-token groups are
    -- built in (catppuccin v2), not integrations.
    auto_integrations = false,
    integrations = {
      blink_cmp = { enabled = true, style = 'bordered' },
      dap = true,
      fzf = true,
      gitsigns = true,
      indent_blankline = { enabled = true, scope_color = 'mauve' },
      mini = { enabled = true },
      treesitter_context = true,
    },
    lsp_styles = {
      underlines = {
        errors = { 'undercurl' },
        warnings = { 'undercurl' },
        information = { 'undercurl' },
        hints = { 'undercurl' },
        ok = { 'undercurl' },
      },
      inlay_hints = { background = true },
    },
    custom_highlights = function(c)
      local accent = { fg = c.mauve }
      local title = { fg = c.mauve, style = { 'bold' } }
      return {
        CursorLineNr = { fg = c.mauve, style = { 'bold' } },
        FloatBorder = accent,
        FloatTitle = title,
        WinSeparator = { fg = c.surface1 },
        -- statusline modes: normal mauve (fleet accent), visual lavender (helix select)
        MiniStatuslineModeNormal = { fg = c.mantle, bg = c.mauve, style = { 'bold' } },
        MiniStatuslineModeVisual = { fg = c.base, bg = c.lavender, style = { 'bold' } },
        -- bufferline like helix: active = mauve with a mauve underline
        MiniTablineCurrent = { fg = c.mauve, bg = c.base, sp = c.mauve, style = { 'bold', 'underline' } },
        MiniTablineModifiedCurrent = { fg = c.peach, bg = c.base, sp = c.mauve, style = { 'bold', 'underline' } },
        MiniTablineVisible = { fg = c.text, bg = c.mantle },
        MiniTablineModifiedVisible = { fg = c.peach, bg = c.mantle },
        MiniTablineHidden = { fg = c.subtext0, bg = c.mantle },
        MiniTablineModifiedHidden = { fg = c.peach, bg = c.mantle },
        MiniTablineFill = { bg = c.crust },
        FzfLuaBorder = accent,
        FzfLuaTitle = title,
        BlinkCmpMenuBorder = accent,
        BlinkCmpDocBorder = accent,
        BlinkCmpSignatureHelpBorder = accent,
        MiniClueBorder = accent,
        MiniClueTitle = title,
        MiniNotifyBorder = accent,
        MiniNotifyTitle = title,
        TreesitterContextBottom = { sp = c.surface1, style = { 'underline' } },
      }
    end,
  })
  vim.cmd.colorscheme('catppuccin-mocha')
end)

util.setup('mini.icons', function(icons)
  icons.setup()
  icons.mock_nvim_web_devicons() -- for plugins that ask for nvim-web-devicons
end)

-- Notifications (build results, plugin notices) in a corner window instead of
-- the command line, so multi-line ones never stop at "Press ENTER". LSP
-- progress stays in the statusline: clangd's indexing would pin a popup.
-- History: <leader>un.
util.setup('mini.notify', function(notify)
  notify.setup({ lsp_progress = { enable = false } })
  vim.notify = notify.make_notify()
end)

-- Statusline, helix's fields: mode, spinner, file name + modified | diagnostics,
-- selection, position, encoding, line ending, file type (git on the left too).
local spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local tick = 0
vim.api.nvim_create_autocmd('Progress', {
  group = vim.api.nvim_create_augroup('ws.statusline', { clear = true }),
  callback = function()
    tick = tick + 1
    vim.cmd.redrawstatus()
  end,
})

local function progress()
  local s = vim.ui.progress_status()
  return s ~= '' and (spinner[tick % #spinner + 1] .. ' ' .. vim.trim(s)) or '' -- s is statusline-escaped (%%)
end

local function selection()
  local mode = vim.fn.mode()
  if not mode:find('^[vV\22]') then
    return ''
  end
  local lines = math.abs(vim.fn.line('.') - vim.fn.line('v')) + 1
  if mode == 'v' and lines == 1 then
    return (math.abs(vim.fn.col('.') - vim.fn.col('v')) + 1) .. ' sel'
  end
  return lines .. ' lines'
end

local function fileinfo()
  local ft = vim.bo.filetype
  local enc = vim.bo.fileencoding ~= '' and vim.bo.fileencoding or vim.o.encoding
  local eol = ({ unix = 'LF', dos = 'CRLF', mac = 'CR' })[vim.bo.fileformat] or vim.bo.fileformat
  local icon = (ft ~= '' and _G.MiniIcons) and (MiniIcons.get('filetype', ft) .. ' ') or ''
  return table.concat({ enc, eol, icon .. (ft ~= '' and ft or 'text') }, '  ')
end

util.setup('mini.statusline', function(sl)
  sl.setup({
    content = {
      active = function()
        local mode, mode_hl = sl.section_mode({ trunc_width = 120 })
        local git = sl.section_git({ trunc_width = 60 })
        local diff = sl.section_diff({ trunc_width = 75 })
        local diagnostics = sl.section_diagnostics({ trunc_width = 75 })
        -- relative name, [+] when modified, [RO] (helix: file-name, file-modification-indicator)
        local filename = vim.bo.buftype == 'terminal' and '%t' or '%f%m%r'
        local search = sl.section_searchcount({ trunc_width = 75 })
        return sl.combine_groups({
          { hl = mode_hl, strings = { mode } },
          { hl = 'MiniStatuslineDevinfo', strings = { progress(), git, diff } },
          '%<',
          { hl = 'MiniStatuslineFilename', strings = { filename } },
          '%=',
          { hl = 'MiniStatuslineFilename', strings = { diagnostics, selection(), search } },
          { hl = 'MiniStatuslineFileinfo', strings = { sl.is_truncated(100) and '' or fileinfo() } },
          { hl = mode_hl, strings = { '%l:%v' } },
        })
      end,
    },
  })
end)

-- Bufferline, always shown (helix: bufferline = "always"). [b ]b cycle,
-- <leader>b picks, <leader>qb closes a buffer and keeps the window layout.
util.setup('mini.tabline', function(tl)
  tl.setup({ tabpage_section = 'right' })
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
        { mode = 'n', keys = '<Leader>m', desc = '+make/run' },
        { mode = 'n', keys = '<Leader>q', desc = '+buffer/session' },
        { mode = 'n', keys = '<Leader>u', desc = '+toggle' },
        { mode = 'n', keys = '<Leader>x', desc = '+diagnostics/lists' },
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

-- TODO/FIXME/HACK/NOTE and #rrggbb highlighting in any buffer (<leader>xt lists them).
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

-- Sticky header: the enclosing namespace/class/function stays on screen
-- (at most 3 lines). <leader>uc toggles.
util.later(function()
  util.setup('treesitter-context', function(ctx)
    ctx.setup({ max_lines = 3, multiline_threshold = 1, trim_scope = 'outer' })
  end)
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
