-- Clipboard: OSC 52, the fleet's only path from a remote zellij pane to the
-- Windows clipboard (zellij's copy_command stays unset).
--
-- Copy: OSC 52 escape to the terminal, through zellij.
-- Paste: the last text Neovim itself copied ("+y then "+p round-trips). An
-- OSC 52 *read* query blocks for up to 10 s, because zellij, Windows Terminal
-- and Warp (write_only) never answer it. Paste from Windows with the
-- terminal's paste key (bracketed paste) instead.
--
-- Set unconditionally: auto-detection (XTGETTCAP) fails behind zellij, and
-- WSL hosts have no win32yank/clip.exe on PATH (appendWindowsPath=false).
local osc52 = require('vim.ui.clipboard.osc52')

local last = { { '' }, 'v' }

local function copy(reg)
  local send = osc52.copy(reg)
  return function(lines, regtype)
    last = { vim.deepcopy(lines), regtype }
    send(lines)
  end
end

local function paste()
  return last
end

vim.g.clipboard = {
  name = 'OSC 52 (copy only)',
  copy = { ['+'] = copy('+'), ['*'] = copy('*') },
  paste = { ['+'] = paste, ['*'] = paste },
}

-- Like helix: y/d/p stay in Neovim's registers; <leader>y sends to the system
-- clipboard (see ws.keymaps). Set vim.o.clipboard = 'unnamedplus' in
-- ~/.config/nvim/lua/ws/local.lua if you want every yank sent.
