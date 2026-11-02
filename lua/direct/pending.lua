-- One async direct operation may own the editor until its UI callback settles.
local M = {}

local active = false
local label
local generation = 0
local current_token

function M.is_pending()
  return active
end

function M.is_active(token)
  return active and (token == nil or token == current_token)
end

function M.begin(operation)
  if active then
    return nil, 'another direct operation is pending'
  end
  active = true
  label = operation or 'operation'
  generation = generation + 1
  current_token = generation
  return true, current_token
end

function M.finish(token)
  if token ~= nil and token ~= current_token then return false end
  active = false
  label = nil
  current_token = nil
  return true
end

function M.refuse(operation, only_label)
  if not active then return false end
  if only_label ~= nil and label ~= only_label then return false end
  local ui = require('direct.ui')
  ui.notify('direct: cannot ' .. tostring(operation or 'start operation')
    .. ' while ' .. tostring(label or 'another operation') .. ' is pending',
    vim.log.levels.WARN)
  return true
end

return M
