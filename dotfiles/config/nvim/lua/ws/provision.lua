-- Headless provisioning, run by the mise task `nvim-plugins`:
--   nvim --headless --cmd 'let g:ws_pack_install = 1' -c "lua require('ws.provision').run()"
-- 1. g:ws_pack_install lets init.lua's vim.pack.add() install missing plugins
--    at the lockfile's commits; here plugins already on disk are moved to the
--    lockfile too (after `wsu` pulled a new one).
-- 2. blink.cmp's prebuilt fuzzy library is downloaded.
-- 3. Treesitter parsers are built (skipped, not failed, without cc/tree-sitter).
-- Exits non-zero only when something that should have worked failed.
local M = {}

local function say(fmt, ...)
  io.stdout:write(('nvim-plugins: ' .. fmt .. '\n'):format(...))
end

function M.run()
  local failed = false

  -- 1. plugins at lockfile revisions (the lockfile on disk is the truth:
  -- vim.pack's own list empties itself when installs fail)
  local missing = require('ws.plugins').missing_locked()
  if #missing > 0 then
    failed = true
    say('%d plugin(s) not installed (offline?): %s', #missing, table.concat(missing, ', '))
  else
    local ok, err = pcall(vim.pack.update, nil, { target = 'lockfile', force = true })
    if not ok then
      failed = true
      say('could not move plugins to the lockfile: %s', err)
    end
    say('%d plugins at lockfile revisions', #vim.pack.get(nil, { info = false }))
  end

  -- 2. blink.cmp fuzzy library (prebuilt, from the plugin's GitHub release)
  local dl_ok, download = pcall(require, 'blink.cmp.fuzzy.download')
  if dl_ok then
    local done, dl_err, impl = false, nil, nil
    download.ensure_downloaded(function(e, i)
      done, dl_err, impl = true, e, i
    end)
    vim.wait(120000, function()
      return done
    end, 200)
    if dl_err or not done then
      say('blink.cmp fuzzy library: %s (Lua matcher will be used)', dl_err or 'timeout')
    else
      say('blink.cmp fuzzy matcher: %s', impl or 'rust')
    end
  end

  -- 3. treesitter parsers
  local ts = require('ws.treesitter')
  local ok, why = ts.install_sync(900000)
  io.stdout:write('\n')
  if why then
    say('treesitter: %s', why)
  elseif not ok then
    failed = true
    say('treesitter: some parsers failed to build (:checkhealth nvim-treesitter)')
  else
    say('treesitter: %d parsers ready', #ts.parsers)
  end

  vim.cmd(failed and 'cquit 1' or 'qall!')
end

return M
