-- Pure history-file classification. Legacy logs are recognized only for reset;
-- they are never replayed or migrated. Unknown and malformed bytes fail closed.
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

local function split_tabs(line)
  local fields, first = {}, 1
  while true do
    local ending = line:find('\t', first, true)
    if not ending then
      fields[#fields + 1] = line:sub(first)
      return fields
    end
    fields[#fields + 1] = line:sub(first, ending - 1)
    first = ending + 1
  end
end

local function valid_path_field(value)
  return type(value) == 'string' and value ~= ''
    and paths.valid_utf8(value) and not value:find('%c')
end

local function valid_component(value)
  return type(value) == 'string' and value ~= '' and value ~= '.' and value ~= '..'
    and not value:find('/', 1, true) and paths.valid_utf8(value)
    and not value:find('%c')
end

local function equal_legacy_names(src, dst)
  if src == '' or dst == '' then return src == '' and dst == '' end
  -- Any space could be either a separator or part of one legal basename, so
  -- only a single unambiguous name is recognized in each legacy field.
  return not src:find(' ', 1, true) and not dst:find(' ', 1, true)
    and valid_component(src) and valid_component(dst)
end

local arity = {
  mv = 3, rm = 3, rmdir = 3, rs = 3, rsdir = 3,
  touch = 2, mkdir = 2, p = 5, up = 5,
}

local function valid_legacy_record(line, version, python)
  local fields = split_tabs(line)
  local verb = fields[1]
  if verb == 'g' then
    if python or version ~= 3 or #fields < 2
      or not fields[2]:match('^%d+$') then
      return false
    end
    local count = tonumber(fields[2])
    if not count or count < 2 or #fields ~= 2 + count * 2 then return false end
    for i = 1, count do
      if not valid_path_field(fields[1 + i * 2])
        or not valid_path_field(fields[2 + i * 2]) then
        return false
      end
    end
    return true
  end

  local expected = arity[verb]
  if not expected or #fields ~= expected then return false end
  if verb == 'touch' or verb == 'mkdir' then
    return valid_path_field(fields[2])
  end
  if not valid_path_field(fields[2]) or not valid_path_field(fields[3]) then
    return false
  end
  if verb == 'p' or verb == 'up' then
    if python then return true end -- framing only; never decode predecessor names
    return equal_legacy_names(fields[4], fields[5])
  end
  return true
end

local function valid_legacy_body(lines, start, version, python)
  for i = start, #lines do
    if lines[i] == '' or not valid_legacy_record(lines[i], version, python) then
      return false
    end
  end
  return true
end

local function preserve(reason)
  return { state = 'preserve', reason = reason }
end

-- classify(bytes, exists) -> {state='current'|'reset'|'preserve', lines?, warn?}.
function M.classify(bytes, exists)
  if not exists or bytes == nil or bytes == '' then
    return { state = 'reset', lines = {}, warn = true }
  end
  if type(bytes) ~= 'string' then return preserve('history read did not return bytes') end
  if not paths.valid_utf8(bytes) then return preserve('history is not valid UTF-8') end
  if bytes:find('\0', 1, true) then return preserve('history contains NUL') end
  if bytes:find('\r\n', 1, true) then return preserve('history uses CRLF') end
  if bytes:sub(1, 3) == '\239\187\191' then return preserve('history has a UTF-8 BOM') end
  if bytes:sub(-1) ~= '\n' then return preserve('history has no final LF') end

  local lines = split_lines(bytes)
  if not lines or #lines == 0 then return preserve('history framing is malformed') end
  if lines[1] == M.HEADER then
    for i = 2, #lines do
      local ok, parsed = pcall(action.deserialize, lines[i])
      if lines[i] == '' or not ok or not parsed then
        return preserve('current JSONL history has a malformed record')
      end
    end
    return { state = 'current', lines = lines }
  end

  local version = lines[1] == '#direct-history-v2' and 2
    or lines[1] == '#direct-history-v3' and 3
  if version then
    if valid_legacy_body(lines, 2, version, false) then
      return { state = 'reset', lines = {}, warn = true, legacy = true }
    end
    return preserve('known legacy history is malformed')
  end

  -- Markerless tab-framed Python history is recognized strictly by verb and
  -- arity. Its p/up name fields remain opaque and are never decoded.
  if valid_legacy_body(lines, 1, nil, true) then
    return { state = 'reset', lines = {}, warn = true, legacy = true }
  end
  return preserve('unknown or malformed history format')
end

return M
