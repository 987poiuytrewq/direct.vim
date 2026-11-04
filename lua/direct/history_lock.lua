-- Same-host advisory lock shared by Direct processes using the same data home.
-- The lock file is intentionally persistent: unlinking it could let waiters lock
-- different inodes. flock is released by the OS if Neovim exits or crashes.
local M = {}

M.uv = vim.uv

local ffi_ok, ffi = pcall(require, 'ffi')
local windows = M.uv.os_uname().sysname:match('Windows') ~= nil
local windows_api, windows_crt
if ffi_ok and windows then
  pcall(ffi.cdef, [[
    typedef unsigned long direct_dword;
    typedef unsigned long long direct_uintptr;
    typedef long long direct_intptr;
    typedef struct {
      direct_uintptr Internal;
      direct_uintptr InternalHigh;
      direct_dword Offset;
      direct_dword OffsetHigh;
      void *hEvent;
    } direct_overlapped;
    direct_intptr _get_osfhandle(int fd);
    int __stdcall LockFileEx(void *hFile, direct_dword flags, direct_dword reserved,
      direct_dword length_low, direct_dword length_high,
      direct_overlapped *overlapped);
    int __stdcall UnlockFileEx(void *hFile, direct_dword reserved,
      direct_dword length_low, direct_dword length_high,
      direct_overlapped *overlapped);
    direct_dword __stdcall GetLastError(void);
  ]])
  local api_ok, api = pcall(ffi.load, 'kernel32')
  local crt_ok, crt = pcall(ffi.load, 'msvcrt')
  if api_ok and crt_ok then windows_api, windows_crt = api, crt end
elseif ffi_ok then
  pcall(ffi.cdef, 'int flock(int fd, int operation);')
end

local LOCK_EX, LOCK_NB, LOCK_UN = 2, 4, 8
local depth, fd = 0, nil
local native_handle, overlapped

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
  if windows and (not windows_api or not windows_crt) then
    return nil, 'same-host history locking requires Windows LockFileEx support'
  end
  local path, path_err = lock_path()
  if not path then return nil, path_err end
  local opened, open_err, code = M.uv.fs_open(path, 'a', 384)
  if not opened then
    return nil, tostring(open_err or code or 'could not open history lock')
  end
  local ok, lock_err = pcall(function()
    if windows then
      local os_handle = windows_crt._get_osfhandle(opened)
      if os_handle == -1 then error('could not get native history lock handle') end
      local handle = ffi.cast('void *', os_handle)
      local state = ffi.new('direct_overlapped[1]')
      if windows_api.LockFileEx(handle, 3, 0, 1, 0, state) == 0 then
        error('LockFileEx failed (error ' .. tostring(windows_api.GetLastError()) .. ')')
      end
      native_handle, overlapped = handle, state
    elseif ffi.C.flock(opened, LOCK_EX + LOCK_NB) ~= 0 then
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
    if windows then
      unlocked = windows_api.UnlockFileEx(native_handle, 0, 1, 0, overlapped) ~= 0
      if not unlocked then unlock_err = 'UnlockFileEx failed (error '
        .. tostring(windows_api.GetLastError()) .. ')' end
      native_handle, overlapped = nil, nil
    else
      unlocked = ffi.C.flock(held, LOCK_UN) == 0
      if not unlocked then unlock_err = 'flock unlock failed (errno '
        .. tostring(ffi.errno()) .. ')' end
    end
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
