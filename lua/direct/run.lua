-- lua/direct/run.lua -- asynchronously run shell commands for a direct row.

local M = {}

local buffer = require('direct.buffer')
local fs = require('direct.fs')
local ui = require('direct.ui')

local function report_result(result)
  local message = string.format('direct: command exited with status %d', result.code)
  local stdout = (result.stdout or ''):gsub('%s+$', '')
  local stderr = (result.stderr or ''):gsub('%s+$', '')
  if stdout ~= '' then message = message .. '\nstdout:\n' .. stdout end
  if stderr ~= '' then message = message .. '\nstderr:\n' .. stderr end
  ui.notify(message, result.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
end

-- current_entry(command) -> vim.SystemObj | nil, error. `{}` is replaced with
-- the shell-escaped absolute path for the current direct-buffer row.
function M.current_entry(command, on_complete)
  if type(command) ~= 'string' or command:match('^%s*$') then
    local err = 'DirectRun requires a shell command'
    ui.notify('direct: ' .. err, vim.log.levels.ERROR)
    return nil, err
  end
  if not command:find('{}', 1, true) then
    local err = 'DirectRun command must contain {} for the current entry'
    ui.notify('direct: ' .. err, vim.log.levels.ERROR)
    return nil, err
  end

  local listing = buffer.restore()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local path, path_err = listing:get_entry_path(row)
  local record = listing:get_entry_record(row)
  if not path then
    local err = 'cannot run command for current entry: ' .. tostring(path_err)
    ui.notify('direct: ' .. err, vim.log.levels.ERROR)
    return nil, err
  end
  if not (record and record.deleted_kind) and not fs.taken(path) then
    local err = 'current row does not name an existing entry'
    ui.notify('direct: ' .. err, vim.log.levels.ERROR)
    return nil, err
  end

  local escaped_path = vim.fn.shellescape(path)
  local expanded = command:gsub('%{%}', function() return escaped_path end)
  local argv = { vim.o.shell }
  for _, flag in ipairs(vim.split(vim.o.shellcmdflag, '%s+', { trimempty = true })) do
    argv[#argv + 1] = flag
  end
  argv[#argv + 1] = expanded

  local ok, process = pcall(vim.system, argv, {
    cwd = listing.root,
    text = true,
  }, function(result)
    vim.schedule(function()
      report_result(result)
      if on_complete then
        local completed, err = pcall(on_complete, result, bufnr, listing.root)
        if not completed then
          ui.notify('direct: command completion callback failed: ' .. tostring(err),
            vim.log.levels.WARN)
        end
      end
    end)
  end)
  if not ok then
    local err = 'could not start shell command: ' .. tostring(process)
    ui.notify('direct: ' .. err, vim.log.levels.ERROR)
    return nil, err
  end
  return process
end

return M
