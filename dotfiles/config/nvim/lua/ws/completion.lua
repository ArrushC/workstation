-- Completion: blink.cmp. Its Rust fuzzy matcher is a prebuilt library that
-- blink downloads from its GitHub release (glibc 2.17, so EL8 is fine) the
-- first time it runs on a release tag; offline it falls back to Lua matching.
-- Snippets: Neovim's vim.snippet with friendly-snippets.
--
-- setup() waits for the first Insert or Cmdline mode: it spawns git to check
-- the library version (~30 ms on WSL). LSP capabilities do not wait: blink's
-- plugin/ file registers them for every server at startup.
local function setup()
  require('ws.util').setup('blink.cmp', function(blink)
    blink.setup({
      -- default preset: <C-y> accept, <C-space> open, <C-n>/<C-p> or <Up>/<Down>
      -- select, <C-e> close, <Tab>/<S-Tab> snippet jumps, <C-k> signature.
      -- In zellij, lock it (Ctrl+G) or zellij takes <C-n>/<C-p>.
      keymap = { preset = 'default' },
      appearance = { nerd_font_variant = 'mono' }, -- JetBrainsMono Nerd Font Mono
      completion = {
        accept = { auto_brackets = { enabled = true } },
        documentation = { auto_show = true, auto_show_delay_ms = 300 },
        list = { selection = { preselect = true, auto_insert = false } },
        menu = { draw = { treesitter = { 'lsp' } } },
      },
      signature = { enabled = true },
      sources = { default = { 'lsp', 'path', 'snippets', 'buffer' } },
      fuzzy = { implementation = 'prefer_rust' }, -- quiet Lua fallback offline
    })
  end)
end

vim.api.nvim_create_autocmd({ 'InsertEnter', 'CmdlineEnter' }, {
  group = vim.api.nvim_create_augroup('ws.completion', { clear = true }),
  once = true,
  callback = setup,
})
