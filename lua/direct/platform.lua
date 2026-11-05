-- Platform adapter selected once at startup. OS-specific behavior lives in
-- platform/windows.lua and platform/unix.lua; feature modules use this contract.
local windows = vim.uv.os_uname().sysname == 'Windows_NT'
local implementation = require(windows and 'direct.platform.windows' or 'direct.platform.unix')

implementation.is_windows = windows
implementation.separator = package.config:sub(1, 1)
implementation.path_style = windows and 'win32' or 'posix'

return implementation
