-- Per-buffer row identities, deleted-row protections, and expansion state.
-- The buffer model and its helpers are injected to preserve existing behavior.

return function(context)
  local M = context.M
  local Buffer = context.Buffer
  local fs = context.fs
  local paths = context.paths
  local git = context.git
  local ui = context.ui
  local states = context.states
  local deleted_guards = context.deleted_guards
  local namespace = context.namespace
  local set_row_mark = context.set_row_mark
  local refresh_display_ids = context.refresh_display_ids
  local refresh_highlights = context.refresh_highlights
  local refresh_icons = context.refresh_icons
  local row_ids_by_row = context.row_ids_by_row
  local current_row_record = context.current_row_record
  local is_dir_line = context.is_dir_line
  local dirs_then_name = context.dirs_then_name
  local next_id = context.next_id
  local row_path = context.row_path
  local recorded_row_text = context.recorded_row_text
  local set_directory_snapshot = context.set_directory_snapshot
  local get_directory_snapshot = context.get_directory_snapshot
  local list_with_snapshot = context.list_with_snapshot
  local filter_git_status_lines = context.filter_git_status_lines
  local filter_git_diff_lines = context.filter_git_diff_lines
  local ensure_git_snapshot = context.ensure_git_snapshot
  local indent_size = context.indent_size
  local path_identity = context.path_identity
  local remove_expanded_subtree = context.remove_expanded_subtree
  local reconcile_undone_materialization = context.reconcile_undone_materialization
  local action_mod = context.action_mod

local function is_deleted_record(record)
  return record ~= nil and record.deleted_kind ~= nil
end

local function merge_deleted_entries(directory, lines, git_snapshot, show_hidden)
  local result, seen, deleted = {}, {}, {}
  for _, line in ipairs(lines or {}) do
    result[#result + 1] = line
    seen[paths.strip_directory_marker(line)] = true
  end
  for _, entry in ipairs(git.deleted_children(git_snapshot, directory)) do
    local basename = paths.strip_directory_marker(entry.name)
    local raw_name = entry.kind == 'directory' and basename or entry.name
    if not raw_name:find(paths.directory_separator(), 1, true)
      and not seen[basename]
      and (show_hidden ~= false or basename:sub(1, 1) ~= '.') then
      result[#result + 1] = entry.name
      seen[basename] = true
      deleted[vim.fs.normalize(entry.path)] = entry.kind
    end
  end
  return dirs_then_name(result), deleted
end

local function hide_deleted_expansions(expanded, records)
  local function discard(id)
    local expansion = expanded[id]
    if not expansion then return end
    for _, child in ipairs(expansion.children or {}) do discard(child.id) end
    expanded[id] = nil
  end
  local parents = vim.tbl_keys(expanded)
  for _, id in ipairs(parents) do
    local parent = records[id]
    if parent and parent.deleted_kind then discard(id) end
  end
  local function prune(parent_id)
    local expansion = expanded[parent_id]
    if not expansion then return end
    local children = {}
    for _, child in ipairs(expansion.children or {}) do
      if child.deleted_kind then
        discard(child.id)
      else
        children[#children + 1] = child
        prune(child.id)
      end
    end
    expansion.children = children
  end
  for id in pairs(expanded) do prune(id) end
end

local function capture_deleted_guard_snapshot(bufnr, state)
  state = state or states[bufnr]
  if not state then return end
  state.edit_snapshot = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  state.edit_row_ids = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
      { details = true })) do
    if not (mark[4] and mark[4].invalid) then
      state.edit_row_ids[mark[2]] = mark[1]
    end
  end
end

local function changed_rows_need_decoration_refresh(bufnr, firstline,
    lastline, new_lastline, old_ids)
  if new_lastline ~= lastline then return true end
  local active_by_row = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace,
      { firstline, 0 }, { new_lastline, -1 }, { details = true })) do
    local row, id, details = mark[2], mark[1], mark[4] or {}
    if details.invalid then return true end
    active_by_row[row] = id
  end
  for row = firstline, lastline - 1 do
    local expected = old_ids[row]
    if expected and active_by_row[row] ~= expected then return true end
  end
  return false
end

local function restore_deleted_rows(bufnr, state)
  state = state or states[bufnr]
  local pending_restore = state and state.pending_deleted_restore
  if not pending_restore or state.restoring_deleted then return end
  state.restoring_deleted = true
  local ok = pcall(function()
    vim.api.nvim_buf_set_lines(bufnr, pending_restore.firstline,
      pending_restore.new_lastline, false, pending_restore.lines)
    for row, id in pairs(pending_restore.row_ids) do
      if state.rows[id] then set_row_mark(bufnr, row, id) end
    end
  end)
  state.restoring_deleted = nil
  state.pending_deleted_restore = nil
  if ok then
    local row_ids = refresh_display_ids(bufnr, state)
    capture_deleted_guard_snapshot(bufnr, state)
    refresh_highlights(bufnr, state, row_ids)
    refresh_icons(bufnr, state, row_ids)
  end
