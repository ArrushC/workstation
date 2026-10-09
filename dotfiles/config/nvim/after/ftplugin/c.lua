-- C and C++: Neovim's cpp ftplugin runs `runtime! ftplugin/c.*`, which also finds
-- this after/ file, so C++ buffers get it too. Runs after Neovim's own c ftplugin.
--
-- Typing indent: cindent with options close to clang-format's LLVM/Google
-- styles; clang-format (<leader>cf, gq, or on save where .clang-format exists)
-- has the final say.
--   :0   case labels at the switch's indent     l1  align to the case label
--   g0   public:/private: at the class indent   N-s no indent inside namespace
--   E-s  no indent inside extern "C" { }        t0  return type at column 0
--   (0   align to an open parenthesis           Ws  ...or one shiftwidth if it ends the line
--   j1   lambdas and anonymous classes as blocks
vim.opt_local.cindent = true
vim.opt_local.cinoptions = ':0,l1,g0,N-s,E-s,t0,(0,Ws,j1'

-- // line comments for gc (C99+), /// and /** */ (Doxygen) continue on <CR>.
vim.bo.commentstring = '// %s'
vim.opt_local.comments = 's1:/*,mb:*,ex:*/,:///,://!,://'
vim.opt_local.formatoptions:append('ro')

-- gf on #include "x.h" / <x.h>: search the project tree and the system headers.
vim.opt_local.path:append({ '**', '/usr/include', '/usr/local/include' })
