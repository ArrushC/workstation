-- IDE layout: a file tree on the left (nvim-tree), the outline of the current
-- window on the right (aerial), breadcrumbs in each editor's winbar (dropbar)
-- and a terminal panel at the bottom (:terminal, kept running while hidden).
--
--   <leader>E tree   <leader>o outline   <C-/> or <leader>T terminal
--   <leader>ui both side panels   <leader>p projects   <leader>; breadcrumbs
--
-- Layout and session: started in a project (`nvim`, `nvim <dir>`, `nvim file`),
-- the side panels that were open last time in that project reopen; a project
-- seen for the first time gets the tree from 100 columns and the outline from
-- 160. A bare `nvim` or `nvim <dir>` also restores the directory's session
-- (ws.autocmds saves it on exit), else shows a start screen (mini.starter);
-- `vim.g.ws_session_autoload = false` in lua/ws/local.lua turns that off.
local util = require('ws.util')
local M = {}
local api = vim.api
local win32 = vim.fn.has('win32') == 1

-- Windows that are not editors: pickers never open files in them, a session
-- save closes them, and :q in the last editor window closes them too.
M.panel_ft = {
  NvimTree = true,
  aerial = true,
  qf = true,
  ['dap-view'] = true,
  ['dap-repl'] = true,
  ['dap-view-term'] = true,
  DiffviewFiles = true,
  DiffviewFileHistory = true,
}

function M.is_panel(win)
  local buf = api.nvim_win_get_buf(win)
  return M.panel_ft[vim.bo[buf].filetype] or vim.b[buf].ws_term == true or api.nvim_win_get_config(win).relative ~= ''
end

--- The window to open files in: the current one unless it is a panel, else
--- the previous window, else the first editor window.
function M.editor_win()
  local cur = api.nvim_get_current_win()
  if not M.is_panel(cur) then
    return cur
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= 0 and not M.is_panel(prev) then
    return prev
  end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if not M.is_panel(w) then
      return w
    end
  end
  return cur
end

