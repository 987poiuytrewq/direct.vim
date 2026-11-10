-- lua/direct/buffer.lua -- direct-buffer lifecycle, row state, sync, and open.
-- Path identity uses fs.same_path. Sync validates edits, stages dependent
-- moves, records only successful actions, and re-lists the filesystem state.
-- Expanded rows retain their filesystem identities; sync reconciles edits per
-- directory and coordinates path-changing moves across the materialized tree.

local M = {}

-- Module tables are captured once so tests can stub `fs.rename`
-- `history.log`, `register.yank`, `ui.notify`,... on the very tables the
-- code below resolves through.
local fs = require('direct.fs')
local paths = require('direct.paths')
local action_mod = require('direct.action.action')
local history = require('direct.history.history')
local register = require('direct.register')
local ui = require('direct.ui')
local highlight = require('direct.highlight')
local git = require('direct.git')
local constants = require('direct.constants')
local folding = require('direct.folding')
local listing = require('direct.buffer.listing')
local rows = require('direct.buffer.rows')
local states = rows.states
local namespace = rows.namespace
local deleted_guards = {}
local state_generations = {}
local next_state_generation = 0
local git_status_timeout_notified = {}
local next_id = rows.next_id
local set_row_mark = rows.set_row_mark
local row_ids_by_row = rows.row_ids_by_row
local refresh_display_ids = rows.refresh_display_ids
local row_path = rows.row_path
local current_row_record = rows.current_row_record
local is_dir_line = rows.is_dir_line
local refresh_icons = rows.refresh_icons
local dirs_then_name = rows.dirs_then_name
local recorded_row_text = rows.recorded_row_text
local visible_row_for_id = rows.visible_row_for_id
local record_identity = rows.record_identity
local remove_expanded_subtree = rows.remove_expanded_subtree
M._state_for_test = rows.state_for_test
M.entry_path = listing.entry_path
M.ignore_set = listing.ignore_set
M.read = listing.read
local function list_with_snapshot(root, show_hidden, respect_gitignore)
  return listing.list_with_snapshot(root, M.read, show_hidden, respect_gitignore)
end

