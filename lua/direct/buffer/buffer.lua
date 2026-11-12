-- lua/direct/buffer/buffer.lua -- assemble the Direct buffer model and lifecycle.
-- Listing, row state, navigation, open, and sync implementations live in the
-- focused modules under direct.buffer and install methods on the shared model.

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
    if git.status_for(snapshot, M.entry_path(root, line)) then filtered[#filtered + 1] = line end
  end
  return filtered
end

local function filter_git_diff_lines(root, lines, snapshot)
  local filtered = {}
  for _, line in ipairs(lines or {}) do
    if git.status_for(snapshot, M.entry_path(root, line)) then filtered[#filtered + 1] = line end
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

local function ensure_git_snapshot(state) return state.git_status end

local refresh_highlights

local function start_git_status(bufnr, state, timeout_ms)
  if state.git_status_cancel then state.git_status_cancel() end
  local request = {}
  state.git_status_request = request
  state.git_status_pending = true
  local cancel = git.read_async(state.root, timeout_ms, function(snapshot, err)
    if not vim.api.nvim_buf_is_valid(bufnr) or states[bufnr] ~= state or state.git_status_request ~= request then
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
        ui.notify('direct: Git status unavailable for ' .. state.root .. ': ' .. tostring(err), vim.log.levels.WARN)
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
      if snapshot then
        status, conflict = git.status_for(snapshot, rec.path)
      end
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
  if not vim.api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].filetype ~= constants.FILETYPE then return false end
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

local is_deleted_record, merge_deleted_entries, hide_deleted_expansions
local capture_deleted_guard_snapshot, restore_deleted_rows, attach_deleted_guard

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
local function path_identity(path) return fs.path_identity(path, fs.stat(path)) end

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
    return (counts.by_inode[identity.inode] or 0) > 1 or (counts.unknown_by_path[identity.path] or 0) > 0
  end
  return (counts.by_path[identity.path] or 0) > 1
end

local function count_identity(counts, identity)
  if not identity then return end
  counts.by_path[identity.path] = (counts.by_path[identity.path] or 0) + 1
  if identity.inode then
    counts.by_inode[identity.inode] = (counts.by_inode[identity.inode] or 0) + 1
  else
    counts.unknown_by_path[identity.path] = (counts.unknown_by_path[identity.path] or 0) + 1
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
  if name == nil then name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) end
  if type(name) ~= 'string' or name == '' then return nil end
  if fs.stat(name) then return name end
  return nil
end

-- ---------------------------------------------------------------------------
-- sync-boundary framing guard
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

local function indent_size() return require('direct.config').options.indent_size end

local tree_planner = require('direct.buffer.tree')({
  fs = fs,
  states = states,
  namespace = namespace,
  row_ids_by_row = row_ids_by_row,
  set_row_mark = set_row_mark,
  is_dir_line = is_dir_line,
  strip_directory_marker = paths.strip_directory_marker,
  component_reason = component_reason,
  nested_path_reason = sync_plan.nested_path_reason,
  entry_path = M.entry_path,
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
local row_state = require('direct.buffer.row_state')({
  M = M,
  Buffer = Buffer,
  fs = fs,
  paths = paths,
  git = git,
  ui = ui,
  states = states,
  deleted_guards = deleted_guards,
  namespace = namespace,
  set_row_mark = set_row_mark,
  refresh_display_ids = refresh_display_ids,
  refresh_highlights = refresh_highlights,
  refresh_icons = refresh_icons,
  row_ids_by_row = row_ids_by_row,
  current_row_record = current_row_record,
  is_dir_line = is_dir_line,
  dirs_then_name = dirs_then_name,
  next_id = next_id,
  row_path = row_path,
  recorded_row_text = recorded_row_text,
  set_directory_snapshot = set_directory_snapshot,
  set_git_timeout_indicator = listing.set_git_timeout_indicator,
  get_directory_snapshot = get_directory_snapshot,
  list_with_snapshot = list_with_snapshot,
  filter_git_status_lines = filter_git_status_lines,
  filter_git_diff_lines = filter_git_diff_lines,
  ensure_git_snapshot = ensure_git_snapshot,
  indent_size = indent_size,
  path_identity = path_identity,
  remove_expanded_subtree = remove_expanded_subtree,
  reconcile_undone_materialization = reconcile_undone_materialization,
  action_mod = action_mod,
})
is_deleted_record = row_state.is_deleted_record
local merge_status_deleted_entries = row_state.merge_deleted_entries
merge_deleted_entries = function(directory, lines, git_snapshot, show_hidden, diff_snapshot)
  local result, deleted = merge_status_deleted_entries(directory, lines, git_snapshot, show_hidden)
  if not diff_snapshot then return result, deleted end
  local with_diff, diff_deleted = merge_status_deleted_entries(directory, result, diff_snapshot, show_hidden)
  for path, kind in pairs(diff_deleted) do
    deleted[path] = kind
  end
  return with_diff, deleted
end
hide_deleted_expansions = row_state.hide_deleted_expansions
capture_deleted_guard_snapshot = row_state.capture_deleted_guard_snapshot
restore_deleted_rows = row_state.restore_deleted_rows
attach_deleted_guard = row_state.attach_deleted_guard

-- Buffer options
-- ---------------------------------------------------------------------------

local function ensure_direct_syntax(bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    if vim.b.current_syntax ~= 'direct' then
      if vim.b.current_syntax ~= nil then vim.cmd('syntax clear') end
      vim.b.current_syntax = nil
      vim.bo.syntax = 'direct'
      -- `syntax=direct` does not source a syntax file when the user's global
      -- syntax loader is off. Source this small buffer-local syntax explicitly
      -- so direct listings still get their filename highlights in that setup.
      if vim.b.current_syntax ~= 'direct' then vim.cmd('runtime! syntax/direct.vim') end
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
      if state and (state.decorations_dirty or state.icon_line_count ~= vim.api.nvim_buf_line_count(bufnr)) then
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

-- direct_root keeps a directory listing's filesystem path independent of its
-- buffer name. This is needed when reuse is disabled because Neovim requires
-- buffer names to be unique.
function M.root_for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == constants.FILETYPE then
    local root = vim.b[bufnr].direct_root
    if type(root) == 'string' and root ~= '' then return root end
  end
  return vim.api.nvim_buf_get_name(bufnr)
end

-- Capture current_entry before switching buffers. Reuse uses path identity so
-- symlink aliases still select the same listing.
function M.Buffer(path, options)
  options = options or {}
  local configured = require('direct.config').options.buffers
  local reuse = options.reuse
  if reuse == nil then reuse = configured.reuse end
  local open_in = options.open_in
  if open_in == nil then open_in = configured.open_in end
  local root = paths.root(path)
  local self = setmetatable({
    root = root,
    current_entry = M.current_entry(),
  }, Buffer)

  if reuse then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = M.root_for_buffer(bufnr)
      -- Compare by path identity, never `==` (a symlinked prefix makes the buffer
      -- name and root different spellings of the same directory) and never
      -- `vim.fn.bufnr` (which pattern-matches and is spelling-sensitive).
      if name ~= '' and fs.same_path(name, root) then
        vim.api.nvim_set_current_buf(bufnr)
        vim.b[bufnr].direct_root = root
        return self
      end
    end
  end

  local bufnr
  if not reuse then
    -- Neovim forbids two buffers with the same name (E95). Keep the real root
    -- in buffer-local metadata and give this independent listing a readable,
    -- unique URI.
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_name(bufnr, string.format('direct://%s#%d', root, bufnr))
  elseif open_in == 'new' then
    bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_name(bufnr, root)
  else
    vim.cmd('enew')
    bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(bufnr, root)
  end
  vim.b[bufnr].direct_root = root
  return self
end

-- Buffer attach/list behavior is isolated from row expansion and sync.
local collapse_single_entry_paths = require('direct.buffer.collapse')({
  paths = paths,
  fs = fs,
  entry_path = M.entry_path,
  list_with_snapshot = list_with_snapshot,
  filter_git_status_lines = filter_git_status_lines,
  filter_git_diff_lines = filter_git_diff_lines,
  get_directory_snapshot = get_directory_snapshot,
  apply_snapshot = apply_snapshot,
  is_dir_line = is_dir_line,
  dirs_then_name = dirs_then_name,
})

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
  filter_git_diff_lines = filter_git_diff_lines,
  merge_deleted_entries = merge_deleted_entries,
  hide_deleted_expansions = hide_deleted_expansions,
  path_identity = path_identity,
  add_identity = add_identity,
  matching_identity_values = matching_identity_values,
  identity_is_duplicated = identity_is_duplicated,
  count_identity = count_identity,
  set_directory_snapshot = set_directory_snapshot,
  set_git_timeout_indicator = listing.set_git_timeout_indicator,
  reconcile_undone_materialization = reconcile_undone_materialization,
  refresh_highlights = refresh_highlights,
  refresh_icons = refresh_icons,
  set_options = set_options,
  start_git_status = start_git_status,
  collapse_single_entry_paths = collapse_single_entry_paths,
})

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
  if rec and states[bufnr] and states[bufnr].expanded[rec.id] then return M.collapse() end
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
    for key, value in pairs(previous) do
      state[key] = value
    end
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
    if enabled then return require('direct.folding').expand_all(M) end
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
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  if enabled then return require('direct.folding').expand_all(M) end
  return listed
end

function M.toggle_gitignore()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if vim.bo[bufnr].modified then
    local only_unfiltered = state ~= nil and state.view_respect_gitignore == true
    local saw_timeout = false
    for _, snapshot in ipairs(state and state.directory_snapshots or {}) do
      if snapshot.respect_gitignore then
        if snapshot.git_timeout or snapshot.git_unfiltered then
          saw_timeout = true
        elseif snapshot.git_repo ~= false then
          only_unfiltered = false
          break
        end
      end
    end
    if only_unfiltered and saw_timeout then
      state.view_respect_gitignore = false
      state.view_respect_gitignore_override = true
      for _, snapshot in ipairs(state.directory_snapshots or {}) do
        if snapshot.respect_gitignore then
          snapshot.respect_gitignore = false
          snapshot.git_timeout = false
          snapshot.git_timeout_error = nil
          snapshot.git_unfiltered = false
          snapshot.git_retry_snapshot = nil
          snapshot.git = nil
        end
      end
      listing.set_git_timeout_indicator(bufnr, state)
      ui.notify('direct: Git-ignore filtering disabled; unsaved listing edits were preserved', vim.log.levels.INFO)
      return true
    end
    local reason = 'cannot toggle Git-ignore filtering with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
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
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  return listed
end

function M.toggle_git_status()
  local state = states[vim.api.nvim_get_current_buf()]
  if not state then return set_git_status_only(true) end
  return set_git_status_only(not state.view_git_status_only)
end

function M.show_git_status() return set_git_status_only(true) end

local function set_git_diff_only(ref, include_uncommitted)
  local bufnr = vim.api.nvim_get_current_buf()
  if ref ~= nil and type(ref) ~= 'string' then
    local reason = 'Git ref must be a string'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  if vim.bo[bufnr].modified then
    local reason = 'cannot change the Git-diff filter with unsaved edits; sync or discard them first'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end
  local state = states[bufnr]
  if not state then
    local reason = 'direct listing state is unavailable; re-list this directory'
    ui.notify('direct: ' .. reason, vim.log.levels.ERROR)
    return nil, reason
  end

  local active_snapshot = type(state.git_diff_snapshot) == 'table' and state.git_diff_snapshot or nil
  local same_ref = ref == nil or (active_snapshot and vim.trim(ref) == active_snapshot.ref)
  local same_uncommitted = include_uncommitted == nil
    or (active_snapshot and include_uncommitted == active_snapshot.include_uncommitted)
  local turning_off = state.view_git_diff_only and same_ref and same_uncommitted
  local snapshot = false
  if not turning_off then
    local err
    snapshot, err = git.compare_snapshot(state.root, ref, {
      include_uncommitted = include_uncommitted == true,
    })
    if not snapshot then
      ui.notify('direct: cannot compare Git diff: ' .. tostring(err), vim.log.levels.ERROR)
      return nil, err
    end
  end

  local previous = {
    view_git_diff_only = state.view_git_diff_only,
    git_diff_snapshot = state.git_diff_snapshot,
    expanded = state.expanded,
    known_children = state.known_children,
    directory_snapshots = state.directory_snapshots,
    materialization_undos = state.materialization_undos,
    materialization_recoveries = state.materialization_recoveries,
    collapse_undos = state.collapse_undos,
  }
  state.view_git_diff_only = not turning_off
  state.git_diff_snapshot = snapshot
  state.expanded = {}
  state.known_children = {}
  state.directory_snapshots = {}
  state.materialization_undos = {}
  state.materialization_recoveries = {}
  state.collapse_undos = {}
  local listed, err = M.restore():list({
    reset_undo = true,
    git_diff_resolved = true,
    git_diff_only = not turning_off,
    git_diff_snapshot = snapshot,
  })
  if not listed then
    for key, value in pairs(previous) do
      state[key] = value
    end
    return nil, err
  end
  if not turning_off then return folding.expand_all(M) end
  return listed
end

function M.toggle_git_diff(ref, include_uncommitted) return set_git_diff_only(ref, include_uncommitted) end

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
  filter_git_diff_lines = filter_git_diff_lines,
  is_dir_line = is_dir_line,
  is_real_directory = is_real_directory,
  hidden_descendant = hidden_descendant,
  result_entry = result_entry,
  current_row_record = current_row_record,
  remove_expanded_subtree = remove_expanded_subtree,
  collapse_single_entry_paths = collapse_single_entry_paths,
  set_git_timeout_indicator = listing.set_git_timeout_indicator,
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
