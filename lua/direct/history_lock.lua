-- Same-host advisory lock shared by Direct processes using the same data home.
-- The lock file is intentionally persistent: unlinking it could let waiters lock
-- different inodes. flock is released by the OS if Neovim exits or crashes.
local M = {}

M.uv = vim.uv

local ffi_ok, ffi = pcall(require, 'ffi')
local windows = M.uv.os_uname().sysname:match('Windows') ~= nil
local windows_api
if ffi_ok and windows then
  pcall(ffi.cdef, [[
    typedef unsigned long direct_dword;
    typedef unsigned long long direct_uintptr;
    typedef struct {
      direct_uintptr Internal;
      direct_uintptr InternalHigh;
      direct_dword Offset;
      direct_dword OffsetHigh;
      void *hEvent;
    } direct_overlapped;
    void *__stdcall CreateFileW(const unsigned short *name, direct_dword access,
      direct_dword share, void *security, direct_dword creation,
      direct_dword flags, void *template_file);
    int __stdcall LockFileEx(void *hFile, direct_dword flags, direct_dword reserved,
      direct_dword length_low, direct_dword length_high,
      direct_overlapped *overlapped);
    int __stdcall UnlockFileEx(void *hFile, direct_dword reserved,
      direct_dword length_low, direct_dword length_high,
      direct_overlapped *overlapped);
    int __stdcall CloseHandle(void *handle);
    direct_dword __stdcall GetLastError(void);
  ]])
  local api_ok, api = pcall(ffi.load, 'kernel32')
  if api_ok then
    local symbols_ok = pcall(function()
      return api.CreateFileW, api.LockFileEx, api.UnlockFileEx, api.CloseHandle,
        api.GetLastError
    end)
    if symbols_ok then windows_api = api end
  end
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
  if windows and not windows_api then
    return nil, 'same-host history locking requires Windows LockFileEx support'
  end
  local path, path_err = lock_path()
  if not path then return nil, path_err end
  if windows then
    local converted, utf16 = pcall(vim.fn.iconv, path, 'utf-8', 'utf-16le')
    if not converted then return nil, tostring(utf16) end
    if type(utf16) ~= 'string' then return nil, 'could not encode Windows lock path' end
    local created, create_err, create_code = M.uv.fs_open(path, 'a', 384)
    if not created then
      return nil, tostring(create_err or create_code or 'could not open history lock')
    end
    M.uv.fs_close(created)
    local wide = ffi.new('unsigned short[?]', #utf16 / 2 + 1)
    ffi.copy(wide, utf16, #utf16)
    local handle = windows_api.CreateFileW(wide, 0x80000000 + 0x40000000,
      0x1 + 0x2, nil, 3, 0x80, nil)
    if handle == ffi.cast('void *', -1) then
      return nil, 'CreateFileW failed (error '
        .. tostring(windows_api.GetLastError()) .. ')'
    end
    local state = ffi.new('direct_overlapped[1]')
    if windows_api.LockFileEx(handle, 3, 0, 1, 0, state) == 0 then
      local lock_error = windows_api.GetLastError()
      windows_api.CloseHandle(handle)
      return nil, 'LockFileEx failed (error ' .. tostring(lock_error) .. ')'
    end
    native_handle, overlapped, depth = handle, state, 1
    return true
  end
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
    if windows then
      unlocked = windows_api.UnlockFileEx(native_handle, 0, 1, 0, overlapped) ~= 0
      if not unlocked then unlock_err = 'UnlockFileEx failed (error '
        .. tostring(windows_api.GetLastError()) .. ')' end
      local closed = windows_api.CloseHandle(native_handle)
      if closed == 0 and unlocked then
        unlocked = false
        unlock_err = 'CloseHandle failed (error '
          .. tostring(windows_api.GetLastError()) .. ')'
      end
      native_handle, overlapped = nil, nil
    else
      unlocked = ffi.C.flock(held, LOCK_UN) == 0
      if not unlocked then unlock_err = 'flock unlock failed (errno '
        .. tostring(ffi.errno()) .. ')' end
    end
  end)
  local closed, close_err = true, nil
  if not windows then closed, close_err = M.uv.fs_close(held) end
  if not called then return nil, tostring(call_err) end
  if not unlocked then return nil, unlock_err end
  if closed == nil or closed == false then
    return nil, tostring(close_err or 'could not close history lock')
  end
  return true
end

return M
