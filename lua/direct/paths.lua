-- lua/direct/paths.lua -- XDG data dirs, digest, path helpers. Stateless: nothing
-- is cached, so re-pointing $XDG_DATA_HOME takes effect on the next call. The
-- only filesystem touch (`mkdir -p`) goes through the fs seam and never raises.

local M = {}

local fs = require('direct.fs')
local constants = require('direct.constants')

M.separator = package.config:sub(1, 1)

function M.directory_separator()
  local config = package.loaded['direct.config']
  return config and config.options.directory_separator
    or M.separator
end

function M.is_directory_name(name)
  return type(name) == 'string' and name:sub(-1) == M.directory_separator()
end

function M.strip_directory_marker(name)
  if M.is_directory_name(name) then
    return name:sub(1, -2)
  end
  return name
end

function M.mark_directory(name)
  return tostring(name) .. M.directory_separator()
end

function M.join_entry(root, name)
  local directory = M.is_directory_name(name)
  local component = M.strip_directory_marker(name)
  if M.separator == '\\' then
    component = component:gsub('/', '\\')
  elseif M.directory_separator() == '\\' then
    component = component:gsub('\\', '/')
  end
  local path = vim.fs.joinpath(root, component)
  if directory and path:sub(-1) ~= M.separator then
    path = path .. M.separator
  end
  return path
end

function M.strip_trailing_separator(path)
  if type(path) ~= 'string' then return path end
  local trimmed
  if M.separator == '\\' then
    trimmed = path:gsub('[/\\]+$', '')
  else
    trimmed = path:gsub('/+$', '')
  end
  if trimmed == '' then
    return M.separator
  end
  if M.separator == '\\' and path:match('^%a:[/\\]+$') then
    return path:sub(1, 2) .. M.separator
  end
  return trimmed
end

-- A slash-normalized spelling for comparisons and URI-relative paths only.
-- Filesystem calls should retain their native spelling.
function M.canonical(path)
  local normalized = vim.fs.normalize(tostring(path))
  if M.separator == '\\' then normalized = normalized:gsub('\\', '/') end
  if normalized:match('^%a:/$') then return normalized end
  local trimmed = normalized:gsub('/+$', '')
  return trimmed == '' and '/' or trimmed
end

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
  local lexical = value
  if M.separator == '\\' then lexical = lexical:gsub('\\', '/') end
  local normalized = vim.fs.normalize(lexical)
  if M.separator == '\\' then normalized = normalized:gsub('\\', '/') end
  local spelling = lexical:gsub('/+$', '')
  normalized = normalized:gsub('/+$', '')
  if normalized ~= spelling or M.canonical(M.root(value)) ~= M.canonical(value) then
    return nil, 'path must be absolute and canonical'
  end
  return true
end

-- Persist paths in separator-neutral form so JSONL history is stable across
-- Windows APIs that may return either slash style. Keep a directory's trailing
-- marker because action replay uses it to distinguish directory operations.
function M.record_path(value)
  local is_directory = type(value) == 'string' and value:match('[/\\]$') ~= nil
  local result = M.canonical(M.root(value))
  if is_directory and result ~= '/' and not result:match('^%a:/$') then
    result = result .. '/'
  end
  return result
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
  local trimmed = M.strip_trailing_separator(path)
  return vim.fs.basename(trimmed)
end

function M.join(...)
  return vim.fs.joinpath(...)
end

return M
