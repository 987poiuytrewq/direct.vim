-- lua/direct/paths.lua -- XDG data dirs, digest, path helpers.
--
-- Responsibility (spec section 5): root, data_home, data_dir, digest, dirname,
-- basename, join. Everything here is stateless: nothing is cached, so
-- re-pointing $XDG_DATA_HOME (as the harness does per spec) is reflected on the
-- very next call without an invalidation hook (B9/T-006). The only filesystem
-- touch is `mkdir -p` of a data directory, routed through the fs seam
-- (`direct.fs.mkdirp`) so a failure is returned as nil, err -- never raised
-- (B1, spec section 8 never-raise rule).
--
-- This module never reads a buffer or runs a command, so it is headless-safe.

local M = {}

local fs = require('direct.fs')

-- root(input) -> an absolute, normalised path for a user-supplied listing root
-- (B3/T-006). `vim.fs.normalize` collapses separators and `.`/`..` but does NOT
-- make a relative path absolute -- a relative `:DirectList .` must still match
-- the absolute spelling a buffer name is stored under, so the result also goes
-- through `vim.fs.abspath`. The returned spelling is not symlink-resolved
-- (that divergence is exactly what `fs.same_path` exists for, B9).
function M.root(input)
  if input == nil or input == '' then
    input = '.'
  end
  return vim.fs.abspath(vim.fs.normalize(input))
end

-- data_home() -> the direct data root (B9). Precedence:
--   1. $XDG_DATA_HOME when set and non-empty;
--   2. $HOME/.local/share;
--   3. vim.fn.stdpath('data') plus a warning -- the only place stdpath is used.
-- Recomputed on every call (statelessness, T-006).
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

-- data_dir(name) -> <data_home>/direct/<name> on success, or nil, err when the
-- directory cannot be created (for example the data home is occupied by a
-- regular file, or is unwritable). `name` is one of history / trash /
-- register. Recomputed per call. Callers must branch on the nil, err failure
-- rather than assuming the directory exists: a P2 history/trash/register
-- caller either uses the returned dir or reports the error.
function M.data_dir(name)
  local dir = M.join(M.data_home(), 'direct', name)
  local ok, err = fs.mkdirp(dir)
  if not ok then
    return nil, err
  end
  return dir
end

-- digest(...) -> hex sha256 of the NUL-joined paths (D15/L9). Accepts either
-- varargs (`digest(a, b)`) or a single list (`digest({ a, b })`), which is what
-- callers with an already-sorted source list want. `vim.fn.sha256` takes
-- exactly one argument, hence the join first.
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

-- basename(path) -> the last path component. `vim.fs.basename('/a/b/')` is ''
-- (R4), so a trailing slash is stripped first; a directory yank therefore
-- stores `dir1`, never ''. The filesystem root is the only component-less case.
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
