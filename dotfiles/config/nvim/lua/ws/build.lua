-- Build loop: asynchronous :Make into the quickfix list, parsed with Neovim's
-- gcc errorformat (gcc and clang print the same file:line:col: format).
--
--   :Make [args]   build: the 'makeprg' you set, else detected from the project
--                  (cmake --build build | meson compile -C build | make)
--   :CMakeConfigure [type]   cmake -S . -B build -G Ninja (Debug by default),
--                  with compile_commands.json for clangd
--   :Cppcheck      cppcheck over build/compile_commands.json into quickfix
--   :MakeStop      stop the running job
--   :Run [args]    run a program from build/ in a terminal split (:Run! picks again)
local util = require('ws.util')
local M = {}
local job ---@type vim.SystemObj?

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

-- gcc.vim's errorformat (gcc and clang), read once on first build without
-- changing the global option. Its %D rule follows "ninja: Entering directory",
-- so meson's build-relative paths resolve.
local efm_cache ---@type string?
local function efm()
  if not efm_cache then
    local saved = vim.go.errorformat
    vim.cmd('silent! compiler! gcc')
    efm_cache = vim.go.errorformat
    vim.go.errorformat = saved
  end
  return efm_cache
end

--- The build command for project `root`, or nil.
function M.detect(root)
  local b = root .. '/build'
  if exists(b .. '/CMakeCache.txt') then
    return 'cmake --build build'
  elseif exists(b .. '/meson-info') then
    return 'meson compile -C build'
  elseif exists(root .. '/CMakeLists.txt') then
    return M.configure_cmd('Debug') .. ' && cmake --build build'
  elseif exists(root .. '/meson.build') then
    return 'meson setup build --buildtype=debug && meson compile -C build'
  elseif exists(root .. '/Makefile') or exists(root .. '/makefile') then
    -- Windows: llvm-mingw ships GNU make as mingw32-make
    local make = vim.fn.executable('make') == 0 and vim.fn.executable('mingw32-make') == 1 and 'mingw32-make' or 'make'
    return make .. ' -j' .. #vim.uv.cpu_info()
  end
end

