-- tests/fixtures/live_init.lua -- minimal init for the 11.4 live smoke (T-029).
--
-- This file is passed with `-u`, NEVER as the file-to-edit argument (N4): naming
-- it positionally would make Neovim edit the Lua source instead of loading it.
--
-- It prepends the repo root to `runtimepath` (the invocation also does
-- `--cmd 'set rtp+=$PWD'`, this keeps the fixture self-contained), calls
-- `setup()` with the option under test, and does nothing else.
--
-- Under a real startup (unlike `nvim --headless -l`, which loads neither user
-- config nor runtimepath plugins) `filetype plugin` is on and the rtp plugins
-- load, so this is the only route to observe the D10 global `-` mapping and the
-- CLI half of the D7/B12 directory intercept.
--
-- `setup({ map_default_keys = false })` is selected by
-- `DIRECT_LIVE_MAP_DEFAULT_KEYS=false`, so one fixture serves both oracle
-- invocations without being edited between them.

local source = debug.getinfo(1, 'S').source:gsub('^@', '')
-- <repo>/tests/fixtures/live_init.lua -> <repo>
local repo = vim.fn.fnamemodify(source, ':p:h:h:h')
vim.opt.runtimepath:prepend(repo)

if vim.env.DIRECT_LIVE_MAP_DEFAULT_KEYS == 'false' then
  require('direct').setup({ map_default_keys = false })
end
