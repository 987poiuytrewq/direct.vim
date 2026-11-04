-- POSIX platform implementation for path and filesystem primitives.
local M = {}
local ffi

local function get_ffi()
  if ffi then return ffi end
  local loaded, module = pcall(require, 'ffi')
  if not loaded then return nil end
  ffi = module
  pcall(ffi.cdef, 'int flock(int fd, int operation);')
  return ffi
end

function M.canonical_path(path)
  return vim.fs.normalize(tostring(path))
end

function M.identity_path(path)
  return M.canonical_path(path)
end

function M.validation_path(path)
  return path
end

function M.strip_trailing_separator(path)
  if type(path) ~= 'string' then return path end
  local trimmed = path:gsub('/+$', '')
  return trimmed == '' and '/' or trimmed
end

function M.path_component(component, display_separator)
  if display_separator == '\\' then return component:gsub('\\', '/') end
  return component
end

function M.home_directory(home)
  return home
end

function M.component_path_reason(component, path_style)
  if path_style == 'win32' then
    return require('direct.platform.windows_path').component_reason(component)
  end
  return nil
end

function M.file_identity(_path, _nofollow)
  return nil
end

function M.create_symlink(target, link, _source_link)
  return vim.uv.fs_symlink(target, link)
end

function M.rename_noreplace(src, dst, sysname)
  local ffi_ok, ffi = pcall(require, 'ffi')
  if not ffi_ok then
    return nil, 'atomic no-replace rename is unavailable (LuaJIT FFI unavailable)'
  end
  pcall(ffi.cdef, [[
    int renamex_np(const char *from, const char *to, unsigned int flags);
    int renameat2(int olddirfd, const char *oldpath, int newdirfd,
      const char *newpath, unsigned int flags);
    char *strerror(int errnum);
  ]])

  sysname = sysname or vim.uv.os_uname().sysname
  local ok, result = pcall(function()
    if sysname == 'Darwin' then
      return ffi.C.renamex_np(src, dst, 0x00000004) -- RENAME_EXCL
    elseif sysname == 'Linux' then
      return ffi.C.renameat2(-100, src, -100, dst, 0x00000001) -- RENAME_NOREPLACE
    end
    error('atomic no-replace rename is unavailable on ' .. tostring(sysname))
  end)
  if not ok then return nil, tostring(result) end
  if result == 0 then return true end
  local code = ffi.errno()
  local err_ok, err = pcall(function() return ffi.string(ffi.C.strerror(code)) end)
  local message = err_ok and err or ('errno ' .. tostring(code))
  if code == 17 then
    return nil, 'destination exists: ' .. dst, 'EEXIST'
  elseif code == 18 then
    return nil, 'EXDEV: ' .. tostring(message), 'EXDEV'
  end
  return nil, tostring(message), code
end

function M.shellescape_path(path, _shell)
  return vim.fn.shellescape(path)
end

function M.command_argv(shell, shellcmdflag, command)
  local argv = { shell }
  for _, flag in ipairs(vim.split(shellcmdflag, '%s+', { trimempty = true })) do
    argv[#argv + 1] = flag
  end
  argv[#argv + 1] = command
  return argv
end

function M.cleanup_command(_path) end

function M.acquire_file_lock(path)
  local lib = get_ffi()
  if not lib then return nil, 'same-host history locking requires LuaJIT FFI' end
  local fd, open_err = vim.uv.fs_open(path, 'a', 384)
  if not fd then return nil, tostring(open_err or 'could not open history lock') end
  if lib.C.flock(fd, 2 + 4) ~= 0 then
    local err = 'flock failed (errno ' .. tostring(lib.errno()) .. ')'
    vim.uv.fs_close(fd)
    return nil, err
  end
  return { fd = fd }
end

function M.release_file_lock(token)
  local unlocked = ffi.C.flock(token.fd, 8) == 0
  local unlock_err = not unlocked and ('flock unlock failed (errno '
    .. tostring(ffi.errno()) .. ')') or nil
  local closed, close_err = vim.uv.fs_close(token.fd)
  if not unlocked then return nil, unlock_err end
  if not closed then return nil, tostring(close_err or 'could not close history lock') end
  return true
end

return M