-- Keep only entries represented by the list-time Git status snapshot. Directory
-- statuses are already aggregated from changed descendants by direct.git.
local function filter_git_status_lines(root, lines, snapshot)
  local filtered = {}
  for _, line in ipairs(lines or {}) do
    if git.status_for(snapshot, M.entry_path(root, line)) then
      filtered[#filtered + 1] = line
    end
  end
  return filtered
end

local set_directory_snapshot = listing.set_directory_snapshot
local get_directory_snapshot = listing.get_directory_snapshot
local apply_snapshot = listing.apply_snapshot
local path_without_marker = listing.path_without_marker
local lstat = listing.lstat
local is_real_directory = listing.is_real_directory
local hidden_descendant = listing.hidden_descendant

local function ensure_git_snapshot(state)
  return state.git_status
end

local refresh_highlights

local function start_git_status(bufnr, state, timeout_ms)
  if state.git_status_cancel then state.git_status_cancel() end
  local request = {}
  state.git_status_request = request
  state.git_status_pending = true
  local cancel = git.read_async(state.root, timeout_ms, function(snapshot, err)
    if not vim.api.nvim_buf_is_valid(bufnr) or states[bufnr] ~= state
      or state.git_status_request ~= request then
      return
    end
    if not fs.stat(state.root) then return end
    state.git_status_request = nil
    state.git_status_cancel = nil
    state.git_status_pending = false
    state.git_status = snapshot or false

    if err then
      local key = paths.canonical(state.root)
      if not git_status_timeout_notified[key] then
        git_status_timeout_notified[key] = true
        ui.notify('direct: Git status unavailable for ' .. state.root .. ': '
          .. tostring(err), vim.log.levels.WARN)
      end
    end

    if snapshot and not vim.bo[bufnr].modified then
      local expand_git_view = state.git_expand_all == true
      state.git_expand_all = false
      vim.api.nvim_buf_call(bufnr, function()
        if states[bufnr] == state and not vim.bo[bufnr].modified then
          M.list(state.root, { git_status_resolved = true, git_status = snapshot })
          if expand_git_view then require('direct.folding').expand_all(M) end
        end
      end)
      return
    end

    local row_ids = row_ids_by_row(bufnr)
    refresh_highlights(bufnr, state, row_ids)
    refresh_icons(bufnr, state, row_ids)
  end)
  if state.git_status_request == request then state.git_status_cancel = cancel end
end

function M.cancel_git_status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then return false end
  if state.git_status_cancel then state.git_status_cancel() end
  state.git_status_cancel = nil
  state.git_status_request = nil
  state.git_status_pending = false
  return true
end

refresh_highlights = function(bufnr, state, row_ids)
  local options = require('direct.config').options
  local snapshot = ensure_git_snapshot(state)
  local display_rows = {}
  row_ids = row_ids or row_ids_by_row(bufnr)
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    local id = row_ids[row]
    local rec = id and state.rows[id]
    if rec then
      local status, conflict
      if snapshot then status, conflict = git.status_for(snapshot, rec.path) end
      display_rows[#display_rows + 1] = {
        row = row,
        depth = rec.depth or 0,
        status = status,
        conflict = conflict,
        first_status = snapshot and git.first_status_for(snapshot, rec.path) or nil,
        deleted_kind = rec.deleted_kind,
      }
    end
  end
  highlight.render(bufnr, display_rows, options)
end

-- Refresh Git-only decorations for a loaded direct buffer without changing its
-- text or list-time filesystem snapshot.
function M.refresh_git_status(bufnr, root)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_loaded(bufnr)
    or vim.bo[bufnr].filetype ~= constants.FILETYPE then
    return false
  end
  local state = states[bufnr]
  if not state or (root and state.root ~= root) then return false end
  state.git_status = nil
  local options = require('direct.config').options
  if not options.git.enabled then
    state.git_status = false
    refresh_highlights(bufnr, state)
    refresh_icons(bufnr, state)
    return true
  end
  refresh_highlights(bufnr, state)
  refresh_icons(bufnr, state)
  start_git_status(bufnr, state, options.git.timeout_ms)
  return true
end

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

local sync_plan = require('direct.buffer.sync_plan')({
  action_mod = action_mod,
  entry_path = M.entry_path,
  is_dir_line = is_dir_line,
  directory_separator = paths.directory_separator,
  dirs_then_name = dirs_then_name,
  lstat = lstat,
  path_without_marker = path_without_marker,
  fs = fs,
})
M.classify = sync_plan.classify
local classify_identity = sync_plan.classify_identity
M._component_reason = sync_plan.component_reason
M._nested_path_reason = sync_plan.nested_path_reason
local component_reason = sync_plan.component_reason
local first_unsafe = sync_plan.first_unsafe
local ambiguous_message = sync_plan.ambiguous_message
local result_entry = sync_plan.result_entry
local build_actions = sync_plan.build_actions
local pending = require('direct.pending')
M._pending_for_test = pending
local file_operations = require('direct.file_operations')
local pending_sync = {}
local reconcile_undone_materialization
local edited_subtrees
local children_integrity

local Buffer = {}
Buffer.__index = Buffer

-- Display rows are identified by extmarks rather than their spelling.  In
-- particular, child rows are never interpreted as root-relative filenames.
local function path_identity(path)
  return fs.path_identity(path, fs.stat(path))
end

local function add_identity(index, identity, value)
  if not identity then return end
  local function add(bucket, key)
    if not key then return end
    local entry = bucket[key]
    if not entry then
      entry = { count = 0 }
      bucket[key] = entry
    end
    entry.count = entry.count + 1
    if entry.count == 1 then entry.only = value end
    if entry.count > 1 then entry.only = nil end
  end
  add(index.by_path, identity.path)
  if identity.inode then
    add(index.by_inode, identity.inode)
  else
    add(index.unknown_by_path, identity.path)
  end
end

local function matching_identity_values(index, identity)
  if not identity then return nil, 0 end
  if not identity.inode then
    local entry = index.by_path[identity.path]
    return entry and entry.only, entry and entry.count or 0
  end
  local inode = index.by_inode[identity.inode]
  local unknown = index.unknown_by_path[identity.path]
  local count = (inode and inode.count or 0) + (unknown and unknown.count or 0)
  if count == 1 then return (inode and inode.only) or (unknown and unknown.only), count end
  return nil, count
end

local function identity_is_duplicated(identity, counts)
  if not identity then return false end
  if identity.inode then
    return (counts.by_inode[identity.inode] or 0) > 1
      or (counts.unknown_by_path[identity.path] or 0) > 0
  end
  return (counts.by_path[identity.path] or 0) > 1
end

local function count_identity(counts, identity)
  if not identity then return end
  counts.by_path[identity.path] = (counts.by_path[identity.path] or 0) + 1
  if identity.inode then
    counts.by_inode[identity.inode] = (counts.by_inode[identity.inode] or 0) + 1
  else
    counts.unknown_by_path[identity.path] =
      (counts.unknown_by_path[identity.path] or 0) + 1
  end
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- current_entry([name]) -> `name` when it names an existing filesystem entry
-- else nil. Defaults to the current buffer's stored name: the buffer name
-- `nvim_buf_get_name` returns (the resolved spelling). `same_path` makes the
-- spelling irrelevant, so no `bufname('%')` accessor is needed.
function M.current_entry(name)
  if name == nil then
    name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  end
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  if fs.stat(name) then
    return name
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- classification
-- ---------------------------------------------------------------------------

-- classify(actual, expected) -> a plan
-- { kind = 'ADD', added = <lines, dirs-then-name> }
-- { kind = 'DELETE', removed = <lines, dirs-then-name> }
-- { kind = 'RENAME', moves = { { src = <expected line>, dst = <actual line> } } }
-- { kind = 'AMBIGUOUS', reason = 'duplicate' | 'mixed' }
-- The duplicate check is FIRST: the Python version collapsed
-- duplicates through set diffs, and a duplicated line in a RENAME-shaped edit
-- produced a self-move.
-- ---------------------------------------------------------------------------
-- the sync-boundary framing guard
-- ---------------------------------------------------------------------------

-- unsafe_path_reason(path) -> the shared `action.path_reason`, which rejects
-- invalid UTF-8 and controls before any sync side effect. This boundary keeps
-- its early, user-facing refusal; action serialization applies the same guard
-- to every emitted record.
local function same_lines(actual, expected)
  if #actual ~= #expected then return false end
  for index, line in ipairs(expected) do
    if actual[index] ~= line then return false end
  end
  return true
end

local function indent_size()
  return require('direct.config').options.indent_size
end

local tree_planner = require('direct.buffer.tree')({
  fs = fs,
  states = states,
  namespace = namespace,
  row_ids_by_row = row_ids_by_row,
  set_row_mark = set_row_mark,
  is_dir_line = is_dir_line,
  strip_directory_marker = paths.strip_directory_marker,
  component_reason = component_reason,
  same_lines = same_lines,
  entry_path = M.entry_path,
  ignore_set = M.ignore_set,
  read_with_snapshot = listing.read_with_snapshot,
  filter_git_status_lines = filter_git_status_lines,
  action_mod = action_mod,
  indent_size = indent_size,
})
children_integrity = tree_planner.children_integrity
edited_subtrees = tree_planner.edited_subtrees
reconcile_undone_materialization = require('direct.buffer.undo_state')({
  states = states,
  namespace = namespace,
  fs = fs,
  path_identity = path_identity,
  same_lines = same_lines,
  row_ids_by_row = row_ids_by_row,
  set_row_mark = set_row_mark,
  refresh_display_ids = refresh_display_ids,
  is_dir_line = is_dir_line,
  recorded_row_text = recorded_row_text,
  indent_size = indent_size,
  ignore_set = M.ignore_set,
  read = M.read,
  read_with_snapshot = listing.read_with_snapshot,
  entry_path = M.entry_path,
  highlight = highlight,
  refresh_highlights = refresh_highlights,
  refresh_icons = refresh_icons,
  remove_expanded_subtree = remove_expanded_subtree,
})

-- ---------------------------------------------------------------------------
-- Buffer options
-- ---------------------------------------------------------------------------

local function ensure_direct_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    if vim.b.current_syntax ~= 'direct' then
      if vim.b.current_syntax ~= nil then
        vim.cmd('syntax clear')
      end
      vim.b.current_syntax = nil
      vim.bo.syntax = 'direct'
      -- `syntax=direct` does not source a syntax file when the user's global
      -- syntax loader is off. Source this small buffer-local syntax explicitly
      -- so direct listings still get their filename highlights in that setup.
      if vim.b.current_syntax ~= 'direct' then
        vim.cmd('runtime! syntax/direct.vim')
      end
    else
      vim.bo.syntax = 'direct'
    end
  end)