end

local function attach_deleted_guard(bufnr)
  if deleted_guards[bufnr] then return end
  local attached = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, changed_buf, _, firstline, lastline, new_lastline)
      local state = states[changed_buf]
      if not state or state.restoring_deleted or state.suppress_deleted_guard then return end
      local old_lines, old_ids = state.edit_snapshot or {}, state.edit_row_ids or {}
      local deleted_touched = false
      for row = firstline, lastline - 1 do
        local id = old_ids[row]
        if id and is_deleted_record(state.rows[id]) then
          deleted_touched = true
          break
        end
      end
      if deleted_touched then
        state.decorations_dirty = true
        local original_lines = {}
        for row = firstline, lastline - 1 do
          if old_lines[row + 1] ~= nil then
            original_lines[#original_lines + 1] = old_lines[row + 1]
          end
        end
        local pending_restore = {
          firstline = firstline,
          new_lastline = new_lastline,
          lines = original_lines,
          row_ids = vim.deepcopy(old_ids),
        }
        state.pending_deleted_restore = pending_restore
        vim.schedule(function()
          if states[changed_buf] == state
            and state.pending_deleted_restore == pending_restore then
            restore_deleted_rows(changed_buf, state)
          end
        end)
        return
      end

      local delta = new_lastline - lastline
      if changed_rows_need_decoration_refresh(changed_buf, firstline,
          lastline, new_lastline, old_ids) then
        state.decorations_dirty = true
      end
      local next_ids = {}
      for row, id in pairs(old_ids) do
        if row < firstline then
          next_ids[row] = id
        elseif row >= lastline then
          local target = row + delta
          next_ids[target] = id
        end
      end
      state.edit_snapshot = vim.api.nvim_buf_get_lines(changed_buf, 0, -1, false)
      state.edit_row_ids = next_ids
    end,
    on_detach = function(_, detached_buf)
      deleted_guards[detached_buf] = nil
    end,
  })
  if attached then deleted_guards[bufnr] = true end
end

