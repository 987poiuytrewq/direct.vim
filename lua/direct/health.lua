-- lua/direct/health.lua -- non-mutating diagnostics for :checkhealth direct.
local M = {}

local function check_git()
  if vim.fn.executable('git') ~= 1 then
    vim.health.warn('Git executable is unavailable; Git status and ignore features are disabled')
    return
  end
  local ok, process = pcall(vim.system, { 'git', '--version' }, { text = true })
  if not ok or not process then
    vim.health.warn('Git could not be started: ' .. tostring(process))
    return
  end
  local result_ok, result = pcall(process.wait, process, 1500)
  if not result_ok or not result then
    pcall(process.kill, process, 15)
    vim.health.warn('Git version check timed out')
  elseif result.code ~= 0 then
    vim.health.warn('Git version check failed: '
      .. tostring((result.stderr or ''):gsub('%s+$', '')))
  else
    local version = (result.stdout or ''):gsub('[\r\n]+$', '')
    vim.health.ok('Git: ' .. (version ~= '' and version or 'available'))
  end
end

local function check_data_directory()
  local paths = require('direct.paths')
  local fs = require('direct.fs')
  local constants = require('direct.constants')
  local home = paths.data_home()
  local directory = paths.join(home, constants.DATA_DIRECTORY)
  vim.health.ok('data directory: ' .. home)
  local created, mkdir_err = fs.mkdirp(directory)
  if not created then
    vim.health.error('data directory is not writable: ' .. tostring(mkdir_err))
    return directory, false
  end

  local probe = paths.join(directory, '.health-write-' .. tostring(vim.uv.os_getpid())
    .. '-' .. tostring(vim.uv.hrtime()))
  local fd, open_err = vim.uv.fs_open(probe, 'wx', 384)
  if not fd then
    vim.health.error('data directory is not writable: ' .. tostring(open_err))
    return directory, false
  end
  local closed, close_err = vim.uv.fs_close(fd)
  local removed, remove_err = vim.uv.fs_unlink(probe)
  if not closed or not removed then
    vim.health.error('data directory write probe could not be cleaned up: '
      .. tostring(close_err or remove_err))
    return directory, false
  end
  vim.health.ok('data directory is writable: ' .. directory)
  return directory, true
end

local function inspect_history(directory)
  local paths = require('direct.paths')
  local log = require('direct.log')
  local format = require('direct.history.format')
  local transaction_codec = require('direct.history.transaction')
  local lock = require('direct.history.lock')
  local history_dir = paths.join(directory, 'history')
  local acquired, lock_err = lock.acquire()
  if not acquired then
    vim.health.warn('history could not be inspected because its lock is unavailable: '
      .. tostring(lock_err))
    return
  end

  local function inspect_stack(name)
    local path = paths.join(history_dir, name)
    local bytes, read_err, exists = log.read_raw(path)
    if read_err then
      vim.health.error(name .. ' is unreadable: ' .. tostring(read_err))
      return
    end
    if not exists or bytes == '' then
      vim.health.ok(name .. ': not initialized (fresh)')
      return
    end
    local state = format.classify(bytes, exists)
    if state.state == 'current' then
      vim.health.ok(name .. ': current history format')
    elseif state.state == 'legacy' then
      vim.health.warn(name .. ': recognized legacy history; it will be backed up on use')
    else
      vim.health.warn(name .. ': preserved because damaged or unrecognized ('
        .. tostring(state.reason) .. ')')
    end
  end

  local ok, inspect_err = xpcall(function()
    inspect_stack('undo.log')
    inspect_stack('redo.log')

    local transaction_path = paths.join(history_dir, 'transaction.json')
    local bytes, read_err, exists = log.read_raw(transaction_path)
    if read_err then
      vim.health.error('recovery journal is unreadable: ' .. tostring(read_err))
    elseif not exists then
      vim.health.ok('recovery journal: none')
    elseif not transaction_codec.parse(bytes) then
      vim.health.warn('recovery journal is damaged and preserved for manual inspection')
    else
      vim.health.warn('unfinished transaction requires recovery on next history operation')
    end
  end, debug.traceback)
  local released, release_err = lock.release()
  if not released then
    vim.health.warn('history inspection lock could not be released: '
      .. tostring(release_err))
  end
  if not ok then vim.health.warn('history inspection failed: ' .. tostring(inspect_err)) end
end

local function inspect_icons()
  local options = require('direct.config').options
  local installed = pcall(require, 'nvim-web-devicons')
  vim.health.ok('nvim-web-devicons: ' .. (installed and 'installed' or 'not installed'))
  vim.health.info(string.format('icons enabled: folders=%s files=%s filetypes=%s',
    tostring(options.show_folder_icons), tostring(options.show_file_icons),
    tostring(options.show_filetype_icons)))
  for name, glyph in pairs(options.icons or {}) do
    vim.health.info('icon ' .. tostring(name) .. ': ' .. tostring(glyph))
  end
end

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

  local data_directory, writable = check_data_directory()
  check_git()
  if writable then
    inspect_history(data_directory)
  else
    vim.health.warn('history checks skipped because the data directory is not writable')
  end

  local trash_size, trash_err = require('direct.trash').size_bytes()
  if trash_size then
    vim.health.ok(string.format('trash size: %d bytes', trash_size))
  else
    vim.health.warn('trash size unavailable: ' .. tostring(trash_err))
  end
  inspect_icons()
end

return M
