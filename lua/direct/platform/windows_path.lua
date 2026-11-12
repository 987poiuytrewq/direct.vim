-- Win32 path-component constraints, also used by platform-independent tests.
local M = {}

function M.component_reason(component)
  if component:find('\\', 1, true) or component:match('^%a:') then return 'invalid Windows path component' end
  if component:match('[%. ]$') then return 'Windows path components may not end in a dot or space' end
  local device = component:match('^([^%.]+)') or component
  device = device:gsub('[%. ]+$', ''):upper()
  if
    device == 'CON'
    or device == 'PRN'
    or device == 'AUX'
    or device == 'NUL'
    or device:match('^COM[1-9]$')
    or device:match('^LPT[1-9]$')
  then
    return 'reserved Windows device name'
  end
  return nil
end

return M