end

local function set_options(bufnr)
  next_state_generation = next_state_generation + 1
  local generation = next_state_generation
  state_generations[bufnr] = generation
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].swapfile = false
  -- Keep a dirty listing available while navigating to another directory even
  -- when the user's global 'hidden' option is off.
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].filetype = constants.FILETYPE
  ensure_direct_syntax(bufnr)
  -- BufWriteCmd <buffer>: modified listings sync, while a clean `:write`
  -- refreshes from disk instead of interpreting external changes as deletions.
  -- Each buffer owns a shared group outside `direct` so re-sourcing
  -- plugin/direct.lua can clear its global handlers without removing this one.
  -- Clear only this buffer's previous handler so relisting cannot stack handlers.
  local group = vim.api.nvim_create_augroup('direct-buffer', { clear = false })
  pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = bufnr,
    callback = function()
      if state_generations[bufnr] ~= generation then return end
      state_generations[bufnr] = nil
      local operation = pending_sync[bufnr]
      if operation then
        if operation.cancel then operation.cancel() end
        operation.cleanup()
      end
      states[bufnr] = nil
      deleted_guards[bufnr] = nil
    end,
    desc = 'direct: release listing row state when the buffer is wiped',
  })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      vim.api.nvim_set_current_buf(args.buf)
      if pending.refuse('sync') then return end
      if vim.bo[args.buf].modified then
        vim.cmd('DirectSync')
      else
        M.restore():list({ reset_undo = true })
      end
    end,
    desc = 'direct: sync the listing on :write',
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      vim.api.nvim_set_current_buf(args.buf)
      M.restore():list({ reset_undo = true })
    end,
    desc = 'direct: refresh the listing on :edit',
  })
  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    buffer = bufnr,
    callback = function()
      local state = states[bufnr]
      if state then restore_deleted_rows(bufnr, state) end
      reconcile_undone_materialization(bufnr)
      -- Edits such as `J` can move display extmarks from a deleted row into
      -- the middle of the surviving line. Rebuild them from row identities.
      state = states[bufnr]
      if state and state.decorations_dirty and not state.pending_deleted_restore then
        local row_ids = row_ids_by_row(bufnr)
        refresh_highlights(bufnr, state, row_ids)
        refresh_icons(bufnr, state, row_ids)
      end
    end,
    desc = 'direct: reconcile child rows and refresh display marks after text changes',
  })
  vim.api.nvim_create_autocmd('TextChangedI', {
    group = group,
    buffer = bufnr,
    callback = function()
      local state = states[bufnr]
      if state then restore_deleted_rows(bufnr, state) end
      state = states[bufnr]
      if state and (state.decorations_dirty
          or state.icon_line_count ~= vim.api.nvim_buf_line_count(bufnr)) then
        local row_ids = row_ids_by_row(bufnr)
        refresh_highlights(bufnr, state, row_ids)
        refresh_icons(bufnr, state, row_ids)
      end
    end,
    desc = 'direct: refresh display marks when insert-mode edits change line count',
  })
  folding.install_mappings(bufnr, M)
  attach_deleted_guard(bufnr)
  capture_deleted_guard_snapshot(bufnr, states[bufnr])
