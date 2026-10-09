-- Debugging: nvim-dap + nvim-dap-view, loaded on the first debug key or :Dap*.
--
-- Adapters (no downloads: both debuggers are already on every host):
--   gdb  — GDB's own DAP server (`gdb -i=dap`, GDB 14+). `gdb` on PATH is
--          pwndbg's GDB 17 on every host (EL8's /usr/bin/gdb 8.2 has no DAP).
--          -nx skips ~/.gdbinit: GEF would turn values to hex and run its
--          context display at every stop. The -iex lines keep what DAP needs
--          from it: the distro's libstdc++ pretty printers and libthread_db.
--   lldb — /usr/bin/lldb-dap from dnf (LLVM).
local M = {}
local loaded = false

local gdb_args = {
  '-nx',
  '-q',
  '-iex', 'set debuginfod enabled off', -- no network lookups stalling a launch
  '-iex', 'add-auto-load-safe-path /usr/share/gdb/auto-load',
  '-iex', 'add-auto-load-scripts-directory /usr/share/gdb/auto-load',
  '-iex', 'add-auto-load-safe-path /usr/lib64/libthread_db.so.1',
  '-iex', 'set print pretty on',
  '-iex', 'set print object on',
  '-i=dap',
}

--- First gdb with DAP support (GDB 14+): PATH (pwndbg's GDB 17), then the system one.
local function find_gdb()
  for _, cand in ipairs({ 'gdb', '/usr/bin/gdb' }) do
    local exe = vim.fn.exepath(cand)
    if exe ~= '' then
      local out = vim.system({ exe, '--version' }, { text = true }):wait(3000).stdout or ''
      local major = tonumber((out:match('[^\n]-(%d+)%.%d+') or ''))
      if major and major >= 14 then
        return exe
      end
    end
  end
end

--- Pick the executable: nvim-dap's picker (fzf-lua via vim.ui.select) over
--- executables under the project's build/ (else the project root), without
--- CMake's probe binaries, shared libraries and VCS/cache dirs.
local function pick_program()
  local root = require('ws.util').root()
  local dir = vim.uv.fs_stat(root .. '/build') and (root .. '/build') or root
  return require('dap.utils').pick_file({
    path = dir,
    executables = true,
    filter = function(p)
      return not (p:find('/CMakeFiles/', 1, true) or p:find('/%.git/') or p:find('/%.cache/')
        or p:match('%.so[%.%d]*$') or p:match('%.sh$'))
    end,
  })
end

local function ask_args()
  local s = vim.fn.input('Arguments: ')
  return require('dap.utils').splitstr(s)
end

function M.load()
  if loaded then
    return require('dap')
  end
  vim.cmd.packadd('nvim-dap')
  vim.cmd.packadd('nvim-dap-view')
  local dap = require('dap')
  loaded = true

  local gdb = find_gdb()
  if gdb then
    dap.adapters.gdb = { type = 'executable', command = gdb, args = gdb_args, id = 'gdb' }
  end
  local lldb = vim.fn.exepath('lldb-dap')
  if lldb ~= '' then
    dap.adapters.lldb = { type = 'executable', command = lldb, name = 'lldb' }
  end

  local configs = {}
  if gdb then
    vim.list_extend(configs, {
      {
        name = 'gdb: launch',
        type = 'gdb',
        request = 'launch',
        program = pick_program,
        cwd = '${workspaceFolder}',
        stopAtBeginningOfMainSubprogram = false,
      },
      {
        name = 'gdb: launch with arguments',
        type = 'gdb',
        request = 'launch',
        program = pick_program,
        args = ask_args,
        cwd = '${workspaceFolder}',
      },
      {
        name = 'gdb: attach to process',
        type = 'gdb',
        request = 'attach',
        pid = function()
          return require('dap.utils').pick_process()
        end,
        cwd = '${workspaceFolder}',
      },
      {
        name = 'gdb: attach to gdbserver',
        type = 'gdb',
        request = 'attach',
        target = function()
          return vim.fn.input('gdbserver host:port: ', 'localhost:1234')
        end,
        program = pick_program,
        cwd = '${workspaceFolder}',
      },
    })
  end
  if lldb ~= '' then
    vim.list_extend(configs, {
      {
        name = 'lldb: launch',
        type = 'lldb',
        request = 'launch',
        program = pick_program,
        args = {},
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
      },
      {
        name = 'lldb: attach to process',
        type = 'lldb',
        request = 'attach',
        pid = function()
          return require('dap.utils').pick_process()
        end,
      },
    })
  end
  for _, ft in ipairs({ 'c', 'cpp', 'rust' }) do
    dap.configurations[ft] = configs
  end

  vim.fn.sign_define('DapBreakpoint', { text = '●', texthl = 'DapBreakpoint' })
  vim.fn.sign_define('DapBreakpointCondition', { text = '◆', texthl = 'DapBreakpointCondition' })
  vim.fn.sign_define('DapLogPoint', { text = '◉', texthl = 'DapLogPoint' })
  vim.fn.sign_define('DapBreakpointRejected', { text = '○', texthl = 'DapBreakpointRejected' })
  vim.fn.sign_define('DapStopped', { text = '→', texthl = 'DapStopped', linehl = 'DapStoppedLine' })

  require('ws.util').setup('dap-view', function(view)
    view.setup({
      auto_toggle = true, -- opens with a session, closes after it
      virtual_text = { enabled = true }, -- variable values inline, at their use
    })
  end)
  return dap
end

-- Keys: VS Code's F-keys plus a <leader>d group (helix has no debugger keys).
local function with_dap(fn)
  return function()
    fn(M.load())
  end
end

local maps = {
  { '<F5>', function(d) d.continue() end, 'Debug: start/continue' },
  { '<F9>', function(d) d.toggle_breakpoint() end, 'Debug: toggle breakpoint' },
  { '<F10>', function(d) d.step_over() end, 'Debug: step over' },
  { '<F11>', function(d) d.step_into() end, 'Debug: step into' },
  { '<F12>', function(d) d.step_out() end, 'Debug: step out' },
  { '<leader>dc', function(d) d.continue() end, 'Start/continue' },
  { '<leader>db', function(d) d.toggle_breakpoint() end, 'Toggle breakpoint' },
  { '<leader>dB', function(d) d.set_breakpoint(vim.fn.input('Condition: ')) end, 'Conditional breakpoint' },
  { '<leader>dl', function(d) d.set_breakpoint(nil, nil, vim.fn.input('Log message: ')) end, 'Log point' },
  { '<leader>dn', function(d) d.step_over() end, 'Step over (next)' },
  { '<leader>di', function(d) d.step_into() end, 'Step into' },
  { '<leader>do', function(d) d.step_out() end, 'Step out' },
  { '<leader>dC', function(d) d.run_to_cursor() end, 'Run to cursor' },
  { '<leader>dr', function(d) d.run_last() end, 'Re-run last' },
  { '<leader>dp', function(d) d.pause() end, 'Pause' },
  { '<leader>dt', function(d) d.terminate() end, 'Terminate' },
  { '<leader>dk', function(d) d.up() end, 'Frame up' },
  { '<leader>dj', function(d) d.down() end, 'Frame down' },
  { '<leader>dv', function() vim.cmd('DapViewToggle') end, 'Toggle debug view' },
  { '<leader>dw', function() vim.cmd('DapViewWatch') end, 'Watch expression under cursor' },
}
for _, m in ipairs(maps) do
  vim.keymap.set('n', m[1], with_dap(m[2]), { desc = m[3] })
end
vim.keymap.set({ 'n', 'x' }, '<leader>de', function()
  M.load()
  require('dap.ui.widgets').hover()
end, { desc = 'Evaluate expression' })

vim.api.nvim_create_user_command('DapLoad', function()
  M.load()
end, { desc = 'Load nvim-dap and the C/C++ debug configurations' })

return M
