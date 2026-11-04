-- POSIX platform implementation for path and filesystem primitives.
local M = {}

function M.canonical_path(path)
  return vim.fs.normalize(tostring(path))
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

return M
