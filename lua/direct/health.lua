-- lua/direct/health.lua -- :checkhealth direct.
-- The 0.11 floor is the only hard requirement; every other line is
-- informational, so this never reports an error for anything else.

local M = {}

function M.check()
  vim.health.start('direct')

  local version = vim.version()
  local pretty = string.format('%d.%d.%d', version.major, version.minor,
    version.patch)
  if vim.fn.has('nvim-0.11') == 1 then
    vim.health.ok('Neovim ' .. pretty .. ' (>= 0.11 required)')
  else
    vim.health.error('Neovim ' .. pretty .. ' is too old; 0.11+ is required')
  end

  local home = require('direct.paths').data_home()
  vim.health.ok('data directory: ' .. home)
end

return M
