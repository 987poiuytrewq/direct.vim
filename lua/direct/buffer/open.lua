-- Buffer open, row lookup, and post-paste refresh operations.
-- Dependencies are injected from buffer.lua so behavior stays unchanged.

return function(context)
  local M = context.M
  local Buffer = context.Buffer
  local paths = context.paths
  local ui = context.ui
  local constants = context.constants
  local states = context.states
  local restore_deleted_rows = context.restore_deleted_rows
  local children_integrity = context.children_integrity
  local current_row_record = context.current_row_record
  local is_deleted_record = context.is_deleted_record
  local row_path = context.row_path
  local is_dir_line = context.is_dir_line
  local recorded_row_text = context.recorded_row_text
  local indent_size = context.indent_size
  local remove_expanded_subtree = context.remove_expanded_subtree

-- ---------------------------------------------------------------------------
-- open / get_paths
-- ---------------------------------------------------------------------------

-- Open directories with a direct listing and files with `:edit`. Pass paths
-- through fnameescape so special characters cannot become Ex syntax. Keep
-- previous direct buffers when navigating between directories so returning to
-- a directory can reuse its existing listing; remove the old listing on file
-- opens after another buffer is current.
-- Child paths resolve from their row identities rather than their display text.
function Buffer:open(line, options)
  options = options or {}
  if type(options) ~= 'table' then
    return nil, 'open options must be a table'
  end
  if options.split ~= nil and options.split ~= 'horizontal'
    and options.split ~= 'vertical' and options.split ~= 'tab' then
    return nil, "open split must be 'horizontal', 'vertical', or 'tab'"
  end
  local configured = require('direct.config').options.buffers
  local open_in = options.open_in
  if open_in == nil then open_in = configured.open_in end
  if options.reuse ~= nil and type(options.reuse) ~= 'boolean' then
    return nil, 'open reuse must be a boolean'
  end
  if open_in ~= 'current' and open_in ~= 'new' then
    return nil, "open_in must be 'current' or 'new'"
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local direct_buf = bufnr
  restore_deleted_rows(bufnr)
  local safe, integrity_err = children_integrity(bufnr,
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if not safe then return nil, integrity_err end
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  local target_row
  local current = vim.api.nvim_buf_get_lines(bufnr, cursor_row - 1, cursor_row, false)[1]
  if current == line then
    target_row = cursor_row
  else
    local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for row, candidate in ipairs(all) do
      if candidate == line then target_row = row; break end
    end
  end
  local record = target_row and current_row_record(bufnr, target_row - 1)
  if is_deleted_record(record) then return false end
  local path = row_path(self.root, record, line)
  if not path and type(line) == 'string' and not line:match('^%s') then
    path = M.entry_path(self.root, line)
  end
  if not path then return nil, 'row identity is unavailable' end

  if options.split then
    local command = options.split == 'horizontal' and 'new'
      or options.split == 'vertical' and 'vnew' or 'tabnew'
    local ok, split_err = pcall(vim.cmd, command)
    if not ok then return nil, tostring(split_err) end
  end

  if is_dir_line(record and record.name or line) then
    local listed, list_err = M.list(path, { reuse = options.reuse, open_in = open_in })
    if not listed then return nil, list_err end
  else
    if vim.bo[direct_buf].filetype == constants.FILETYPE
      and vim.bo[direct_buf].modified and not options.split and open_in == 'current' then
      local reason = 'cannot open a file with unsaved edits; sync or discard them first'
      ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
      return nil, reason
    end
    vim.cmd((open_in == 'new' and not options.split and 'hide edit ' or 'edit ')
      .. vim.fn.fnameescape(path))
    if not options.split and open_in == 'current' and vim.api.nvim_buf_is_valid(direct_buf)
      and vim.api.nvim_get_current_buf() ~= direct_buf then
      pcall(vim.api.nvim_buf_delete, direct_buf, { force = true })
    end
  end
  return true
end

-- Buffer:get_paths(firstline, lastline) -> the absolute path of every line in
-- the inclusive 1-based range (Python's buffer slice). Used by `:DirectYank`.
function Buffer:get_paths(firstline, lastline)
  local bufnr = vim.api.nvim_get_current_buf()
  restore_deleted_rows(bufnr)
  local safe, integrity_err = children_integrity(bufnr,
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if not safe then return nil, integrity_err end
  local lines = vim.api.nvim_buf_get_lines(bufnr, firstline - 1, lastline, false)
  local out = {}
  for offset, line in ipairs(lines) do
    local row = firstline + offset - 2
    local record = current_row_record(bufnr, row)
    if is_deleted_record(record) then
      -- Deleted Git rows are view-only and never enter the register.
    elseif record and record.kind == 'child' then
      out[#out + 1] = record.path
    elseif record and record.kind == 'root' then
      out[#out + 1] = M.entry_path(self.root, line)
    elseif line:match('^%s') then
      return nil, 'row has no valid identity'
    else
      out[#out + 1] = M.entry_path(self.root, line)
    end
  end
  return out
end

-- Buffer:get_entry_path(row) -> the existing row identity at one display row.
-- Unlike get_paths(), this is for actions that must target the entry that was
-- actually listed: it refuses blank rows and rows with unsaved name edits.
function Buffer:get_entry_path(row)
  local bufnr = vim.api.nvim_get_current_buf()
  restore_deleted_rows(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local safe, integrity_err = children_integrity(bufnr, lines)
  if not safe then return nil, integrity_err end
  local line = lines[row]
  local record = current_row_record(bufnr, row - 1)
  if not line or not record then
    return nil, 'row identity is unavailable'
  end
  if line ~= record.text then
    return nil, 'current row has unsaved edits'
  end
  return record.path
end

function Buffer:get_entry_record(row)
  local bufnr = vim.api.nvim_get_current_buf()
  restore_deleted_rows(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local safe = children_integrity(bufnr, lines)
  if not safe then return nil end
  return current_row_record(bufnr, row - 1)
end

-- Buffer:paste_destination([row]) -> the directory represented by the row.
-- A directory row is itself the destination; a file row uses its parent.
-- Resolve through the row record so expanded child rows never rely on their
-- indented display text for filesystem paths.
function Buffer:paste_destination(row)
  local bufnr = vim.api.nvim_get_current_buf()
  restore_deleted_rows(bufnr)
  local safe, integrity_err = children_integrity(bufnr,
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if not safe then return nil, integrity_err end

  row = row or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if line == nil then return nil, 'row identity is unavailable' end
  local record = current_row_record(bufnr, row - 1)
  if not record then
    if line == '' then return self.root end
    return nil, 'row identity is unavailable'
  end
  if is_deleted_record(record) then return false, 'deleted Git entries are view-only' end
  if line ~= recorded_row_text(record) then
    return nil, 'cannot paste from a row with unsaved edits'
  end
  if type(record.path) ~= 'string' or record.path == '' then
    return nil, 'row path is unavailable'
  end
  if is_dir_line(record.name) then return record.path end
  return vim.fs.dirname(record.path)
end

local function normalized_path(path)
  return paths.canonical(path)
end

local function path_is_within(parent, candidate)
  parent, candidate = normalized_path(parent), normalized_path(candidate)
  if candidate == parent then return true end
  local prefix = parent:sub(-1) == '/' and parent or parent .. '/'
  return candidate:sub(1, #prefix) == prefix
end

-- Refresh the root listing after a paste. Reopen existing folds and the path to
-- the destination so the last pasted entry is visible; place the cursor on its
-- name and expand it when it is a directory.
function Buffer:refresh_after_paste(destination, pasted_entry)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then return self:list({ allow_modified = true, reset_undo = true }) end

  local expanded_paths, destination_id = {}, nil
  for id in pairs(state.expanded or {}) do
    local record = state.rows[id]
    if record and record.path then
      expanded_paths[#expanded_paths + 1] = record.path
      if normalized_path(record.path) == normalized_path(destination) then
        destination_id = id
      end
    end
  end

  local cursor_record = current_row_record(bufnr,
    vim.api.nvim_win_get_cursor(0)[1] - 1)
  local cursor_path = cursor_record and cursor_record.path or nil
  local reopen = {}
  if destination_id then
    for _, path in ipairs(expanded_paths) do
      if path_is_within(destination, path) then reopen[#reopen + 1] = path end
    end
    remove_expanded_subtree(bufnr, state, destination_id)
  end

  local ok, err = self:list({ allow_modified = true, reset_undo = true })
  if not ok then return nil, err end

  local function visible_row(path)
    local current = states[bufnr]
    for row, id in ipairs(current.display_ids or {}) do
      local record = current.rows[id]
      if record and record.path
        and normalized_path(record.path) == normalized_path(path) then
        return row
      end
    end
    return nil
  end

  -- A paste into a collapsed nested directory still needs to expose the new
  -- entry. Add each ancestor from the listing root through the destination to
  -- the folds to reopen, then process shallow paths before their descendants.
  if type(pasted_entry) == 'string' then
    local root_path = normalized_path(self.root)
    local path = normalized_path(destination)
    local destination_ancestors = {}
    while path ~= root_path and path_is_within(root_path, path) do
      destination_ancestors[#destination_ancestors + 1] = path
      local parent = normalized_path(vim.fs.dirname(path))
      if parent == path then break end
      path = parent
    end
    for _, ancestor in ipairs(destination_ancestors) do
      reopen[#reopen + 1] = ancestor
    end
  end

  local unique_reopen, reopen_seen = {}, {}
  for _, expanded_path in ipairs(reopen) do
    local key = normalized_path(expanded_path)
    if not reopen_seen[key] then
      reopen_seen[key] = true
      unique_reopen[#unique_reopen + 1] = expanded_path
    end
  end
  table.sort(unique_reopen, function(a, b) return #a < #b end)
  for _, expanded_path in ipairs(unique_reopen) do
    local row = visible_row(expanded_path)
    if row then
      local current = states[bufnr]
      local id = current.display_ids[row]
      if not current.expanded[id] then
        local expanded, expand_err = self:expand(row)
        if expanded == nil then return nil, expand_err end
      end
    end
  end

  local pasted_row = type(pasted_entry) == 'string' and visible_row(pasted_entry)
    or nil
  if pasted_row then
    local record = current_row_record(bufnr, pasted_row - 1)
    local col = record and record.kind == 'child'
      and (record.depth or 0) * indent_size() or 0
    pcall(vim.api.nvim_win_set_cursor, 0, { pasted_row, col })
    local expanded, expand_err = self:expand(pasted_row)
    if expanded == nil then return nil, expand_err end
  elseif cursor_path then
    local row = visible_row(cursor_path)
    if row then pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 }) end
  end
  return true
end

end