function Buffer:expand(row)
  local bufnr = vim.api.nvim_get_current_buf()
  reconcile_undone_materialization(bufnr)
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  local rec = current_row_record(bufnr, row - 1)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if not rec or not line then return nil, 'row identity is unavailable' end
  if not is_dir_line(rec.name) then return false end

  local state = states[bufnr]
  local display_row_ids
  local just_materialized = false
  if not state.expanded[rec.id] then
    local path = row_path(self.root, rec, line)
    local physical_children, snapshot
    if rec.deleted_kind then
      physical_children = {}
      snapshot = {
        wildignore = vim.o.wildignore or '', show_hidden = state.view_show_hidden,
        respect_gitignore = state.view_respect_gitignore,
      }
    else
      local err
      physical_children, snapshot, err = list_with_snapshot(path,
        state.view_show_hidden, state.view_respect_gitignore)
      if not physical_children then
        ui.notify('direct: cannot expand ' .. tostring(path) .. ': '
          .. tostring(err), vim.log.levels.ERROR)
        return nil, err
      end
    end
    local options = require('direct.config').options
    local git_snapshot = ensure_git_snapshot(state)
    local show_deleted = options.git.enabled and options.git.show_deleted ~= false
    local children, deleted_children = merge_deleted_entries(path, physical_children,
      show_deleted and git_snapshot or nil, state.view_show_hidden,
      state.view_git_diff_only and state.git_diff_snapshot or nil)
    -- Keep an unfiltered snapshot for destructive sync preflight. Ignored names
    -- are hidden from the view but still make the directory non-empty.
    local known_children = rec.deleted_kind and {} or fs.read_dir_lines(path)
    state.known_children[rec.id] = known_children or vim.deepcopy(physical_children)
    if state.view_git_status_only then
      children = filter_git_status_lines(path, children, state.git_status)
    end
    if state.view_git_diff_only then
      children = filter_git_diff_lines(path, children, state.git_diff_snapshot)
    end
    local materialized = {}
    for order, child_name in ipairs(children) do
      local child_path = M.entry_path(path, child_name)
      local reason = action_mod.path_reason(child_path)
      if not reason then
        materialized[#materialized + 1] = {
          id = next_id(state), kind = 'child', name = child_name,
          deleted_kind = deleted_children[vim.fs.normalize(child_path)],
          text = string.rep(' ', indent_size() * ((rec.depth or 0) + 1)) .. child_name,
          parent = rec.id, order = order, depth = (rec.depth or 0) + 1,
          path = child_path, identity = path_identity(child_path),
        }
      else
        ui.notify('direct: skipping unlistable entry (' .. reason .. '): '
          .. child_name, vim.log.levels.ERROR)
      end
    end
    state.expanded[rec.id] = {
      children = materialized,
      listing_lines = vim.deepcopy(rec.deleted_kind and children or physical_children),
      wildignore = snapshot.wildignore,
      filter_snapshot = vim.deepcopy(snapshot),
      deleted_parent = rec.deleted_kind ~= nil,
    }
    if not rec.deleted_kind then set_directory_snapshot(state, snapshot) end
    just_materialized = true
    if #materialized > 0 then
      local insert_at, add = row, {}
      local modified = vim.bo[bufnr].modified
      local cursor = vim.api.nvim_win_get_cursor(0)
      for _, child in ipairs(materialized) do
        add[#add + 1] = child.text
        state.rows[child.id] = child
      end
      -- A view insertion must not join the preceding user edit. Setting the
      -- buffer's existing undolevels value closes the current block without
      -- changing undo depth (Neovim :help undo-blocks); the insertion then has
      -- its own undo sequence, while text undo remains enabled.
      local undo_levels = vim.bo[bufnr].undolevels
      local base_seq = vim.fn.undotree().seq_cur
      if undo_levels == -123456 then
        -- Neovim reports this sentinel when the buffer inherits the global
        -- option; writing the global value to itself closes the current block
        -- without pinning a buffer-local override.
        vim.go.undolevels = vim.go.undolevels
      elseif undo_levels >= 0 then
        vim.bo[bufnr].undolevels = undo_levels
      end
      state.suppress_deleted_guard = true
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, add)
      state.suppress_deleted_guard = nil
      for offset, child in ipairs(materialized) do
        set_row_mark(bufnr, insert_at + offset - 1, child.id)
      end
      state.display_ids = {}
      display_row_ids = row_ids_by_row(bufnr)
      for display_row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
        local id = display_row_ids[display_row]
        if id then state.display_ids[#state.display_ids + 1] = id end
      end
      capture_deleted_guard_snapshot(bufnr, state)
      refresh_highlights(bufnr, state, display_row_ids)
      state.materialization_seq = vim.fn.undotree().seq_cur
      if state.materialization_seq ~= base_seq then
        local child_ids = {}
        for _, child in ipairs(materialized) do
          child_ids[#child_ids + 1] = child.id
        end
        local materialization = {
          parent_id = rec.id,
          child_ids = child_ids,
          base_seq = base_seq,
          seq = state.materialization_seq,
          parent_path = path,
          parent_identity = path_identity(path),
          listing_lines = vim.deepcopy(children),
          wildignore = snapshot.wildignore or '',
          filter_snapshot = vim.deepcopy(snapshot),
          children_snapshot = vim.deepcopy(materialized),
        }
        state.materialization_undos = state.materialization_undos or {}
        state.materialization_undos[#state.materialization_undos + 1] = materialization
      end
      vim.bo[bufnr].modified = modified
      pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    end
  end

  if just_materialized then vim.cmd('redraw') end
  refresh_icons(bufnr, state, display_row_ids)
  return true
end

local function collapse_snapshot(bufnr, state, parent, parent_row)
  local rows, rows_by_id, expansions, directory_snapshots = {}, {}, {}, {}
  local visible_ids_by_row = row_ids_by_row(bufnr)
  local cursor = parent_row
  local function visit(parent_id)
    local expansion = state.expanded[parent_id]
    if not expansion then return true end
    for _, child in ipairs(expansion.children or {}) do
      local row = cursor + 1
      cursor = row
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      if state.rows[child.id] ~= child or child.parent ~= parent_id
        or visible_ids_by_row[row] ~= child.id
        or line ~= recorded_row_text(child) then
        return false
      end
      local saved = vim.deepcopy(child)
      rows[#rows + 1] = { id = child.id, row = row, text = line }
      rows_by_id[child.id] = saved
      if state.expanded[child.id] then
        expansions[child.id] = vim.deepcopy(state.expanded[child.id])
        if not state.expanded[child.id].deleted_parent then
          directory_snapshots[child.id] = vim.deepcopy(
            state.expanded[child.id].listing_lines or {})
        end
      end
      if not visit(child.id) then return false end
    end
    return true
  end
  if not visit(parent.id) then
    return nil, 'child row has unsaved edits or a missing/invalid identity mark'
  end
  local display_snapshot
  local display_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #state.display_ids == #display_lines then
    local visible_rows, visible_records, complete = {}, {}, true
    for row, id in ipairs(state.display_ids) do
      local rec = state.rows[id]
      local line = display_lines[row]
      local identity = rec and rec.path and path_identity(rec.path) or nil
      if not rec or visible_records[id] or visible_ids_by_row[row - 1] ~= id
        or not identity
        or (rec.kind == 'child'
          and not fs.path_identities_match(identity, rec.identity)) then
        complete = false
        break
      end
      local saved = vim.deepcopy(rec)
      visible_records[id] = saved
      visible_rows[#visible_rows + 1] = {
        id = id, row = row - 1, text = line, record = saved, identity = identity,
      }
    end
    local directory_snapshots = {}
    if complete then
      for id, expanded in pairs(state.expanded) do
        local rec = visible_records[id]
        if not rec or not is_dir_line(rec.name) then
          complete = false
          break
        end
        if not expanded.deleted_parent then
          directory_snapshots[id] = {
            listing_lines = vim.deepcopy(expanded.listing_lines or {}),
            wildignore = expanded.wildignore or vim.o.wildignore or '',
            filter_snapshot = vim.deepcopy(expanded.filter_snapshot),
          }
        end
      end
    end
    if complete then
      display_snapshot = {
        lines = vim.deepcopy(display_lines),
        rows = visible_rows,
        rows_by_id = visible_records,
        root_ids = vim.deepcopy(state.root_ids),
        expansions = vim.deepcopy(state.expanded),
        directory_snapshots = directory_snapshots,
      }
    end
  end
  if not display_snapshot then
    return nil, 'the complete display cannot be safely associated with row identities'
  end
  return {
    parent_id = parent.id,
    parent_path = parent.path,
    parent_identity = path_identity(parent.path),
    parent_text = vim.api.nvim_buf_get_lines(bufnr, parent_row, parent_row + 1, false)[1],
    base_seq = vim.fn.undotree(bufnr).seq_cur,
    rows = rows,
    rows_by_id = rows_by_id,
    expansions = expansions,
    directory_snapshots = directory_snapshots,
    children_snapshot = vim.deepcopy(state.expanded[parent.id].children),
    listing_lines = vim.deepcopy(state.expanded[parent.id].listing_lines or {}),
    wildignore = vim.o.wildignore or '',
    filter_snapshot = vim.deepcopy(get_directory_snapshot(state, parent.path)),
    display_snapshot = display_snapshot,
  }
end


function Buffer:collapse(row)
  local bufnr = vim.api.nvim_get_current_buf()
  reconcile_undone_materialization(bufnr)
  row = row or vim.api.nvim_win_get_cursor(0)[1]
  local parent = current_row_record(bufnr, row - 1)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if not parent or not line then return nil, 'row identity is unavailable' end
  if not is_dir_line(parent.name) then return false end
  local state = states[bufnr]
  local expansion = state.expanded[parent.id]
  if not expansion then return false end

  local snapshot, reason = collapse_snapshot(bufnr, state, parent, row - 1)
  if not snapshot then
    local message = 'direct: cannot collapse ' .. parent.name .. ': ' .. reason
    ui.notify(message, vim.log.levels.ERROR)
    return false, reason
  end
  local display_row_ids
  if #snapshot.rows > 0 then
    local modified = vim.bo[bufnr].modified
    local undo_levels = vim.bo[bufnr].undolevels
    if undo_levels == -123456 then
      vim.go.undolevels = vim.go.undolevels
    elseif undo_levels >= 0 then
      vim.bo[bufnr].undolevels = undo_levels
    end
    state.suppress_deleted_guard = true
    vim.api.nvim_buf_set_lines(bufnr, row, row + #snapshot.rows, false, {})
    state.suppress_deleted_guard = nil
    snapshot.seq = vim.fn.undotree().seq_cur
    snapshot.status = 'collapsed'
    state.collapse_undos = state.collapse_undos or {}
    state.collapse_undos[#state.collapse_undos + 1] = snapshot
    remove_expanded_subtree(bufnr, state, parent.id)
    display_row_ids = refresh_display_ids(bufnr, state)
    capture_deleted_guard_snapshot(bufnr, state)
    refresh_highlights(bufnr, state, display_row_ids)
    vim.bo[bufnr].modified = modified
  else
    state.expanded[parent.id] = nil
  end
  refresh_icons(bufnr, state, display_row_ids)
  return true
end


return {
  is_deleted_record = is_deleted_record,
  merge_deleted_entries = merge_deleted_entries,
  hide_deleted_expansions = hide_deleted_expansions,
  capture_deleted_guard_snapshot = capture_deleted_guard_snapshot,
  restore_deleted_rows = restore_deleted_rows,
  attach_deleted_guard = attach_deleted_guard,
}
end
