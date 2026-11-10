-- Visible file/Git navigation and the narrow folding adapter for buffers.
-- Dependencies are injected to keep this a behavior-preserving extraction.

return function(context)
  local M = context.M
  local states = context.states
  local row_ids_by_row = context.row_ids_by_row
  local git = context.git
  local is_dir_line = context.is_dir_line
  local current_row_record = context.current_row_record
  local visible_row_for_id = context.visible_row_for_id
  local record_identity = context.record_identity
  local pending = context.pending
  local folding = context.folding
  local ensure_git_snapshot = context.ensure_git_snapshot

-- Move to the next/previous row in this listing with a non-ignored Git change.
-- This deliberately walks materialized rows only: filtered-out and collapsed
-- entries are not navigation targets.
function M.navigate_git_status(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state or (direction ~= 1 and direction ~= -1) then return false end

  local options = require('direct.config').options
  if not options.git.enabled then return false end
  local snapshot = ensure_git_snapshot(state)
  if not snapshot then return false end

  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local row_ids = row_ids_by_row(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = cursor_row + direction
  while row >= 0 and row < line_count do
    local id = row_ids[row]
    local record = id and state.rows[id]
    local status = record and git.first_status_for(snapshot, record.path)
    if status and status ~= 'ignored' then
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      return true
    end
    row = row + direction
  end
  return false
end

function M.next_change()
  return M.navigate_git_status(1)
end

function M.previous_change()
  return M.navigate_git_status(-1)
end

-- Move to the next/previous materialized file row, skipping directories. Like
-- Git-status navigation this follows visible listing order and never wraps.
function M.navigate_file(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state or (direction ~= 1 and direction ~= -1) then return false end

  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local row_ids = row_ids_by_row(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = cursor_row + direction
  while row >= 0 and row < line_count do
    local id = row_ids[row]
    local record = id and state.rows[id]
    if record and not is_dir_line(record.name) then
      vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
      return true
    end
    row = row + direction
  end
  return false
end

function M.next_file()
  return M.navigate_file(1)
end

function M.previous_file()
  return M.navigate_file(-1)
end


-- Internal adapter for the folding command module. Keep row marks and state
-- owned by this buffer model; folding.lua only receives these narrow accessors.
function M._folding_context(bufnr)
  local state = states[bufnr]
  if not state then return nil end
  return {
    get_row_record = function(row) return current_row_record(bufnr, row - 1) end,
    get_record = function(id) return state.rows[id] end,
    visible_row_for_id = function(id) return visible_row_for_id(bufnr, state, id) end,
    is_directory = function(rec) return rec ~= nil and is_dir_line(rec.name) end,
    identity_for_record = record_identity,
    is_expanded = function(id) return state.expanded[id] ~= nil end,
    get_expanded_children = function(id)
      local expansion = state.expanded[id]
      return expansion and expansion.children or {}
    end,
    get_root_directory_ids = function()
      local ids = {}
      for _, id in ipairs(state.root_ids or {}) do
        local rec = state.rows[id]
        if rec and is_dir_line(rec.name) then ids[#ids + 1] = id end
      end
      return ids
    end,
  }
end

function M.expand_recursive()
  if pending.refuse('expand', 'willRenameFiles') then return nil end
  return folding.expand_recursive(M)
end

function M.toggle_recursive()
  if pending.refuse('toggle', 'willRenameFiles') then return nil end
  return folding.toggle_recursive(M)
end

function M.expand_all()
  if pending.refuse('expand', 'willRenameFiles') then return nil end
  return folding.expand_all(M)
end

function M.collapse_all()
  if pending.refuse('collapse', 'willRenameFiles') then return nil end
  return folding.collapse_all(M)
end

end
