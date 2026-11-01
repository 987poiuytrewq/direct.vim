-- One async direct operation may own the editor until its UI callback settles.
local M = {}

local active = false
local label

function M.is_pending()
  return active
end

function M.begin(operation)
  if active then
    return nil, 'another direct operation is pending'
  end
  active = true
  label = operation or 'operation'
  return true
end

function M.finish()
  active = false
  label = nil
end

function M.refuse(operation)
  if not active then return false end
  local ui = require('direct.ui')
  ui.notify('direct: cannot ' .. tostring(operation or 'start operation')
    .. ' while ' .. tostring(label or 'another operation') .. ' is pending',
    vim.log.levels.WARN)
  return true
end

return M
