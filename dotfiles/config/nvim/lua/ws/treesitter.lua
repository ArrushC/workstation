-- Treesitter: nvim-treesitter `main` installs parsers and queries; Neovim
-- itself highlights and folds. Parsers compile locally, which needs the
-- tree-sitter CLI (mise: conda:tree-sitter-cli; Windows: aqua tree-sitter) and
-- a C compiler (see M.compiler: the host's cc, else mise's zig on Linux;
-- llvm-mingw's clang on Windows). A host without them keeps Neovim's bundled
-- parsers (c, lua, vim, vimdoc, query, markdown) and regex syntax for the rest.
local util = require('ws.util')
local M = {}

M.parsers = {
  'c', 'cpp', 'cmake', 'make', 'meson', 'ninja', 'doxygen', 'asm', 'printf', 'regex',
  'lua', 'luadoc', 'vim', 'vimdoc', 'query', 'bash', 'python', 'json', 'yaml', 'toml',
  'markdown', 'markdown_inline', 'diff', 'gitcommit', 'git_rebase', 'gitignore',
}

--- The C compiler `tree-sitter build` will run, or nil. tree-sitter's cc-rs
--- runs $CC, else its platform default, so a host compiler always wins and
--- nothing here shadows it; CC/CFLAGS are set in this Neovim process only.
--- * Linux: `cc`, else gcc/clang, else mise's zig (a host with no sudo has no
---   dnf gcc). The zig CFLAGS target does two jobs: zig assumes glibc 2.31 on
---   EL8 (2.28), so its .so could need symbols EL8 lacks; and a --target in
---   CFLAGS stops cc-rs adding its own (x86_64-unknown-linux-gnu), which zig
---   cc rejects.
--- * Windows: tree-sitter.exe is an MSVC build, so cc-rs runs cl.exe unless $CC
---   names another compiler, and gives clang --target=x86_64-pc-windows-msvc,
---   which needs Visual Studio's headers. With llvm-mingw (no Visual Studio, no
---   admin) use its clang, retargeted to MinGW through cc-rs's target-scoped
---   CFLAGS (only cc-rs reads that variable, so CMake and make never see it).
function M.compiler()
  if (vim.env.CC or '') ~= '' then
    return vim.env.CC
  end
  if vim.fn.has('win32') == 1 then
    if vim.fn.executable('cl') == 1 then
      return 'cl'
    elseif vim.fn.executable('clang') == 1 then
      vim.env.CC = 'clang'
      vim.env.CFLAGS_x86_64_pc_windows_msvc = vim.env.CFLAGS_x86_64_pc_windows_msvc or '--target=x86_64-w64-mingw32'
      return vim.env.CC
    elseif vim.fn.executable('gcc') == 1 then
      vim.env.CC = 'gcc' -- a real MinGW GCC (WinLibs) needs no --target
      return vim.env.CC
    end
    return nil
  end
  if vim.fn.executable('cc') == 1 then
    return 'cc'
  end
  for _, cc in ipairs({ 'gcc', 'clang' }) do
    if vim.fn.executable(cc) == 1 then
      vim.env.CC = cc
      return cc
    end
  end
  if vim.fn.executable('zig') == 1 then
    vim.env.CC = 'zig cc'
    vim.env.CFLAGS = ('--target=%s-linux-gnu.2.28'):format(vim.uv.os_uname().machine)
    return vim.env.CC
  end
end

--- Why parsers cannot be built here, or nil when they can (it also points
--- cc-rs at the compiler, see M.compiler).
function M.missing_tools()
  local missing = {}
  if vim.fn.executable('tree-sitter') == 0 then
    table.insert(missing, 'tree-sitter CLI')
  end
  if not M.compiler() then
    table.insert(missing, vim.fn.has('win32') == 1 and 'a C compiler (mise llvm-mingw)'
      or 'a C compiler (dnf gcc, or mise zig)')
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

-- Linux: at startup, so :TSInstall/:TSUpdate get zig on a compiler-less host
-- too (elsewhere it is one executable() lookup). Windows sets CC only for
-- parser builds, so :Make's CMake never sees it.
if vim.fn.has('win32') == 0 then
  M.compiler()
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