end

-- ---------------------------------------------------------------------------
-- Attach / create
-- ---------------------------------------------------------------------------

-- Capture current_entry before switching buffers, then reuse a buffer only when
-- fs.same_path confirms that it represents the requested directory.
function M.Buffer(path)
  local root = paths.root(path)
  local self = setmetatable({
    root = root,
    current_entry = M.current_entry(),
  }, Buffer)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    -- Compare by path identity, never `==` (a symlinked prefix makes the buffer
    -- name and root different spellings of the same directory) and never
    -- `vim.fn.bufnr` (which pattern-matches and is spelling-sensitive).
    if name ~= '' and fs.same_path(name, root) then
      vim.api.nvim_set_current_buf(bufnr)
      return self
    end
  end

  vim.cmd('enew')
  vim.api.nvim_buf_set_name(0, root)
  return self
end

-- Buffer attach/list behavior is isolated from row expansion and sync.
require('direct.buffer.list')({
  M = M,
  Buffer = Buffer,
  paths = paths,
  fs = fs,
  action_mod = action_mod,
  ui = ui,
  constants = constants,
  states = states,
  namespace = namespace,
  next_id = next_id,
  set_row_mark = set_row_mark,
  row_ids_by_row = row_ids_by_row,
  current_row_record = current_row_record,
  row_path = row_path,
  is_dir_line = is_dir_line,
  indent_size = indent_size,
  list_with_snapshot = list_with_snapshot,
  filter_git_status_lines = filter_git_status_lines,
  merge_deleted_entries = merge_deleted_entries,
  hide_deleted_expansions = hide_deleted_expansions,
  path_identity = path_identity,
  add_identity = add_identity,
  matching_identity_values = matching_identity_values,
  identity_is_duplicated = identity_is_duplicated,
  count_identity = count_identity,
  set_directory_snapshot = set_directory_snapshot,
  reconcile_undone_materialization = reconcile_undone_materialization,
  refresh_highlights = refresh_highlights,
  refresh_icons = refresh_icons,
  set_options = set_options,
  start_git_status = start_git_status,
})

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
      show_deleted and git_snapshot or nil, state.view_show_hidden)
    -- Keep an unfiltered snapshot for destructive sync preflight. Ignored names
    -- are hidden from the view but still make the directory non-empty.
    local known_children = rec.deleted_kind and {} or fs.read_dir_lines(path)
    state.known_children[rec.id] = known_children or vim.deepcopy(physical_children)
    if state.view_git_status_only then
      children = filter_git_status_lines(path, children, state.git_status)
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

