-- Same-host advisory lock shared by Direct processes using the same data home.
-- The lock file is intentionally persistent: unlinking it could let waiters lock
-- different inodes. The platform adapter owns the native lock implementation,
-- which the OS releases if Neovim exits or crashes.
local M = {}
local platform = require('direct.platform')
M.uv = vim.uv

local depth, token = 0, nil

local function lock_path()
  local paths = require('direct.paths')
  local fs = require('direct.fs')
  local home = paths.data_home()
  local ok, err = fs.mkdirp(home)
  if not ok then return nil, err end
  return paths.join(home, '.direct-history.lock')
end

function M.acquire()
  if depth > 0 then
    depth = depth + 1
    return true
  end
  local path, path_err = lock_path()
  if not path then return nil, path_err end
  local acquired, acquire_err = platform.acquire_file_lock(path)
  if not acquired then return nil, acquire_err end
  token, depth = acquired, 1
  return true
end

function M.release()
  if depth == 0 then return true end
  depth = depth - 1
  if depth > 0 then return true end
  local held = token
  token = nil
  return platform.release_file_lock(held)
end

return M
