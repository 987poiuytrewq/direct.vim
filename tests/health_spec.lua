-- tests/health_spec.lua -- `:checkhealth direct` (spec section 5 / T-027 / D1).
--
-- `:checkhealth direct` loads `lua/direct/health.lua`, opens the `health://`
-- buffer and fills it with the report. Under `--headless` it also writes a
-- progress line to stdout; the report itself lives in the buffer. This file
-- asserts the two facts T-027 requires: the Neovim version against the 0.11
-- floor, and the resolved data directory (B9).

local H = require('tests.support.harness')

H.describe('health: :checkhealth direct (T-027)', function()
  H.it('reports the Neovim version floor and the resolved data directory (T-027)', function()
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
