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
    '--query-driver=/usr/bin/gcc*,/usr/bin/g++*,/usr/bin/cc,/usr/bin/c++,/usr/bin/clang*,'
      .. '/usr/lib64/ccache/*,/opt/rh/gcc-toolset-*/root/usr/bin/*',
  },
  -- Treat a compile database as the strongest root marker, then build files, then git.
  root_markers = {
    { 'compile_commands.json', 'compile_flags.txt', '.clangd' },
    { 'CMakeLists.txt', 'meson.build', '.clang-tidy', '.clang-format' },
    '.git',
  },
  init_options = {
    fallbackFlags = { '-std=c++20' }, -- files outside any compile database
  },
}
