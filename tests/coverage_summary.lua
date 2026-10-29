-- LuaCov's ReporterBase accounts for executable lines; this reporter formats the
-- per-file totals as Markdown for GitHub Actions.
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
local report = require('luacov.reporter')
local config = runner.load_config()
config.reportfile = vim.fs.joinpath(root, 'coverage', 'summary.md')

local MarkdownReporter = setmetatable({}, report.ReporterBase)
MarkdownReporter.__index = MarkdownReporter

function MarkdownReporter:on_start()
  self._summary = {}
end

function MarkdownReporter:on_end_file(filename, hits, missed)
  self._summary[filename] = { hits = hits, missed = missed }
end

function MarkdownReporter:on_end()
  local version = vim.version()
  self:write(string.format('## Coverage (Neovim %d.%d.%d)\n\n',
    version.major, version.minor, version.patch))
  self:write('| File | Hit lines | Missed lines | Coverage |\n')
  self:write('|---|---:|---:|---:|\n')

  local total_hits, total_missed = 0, 0
  for _, filename in ipairs(self:files()) do
    local row = self._summary[filename]
    if row then
      local path = filename:match('lua/direct/.*') or filename
      local total = row.hits + row.missed
      local percent = total > 0 and (100 * row.hits / total) or 100
      self:write(string.format('| `%s` | %d | %d | %.2f%% |\n',
        path, row.hits, row.missed, percent))
      total_hits = total_hits + row.hits
      total_missed = total_missed + row.missed
    end
  end

  local total = total_hits + total_missed
  local percent = total > 0 and (100 * total_hits / total) or 100
  self:write(string.format('| **Total** | %d | %d | %.2f%% |\n',
    total_hits, total_missed, percent))
end

report.report(MarkdownReporter)
