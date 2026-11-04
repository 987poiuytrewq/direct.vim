-- lua/direct/run.lua -- asynchronously run shell commands for a direct row.

local M = {}

local buffer = require('direct.buffer')
local fs = require('direct.fs')
local ui = require('direct.ui')

local function shellescape_path(path)
  if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    local shell = (vim.o.shell or ''):lower():gsub('\\', '/')
    if shell:find('powershell', 1, true) or shell:find('pwsh', 1, true) then
      return "'" .. path:gsub("'", "''") .. "'"
    elseif shell:find('bash', 1, true) or shell:find('zsh', 1, true)
      or shell:find('fish', 1, true) then
      return "'" .. path:gsub("'", "'\\''") .. "'"
    end
  end
  return vim.fn.shellescape(path)
end

local function report_result(result, quiet_success)
  if quiet_success and result.code == 0 then return end
  local message = result.code == 0
    and 'direct: command completed successfully (exit status 0)'
    or string.format('direct: command failed with exit status %d', result.code)
  local stdout = (result.stdout or ''):gsub('%s+$', '')
  local stderr = (result.stderr or ''):gsub('%s+$', '')
  if stdout ~= '' then message = message .. '\nstdout:\n' .. stdout end
  if stderr ~= '' then message = message .. '\nstderr:\n' .. stderr end
  ui.notify(message, result.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
end

-- current_entry(command[, on_complete[, opts]]) -> vim.SystemObj | nil, error.
-- `{}` is replaced with the shell-escaped absolute path for the current row.
-- opts.quiet_success suppresses the completion notification for successful runs.
function M.current_entry(command, on_complete, opts)
  opts = opts or {}
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

  local escaped_path = shellescape_path(path)
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
      local reported, report_err = pcall(report_result, result, opts.quiet_success)
      if not reported then
        ui.report_error('report the command result', report_err)
      end
      if on_complete then
        local completed, err = pcall(on_complete, result, bufnr, listing.root)
        if not completed then
          ui.report_error('refresh after the command', err, vim.log.levels.WARN)
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