--- argv running `cmd` through 'shell'. 'shellcmdflag' can be several words
--- (cmd.exe: "/s /c"); passed as one argument, cmd.exe runs nothing.
local function shell_argv(cmd)
  local argv = { vim.o.shell }
  vim.list_extend(argv, vim.split(vim.o.shellcmdflag, ' ', { trimempty = true }))
  argv[#argv + 1] = cmd
  return argv
end

function M.configure_cmd(build_type)
  local gen = vim.fn.executable('ninja') == 1 and ' -G Ninja' or ''
  return ('cmake -S . -B build%s -DCMAKE_BUILD_TYPE=%s -DCMAKE_EXPORT_COMPILE_COMMANDS=ON'):format(
    gen,
    build_type or 'Debug'
  )
end

--- Run `cmd` (shell string) in `cwd`, streaming output into quickfix.
---@param cmd string
---@param opts? { cwd?: string, title?: string, on_exit?: fun(code: integer) }
function M.run(cmd, opts)
  opts = opts or {}
  if job then
    return vim.notify('a build is already running (:MakeStop)', vim.log.levels.WARN)
  end
  local cwd = opts.cwd or util.root()
  local title = opts.title or cmd
  local start = vim.uv.hrtime()
  vim.fn.setqflist({}, ' ', { title = title, lines = {}, efm = efm() })
  local qf_id = vim.fn.getqflist({ id = 0 }).id
  local pending = ''

  local function flush(data)
    if not data then
      return
    end
    local text = pending .. data
    local lines = vim.split(text, '\n', { plain = true })
    pending = table.remove(lines) -- keep a partial last line
    if #lines > 0 then
      vim.schedule(function()
        vim.fn.setqflist({}, 'a', { id = qf_id, lines = lines, efm = efm() })
      end)
    end
  end

  vim.notify('build: ' .. cmd)
  job = vim.system(shell_argv(cmd), {
    cwd = cwd,
    text = true,
    stdout = function(_, d)
      flush(d)
    end,
    stderr = function(_, d)
      flush(d)
    end,
  }, function(res)
    job = nil
    vim.schedule(function()
      if pending ~= '' then
        vim.fn.setqflist({}, 'a', { id = qf_id, lines = { pending }, efm = efm() })
      end
      local secs = (vim.uv.hrtime() - start) / 1e9
      local items = vim.fn.getqflist({ id = qf_id, items = 0 }).items
      local errors = 0
      for _, it in ipairs(items) do
        if it.valid == 1 then
          errors = errors + 1
        end
      end
      if res.code == 0 and errors == 0 then
        vim.notify(('build ok (%.1fs)'):format(secs))
      else
        vim.notify(
          ('build %s, %d quickfix entr%s (%.1fs)'):format(
            res.code == 0 and 'ok' or ('failed: exit ' .. res.code),
            errors,
            errors == 1 and 'y' or 'ies',
            secs
          ),
          res.code == 0 and vim.log.levels.WARN or vim.log.levels.ERROR
        )
        vim.cmd(res.code == 0 and 'botright cwindow' or 'botright copen')
      end
      vim.api.nvim_exec_autocmds('User', { pattern = 'WsBuildDone', data = { code = res.code } })
      if opts.on_exit then
        opts.on_exit(res.code)
      end
    end)
  end)
end

-- An explicit 'makeprg' (global, or per buffer/project) wins over detection.
local function makeprg_or_detect(root)
  local prg = vim.o.makeprg -- effective value: buffer-local if set, else global
  if prg ~= '' and prg ~= 'make' then
    return vim.fn.expandcmd(prg)
  end
  return M.detect(root)
end

vim.api.nvim_create_user_command('Make', function(a)
  vim.cmd('silent! wall')
  local root = util.root()
  local cmd = makeprg_or_detect(root)
  if not cmd then
    return vim.notify('no build system found in ' .. root, vim.log.levels.WARN)
  end
  M.run(cmd .. (a.args ~= '' and (' ' .. a.args) or ''), { cwd = root })
end, { nargs = '*', desc = 'Build asynchronously into quickfix' })

vim.api.nvim_create_user_command('CMakeConfigure', function(a)
  M.run(M.configure_cmd(a.args ~= '' and a.args or 'Debug'), { cwd = util.root() })
end, {
  nargs = '?',
  complete = function()
    return { 'Debug', 'RelWithDebInfo', 'Release', 'MinSizeRel' }
  end,
  desc = 'Configure CMake into build/ with compile_commands.json',
})

vim.api.nvim_create_user_command('Cppcheck', function()
  local root = util.root()
  local db = root .. '/build/compile_commands.json'
  local src = exists(db) and ('--project=' .. vim.fn.shellescape(db)) or '.'
  vim.fn.mkdir(root .. '/build/cppcheck', 'p') -- not `mkdir -p`: cmd.exe has no -p
  local cmd = table.concat({
    'cppcheck',
    src,
    '--enable=warning,style,performance,portability',
    '--inline-suppr --quiet --template=gcc',
    '--suppress=missingIncludeSystem',
    '--cppcheck-build-dir=build/cppcheck',
    '-j' .. #vim.uv.cpu_info(),
  }, ' ')
  M.run(cmd, { cwd = root, title = 'cppcheck' })
end, { desc = 'cppcheck the project into quickfix' })

vim.api.nvim_create_user_command('MakeStop', function()
  if job then
    job:kill(15)
  end
end, { desc = 'Stop the running build' })

--- Executables under the project's build/ (else root), without CMake's probes.
function M.executables(root)
  local dir = vim.uv.fs_stat(root .. '/build') and (root .. '/build') or root
  local out = {}
  for name, kind in vim.fs.dir(dir, {
    depth = 4,
    skip = function(d)
      local base = vim.fs.basename(d)
      return not (base == 'CMakeFiles' or base:match('^%.'))
    end,
  }) do
    local p = dir .. '/' .. name
    if kind == 'file' and not name:match('%.so[%.%d]*$') and vim.fn.executable(p) == 1 then
      out[#out + 1] = p
    end
  end
  table.sort(out)
  return out
end

local last_run ---@type string?
vim.api.nvim_create_user_command('Run', function(a)
  local root = util.root()
  local function run(exe)
    if not exe then
      return
    end
    last_run = exe
    vim.cmd('botright 15new')
    vim.fn.jobstart(vim.list_extend({ exe }, vim.split(a.args, '%s+', { trimempty = true })), {
      term = true,
      cwd = root,
    })
    vim.cmd.startinsert()
  end
  if last_run and not a.bang then
    return run(last_run)
  end
  local exes = M.executables(root)
  if #exes == 0 then
    return vim.notify('no executables under ' .. root .. '/build (:Make first)', vim.log.levels.WARN)
  end
  vim.ui.select(exes, {
    prompt = 'Run',
    format_item = function(p)
      return vim.fs.relpath(root, p) or p
    end,
  }, run)
end, { nargs = '*', bang = true, desc = 'Run a built program in a terminal split' })

vim.keymap.set('n', '<leader>mm', '<cmd>Make<cr>', { desc = 'Build (:Make)' })
vim.keymap.set('n', '<leader>mr', '<cmd>Run<cr>', { desc = 'Run program (:Run, :Run! to pick)' })
vim.keymap.set('n', '<leader>mc', '<cmd>CMakeConfigure<cr>', { desc = 'CMake configure (Debug)' })
vim.keymap.set('n', '<leader>mk', '<cmd>Cppcheck<cr>', { desc = 'cppcheck' })
vim.keymap.set('n', '<leader>mt', function()
  M.run('ctest --test-dir build --output-on-failure', { title = 'ctest' })
end, { desc = 'ctest' })
vim.keymap.set('n', '<leader>mx', '<cmd>MakeStop<cr>', { desc = 'Stop build' })

return M
