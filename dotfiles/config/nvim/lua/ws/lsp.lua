-- LSP: Neovim's own client (vim.lsp.config / vim.lsp.enable). nvim-lspconfig
-- only supplies the lsp/<server>.lua definitions; overrides live in after/lsp/.
-- Every server below is installed by dnf or mise; a missing binary is skipped.
local util = require('ws.util')

vim.lsp.enable({
  'clangd', -- dnf clang-tools-extra
  'lua_ls',
  'basedpyright',
  'bashls',
  'yamlls',
  'jsonls',
  'taplo',
  'marksman',
  'rust_analyzer',
  'gopls',
  'ts_ls',
})

vim.diagnostic.config({
  severity_sort = true,
  underline = true,
  update_in_insert = false,
  virtual_text = { spacing = 2, source = 'if_many', prefix = '●' },
  float = { source = 'if_many' },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = '\u{f057}',
      [vim.diagnostic.severity.WARN] = '\u{f071}',
      [vim.diagnostic.severity.INFO] = '\u{f05a}',
      [vim.diagnostic.severity.HINT] = '\u{f0eb}',
    },
  },
  jump = {
    on_jump = function(_, bufnr)
      vim.diagnostic.open_float({ bufnr = bufnr, scope = 'cursor', focus = false })
    end,
  },
})

local group = vim.api.nvim_create_augroup('ws.lsp', { clear = true })

vim.api.nvim_create_autocmd('LspAttach', {
  group = group,
  callback = function(ev)
    local client = assert(vim.lsp.get_client_by_id(ev.data.client_id))
    local buf = ev.buf
    local map = function(lhs, rhs, desc, mode)
      vim.keymap.set(mode or 'n', lhs, rhs, { buffer = buf, desc = desc })
    end
    local fzf = util.try('fzf-lua')

    -- Neovim's defaults stay: K hover, grn rename, gra action, grr references,
    -- gri implementation, grt type definition, gO symbols, <C-s> signature (insert).
    map('gd', fzf and fzf.lsp_definitions or vim.lsp.buf.definition, 'Go to definition')
    map('gD', vim.lsp.buf.declaration, 'Go to declaration')
    map('<leader>a', vim.lsp.buf.code_action, 'Code action', { 'n', 'x' })
    map('<leader>r', vim.lsp.buf.rename, 'Rename symbol')
    map('<leader>k', vim.lsp.buf.hover, 'Hover')
    if fzf then
      map('grr', fzf.lsp_references, 'References')
      map('gri', fzf.lsp_implementations, 'Implementations')
      map('<leader>s', fzf.lsp_document_symbols, 'Document symbols')
      map('<leader>S', fzf.lsp_live_workspace_symbols, 'Workspace symbols')
      map('<leader>ci', fzf.lsp_incoming_calls, 'Incoming calls')
      map('<leader>co', fzf.lsp_outgoing_calls, 'Outgoing calls')
    end

    if client.name == 'clangd' then
      map('<leader>ch', '<cmd>LspClangdSwitchSourceHeader<cr>', 'Switch source/header')
      map('<leader>cI', '<cmd>LspClangdShowSymbolInfo<cr>', 'Symbol info')
      map('<leader>ct', '<cmd>ClangdTypeHierarchy<cr>', 'Type hierarchy')
      map('<leader>cA', '<cmd>ClangdAST<cr>', 'AST of current line', { 'n', 'x' })
      map('<leader>cM', '<cmd>ClangdMemoryUsage<cr>', 'clangd memory usage')
    end

    -- An unnamed buffer (`:enew | set ft=cpp`) has no URI clangd can resolve:
    -- inlay-hint and highlight requests on it only produce errors.
    local named = vim.api.nvim_buf_get_name(buf) ~= ''

    if named and client:supports_method('textDocument/inlayHint', buf) then
      vim.lsp.inlay_hint.enable(true, { bufnr = buf })
    end

    -- Highlight other uses of the symbol under the cursor.
    if named and client:supports_method('textDocument/documentHighlight', buf) then
      vim.b[buf].minicursorword_disable = true -- the server's highlight replaces mini.cursorword's
      local hl = vim.api.nvim_create_augroup('ws.lsp.highlight.' .. buf, { clear = true })
      vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
        group = hl,
        buffer = buf,
        callback = vim.lsp.buf.document_highlight,
      })
      vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufLeave' }, {
        group = hl,
        buffer = buf,
        callback = vim.lsp.buf.clear_references,
      })
    end
  end,
})

-- Server progress (clangd indexing) as Neovim progress messages: shown in the
-- statusline (vim.ui.progress_status) and as a terminal progress bar (OSC 9;4).
vim.api.nvim_create_autocmd('LspProgress', {
  group = group,
  callback = function(ev)
    local value = ev.data.params.value
    if type(value) ~= 'table' then
      return
    end
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    vim.api.nvim_echo({ { value.message or (value.kind == 'end' and 'done' or '') } }, false, {
      id = 'lsp.' .. ev.data.client_id .. '.' .. tostring(ev.data.params.token),
      kind = 'progress',
      source = 'vim.lsp',
      title = (client and client.name .. ': ' or '') .. (value.title or ''),
      status = value.kind == 'end' and 'success' or 'running',
      percent = value.percentage,
    })
  end,
})
