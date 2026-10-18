-- Minimal init for real-startup checks of mappings and directory interception.
-- Load with `-u`, not as a file argument: Neovim edits positional paths rather
-- than sourcing them. The environment flag selects the mapping option.

local source = debug.getinfo(1, 'S').source:gsub('^@', '')
-- <repo>/tests/fixtures/live_init.lua -> <repo>
local repo = vim.fn.fnamemodify(source, ':p:h:h:h')
vim.opt.runtimepath:prepend(repo)

if vim.env.DIRECT_LIVE_MAP_DEFAULT_KEYS == 'false' then
  require('direct').setup({ map_default_keys = false })
end
