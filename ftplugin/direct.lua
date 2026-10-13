-- ftplugin/direct.lua -- buffer-local mappings for filetype=direct (T-026).
--
-- The nine mappings installed by the retired `ftplugin/direct.vim`, rebuilt on
-- `<Cmd>` (never a `:` command that would leave visual mode / re-trigger
-- mappings) and installed only when `map_default_keys` is true (section 6).
--
-- Only defines mappings: no commands, no autocmds. Reachable under
-- `nvim --headless -l` only because the harness ran `filetype plugin on`
-- (T-002, reviewer B3) -- with filetype plugins off this file never loads and an
-- assertion here would be vacuously green.

local config = require('direct.config')

if not config.options.map_default_keys then
  return
end

local opts = { buffer = true, silent = true, noremap = true }

-- Buffer-local `-` wins over the global `-` inside a direct buffer, which is why
-- the global mapping resolving to `getcwd()` there is never observable.
vim.keymap.set('n', '<CR>', '<Cmd>lua require("direct").open()<CR>', opts)
vim.keymap.set('n', '-', '<Cmd>lua require("direct").open("../")<CR>', opts)
vim.keymap.set('n', 'u', '<Cmd>DirectUndo<CR>', opts)
vim.keymap.set('n', '<C-r>', '<Cmd>DirectRedo<CR>', opts)
vim.keymap.set('n', 'yy', '<Cmd>DirectYank<CR>', opts)
vim.keymap.set('n', 'Y', '<Cmd>DirectYank<CR>', opts)
-- Visual `y`: a ranged command (`:<C-U>'<,'>DirectYank<CR>`) raises E20 and
-- unsets the marks here, so the Lua entry point is called with the visual range
-- (start from `'v'`, end from the cursor); `M.yank` normalises the order.
vim.keymap.set('v', 'y',
  '<Cmd>lua require("direct").yank(vim.fn.line("v"), vim.fn.line("."))<CR>', opts)
vim.keymap.set('n', 'p', '<Cmd>DirectPaste<CR>', opts)
vim.keymap.set('n', 'P', '<Cmd>DirectPaste<CR>', opts)
