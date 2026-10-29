-- Undo/redo over strict, canonical JSONL logs. Both stacks are classified by
-- raw bytes before any register access, directory creation, or filesystem change.
local M = {}

local log_mod = require('direct.log')
local format = require('direct.history_format')
M.action = require('direct.action')
M.paths = require('direct.paths')
M.ui = require('direct.ui')

M.HEADER = format.HEADER

local function log_paths()
  local dir = M.paths.data_dir_path('history')
  return M.paths.join(dir, 'undo.log'), M.paths.join(dir, 'redo.log')
end

local function notify_unavailable(err)
  M.ui.notify('direct: history unavailable: ' .. tostring(err),
    vim.log.levels.ERROR)
end

local function notify_preserved(path, reason)
  local message = 'direct: refusing operation; history was preserved at '
    .. path .. ' (' .. tostring(reason) .. ')'
  M.ui.notify(message, vim.log.levels.ERROR)
  return nil, message
end

local function validate_user_paths(user_paths)
  for _, path in ipairs(user_paths or {}) do
    local ok, err = M.paths.validate_canonical_path(path)
    if not ok then return nil, 'invalid path: ' .. tostring(err) end
  end
  return true
end

local function classify_path(path)
  local bytes, err, exists = log_mod.read_raw(path)
  if err then
    return { state = 'preserve', reason = err }
  end
  return format.classify(bytes, exists)
end

local function write_stack(path, lines)
  return log_mod.write(path, lines)
end

local function copy_lines(lines)
  local result = {}
  for i, line in ipairs(lines) do result[i] = line end
  return result
end

-- preflight(paths) validates user inputs, then classifies BOTH history stacks
-- using raw bytes. Reset-eligible old logs are discarded, never replayed or
-- migrated; unknown, malformed, unreadable, or future logs remain untouched.
function M.preflight(user_paths)
  local valid, validation_err = validate_user_paths(user_paths)
  if not valid then
    M.ui.notify('direct: refusing operation: ' .. tostring(validation_err),
      vim.log.levels.ERROR)
    return nil, validation_err
  end

  local undo_path, redo_path = log_paths()
  local undo_state = classify_path(undo_path)
  local redo_state = classify_path(redo_path)
  for _, entry in ipairs({
    { path = undo_path, state = undo_state },
    { path = redo_path, state = redo_state },
  }) do
    if entry.state.state == 'preserve' then
      return notify_preserved(entry.path, entry.state.reason)
    end
  end

  local needs_reset = undo_state.state == 'reset' or redo_state.state == 'reset'
  if needs_reset then
    local dir, dir_err = M.paths.ensure_data_dir('history')
    if not dir then
      notify_unavailable(dir_err)
      return nil, dir_err
    end
    if undo_state.state == 'reset' then
      local ok, err = write_stack(undo_path, { M.HEADER })
      if not ok then
        notify_unavailable(err)
        return nil, err
      end
      if undo_state.warn then
        M.ui.notify('Ignoring and resetting legacy or empty undo history',
          vim.log.levels.WARN)
      end
      undo_state.lines = { M.HEADER }
    end
    if redo_state.state == 'reset' then
      local ok, err = write_stack(redo_path, { M.HEADER })
      if not ok then
        notify_unavailable(err)
        return nil, err
      end
      if redo_state.warn then
        M.ui.notify('Ignoring and resetting legacy or empty redo history',
          vim.log.levels.WARN)
      end
      redo_state.lines = { M.HEADER }
    end
  end

  return {
    undo_path = undo_path,
    redo_path = redo_path,
    undo_lines = undo_state.lines,
    redo_lines = redo_state.lines,
  }
end

