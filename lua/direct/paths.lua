-- lua/direct/paths.lua -- XDG data dirs, digest, path helpers. Stateless: nothing
-- is cached, so re-pointing $XDG_DATA_HOME takes effect on the next call. The
-- only filesystem touch (`mkdir -p`) goes through the fs seam and never raises.

local M = {}

local fs = require('direct.fs')
local constants = require('direct.constants')

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

-- Callers must branch on nil, err rather than assume the directory exists.
function M.data_dir(name)
  local dir = M.join(M.data_home(), constants.DATA_DIRECTORY, name)
  local ok, err = fs.mkdirp(dir)
  if not ok then
    return nil, err
  end
  return dir
end

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