--- Move to the editor window first (ws.keymaps' pickers call this).
function M.to_editor()
  local w = M.editor_win()
  if w ~= api.nvim_get_current_win() then
    api.nvim_set_current_win(w)
  end
end

--- packadd + set up an on-demand plugin once; the module, or nil.
local loaded = {}
function M.pack(name, mod, setup)
  if loaded[name] == nil then
    loaded[name] = pcall(vim.cmd.packadd, name) and util.setup(mod, setup) ~= nil
  end
  return loaded[name] and require(mod) or nil
end

---------------------------------------------------------------------------
-- Tree: nvim-tree. oil stays the directory buffer (`-`, <leader>e).
---------------------------------------------------------------------------
local tree ---@type table?

--- Watch nothing in build trees (:Make churns them), on WSL's /mnt drives, or
--- outside the working directory on Windows: nvim-tree warns that watchers
--- are slow there (:h nvim-tree-os-specific). R refreshes by hand.
local function unwatched(path)
  local p = path:gsub('\\', '/') .. '/'
  if p:find('/build/', 1, true) or p:find('/.cache/', 1, true) or p:find('/.git/', 1, true) or p:match('^/mnt/') then
    return true
  end
  if win32 then
    local cwd = vim.fs.normalize(vim.fn.getcwd()):lower()
    return not vim.startswith(p:lower(), cwd)
  end
  return false
end

local function setup_tree()
  tree = util.setup('nvim-tree', function(nt)
    nt.setup({
      hijack_netrw = false,
      disable_netrw = false,
      hijack_directories = { enable = false },
      hijack_cursor = true,
      sync_root_with_cwd = true, -- the root follows :cd (and project switches)
      update_focused_file = { enable = true }, -- follow the current file
      view = { width = 32, preserve_window_proportions = true },
      renderer = {
        group_empty = true, -- src/a/b on one line
        root_folder_label = ':t',
        highlight_git = 'name',
        highlight_opened_files = 'name',
        highlight_modified = 'icon',
        indent_markers = { enable = true },
        icons = { git_placement = 'after', diagnostics_placement = 'after', modified_placement = 'after' },
      },
      diagnostics = {
        enable = true,
        show_on_dirs = true,
        show_on_open_dirs = false,
        icons = { error = '\u{f057}', warning = '\u{f071}', info = '\u{f05a}', hint = '\u{f0eb}' },
      },
      modified = { enable = true },
      git = { enable = true, timeout = 500 },
      filesystem_watchers = { ignore_dirs = unwatched },
      filters = { git_ignored = false, custom = { '^\\.git$' } }, -- build/ shows, dimmed
      actions = {
        change_dir = { global = false },
        open_file = {
          window_picker = {
            enable = true,
            -- the start screen (nofile) is a fine target; panels are not
            exclude = { filetype = vim.tbl_keys(M.panel_ft), buftype = { 'terminal', 'help' } },
          },
        },
      },
      on_attach = function(buf)
        local tapi = require('nvim-tree.api')
        tapi.config.mappings.default_on_attach(buf)
        vim.keymap.set('n', '?', tapi.tree.toggle_help, { buffer = buf, desc = 'nvim-tree: help' })
        vim.keymap.set('n', 'q', tapi.tree.close, { buffer = buf, desc = 'nvim-tree: close' })
      end,
    })
  end)
end
-- After the first screen; on_enter (below) is scheduled after this one.
util.later(setup_tree)

function M.tree_open(focus)
  if not tree then
    return
  end
  local tapi = require('nvim-tree.api')
  if not tapi.tree.is_visible() then
    tapi.tree.toggle({ focus = focus, find_file = true }) -- open() always focuses
  elseif focus then
    tapi.tree.focus()
  end
end

vim.keymap.set('n', '<leader>E', function()
  if tree then
    require('nvim-tree.api').tree.toggle({ focus = false, find_file = true })
  end
end, { desc = 'File tree (toggle)' })

-- mini.tabline spans the whole width; with the tree open, start the buffer
-- tabs after it. `%<` cuts what does not fit from the left of mini's string,
-- which keeps the current buffer (mini centres it) in view.
util.later(function()
  if not _G.MiniTabline then
    return
  end
  function M.tabline()
    local s = MiniTabline.make_tabline_string()
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if vim.bo[api.nvim_win_get_buf(w)].filetype == 'NvimTree' and api.nvim_win_get_position(w)[2] == 0 then
        local width = api.nvim_win_get_width(w) + 1 -- + the separator column
        local title = (' Explorer'):sub(1, width)
        return '%#MiniTablineFill#' .. title .. string.rep(' ', width - #title) .. '%<' .. s
      end
    end
    return s
  end
  vim.o.tabline = "%!v:lua.require'ws.ide'.tabline()"
  api.nvim_create_autocmd({ 'WinNew', 'WinClosed', 'WinResized' }, {
    group = api.nvim_create_augroup('ws.ide.tabline', { clear = true }),
    callback = function()
      vim.schedule(vim.cmd.redrawtabline)
    end,
  })
end)

---------------------------------------------------------------------------
-- Outline: aerial (LSP symbols, treesitter without a server). It follows the
-- current window and stays open on buffers without symbols.
---------------------------------------------------------------------------
function M.aerial()
  return M.pack('aerial.nvim', 'aerial', function(a)
    a.setup({
      backends = { 'lsp', 'treesitter', 'markdown', 'man' },
      attach_mode = 'global',
      layout = { default_direction = 'right', placement = 'edge', min_width = 28, max_width = { 40, 0.2 } },
      close_automatic_events = {},
      show_guides = true,
      highlight_on_hover = true,
      filter_kind = {
        'Class', 'Constructor', 'Enum', 'Function', 'Interface', 'Method', 'Module',
        'Namespace', 'Struct', 'Field',
      },
      ignore = { filetypes = vim.tbl_keys(M.panel_ft) },
    })
  end)
end

vim.keymap.set('n', '<leader>o', function()
  local a = M.aerial()
  if a then
    a.toggle({ focus = false })
  end
end, { desc = 'Outline (toggle)' })

---------------------------------------------------------------------------
-- Breadcrumbs: dropbar in the winbar of editor windows.
---------------------------------------------------------------------------
util.setup('dropbar', function(db)
  -- Editors only: the default also takes terminals and, on 0.12, any buffer
  -- (vim.treesitter.get_parser() returns nil instead of failing).
  local default_enable = require('dropbar.configs').opts.bar.enable
  db.setup({
    bar = {
      enable = function(buf, win, info)
        return vim.bo[buf].buftype == '' and not M.panel_ft[vim.bo[buf].filetype] and default_enable(buf, win, info)
      end,
    },
  })
  local dapi = require('dropbar.api')
  vim.keymap.set('n', '<leader>;', dapi.pick, { desc = 'Breadcrumbs: pick' })
  vim.keymap.set('n', '[;', dapi.goto_context_start, { desc = 'Start of current context' })
  vim.keymap.set('n', '];', dapi.select_next_context, { desc = 'Breadcrumbs: next context' })
end)

---------------------------------------------------------------------------
-- Terminal: one shell in a bottom panel. <C-/> (terminals send <C-_>) in
-- normal mode or inside the panel: hidden -> open, open -> focus, focused ->
-- hide. <Esc><Esc> leaves terminal mode.
-- Shell: Linux 'shell' ($SHELL); Windows nu, else pwsh, else 'shell' (cmd),
-- without changing 'shell' itself (:Make and :! keep cmd.exe quoting).
-- vim.g.ws_term_cmd (a list) overrides it.
---------------------------------------------------------------------------
local term = { height = 12 }

local function term_cmd()
  if vim.g.ws_term_cmd then
    return vim.g.ws_term_cmd
  end
  if win32 then
    for _, cmd in ipairs({ { 'nu' }, { 'pwsh', '-NoLogo' }, { 'powershell', '-NoLogo' } }) do
      if vim.fn.executable(cmd[1]) == 1 then
        return cmd
      end
    end
  end
end

function M.terminal()
  local open = term.win and api.nvim_win_is_valid(term.win)
  if open and api.nvim_get_current_win() == term.win then
    term.height = api.nvim_win_get_height(term.win)
    api.nvim_win_hide(term.win)
    term.win = nil
    if term.prev and api.nvim_win_is_valid(term.prev) then
      api.nvim_set_current_win(term.prev) -- back where <C-/> was pressed
    end
    return
  end
  term.prev = api.nvim_get_current_win()
  if open then
    api.nvim_set_current_win(term.win)
    return vim.cmd.startinsert()
  end
  local fresh = not (term.buf and api.nvim_buf_is_valid(term.buf))
  if fresh then
    term.buf = api.nvim_create_buf(false, false)
  end
  term.win = api.nvim_open_win(term.buf, true, { split = 'below', win = -1, height = term.height })
  if fresh then
    local cmd = term_cmd()
    if cmd then
      vim.fn.jobstart(cmd, { term = true })
    else
      local placeholder = term.buf
      vim.cmd.terminal() -- 'shell'
      term.buf = api.nvim_get_current_buf()
      if placeholder ~= term.buf then -- :terminal reuses an empty buffer
        pcall(api.nvim_buf_delete, placeholder, { force = true })
      end
    end
    vim.bo[term.buf].buflisted = false
    vim.b[term.buf].ws_term = true
    for _, lhs in ipairs({ '<C-/>', '<C-_>' }) do -- terminal mode: this buffer only
      vim.keymap.set('t', lhs, M.terminal, { buffer = term.buf, desc = 'Terminal (toggle)' })
    end
  end
  local wo = vim.wo[term.win][0]
  wo.winfixheight, wo.winfixbuf = true, true
  wo.number, wo.relativenumber, wo.signcolumn = false, false, 'no'
  vim.cmd.startinsert()
end

vim.keymap.set('n', '<C-/>', M.terminal, { desc = 'Terminal (toggle)' })
vim.keymap.set('n', '<C-_>', M.terminal, { desc = 'Terminal (toggle)' })
vim.keymap.set('n', '<leader>T', M.terminal, { desc = 'Terminal (toggle)' })

---------------------------------------------------------------------------
-- Layout memory: the side panels open per project root, and when the project
-- was last used (the <leader>p list). stdpath('state')/ws-layout.json.
---------------------------------------------------------------------------
local state_file = vim.fs.joinpath(vim.fn.stdpath('state'), 'ws-layout.json')
local markers = { '.git', 'compile_commands.json', 'CMakeLists.txt', 'meson.build', 'Makefile', '.clangd' }

--- Project root of the working directory (vim.fs paths: `/` on Windows too),
--- or nil: no marker, or the home directory itself.
function M.root()
  local r = vim.fs.root(vim.fn.getcwd(), markers)
  if r and vim.fs.normalize(r):lower() ~= vim.fs.normalize(vim.uv.os_homedir()):lower() then
    return vim.fs.normalize(r)
  end
end

local function read_state()
  local f = io.open(state_file, 'r')
  if not f then
    return {}
  end
  local ok, t = pcall(vim.json.decode, f:read('*a'))
  f:close()
  return ok and type(t) == 'table' and t or {}
end

local function write_state(t)
  vim.fn.mkdir(vim.fs.dirname(state_file), 'p')
  local f = io.open(state_file, 'w')
  if f then
    f:write(vim.json.encode(t))
    f:close()
  end
end

function M.open_panels()
  local open = { tree = false, outline = false }
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    local ft = vim.bo[api.nvim_win_get_buf(w)].filetype
    if ft == 'NvimTree' then
      open.tree = true
    elseif ft == 'aerial' then
      open.outline = true
    end
  end
  return open
end

local function close_panels()
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(w) and M.is_panel(w) then
      pcall(api.nvim_win_close, w, false)
    end
  end
end

local saved_on_quit = false
-- Set once this session manages the layout (on_enter in a project, or a
-- project switch): headless runs, `nvim -d`, commit messages and the like
-- never overwrite a project's remembered panels.
local active = false

function M.save_layout()
  local root = active and #api.nvim_list_uis() > 0 and M.root()
  if root then
    local st = read_state()
    st[root] = vim.tbl_extend('force', M.open_panels(), { last = os.time() })
    write_state(st)
  end
end

--- ws.autocmds calls this before :mksession (exit, project switch).
function M.before_session_save()
  if not saved_on_quit then -- QuitPre saved it already, then closed the panels
    M.save_layout()
  end
  close_panels()
end

--- Open the side panels this project had last time (or the defaults).
function M.restore_panels(root)
  local st = read_state()[root] or { tree = vim.o.columns >= 100, outline = vim.o.columns >= 160 }
  if st.tree then
    M.tree_open(false)
  end
  if st.outline then
    local a = M.aerial()
    if a then
      a.open({ focus = false })
    end
  end
end

vim.keymap.set('n', '<leader>ui', function()
  local open = M.open_panels()
  if open.tree or open.outline then
    if tree then
      require('nvim-tree.api').tree.close()
    end
    if open.outline then
      M.aerial().close_all()
    end
  else
    M.tree_open(false)
    local a = M.aerial()
    if a then
      a.open({ focus = false })
    end
  end
end, { desc = 'Toggle side panels (tree + outline)' })

---------------------------------------------------------------------------
-- Start screen: mini.starter, when there is no session to restore.
---------------------------------------------------------------------------
function M.starter()
  local st = util.setup('mini.starter', function(s)
    s.setup({
      autoopen = false,
      evaluate_single = true,
      header = function()
        local root = M.root()
        return '\u{f07c}  ' .. vim.fn.fnamemodify(root or vim.fn.getcwd(), ':~')
      end,
      items = {
        s.sections.recent_files(9, true, false),
        {
          { name = 'Find file', action = 'lua require("ws.ide").to_editor(); require("fzf-lua").files()', section = 'Actions' },
          { name = 'Grep', action = 'lua require("fzf-lua").live_grep()', section = 'Actions' },
          { name = 'Projects', action = 'lua require("ws.ide").projects()', section = 'Actions' },
          { name = 'Build (:Make)', action = 'Make', section = 'Actions' },
          { name = 'Quit', action = 'qall', section = 'Actions' },
        },
      },
      footer = '',
    })
  end)
  if st then
    st.open()
  end
end

---------------------------------------------------------------------------
-- Projects: the roots in the layout state, most recently used first.
---------------------------------------------------------------------------
local function restore_session()
  local file = require('ws.autocmds').session_file()
  if vim.uv.fs_stat(file) then
    vim.cmd('silent! source ' .. vim.fn.fnameescape(file))
    return true
  end
end

--- Save this project, close its buffers, cd to `dir`, then restore its
--- session (or the start screen) and its panels.
function M.open_project(dir)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if vim.bo[b].modified and vim.bo[b].buftype == '' then
      return vim.notify('unsaved changes: save them first', vim.log.levels.WARN)
    end
  end
  require('ws.autocmds').save_session()
  close_panels()
  vim.cmd.enew()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and b ~= api.nvim_get_current_buf() then
      pcall(api.nvim_buf_delete, b, {})
    end
  end
  vim.cmd('silent cd ' .. vim.fn.fnameescape(dir))
  active = true
  if not restore_session() then
    M.starter()
  end
  M.restore_panels(M.root() or vim.fs.normalize(dir))
end

function M.projects()
  local items = {}
  for root, st in pairs(read_state()) do
    if vim.fn.isdirectory(root) == 1 then
      items[#items + 1] = { dir = root, last = type(st) == 'table' and st.last or 0 }
    end
  end
  table.sort(items, function(a, b)
    return a.last > b.last
  end)
  if #items == 0 then
    return vim.notify('no projects yet: they are listed after their first session')
  end
  vim.ui.select(items, {
    prompt = 'Project',
    format_item = function(it)
      return vim.fn.fnamemodify(it.dir, ':~')
    end,
  }, function(it)
    if it then
      M.open_project(it.dir)
    end
  end)
end
vim.keymap.set('n', '<leader>p', M.projects, { desc = 'Projects (switch)' })

---------------------------------------------------------------------------
-- Startup and exit.
---------------------------------------------------------------------------
local group = api.nvim_create_augroup('ws.ide', { clear = true })

api.nvim_create_autocmd('StdinReadPre', {
  group = group,
  callback = function()
    vim.g.ws_stdin = true
  end,
})

local skip_ft = { gitcommit = true, gitrebase = true, diff = true, help = true, man = true }

function M.on_enter()
  if #api.nvim_list_uis() == 0 or vim.o.diff or vim.g.ws_stdin or vim.g.ws_ide == false then
    return
  end
  local argc = vim.fn.argc()
  local dir_arg = vim.g.ws_start_dir ~= nil -- init.lua, before oil renamed it
  if dir_arg then
    vim.cmd('silent cd ' .. vim.fn.fnameescape(vim.g.ws_start_dir))
  elseif argc > 0 and skip_ft[vim.bo.filetype] then
    return
  end
  local root = M.root()
  if not root then
    return
  end
  active = true
  if argc == 0 or dir_arg then
    local dirbuf = dir_arg and api.nvim_get_current_buf() or nil
    if not (vim.g.ws_session_autoload ~= false and restore_session()) then
      M.starter() -- a new buffer in this window, replacing the directory
    end
    if dirbuf and api.nvim_buf_is_valid(dirbuf) and dirbuf ~= api.nvim_get_current_buf() then
      pcall(api.nvim_buf_delete, dirbuf, { force = true })
    end
  end
  M.restore_panels(root)
  api.nvim_exec_autocmds('User', { pattern = 'WsIdeReady' })
end

api.nvim_create_autocmd('VimEnter', {
  group = group,
  callback = function()
    vim.schedule(function()
      local ok, err = xpcall(M.on_enter, debug.traceback)
      if not ok then
        vim.notify('ws.ide startup: ' .. err, vim.log.levels.WARN)
      end
    end)
  end,
})

api.nvim_create_autocmd('WinEnter', {
  group = group,
  callback = function()
    saved_on_quit = false -- Neovim kept running after QuitPre (another tab)
  end,
})

api.nvim_create_autocmd('QuitPre', {
  group = group,
  desc = 'Closing the last editor window closes the panels too',
  callback = function()
    local cur = api.nvim_get_current_win()
    if M.is_panel(cur) then
      return
    end
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if w ~= cur and not M.is_panel(w) then
        return -- another editor window stays
      end
    end
    for _, b in ipairs(api.nvim_list_bufs()) do
      if vim.bo[b].modified and vim.bo[b].buftype == '' then
        return -- :q stops at E37 and the layout stays; :q! exits with it
      end
    end
    M.save_layout() -- now: VimLeavePre would see the panels closed
    saved_on_quit = true
    for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
      if w ~= cur then
        pcall(api.nvim_win_close, w, false)
      end
    end
  end,
})

return M
