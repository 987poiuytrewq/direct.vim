-- User autocmd notifications exposed by direct.vim.
local M = {}

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
  local ok, err = pcall(vim.api.nvim_exec_autocmds, 'User', {
    pattern = name,
    data = public_copy(data or {}),
    modeline = false,
  })
  if not ok then
    vim.notify('direct: User event ' .. name .. ' failed: ' .. tostring(err),
      vim.log.levels.WARN)
  end
  return ok
end

return M