function M.expand()
  if pending.refuse('expand', 'willRenameFiles') then return nil end
  local buffer = M.restore()
  return buffer:expand(vim.api.nvim_win_get_cursor(0)[1])
end

function M.collapse()
  if pending.refuse('collapse', 'willRenameFiles') then return nil end
  local buffer = M.restore()
  return buffer:collapse(vim.api.nvim_win_get_cursor(0)[1])
end

function M.toggle()
  if pending.refuse('toggle', 'willRenameFiles') then return nil end
  local bufnr = vim.api.nvim_get_current_buf()
  local rec = current_row_record(bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if rec and states[bufnr] and states[bufnr].expanded[rec.id] then
    return M.collapse()
  end
  return M.expand()
end

function M.toggle_hidden()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    local reason = 'cannot toggle hidden entries with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local previous = {
    view_show_hidden = state.view_show_hidden,
    view_show_hidden_override = state.view_show_hidden_override,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_show_hidden = not state.view_show_hidden
  state.view_show_hidden_override = true
  -- Rebuild from the root so every expanded subtree uses the same visibility
  -- setting; doing this only changes the view and is not text-undoable.
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({ reset_undo = true })
  if not listed then
    for key, value in pairs(previous) do state[key] = value end
    return nil, err
  end
  return listed
end

local function set_git_status_only(enabled)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    local reason = 'cannot change the Git-status filter with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if state.view_git_status_only == enabled then
    if enabled then
      return require('direct.folding').expand_all(M)
    end
    return true
  end
  local previous = {
    view_git_status_only = state.view_git_status_only,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_git_status_only = enabled
  state.git_expand_all = enabled
  -- Rebuild at every level from a fresh Git snapshot; the view must not leave
  -- stale child rows behind when the filter is enabled or disabled.
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({ reset_undo = true })
  if not listed then
    for key, value in pairs(previous) do state[key] = value end
    return nil, err
  end
  if enabled then
    return require('direct.folding').expand_all(M)
  end
  return listed
end

function M.toggle_gitignore()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    local reason = 'cannot toggle Git-ignore filtering with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local previous = {
    view_respect_gitignore = state.view_respect_gitignore,
    view_respect_gitignore_override = state.view_respect_gitignore_override,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_respect_gitignore = not state.view_respect_gitignore
  state.view_respect_gitignore_override = true
  -- Rebuild from the root so every expanded level uses the same Git rules.
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({ reset_undo = true })
  if not listed then
    for key, value in pairs(previous) do state[key] = value end
    return nil, err
  end
  return listed
end

function M.toggle_git_status()
  local state = states[vim.api.nvim_get_current_buf()]
  if not state then
    return set_git_status_only(true)
  end
  return set_git_status_only(not state.view_git_status_only)
end

function M.show_git_status()
  return set_git_status_only(true)
end

-- Visible file/Git navigation and folding accessors live in navigation.lua.
require('direct.buffer.navigation')({
  M = M,
  states = states,
  row_ids_by_row = row_ids_by_row,
  git = git,
  is_dir_line = is_dir_line,
  current_row_record = current_row_record,
  visible_row_for_id = visible_row_for_id,
  record_identity = record_identity,
  pending = pending,
  folding = folding,
  ensure_git_snapshot = ensure_git_snapshot,
})

-- Sync planning and execution lives in its own module; it receives the buffer's
-- private state and helpers so this extraction does not change behavior.
require('direct.buffer.sync')({
  M = M,
  Buffer = Buffer,
  action_mod = action_mod,
  history = history,
  register = register,
  ui = ui,
  fs = fs,
  paths = paths,
  git = git,
  pending = pending,
  file_operations = file_operations,
  states = states,
  pending_sync = pending_sync,
  restore_deleted_rows = restore_deleted_rows,
  reconcile_undone_materialization = reconcile_undone_materialization,
  get_directory_snapshot = get_directory_snapshot,
  children_integrity = children_integrity,
  row_ids_by_row = row_ids_by_row,
  indent_size = indent_size,
  edited_subtrees = edited_subtrees,
  first_unsafe = first_unsafe,
  ambiguous_message = ambiguous_message,
  classify_identity = classify_identity,
  build_actions = build_actions,
  apply_snapshot = apply_snapshot,
  filter_git_status_lines = filter_git_status_lines,
  is_dir_line = is_dir_line,
  is_real_directory = is_real_directory,
  hidden_descendant = hidden_descendant,
  result_entry = result_entry,
  current_row_record = current_row_record,
  remove_expanded_subtree = remove_expanded_subtree,
})

-- Opening and row-path operations are kept separate from listing and sync.
require('direct.buffer.open')({
  M = M,
  Buffer = Buffer,
  paths = paths,
  ui = ui,
  constants = constants,
  states = states,
  restore_deleted_rows = restore_deleted_rows,
  children_integrity = children_integrity,
  current_row_record = current_row_record,
  is_deleted_record = is_deleted_record,
  row_path = row_path,
  is_dir_line = is_dir_line,
  recorded_row_text = recorded_row_text,
  indent_size = indent_size,
  remove_expanded_subtree = remove_expanded_subtree,
})

return M
