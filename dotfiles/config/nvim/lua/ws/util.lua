local M = {}

--- require() a plugin module. Returns nil, silently, when the plugin is not
--- installed yet (fresh or offline host); any other load error is reported.
---@param mod string
function M.try(mod)
  local ok, res = pcall(require, mod)
  if ok then
    return res
  end
  if not tostring(res):find("module '" .. mod .. "' not found", 1, true) then
    vim.notify(('loading %s failed:\n%s'):format(mod, res), vim.log.levels.WARN)
  end
end

--- Call fn(module) when the plugin is installed; report errors, never throw.
---@param mod string
---@param fn fun(m: any)
function M.setup(mod, fn)
  local m = M.try(mod)
  if not m then
    return
  end
  local ok, err = pcall(fn, m)
  if not ok then
    vim.notify(('setting up %s failed:\n%s'):format(mod, err), vim.log.levels.WARN)
  end
  return m
end

--- Run fn right after startup (after VimEnter, off the first-screen path).
---@param fn fun()
function M.later(fn)
  if vim.v.vim_did_enter == 1 then
    return vim.schedule(fn)
  end
  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = function()
      vim.schedule(fn)
    end,
  })
end

--- Root of the project that holds `buf` (compile database, build files, VCS).
---@param buf? integer
function M.root(buf)
  return vim.fs.root(buf or 0, {
    { 'compile_commands.json', 'compile_flags.txt', '.clangd' },
    { 'CMakeLists.txt', 'meson.build', 'Makefile', 'makefile' },
    '.git',
  }) or vim.fn.getcwd()
end

return M
