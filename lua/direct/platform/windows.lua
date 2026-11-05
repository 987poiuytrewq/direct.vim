-- Win32 platform implementation for native file identity, no-replace rename,
-- directory symlinks, and cmd.exe invocation.
local M = {}
local ffi
local kernel32
local ffi_declared = false

local function windows_api()
  if ffi and kernel32 then return ffi, kernel32 end
  local loaded, module = pcall(require, 'ffi')
  if not loaded then return nil, 'LuaJIT FFI unavailable' end
  ffi = module
  if not ffi_declared then
    local source = debug.getinfo(1, 'S').source
    local declared, declaration_err = require('direct.platform.ffi_declarations')
      .load(ffi, source, 'windows.h', 'direct_windows_ffi_declarations')
    if not declared then
      return nil, tostring(declaration_err)
    end
    ffi_declared = true
  end
  local loaded_kernel, library = pcall(ffi.load, 'kernel32')
  if not loaded_kernel then return nil, tostring(library) end
  kernel32 = library
  return ffi, kernel32
end

local function wide_path(path, lib, api)
  path = path:gsub('/', '\\')
  local count = api.MultiByteToWideChar(65001, 0, path, -1, nil, 0)
  if count == 0 then return nil, 'could not convert UTF-8 path to UTF-16' end
  local output = lib.new('direct_platform_WCHAR[?]', count)
  if api.MultiByteToWideChar(65001, 0, path, -1, output, count) == 0 then
    return nil, 'could not convert UTF-8 path to UTF-16'
  end
  return output
end

function M.canonical_path(path)
  return vim.fs.normalize(tostring(path)):gsub('\\', '/')
end

function M.identity_path(path)
  return M.canonical_path(path):lower()
end

function M.validation_path(path)
  return path:gsub('\\', '/')
end

function M.strip_trailing_separator(path)
  if type(path) ~= 'string' then return path end
  local trimmed = path:gsub('[/\\]+$', '')
  if trimmed == '' then return '\\' end
  if path:match('^%a:[/\\]+$') then return path:sub(1, 2) .. '\\' end
  return trimmed
end

function M.path_component(component, _display_separator)
  return component:gsub('/', '\\')
end

function M.home_directory(home)
  local profile = vim.env.USERPROFILE
  if profile == nil or profile == '' then
    profile = (vim.env.HOMEDRIVE or '') .. (vim.env.HOMEPATH or '')
  end
  if home ~= nil and home ~= '' and home == profile then return nil end
  return home
end

function M.component_path_reason(component, path_style)
  if path_style == 'posix' then return nil end
  return require('direct.platform.windows_path').component_reason(component)
end

function M.file_identity(path, nofollow)
  if type(path) ~= 'string' then return nil end
  local lib, api = windows_api()
  if not lib then return nil end
  local ok, identity = pcall(function()
    local wide, err = wide_path(path, lib, api)
    if not wide then error(err) end
    local flags = 0x02000000 -- FILE_FLAG_BACKUP_SEMANTICS
    if nofollow then flags = flags + 0x00200000 end -- FILE_FLAG_OPEN_REPARSE_POINT
    local handle = api.CreateFileW(wide, 0, 7, nil, 3, flags, nil)
    if handle == lib.cast('direct_platform_HANDLE', -1) then return nil end
    local information = lib.new('direct_platform_FILE_INFORMATION[1]')
    local read = api.GetFileInformationByHandle(handle, information) ~= 0
    api.CloseHandle(handle)
    if not read then return nil end
    local info = information[0]
    return table.concat({ 'win', tonumber(info.volume), tonumber(info.index_high),
      tonumber(info.index_low) }, ':')
  end)
  return ok and identity or nil
end

function M.create_symlink(target, link, source_link)
  local options
  if source_link then
    local stat = vim.uv.fs_stat(source_link)
    if stat and stat.type == 'directory' then options = { dir = true } end
  end
  return vim.uv.fs_symlink(target, link, options)
end

