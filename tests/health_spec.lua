-- tests/health_spec.lua -- checks the health report's version and data directory.

local H = require('tests.support.harness')

H.describe('health: :checkhealth direct', function()
  H.it('reports the Neovim version floor and the resolved data directory', function()
    local paths = require('direct.paths')

    vim.cmd('checkhealth direct')

    local buf = vim.api.nvim_get_current_buf()
    H.assert_eq(vim.api.nvim_buf_get_name(buf), 'health://',
      'checkhealth focuses the health report buffer')
    H.assert_eq(vim.bo[buf].filetype, 'checkhealth', 'and marks it as a health buffer')

    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    H.assert_true(text:find('Neovim', 1, true) ~= nil, 'the report names Neovim')
    H.assert_true(text:find('0.11', 1, true) ~= nil, 'the report states the 0.11 floor')
    H.assert_true(text:find('OK', 1, true) ~= nil, 'the version check is OK on this runtime')
    H.assert_true(text:find('data directory: ' .. paths.data_home(), 1, true) ~= nil,
      'the report names the resolved data directory')
  end)
end)