local function action_paths(action)
  local result = {}
  if type(action) == 'table' then
    if type(action.src) == 'string' then result[#result + 1] = action.src end
    if type(action.dst) == 'string' then result[#result + 1] = action.dst end
    for _, member in ipairs(action.actions or {}) do
      if type(member.src) == 'string' then result[#result + 1] = member.src end
      if type(member.dst) == 'string' then result[#result + 1] = member.dst end
    end
  end
  return result
end

-- log(action) appends one action and clears redo. Each complete stack rewrite is
-- atomic; the two stacks are not claimed to be one cross-file transaction.
function M.log(action)
  if type(action) ~= 'table' then
    return nil, 'history.log: an action is required'
  end
  local record, serialize_err = M.action.serialize(action)
  if not record then
    M.ui.notify('direct: cannot write history: ' .. tostring(serialize_err),
      vim.log.levels.ERROR)
    return nil, serialize_err
  end
  local state, preflight_err = M.preflight(action_paths(action))
  if not state then
    return nil, preflight_err
  end
  local undo_lines = copy_lines(state.undo_lines)
  undo_lines[#undo_lines + 1] = record
  local ok, err = write_stack(state.undo_path, undo_lines)
  if not ok then
    M.ui.notify('direct: cannot write history: ' .. tostring(err),
      vim.log.levels.ERROR)
    return nil, err
  end
  ok, err = write_stack(state.redo_path, { M.HEADER })
  if not ok then
    M.ui.notify('direct: cannot write history: ' .. tostring(err),
      vim.log.levels.ERROR)
    return nil, err
  end
  return true
end

function M.undo()
  return M._reverse('undo')
end

function M.redo()
  return M._reverse('redo')
end

-- _reverse(which) preserves the documented pop -> execute -> append order. The
-- atomic stack rewrite narrows write failure windows, but cannot make those
-- multiple operations one transaction.
function M._reverse(which)
  local state, preflight_err = M.preflight()
  if not state then
    return nil, preflight_err
  end
  local src_path, dst_path, src_lines, dst_lines
  if which == 'undo' then
    src_path, dst_path = state.undo_path, state.redo_path
    src_lines, dst_lines = state.undo_lines, state.redo_lines
  elseif which == 'redo' then
    src_path, dst_path = state.redo_path, state.undo_path
    src_lines, dst_lines = state.redo_lines, state.undo_lines
  else
    return nil, 'history._reverse: expected undo or redo'
  end
  if #src_lines <= 1 then
    M.ui.notify(which == 'undo' and 'Nothing to undo' or 'Nothing to redo',
      vim.log.levels.INFO)
    return nil
  end

  local record = src_lines[#src_lines]
  local reversal, reverse_err = M.action.reverse(record)
  if not reversal then
    M.ui.notify('Failed to ' .. which .. ' action - ' .. tostring(reverse_err),
      vim.log.levels.ERROR)
    return nil, reverse_err
  end

  table.remove(src_lines)
  local ok, err = write_stack(src_path, src_lines)
  if not ok then
    M.ui.notify('Failed to ' .. which .. ' action - cannot update history: '
      .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end

  local ran, result, execute_err = pcall(M.action.execute, reversal)
  if not ran or result == nil then
    src_lines[#src_lines + 1] = record
    local restored, restore_err = write_stack(src_path, src_lines)
    local why = not ran and tostring(result)
      or (execute_err ~= nil and tostring(execute_err) or 'action failed')
    if not restored then why = why .. '; could not restore history: ' .. tostring(restore_err) end
    M.ui.notify('Failed to ' .. which .. ' action - '
      .. M.action.summarize({ reversal }) .. ' (' .. why .. ')',
      vim.log.levels.ERROR)
    return nil, why
  end

  local inverse, serialize_err = M.action.serialize(reversal)
  if not inverse then
    M.ui.notify('Failed to ' .. which .. ' action - cannot serialize reversal: '
      .. tostring(serialize_err), vim.log.levels.ERROR)
    return nil, serialize_err
  end
  dst_lines[#dst_lines + 1] = inverse
  local appended, append_err = write_stack(dst_path, dst_lines)
  if not appended then
    M.ui.notify('Failed to ' .. which .. ' action - cannot write history: '
      .. tostring(append_err), vim.log.levels.ERROR)
  end
  M.ui.notify(M.action.summarize({ reversal }), vim.log.levels.INFO)
  return reversal
end

return M