function M.rename_noreplace(src, dst, sysname)
  if sysname and sysname ~= 'Windows_NT' then
    return nil, 'atomic no-replace rename is unavailable on ' .. tostring(sysname)
  end
  local lib, api = windows_api()
  if not lib then return nil, api or 'LuaJIT FFI unavailable' end
  local src_wide, src_err = wide_path(src, lib, api)
  if not src_wide then return nil, src_err end
  local dst_wide, dst_err = wide_path(dst, lib, api)
  if not dst_wide then return nil, dst_err end
  if api.MoveFileW(src_wide, dst_wide) ~= 0 then return true end
  local code = tonumber(api.GetLastError())
  if code == 80 or code == 183 then
    return nil, 'destination exists: ' .. dst, 'EEXIST'
  elseif code == 17 then
    return nil, 'EXDEV: cross-device move', 'EXDEV'
  end
  return nil, 'Windows error ' .. tostring(code), code
end

function M.shellescape_path(path, shell)
  shell = (shell or ''):lower():gsub('\\', '/')
  if shell:find('powershell', 1, true) or shell:find('pwsh', 1, true) then
    return "'" .. path:gsub("'", "''") .. "'"
  elseif shell:find('bash', 1, true) or shell:find('zsh', 1, true)
    or shell:find('fish', 1, true) then
    return "'" .. path:gsub("'", "'\\''") .. "'"
  end
  -- cmd.exe passes quoted arguments through the Windows CRT, where a trailing
  -- backslash would escape the closing quote unless doubled first.
  local escaped = path:gsub('"', '\\"'):gsub('(\\+)$', '%1%1')
  return '"' .. escaped .. '"'
end

local function write_cmd_script(command)
  local path = vim.fn.tempname() .. '.cmd'
  local fd, open_err = vim.uv.fs_open(path, 'wx', 384)
  if not fd then return nil, open_err end
  local written, write_err = vim.uv.fs_write(fd, command .. '\r\n', 0)
  local closed, close_err = vim.uv.fs_close(fd)
  if not written or not closed then
    pcall(vim.uv.fs_unlink, path)
    return nil, write_err or close_err or 'could not write the command script'
  end
  return path
end

function M.command_argv(shell, shellcmdflag, command)
  local shell_name = (shell or ''):lower():gsub('\\', '/')
  if shell_name ~= 'cmd' and not shell_name:match('cmd%.exe$') then
    local argv = { shell }
    for _, flag in ipairs(vim.split(shellcmdflag, '%s+', { trimempty = true })) do
      argv[#argv + 1] = flag
    end
    argv[#argv + 1] = command
    return argv
  end
  local path, err = write_cmd_script(command)
  if not path then return nil, nil, err end
  return { shell, '/d', '/c', path }, path
end

function M.cleanup_command(path)
  if path then pcall(vim.uv.fs_unlink, path) end
end

function M.acquire_file_lock(path)
  local lib, api = windows_api()
  if not lib then return nil, 'same-host history locking requires Windows LockFileEx support' end
  local fd, open_err = vim.uv.fs_open(path, 'a', 384)
  if not fd then return nil, tostring(open_err or 'could not open history lock') end
  vim.uv.fs_close(fd)
  local wide, wide_err = wide_path(path, lib, api)
  if not wide then return nil, wide_err end
  local handle = api.CreateFileW(wide, 0x80000000 + 0x40000000,
    0x1 + 0x2, nil, 3, 0x80, nil)
  if handle == lib.cast('direct_platform_HANDLE', -1) then
    return nil, 'CreateFileW failed (error ' .. tostring(api.GetLastError()) .. ')'
  end
  local overlapped = lib.new('direct_platform_OVERLAPPED[1]')
  if api.LockFileEx(handle, 3, 0, 1, 0, overlapped) == 0 then
    local lock_err = 'LockFileEx failed (error ' .. tostring(api.GetLastError()) .. ')'
    api.CloseHandle(handle)
    return nil, lock_err
  end
  return { handle = handle, overlapped = overlapped }
end

function M.release_file_lock(token)
  local unlocked = kernel32.UnlockFileEx(token.handle, 0, 1, 0, token.overlapped) ~= 0
  local unlock_err = not unlocked and ('UnlockFileEx failed (error '
    .. tostring(kernel32.GetLastError()) .. ')') or nil
  local closed = kernel32.CloseHandle(token.handle) ~= 0
  if not unlocked then return nil, unlock_err end
  if not closed then
    return nil, 'CloseHandle failed (error ' .. tostring(kernel32.GetLastError()) .. ')'
  end
  return true
end

return M
