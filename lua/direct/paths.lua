-- lua/direct/paths.lua -- XDG data dirs, digest, path helpers. Stateless: nothing
-- is cached, so re-pointing $XDG_DATA_HOME takes effect on the next call. The
-- only filesystem touch (`mkdir -p`) goes through the fs seam and never raises.

local M = {}

local fs = require('direct.fs')
local constants = require('direct.constants')

-- valid_utf8(value) validates UTF-8 without relying on decoder replacement
-- behavior. It rejects overlong sequences, surrogates, and codepoints > U+10FFFF.
function M.valid_utf8(value)
  if type(value) ~= 'string' then return false end
  local i, n = 1, #value
  while i <= n do
    local a = value:byte(i)
    if a <= 0x7F then
      i = i + 1
    elseif a >= 0xC2 and a <= 0xDF then
      local b = value:byte(i + 1)
      if not b or b < 0x80 or b > 0xBF then return false end
      i = i + 2
    elseif a >= 0xE0 and a <= 0xEF then
      local b, c = value:byte(i + 1, i + 2)
      if not b or not c or c < 0x80 or c > 0xBF then return false end
      if a == 0xE0 then
        if b < 0xA0 or b > 0xBF then return false end
      elseif a == 0xED then
        if b < 0x80 or b > 0x9F then return false end
      elseif b < 0x80 or b > 0xBF then
        return false
      end
      i = i + 3
    elseif a >= 0xF0 and a <= 0xF4 then
      local b, c, d = value:byte(i + 1, i + 3)
      if not b or not c or not d or c < 0x80 or c > 0xBF
        or d < 0x80 or d > 0xBF then
        return false
      end
      if a == 0xF0 then
        if b < 0x90 or b > 0xBF then return false end
      elseif a == 0xF4 then
        if b < 0x80 or b > 0x8F then return false end
      elseif b < 0x80 or b > 0xBF then
        return false
      end
      i = i + 4
    else
      return false
    end
  end
  return true
end

function M.validate_path(value)
  if type(value) ~= 'string' then return nil, 'invalid path' end
  if value == '' then return nil, 'invalid path' end
  if not M.valid_utf8(value) then return nil, 'invalid UTF-8' end
  if value:find('\t', 1, true) then return nil, 'contains a tab' end
  if value:find('%c') then return nil, 'contains a control character' end
  return true
end

function M.validate_canonical_path(value)
  local ok, err = M.validate_path(value)
  if not ok then return nil, err end
  local normalized = M.root(value)
  local spelling = value:gsub('/+$', '')
  if spelling == '' then spelling = '/' end
  if normalized ~= spelling then return nil, 'path must be absolute and canonical' end
  return true
end

-- normalize does not absolutise, so abspath follows it; the result is not symlink-resolved (fs.same_path covers that).
function M.root(input)
  if input == nil or input == '' then
    input = '.'
  end
  return vim.fs.abspath(vim.fs.normalize(input))
end

function M.data_home()
  local xdg = vim.env.XDG_DATA_HOME
  if xdg ~= nil and xdg ~= '' then
    return vim.fs.normalize(xdg)
  end
  local home = vim.env.HOME
  if home ~= nil and home ~= '' then
    return M.join(home, '.local', 'share')
  end
  local fallback = vim.fn.stdpath('data')
  require('direct.ui').notify(
    'direct: neither $XDG_DATA_HOME nor $HOME is set; using ' .. fallback,
    vim.log.levels.WARN)
  return fallback
end

-- Pure path resolution; this never creates a directory.
function M.data_dir_path(name)
  local dir = M.join(M.data_home(), constants.DATA_DIRECTORY, name)
  return dir
end

-- Creating counterpart to data_dir_path().
function M.ensure_data_dir(name)
  local dir = M.data_dir_path(name)
  local ok, err = fs.mkdirp(dir)
  if not ok then
    return nil, err
  end
  return dir
end

-- Existing internal callers use this creating form; preflight must use the
-- explicitly pure data_dir_path() until input and both history logs are checked.
M.data_dir = M.ensure_data_dir

-- sha256 takes exactly one argument, hence the NUL join; accepts varargs or a single list.
function M.digest(...)
  local paths = { ... }
  if #paths == 1 and type(paths[1]) == 'table' then
    paths = paths[1]
  end
  return vim.fn.sha256(table.concat(paths, '\0'))
end

function M.dirname(path)
  return vim.fs.dirname(path)
end

-- `vim.fs.basename('/a/b/')` is '' so a trailing slash is stripped first (a directory yank stores `dir1`, never '').
function M.basename(path)
  if path == nil then
    return nil
  end
  local trimmed = path:gsub('/+$', '')
  if trimmed == '' then
    trimmed = '/'
  end
  return vim.fs.basename(trimmed)
end

function M.join(...)
  return vim.fs.joinpath(...)
end

return M
