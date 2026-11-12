-- Read-only display of the filesystem undo and redo stacks.
local M = {}

local action = require('direct.action.action')
local constants = require('direct.constants')
local format = require('direct.history.format')
local log = require('direct.log')
local paths = require('direct.paths')

local function history_paths()
  local directory = paths.join(paths.data_home(), constants.DATA_DIRECTORY, 'history')
  return directory, paths.join(directory, 'undo.log'), paths.join(directory, 'redo.log')
end

local function read_stack(path)
  local bytes, err, exists = log.read_raw(path)
  if err then return { state = 'unavailable', reason = err } end
  if not exists or bytes == '' then return { state = 'fresh', actions = {} } end

  local classified = format.classify(bytes, exists)
  if classified.state ~= 'current' then
    return { state = classified.state, reason = classified.reason, actions = {} }
  end

  local actions = {}
  for index = 2, #classified.lines do
    local ok, decoded = pcall(action.deserialize, classified.lines[index])
    if not ok or not decoded then
      return { state = 'preserve', reason = 'history record is malformed', actions = {} }
    end
    actions[#actions + 1] = decoded
  end
  return { state = 'current', actions = actions }
end

local function action_paths(item)
  local result, seen = {}, {}
  local function add(path)
    if type(path) ~= 'string' or path == '' then return end
    local key = paths.canonical(path)
    if not seen[key] then
      seen[key] = true
      result[#result + 1] = path
    end
  end
  local function visit(current)
    if type(current) ~= 'table' then return end
    if current.name == 'g' or current.name == 'batch' then
      for _, member in ipairs(current.actions or {}) do
        visit(member)
      end
      return
    end
    if current.name == 'p' then
      add(current.dst)
      for _, pair in ipairs(current.renames or {}) do
        if type(pair.dst) == 'string' then add(paths.join(current.dst, pair.dst)) end
      end
      return
    end
    add(current.src)
    add(current.dst)
    for _, pair in ipairs(current.renames or {}) do
      if current.src and pair.src then add(paths.join(current.src, pair.src)) end
      if current.dst and pair.dst then add(paths.join(current.dst, pair.dst)) end
    end
  end
  visit(item)
  return result
end

local function append_stack(lines, label, stack)
  local count = (stack.state == 'current' or stack.state == 'fresh') and #stack.actions or nil
  lines[#lines + 1] = label .. ' stack' .. (count and (' (' .. count .. ')') or '')
  if stack.state == 'fresh' then
    lines[#lines + 1] = '  (empty)'
  elseif stack.state == 'legacy' then
    lines[#lines + 1] = '  Legacy history is preserved and not displayed.'
  elseif stack.state ~= 'current' then
    lines[#lines + 1] = '  History is preserved: ' .. tostring(stack.reason)
  elseif #stack.actions == 0 then
    lines[#lines + 1] = '  (empty)'
  else
    for index = #stack.actions, 1, -1 do
      local item = stack.actions[index]
      local ok, summary = pcall(action.summarize, { item })
      lines[#lines + 1] = string.format(
        '  %d. %s',
        #stack.actions - index + 1,
        ok and summary or ('Unknown action: ' .. tostring(item.name))
      )
      local affected = action_paths(item)
      if #affected == 0 then
        lines[#lines + 1] = '     (no paths)'
      else
        for _, path in ipairs(affected) do
          lines[#lines + 1] = '     ' .. path
        end
      end
    end
  end
  lines[#lines + 1] = ''
end

function M.lines()
  local history_dir, undo_path, redo_path = history_paths()
  local undo, redo = read_stack(undo_path), read_stack(redo_path)
  local lines = {
    'direct.vim filesystem history (read-only)',
    'Data directory: ' .. paths.data_home(),
    '',
  }
  append_stack(lines, 'Undo', undo)
  append_stack(lines, 'Redo', redo)

  local journal, journal_err, journal_exists = log.read_raw(paths.join(history_dir, 'transaction.json'))
  if journal_err then
    lines[#lines + 1] = 'Recovery journal unavailable: ' .. tostring(journal_err)
  elseif journal_exists and journal ~= '' then
    lines[#lines + 1] = 'Recovery journal present; this view did not replay it.'
  end
  return lines
end

function M.show()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.lines())
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].filetype = 'direct-history'
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

return M
