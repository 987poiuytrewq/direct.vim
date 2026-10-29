-- Generate LuaCov's compact text summary from the collected coverage statistics.
local this_file = debug.getinfo(1, 'S').source:gsub('^@', '')
local this_abs = vim.fn.fnamemodify(this_file, ':p')
local tests_dir = vim.fs.dirname(this_abs)
local root = vim.fs.dirname(tests_dir)
local rocks_lua = vim.fs.joinpath(root, '.rocks', 'share', 'lua', '5.1')

package.path = table.concat({
  rocks_lua .. '/?.lua',
  rocks_lua .. '/?/init.lua',
  package.path,
}, ';')

local runner = require('luacov.runner')
local config = runner.load_config()
config.reporter = 'summary'
config.reportfile = vim.fs.joinpath(root, 'coverage', 'summary.out')
runner.run_report(config)
