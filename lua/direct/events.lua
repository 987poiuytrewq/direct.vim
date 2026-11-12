-- User autocmd notifications exposed by direct.vim.
local M = {}
local cancel_sequence = 0
local cancellations = {}
local active_cancellations = {}

local function public_copy(value, seen)
  if type(value) ~= 'table' then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    local private = type(key) == 'string' and key:sub(1, 1) == '_'
    if not private and type(key) ~= 'function' and type(item) ~= 'function' then
      result[public_copy(key, seen)] = public_copy(item, seen)
    end
  end
  return result
end

function M.emit(name, data)
  local payload = public_copy(data or {})
  local ok, err = pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = name,
    data = payload,
    modeline = false,
  })
  if not ok then
    require('direct.ui').notify('User event ' .. name .. ' failed: ' .. tostring(err),
      vim.log.levels.WARN)
  end
  return ok, payload
end

-- User autocmd data is copied by Neovim, so a handler cannot cancel an operation
-- by mutating args.data in place. Pass the event data to cancel() instead; the
-- token is scoped to this synchronous dispatch and is always discarded.
function M.cancel(data, reason)
  local token = type(data) == 'table' and data.cancel_token or nil
  if type(token) ~= 'string' or not active_cancellations[token] then
    return nil, 'event data does not support cancellation'
  end
  cancellations[token] = type(reason) == 'string' and reason ~= '' and reason or true
  return true
end

function M.emit_cancellable(name, data)
  cancel_sequence = cancel_sequence + 1
  local token = tostring(vim.uv.hrtime()) .. ':' .. tostring(cancel_sequence)
  local payload = public_copy(data or {})
  payload.cancel_token = token
  active_cancellations[token] = true
  local ok, dispatched = M.emit(name, payload)
  local reason = cancellations[token]
  cancellations[token] = nil
  active_cancellations[token] = nil
  if dispatched and dispatched.cancel == true then
    reason = dispatched.reason or true
  end
  if reason then
    payload.cancel = true
    if type(reason) == 'string' then payload.reason = reason end
  end
  return ok, payload, reason
end

return M
