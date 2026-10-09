local o = vim.opt

-- Look: mirrors helix (relative numbers, cursorline, rulers 80/120, ╎ guides).
o.number = true
o.relativenumber = true
o.cursorline = true
o.signcolumn = 'yes' -- no text shift when diagnostics or git signs appear
o.colorcolumn = '80,120'
o.termguicolors = true -- COLORTERM=truecolor on the fleet
o.showmode = false -- the statusline shows it
o.list = true
o.listchars = { tab = '» ', trail = '·', nbsp = '␣', extends = '›', precedes = '‹' }
o.fillchars = { eob = ' ', fold = ' ', foldopen = '\u{f078}', foldclose = '\u{f054}', foldsep = ' ' }
o.wrap = false
o.linebreak = true
o.breakindent = true
o.winborder = 'rounded' -- every floating window (hover, signature, diagnostics)
o.pumheight = 12
o.scrolloff = 8
o.sidescrolloff = 8
o.splitright = true
o.splitbelow = true
o.splitkeep = 'screen'
o.mouse = 'a'
o.confirm = true
o.inccommand = 'split'
o.virtualedit = 'block'
o.jumpoptions = 'stack,view'
o.shortmess:append('IcC')
o.messagesopt = 'hit-enter,history:1000,progress:' -- LSP progress: statusline, not cmdline

-- Search
o.ignorecase = true
o.smartcase = true

-- Editing. Indent defaults suit C/C++; .editorconfig (built in) and
-- guess-indent override them per project or per file.
o.expandtab = true
o.shiftwidth = 4
o.tabstop = 4
o.softtabstop = -1
o.shiftround = true
o.smartindent = false -- cindent (C ftplugin) and indentexpr do better
o.formatoptions = 'jcroqlnt'
o.completeopt = 'menu,menuone,noselect,popup,fuzzy'

-- Files and timing
o.undofile = true -- persistent undo under stdpath('state')
o.undolevels = 10000
o.swapfile = true
o.updatetime = 250 -- CursorHold: document highlight, gitsigns
o.timeoutlen = 400
o.autoread = true

-- Folding: treesitter (set per buffer in ws.treesitter); start open.
o.foldlevel = 99
o.foldlevelstart = 99
o.foldtext = ''

-- External tools already on the fleet
if vim.fn.executable('rg') == 1 then
  o.grepprg = 'rg --vimgrep --smart-case --hidden --glob=!.git'
  o.grepformat = '%f:%l:%c:%m'
end

-- Unused providers: skip their startup probes and :checkhealth warnings.
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_node_provider = 0
