-- Independent JSONL fixtures for history assertions. These intentionally do
-- not call direct.action.serialize(), so writer regressions cannot self-confirm.
local M = {}

M.header = '{"format":"direct-history","version":1}'

local function quote(value)
  return vim.json.encode(value)
end

local function encode_array(values)
  local encoded = {}
  for i, value in ipairs(values) do encoded[i] = quote(value) end
  return '[' .. table.concat(encoded, ',') .. ']'
end

function M.touch(dst)
  return '{"op":"touch","dst":' .. quote(dst) .. '}'
end

function M.mkdir(dst)
  return '{"op":"mkdir","dst":' .. quote(dst) .. '}'
end

function M.move(src, dst)
  return '{"op":"mv","src":' .. quote(src) .. ',"dst":' .. quote(dst) .. '}'
end

function M.remove(op, src, dst)
  return '{"op":' .. quote(op) .. ',"src":' .. quote(src)
    .. ',"dst":' .. quote(dst) .. '}'
end

function M.paste(op, src, dst, src_names, dst_names)
  return '{"op":' .. quote(op) .. ',"src":' .. quote(src)
    .. ',"dst":' .. quote(dst)
    .. ',"src_names":' .. encode_array(src_names)
    .. ',"dst_names":' .. encode_array(dst_names) .. '}'
end

function M.group(moves)
  local encoded = {}
  for i, move in ipairs(moves) do
    encoded[i] = '{"src":' .. quote(move[1]) .. ',"dst":' .. quote(move[2]) .. '}'
  end
  return '{"op":"g","moves":[' .. table.concat(encoded, ',') .. ']}'
end

return M
