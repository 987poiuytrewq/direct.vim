-- lua/direct/health.lua -- :checkhealth direct.
-- The Neovim 0.12 floor is the only hard requirement; other lines are
-- informational.

local M = {}

function M.check()
  vim.health.start('direct')

  local version = vim.version()
  local pretty = string.format('%d.%d.%d', version.major, version.minor,
    version.patch)
  if vim.fn.has('nvim-0.12') == 1 then
    vim.health.ok('Neovim ' .. pretty .. ' (>= 0.12 required)')
  else
    vim.health.error('Neovim ' .. pretty .. ' is too old; 0.12+ is required')
  end

  local home = require('direct.paths').data_home()
  vim.health.ok('data directory: ' .. home)
end

return M
