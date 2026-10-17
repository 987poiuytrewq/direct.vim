-- lua/direct/health.lua -- :checkhealth direct (spec section 5 / T-027 / D1).
--
-- Responsibility: report the Neovim version against the 0.12 floor (D1) and the
-- resolved data directory (B9). Fails on nothing except `nvim < 0.12`: the floor
-- is the only hard requirement. Everything else is informational.

local M = {}

-- check() is the `:checkhealth direct` entry point invoked by Neovim.
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
