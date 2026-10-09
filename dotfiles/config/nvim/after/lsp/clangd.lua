-- clangd overrides, merged over nvim-lspconfig's lsp/clangd.lua (:h lsp-config-merge).
-- clangd and clang-tidy come from dnf (clang-tools-extra). Per-project tuning
-- belongs in the project's .clangd and .clang-tidy files.
return {
  cmd = {
    'clangd',
    '--background-index', -- whole-project index, persisted in .cache/clangd/
    '--background-index-priority=low',
    '--clang-tidy', -- diagnostics from the project's .clang-tidy
    '--header-insertion=iwyu', -- completion adds the owning #include
    '--header-insertion-decorators',
    '--completion-style=detailed', -- one item per overload, with full types
    '--function-arg-placeholders=1', -- snippet placeholders, <Tab> to the next
    '--pch-storage=memory',
    '--enable-config', -- read .clangd and ~/.config/clangd/config.yaml
    '--log=error', -- Neovim logs a server's stderr as ERROR; keep lsp.log small
    -- Let clangd ask these compilers for their system include paths, so headers
    -- resolve as the real build sees them: gcc and ccache wrappers (CMake on the
    -- fleet records /usr/lib64/ccache/c++), gcc-toolset on EL8, and clang.
    -- Windows: llvm-mingw's drivers under mise's installs (the Linux globs never
    -- match there, nor this one on Linux).
    '--query-driver=/usr/bin/gcc*,/usr/bin/g++*,/usr/bin/cc,/usr/bin/c++,/usr/bin/clang*,'
      .. '/usr/lib64/ccache/*,/opt/rh/gcc-toolset-*/root/usr/bin/*,'
      .. '**/github-mstorsjo-llvm-mingw/*/bin/*',
  },
  -- Root: a compile database is the strongest marker, then build files, then
  -- git. Never for an unnamed buffer (`:enew | set ft=cpp`): clangd cannot
  -- resolve its URI, every request on it fails, and that clangd outlives nvim.
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == '' then
      return
    end
    on_dir(vim.fs.root(bufnr, {
      { 'compile_commands.json', 'compile_flags.txt', '.clangd' },
      { 'CMakeLists.txt', 'meson.build', '.clang-tidy', '.clang-format' },
      '.git',
    }) or vim.fs.dirname(name))
  end,
  -- No fallbackFlags: clangd adds them to C files too, so `-std=c++20` put "not allowed
  -- with 'C'" on every .c file outside a compile database. Loose files get clang's
  -- defaults (C17, C++17); a compile_flags.txt sets anything else. Same as helix.
}
