-- Pure history-file classification. Only the current format is supported;
-- other bytes are silently discarded and are never replayed or migrated.
local M = {}

M.HEADER = '{"format":"direct-history","version":1}'

local paths = require('direct.paths')
local action = require('direct.action')

local function split_lines(bytes)
  local lines, first = {}, 1
  while first <= #bytes do
    local ending = bytes:find('\n', first, true)
    if not ending then return nil end
    lines[#lines + 1] = bytes:sub(first, ending - 1)
    first = ending + 1
  end
  return lines
end

local function reset()
  return { state = 'reset', lines = {} }
end

-- classify(bytes, exists) -> {state='current'|'reset', lines?}.
function M.classify(bytes, exists)
  if not exists or type(bytes) ~= 'string' or bytes == '' then return reset() end
  if not paths.valid_utf8(bytes) or bytes:find('\0', 1, true)
    or bytes:find('\r\n', 1, true) or bytes:sub(1, 3) == '\239\187\191'
    or bytes:sub(-1) ~= '\n' then
    return reset()
  end

  local lines = split_lines(bytes)
  if not lines or #lines == 0 or lines[1] ~= M.HEADER then return reset() end
  for i = 2, #lines do
    local ok, parsed = pcall(action.deserialize, lines[i])
    if lines[i] == '' or not ok or not parsed then return reset() end
  end
  return { state = 'current', lines = lines }
end

return M
