-- Same-host advisory lock shared by Direct processes using the same data home.
-- The lock file is intentionally persistent: unlinking it could let waiters lock
-- different inodes. flock is released by the OS if Neovim exits or crashes.
local M = {}

M.uv = vim.uv

local ffi_ok, ffi = pcall(require, 'ffi')
if ffi_ok then
  pcall(ffi.cdef, 'int flock(int fd, int operation);')
end

local LOCK_EX, LOCK_NB, LOCK_UN = 2, 4, 8
local depth, fd = 0, nil

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
  if not ffi_ok then
    return nil, 'same-host history locking requires LuaJIT FFI'
  end
  local path, path_err = lock_path()
  if not path then return nil, path_err end
  local opened, open_err, code = M.uv.fs_open(path, 'a', 384)
  if not opened then
    return nil, tostring(open_err or code or 'could not open history lock')
  end
  local ok, lock_err = pcall(function()
    if ffi.C.flock(opened, LOCK_EX + LOCK_NB) ~= 0 then
      error('flock failed (errno ' .. tostring(ffi.errno()) .. ')')
    end
  end)
  if not ok then
    M.uv.fs_close(opened)
    return nil, tostring(lock_err)
  end
  fd, depth = opened, 1
  return true
end

function M.release()
  if depth == 0 then return true end
  depth = depth - 1
  if depth > 0 then return true end

  local held = fd
  fd = nil
  local unlocked, unlock_err
  local called, call_err = pcall(function()
    unlocked = ffi.C.flock(held, LOCK_UN) == 0
    if not unlocked then unlock_err = 'flock unlock failed (errno '
      .. tostring(ffi.errno()) .. ')' end
  end)
  local closed, close_err = M.uv.fs_close(held)
  if not called then return nil, tostring(call_err) end
  if not unlocked then return nil, unlock_err end
  if closed == nil or closed == false then
    return nil, tostring(close_err or 'could not close history lock')
  end
  return true
end

return M
