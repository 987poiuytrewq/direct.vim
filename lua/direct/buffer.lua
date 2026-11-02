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
local action_mod = require('direct.action')
local history = require('direct.history')
local register = require('direct.register')
local ui = require('direct.ui')
local highlight = require('direct.highlight')
local git = require('direct.git')
local constants = require('direct.constants')
local folding = require('direct.folding')
local listing = require('direct.buffer_listing')
local rows = require('direct.buffer_rows')
local states = rows.states
local namespace = rows.namespace
local next_id = rows.next_id
local set_row_mark = rows.set_row_mark
local row_id_at = rows.row_id_at
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
local function list_with_snapshot(root, show_hidden)
  return listing.list_with_snapshot(root, M.read, show_hidden)
end
local set_directory_snapshot = listing.set_directory_snapshot
local get_directory_snapshot = listing.get_directory_snapshot
local apply_snapshot = listing.apply_snapshot
local path_without_marker = listing.path_without_marker
local lstat = listing.lstat
local is_real_directory = listing.is_real_directory
local hidden_descendant = listing.hidden_descendant

local function ensure_git_snapshot(state, options)
  if options.git.enabled and state.git_status == nil then
    state.git_status = git.read(state.root) or false
  end
  return state.git_status
end

local function refresh_highlights(bufnr, state)
  local options = require('direct.config').options
  local snapshot = ensure_git_snapshot(state, options)
  local display_rows = {}
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    local id = row_id_at(bufnr, row)
    local rec = id and state.rows[id]
    if rec then
      display_rows[#display_rows + 1] = {
        row = row,
        depth = rec.depth or 0,
        status = snapshot and git.status_for(snapshot, rec.path) or nil,
      }
    end
  end
  highlight.render(bufnr, display_rows, options)
end

local sync_plan = require('direct.buffer_sync_plan')({
  action_mod = action_mod,
  entry_path = M.entry_path,
  is_dir_line = is_dir_line,
  dirs_then_name = dirs_then_name,
  lstat = lstat,
  path_without_marker = path_without_marker,
  fs = fs,
})
M.classify = sync_plan.classify
M._component_reason = sync_plan.component_reason
M._nested_path_reason = sync_plan.nested_path_reason
local component_reason = sync_plan.component_reason
local first_unsafe = sync_plan.first_unsafe
local ambiguous_message = sync_plan.ambiguous_message
local result_entry = sync_plan.result_entry
local build_actions = sync_plan.build_actions
local pending = require('direct.pending')
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

local tree_planner = require('direct.buffer_tree')({
  fs = fs,
  states = states,
  namespace = namespace,
  set_row_mark = set_row_mark,
  is_dir_line = is_dir_line,
  component_reason = component_reason,
  same_lines = same_lines,
  entry_path = M.entry_path,
  ignore_set = M.ignore_set,
  read_with_snapshot = listing.read_with_snapshot,
  action_mod = action_mod,
})
children_integrity = tree_planner.children_integrity
edited_subtrees = tree_planner.edited_subtrees
reconcile_undone_materialization = require('direct.buffer_undo_state')({
  states = states,
  namespace = namespace,
  fs = fs,
  path_identity = path_identity,
  same_lines = same_lines,
  row_id_at = row_id_at,
  set_row_mark = set_row_mark,
  refresh_display_ids = refresh_display_ids,
  is_dir_line = is_dir_line,
  recorded_row_text = recorded_row_text,
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
-- rename staging
-- ---------------------------------------------------------------------------
--
-- The staging mechanism itself lives in `action.lua` (`action.stage_moves`
-- `action.first_free_temp`) because the group REVERSAL has to use the very same
-- one: a swap and its reversal must both route through `.direct-tmp-<n>`, or the
-- reversal renames a live name over a name whose contents are not saved anywhere
-- (the reported data-loss path). This module keeps the reporting around
-- it: the orphan temps of a failed staging rename and the temp of a move that
-- never landed are named, never silently dropped.
local stage_moves = action_mod.stage_moves

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
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].swapfile = false
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
    callback = function() states[bufnr] = nil end,
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
        M.restore():list()
      end
    end,
    desc = 'direct: sync the listing on :write',
  })
  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      vim.api.nvim_set_current_buf(args.buf)
      M.restore():list()
    end,
    desc = 'direct: refresh the listing on :edit',
  })
  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    buffer = bufnr,
    callback = function()
      reconcile_undone_materialization(bufnr)
      -- Edits such as `J` can move display extmarks from a deleted row into
      -- the middle of the surviving line. Rebuild them from row identities.
      local state = states[bufnr]
      if state then
        refresh_highlights(bufnr, state)
        refresh_icons(bufnr, state)
      end
    end,
    desc = 'direct: reconcile child rows and refresh display marks after text changes',
  })
  vim.api.nvim_create_autocmd('TextChangedI', {
    group = group,
    buffer = bufnr,
    callback = function()
      local state = states[bufnr]
      if state and state.icon_line_count ~= vim.api.nvim_buf_line_count(bufnr) then
        refresh_highlights(bufnr, state)
        refresh_icons(bufnr, state)
      end
    end,
    desc = 'direct: refresh display marks when insert-mode edits change line count',
  })
  folding.install_mappings(bufnr, M)
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

-- Attach to the current buffer's directory without listing; the caller decides when to refresh.
function M.restore()
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  return M.Buffer(name)
end

-- List a directory in an attached direct buffer.
function M.list(path)
  local buffer = M.Buffer(path)
  buffer:list()
  return buffer
end

-- ---------------------------------------------------------------------------
-- listing
-- ---------------------------------------------------------------------------

-- Restore the cursor to the pre-attach entry; leave it unchanged if that entry
-- no longer exists. Reset the column on a match.
function Buffer:place_cursor(lines, row_identities, entry_identity)
  if self.current_entry == nil then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  for index, line in ipairs(lines) do
    local matches
    if row_identities and entry_identity then
      matches = fs.path_identities_match(row_identities[index], entry_identity)
    else
      local record = current_row_record(bufnr, index - 1)
      local path = row_path(self.root, record, line)
        or M.entry_path(self.root, line)
      matches = fs.same_path(path, self.current_entry)
    end
    if matches then
      pcall(vim.api.nvim_win_set_cursor, 0, { index, 0 })
      return
    end
  end
end

-- Refresh the listing and restore cursor/options; mark unmodified after refresh.
--
-- (hardening): a directory can hold an entry whose NAME carries a
-- newline (or another control character / a tab). Such a name can never be a
-- buffer line -- `nvim_buf_set_lines` raises "'replacement string' item contains
-- newlines" -- so listing that directory used to abort the whole listing. The
-- representability guard (`action.path_reason`, the same one the history framing
-- uses) drops every unrepresentable line BEFORE the set, notifies per dropped
-- entry, and lists the survivors. A ' ' (space) name is NOT dropped: a space is
-- representable and must still list.
function Buffer:list()
  local bufnr = vim.api.nvim_get_current_buf()
  local old_state = states[bufnr]
  local show_hidden_override
  if old_state and old_state.view_show_hidden_override
    and type(old_state.view_show_hidden) == 'boolean' then
    show_hidden_override = old_state.view_show_hidden
  end
  local lines, snapshot, err = list_with_snapshot(self.root, show_hidden_override)
  if not lines then
    ui.notify('direct: cannot list ' .. tostring(self.root) .. ': '
      .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end

  local safe = {}
  for _, line in ipairs(lines) do
    local reason = action_mod.path_reason(M.entry_path(self.root, line))
    if reason ~= nil then
      ui.notify('direct: skipping unlistable entry (' .. reason .. '): ' .. line,
        vim.log.levels.ERROR)
    else
      safe[#safe + 1] = line
    end
  end

  reconcile_undone_materialization(bufnr)
  old_state = states[bufnr]
  local old_expanded = {}
  local old_known_children = {}
  local old_index = { by_path = {}, by_inode = {}, unknown_by_path = {} }
  if old_state then
    old_expanded = old_state.expanded or {}
    old_known_children = old_state.known_children or {}
    local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for row, line in ipairs(old_lines) do
      local id = row_id_at(bufnr, row - 1)
      local rec = id and old_state.rows[id]
      -- Reuse a root only while its extmark still identifies the unchanged
      -- row. `rec.path` is assigned from this row's entry path on every list;
      -- checking it against the same path again was redundant. Edited text may
      -- happen to equal another root's name; that is not an identity change.
      if rec and rec.kind == 'root' and line == rec.text and line == rec.name
        and rec.path then
        local candidate = { record = rec, identity = path_identity(rec.path) }
        add_identity(old_index, candidate.identity, candidate)
      end
    end
  end

  local new_identities, new_counts = {}, {
    by_path = {}, by_inode = {}, unknown_by_path = {},
  }
  for index, line in ipairs(safe) do
    local identity = path_identity(M.entry_path(self.root, line))
    new_identities[index] = identity
    count_identity(new_counts, identity)
  end

  local state = {
    root = self.root,
    rows = {},
    expanded = old_expanded,
    -- This survives collapse and re-listing so a directory previously observed
    -- to be non-empty cannot be trashed just because its rows are hidden.
    known_children = old_known_children,
    root_ids = {},
    next_id = old_state and old_state.next_id or 0,
    display_ids = {},
    materialization_undos = {},
    directory_snapshots = old_state
      and vim.deepcopy(old_state.directory_snapshots or {}) or {},
    materialization_recoveries = old_state
      and vim.deepcopy(old_state.materialization_recoveries or {}) or {},
    collapse_undos = old_state
      and vim.deepcopy(old_state.collapse_undos or {}) or {},
    git_status = nil,
    view_show_hidden = snapshot.show_hidden,
    view_show_hidden_override = old_state and old_state.view_show_hidden_override or false,
  }
  local git_options = require('direct.config').options.git
  if git_options.enabled then
    state.git_status = git.read(self.root) or false
  end
  set_directory_snapshot(state, snapshot)
  local roots = {}
  local used_root = {}
  for line_index, line in ipairs(safe) do
    local path = M.entry_path(self.root, line)
    local identity = new_identities[line_index]
    local candidate, candidate_count = matching_identity_values(old_index, identity)
    local rec = candidate_count == 1 and candidate and candidate.record or nil
    -- Equivalent spellings may occur more than once (for example two symlink
    -- aliases). Reuse only a unique prior identity for a unique new row.
    if rec and not identity_is_duplicated(identity, new_counts) and not used_root[rec.id] then
      used_root[rec.id] = true
    else
      rec = { id = next_id(state), kind = 'root' }
    end
    rec.kind, rec.name, rec.text, rec.depth = 'root', line, line, 0
    rec.path = M.entry_path(self.root, line)
    state.rows[rec.id] = rec
    state.root_ids[#state.root_ids + 1] = rec.id
    roots[#roots + 1] = rec
  end

  local rendered = {}
  local function render_children(parent_id, parent_path, depth)
    local expansion = state.expanded[parent_id]
    if not expansion then return end
    for _, child in ipairs(expansion.children) do
      child.kind, child.parent, child.depth = 'child', parent_id, depth
      child.path = M.entry_path(parent_path, child.name)
      child.text = string.rep('  ', depth) .. child.name
      state.rows[child.id] = child
      rendered[#rendered + 1] = {
        text = child.text, id = child.id, identity = path_identity(child.path),
      }
      state.display_ids[#state.display_ids + 1] = child.id
      render_children(child.id, child.path, depth + 1)
    end
  end
  for root_index, rec in ipairs(roots) do
    rendered[#rendered + 1] = {
      text = rec.text, id = rec.id, identity = new_identities[root_index],
    }
    state.display_ids[#state.display_ids + 1] = rec.id
    if is_dir_line(rec.name) then
      render_children(rec.id, rec.path, 1)
    end
  end
  for id in pairs(state.expanded) do
    if not state.rows[id] then state.expanded[id] = nil end
  end
  for id in pairs(state.known_children) do
    if not state.rows[id] then state.known_children[id] = nil end
  end

  local display = {}
  local display_identities = {}
  for index, row in ipairs(rendered) do
    display[index] = row.text
    display_identities[index] = row.identity
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  local ok, seterr = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, display)
  if not ok then
    ui.notify('direct: cannot list ' .. tostring(self.root) .. ': '
      .. tostring(seterr), vim.log.levels.ERROR)
    return nil, seterr
  end
  states[bufnr] = state
  for row, item in ipairs(rendered) do
    set_row_mark(bufnr, row - 1, item.id)
  end
  refresh_highlights(bufnr, state)
  refresh_icons(bufnr, state)
  state.materialization_seq = vim.fn.undotree().seq_cur
  set_options(bufnr)
  self:place_cursor(display, display_identities,
    self.current_entry and path_identity(self.current_entry) or nil)
  if self.current_entry == nil then
    pcall(vim.api.nvim_win_set_cursor, 0, {
      math.max(1, math.min(cursor[1], #display)), cursor[2],
    })
  end
  vim.bo[bufnr].modified = false
  return true
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
  local just_materialized = false
  if not state.expanded[rec.id] then
    local path = row_path(self.root, rec, line)
    local children, snapshot, err = list_with_snapshot(path, state.view_show_hidden)
    if not children then
      ui.notify('direct: cannot expand ' .. tostring(path) .. ': '
        .. tostring(err), vim.log.levels.ERROR)
      return nil, err
    end
    -- Keep an unfiltered snapshot for destructive sync preflight. Ignored names
    -- are hidden from the view but still make the directory non-empty.
    local known_children = fs.read_dir_lines(path)
    state.known_children[rec.id] = known_children or vim.deepcopy(children)
    local materialized = {}
    for order, child_name in ipairs(children) do
      local child_path = M.entry_path(path, child_name)
      local reason = action_mod.path_reason(child_path)
      if not reason then
        materialized[#materialized + 1] = {
          id = next_id(state), kind = 'child', name = child_name,
          text = string.rep('  ', (rec.depth or 0) + 1) .. child_name,
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
      listing_lines = vim.deepcopy(children),
      wildignore = snapshot.wildignore,
      filter_snapshot = vim.deepcopy(snapshot),
    }
    set_directory_snapshot(state, snapshot)
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
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, add)
      for offset, child in ipairs(materialized) do
        set_row_mark(bufnr, insert_at + offset - 1, child.id)
      end
      state.display_ids = {}
      for display_row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
        local id = row_id_at(bufnr, display_row)
        if id then state.display_ids[#state.display_ids + 1] = id end
      end
      refresh_highlights(bufnr, state)
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
  refresh_icons(bufnr, state)
  return true
end

local function collapse_snapshot(bufnr, state, parent, parent_row)
  local rows, rows_by_id, expansions, directory_snapshots = {}, {}, {}, {}
  local cursor = parent_row
  local function visit(parent_id)
    local expansion = state.expanded[parent_id]
    if not expansion then return true end
    for _, child in ipairs(expansion.children or {}) do
      local row = cursor + 1
      cursor = row
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      if state.rows[child.id] ~= child or child.parent ~= parent_id
        or row_id_at(bufnr, row) ~= child.id
        or line ~= recorded_row_text(child) then
        return false
      end
      local saved = vim.deepcopy(child)
      rows[#rows + 1] = { id = child.id, row = row, text = line }
      rows_by_id[child.id] = saved
      if state.expanded[child.id] then
        expansions[child.id] = vim.deepcopy(state.expanded[child.id])
        directory_snapshots[child.id] = vim.deepcopy(
          state.expanded[child.id].listing_lines or {})
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
      if not rec or visible_records[id] or row_id_at(bufnr, row - 1) ~= id
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
        directory_snapshots[id] = {
          listing_lines = vim.deepcopy(expanded.listing_lines or {}),
          wildignore = expanded.wildignore or vim.o.wildignore or '',
          filter_snapshot = vim.deepcopy(expanded.filter_snapshot),
        }
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
  if #snapshot.rows > 0 then
    local modified = vim.bo[bufnr].modified
    local undo_levels = vim.bo[bufnr].undolevels
    if undo_levels == -123456 then
      vim.go.undolevels = vim.go.undolevels
    elseif undo_levels >= 0 then
      vim.bo[bufnr].undolevels = undo_levels
    end
    vim.api.nvim_buf_set_lines(bufnr, row, row + #snapshot.rows, false, {})
    snapshot.seq = vim.fn.undotree().seq_cur
    snapshot.status = 'collapsed'
    state.collapse_undos = state.collapse_undos or {}
    state.collapse_undos[#state.collapse_undos + 1] = snapshot
    remove_expanded_subtree(bufnr, state, parent.id)
    refresh_display_ids(bufnr, state)
    refresh_highlights(bufnr, state)
    vim.bo[bufnr].modified = modified
  else
    state.expanded[parent.id] = nil
  end
  refresh_icons(bufnr, state)
  return true
end

function M.expand()
  local buffer = M.restore()
  return buffer:expand(vim.api.nvim_win_get_cursor(0)[1])
end

function M.collapse()
  local buffer = M.restore()
  return buffer:collapse(vim.api.nvim_win_get_cursor(0)[1])
end

function M.toggle()
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
  local listed, err = M.restore():list()
  if not listed then
    for key, value in pairs(previous) do state[key] = value end
    return nil, err
  end
  return listed
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
  return folding.expand_recursive(M)
end

function M.toggle_recursive()
  return folding.toggle_recursive(M)
end

function M.expand_all()
  return folding.expand_all(M)
end

function M.collapse_all()
  return folding.collapse_all(M)
end

-- ---------------------------------------------------------------------------
-- sync
-- ---------------------------------------------------------------------------

-- log_applied(actions, applied) records successful actions in history. History
-- is written per GROUP of interlinked moves: a swap or
-- an N-way rotation is ONE entry, so one `DirectUndo` reverses the whole
-- permutation instead of renaming a live name over an unsaved one. Every other
-- action is its own entry, exactly as before.
--
-- A group with any member that did NOT apply is not recorded at all: its
-- reversal would pass through a colliding name (the reported defect), and
-- already never records a reversal for entries that were never written (the
-- Paste precedent). A singleton group is logged only when its action applied.
local function log_applied(actions, applied)
  for _, group in ipairs(action_mod.move_groups(actions)) do
    local members, complete = {}, true
    for _, index in ipairs(group) do
      if not applied[index] then
        complete = false
      end
      members[#members + 1] = actions[index]
    end
    if complete then
      if #members == 1 then
        history.log(members[1])
      else
        history.log(action_mod.Group(members))
      end
    end
  end
end

-- Buffer:sync -> true when all classified actions succeeded (the buffer was
-- re-listed and marked nomodified), nil, reason when preflight refused the
-- sync or any action failed. Failed action batches are still re-listed so the
-- buffer reflects any independent actions that did succeed.
function Buffer:sync()
  if pending.refuse('sync') then return nil, 'another direct operation is pending' end
  local bufnr = vim.api.nvim_get_current_buf()
  reconcile_undone_materialization(bufnr)
  local state = states[bufnr]
  local snapshot = get_directory_snapshot(state, self.root)
  if not snapshot then
    vim.bo[bufnr].modified = true
    local reason = 'list-time filter snapshot is unavailable; re-list this directory'
    ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
      vim.log.levels.ERROR)
    return nil, reason
  end
  local checked_git = {}
  for _, directory_snapshot in ipairs(state.directory_snapshots or {}) do
    if directory_snapshot.respect_gitignore then
      local matches, git_err = git.ignore_snapshot_matches(
        directory_snapshot.git, directory_snapshot.path, checked_git)
      if matches ~= true then
        vim.bo[bufnr].modified = true
        local reason = matches == false and git_err
          or ('Git ignore query failed: ' .. tostring(git_err))
        ui.notify('Refusing to sync: ' .. tostring(reason) .. '; nothing was changed.',
          vim.log.levels.ERROR)
        return nil, reason
      end
    end
  end
  local visible = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local actual, child_err = children_integrity(bufnr, visible)
  local subtree_edit
  if actual then
    local has_materialized_children = false
    local state = states[bufnr]
    for _, id in ipairs(state and state.display_ids or {}) do
      local rec = state.rows[id]
      if rec and rec.kind == 'child' then
        has_materialized_children = true
        break
      end
    end
    local visible_ids, stack, has_tree_edit, has_indented = {}, {}, false, false
    for row = 0, #visible - 1 do
      local id = row_id_at(bufnr, row)
      if id then visible_ids[id] = true end
    end
    for row, line in ipairs(visible) do
      local rec = current_row_record(bufnr, row - 1)
      if not rec then
        local expected_id = state and state.display_ids[row]
        local expected_rec = expected_id and state.rows[expected_id]
        if expected_rec and line == expected_rec.text then rec = expected_rec end
      end
      local prefix = line:match('^( *)') or ''
      if #prefix > 0 then has_indented = true end
      if #prefix % 2 ~= 0 then
        has_tree_edit = true
        break
      end
      local depth = #prefix / 2
      local parent = depth > 0 and stack[depth] or nil
      if rec then
        if rec.kind == 'root' and depth > 0 then
          has_tree_edit = true
          break
        elseif rec.kind == 'child' and (rec.depth ~= depth
            or rec.parent ~= (parent and parent.id or nil)) then
          local old_parent = state.rows[rec.parent]
          local implicit_root_delete = old_parent and old_parent.kind == 'root'
            and not visible_ids[rec.parent]
          if not implicit_root_delete then
            has_tree_edit = true
            break
          end
        end
      end
      stack[depth + 1] = rec
      for level = depth + 2, #stack do stack[level] = nil end
    end
    if has_tree_edit or (not has_materialized_children and has_indented) then
      actual, child_err = nil, 'row parentage changed in the expanded tree'
    end
  end
  if not actual then
    subtree_edit, child_err = edited_subtrees(bufnr, visible)
    if not subtree_edit then
      vim.bo[bufnr].modified = true
      ui.notify('Refusing to sync: ' .. tostring(child_err)
        .. '; nothing was changed.', vim.log.levels.ERROR)
      return nil, child_err
    end
    actual = subtree_edit.root_lines
  end
  local expected, read_err = fs.read_dir_lines(self.root)
  if not expected then
    ui.notify('direct: cannot read ' .. tostring(self.root) .. ': '
      .. tostring(read_err), vim.log.levels.ERROR)
    return nil, read_err
  end
  local filtered_expected, filter_err = apply_snapshot(self.root, expected, snapshot)
  if not filtered_expected then
    vim.bo[bufnr].modified = true
    local reason = 'Git ignore query failed: ' .. tostring(filter_err)
    ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
      vim.log.levels.ERROR)
    return nil, reason
  end
  expected = filtered_expected
  -- Neovim represents an empty buffer with one empty string. An empty listing
  -- denotes zero root entries, not an empty filename: this applies both to a
  -- clean listing of an empty directory and to deleting its final visible row.
  -- Keep rejecting a modified blank row when there were no visible entries to
  -- delete, since that would otherwise turn an invalid filename into a no-op.
  if #actual == 1 and actual[1] == ''
    and (not vim.bo[bufnr].modified or #expected > 0) then
    actual = {}
  end

  -- refuse a path the history framing cannot represent, before any
  -- action or history write. The buffer is not re-listed and stays modified.
  local nested_added = {}
  -- Recognize a pure add without invoking the classifier: unsafe path checks
  -- intentionally precede classification, and only new rows may use a nested
  -- relative path. Renames and mixed edits retain the basename-only rule.
  local actual_set, expected_set, unique = {}, {}, true
  for _, line in ipairs(actual) do
    if actual_set[line] then unique = false end
    actual_set[line] = true
  end
  for _, line in ipairs(expected) do expected_set[line] = true end
  local is_add = unique and #actual > #expected
  if is_add then
    for line in pairs(expected_set) do
      if not actual_set[line] then is_add = false; break end
    end
  end
  if is_add then
    for line in pairs(actual_set) do
      if not expected_set[line] then nested_added[line] = true end
    end
  end
  local unsafe = first_unsafe(self.root, actual, nested_added)
    or first_unsafe(self.root, expected)
  if unsafe ~= nil then
    vim.bo[bufnr].modified = true
    ui.notify('Unsafe entry in the buffer (' .. unsafe.reason
      .. '); nothing was changed: ' .. unsafe.path, vim.log.levels.ERROR)
    return nil, unsafe.reason
  end

  local plan = M.classify(actual, expected)
  if plan.kind == 'AMBIGUOUS' then
    -- notify, change nothing, write no history, do NOT re-list, and
    -- leave the buffer modified so the unsaved intent is not discarded.
    ui.notify(ambiguous_message(plan, actual, expected), vim.log.levels.ERROR)
    return nil, plan.reason
  end

  local actions, yanks, build_err = build_actions(self.root, plan)
  if not actions then
    vim.bo[bufnr].modified = true
    ui.notify('Refusing to sync: ' .. tostring(build_err)
      .. '; nothing was changed.', vim.log.levels.ERROR)
    return nil, build_err
  end
  local added_expand_paths, added_focus_path = {}, nil
  if plan.kind == 'ADD' then
    local added_set, expand_by_path = {}, {}
    for _, line in ipairs(plan.added or {}) do added_set[line] = true end
    -- Keep the cursor target in the user's row order, not the sorted action
    -- order. Nested parent directories are expanded for every new nested path.
    for _, line in ipairs(actual) do
      if added_set[line] then
        local relative = line:gsub('/+$', '')
        added_focus_path = M.entry_path(self.root, line)
        if relative:find('/', 1, true) then
          local parts = vim.split(relative, '/', { plain = true })
          local directory_count = #parts - (is_dir_line(line) and 0 or 1)
          local parent = self.root
          for index = 1, directory_count do
            parent = fs.join(parent, parts[index])
            local normalized_parent = parent:gsub('/+$', '')
            local key = vim.fs.normalize(normalized_parent)
            expand_by_path[key] = parent
          end
        end
      end
    end
    for _, path in pairs(expand_by_path) do
      added_expand_paths[#added_expand_paths + 1] = path
    end
    table.sort(added_expand_paths, function(a, b)
      local depth_a, depth_b = select(2, a:gsub('/', '')), select(2, b:gsub('/', ''))
      if depth_a ~= depth_b then return depth_a < depth_b end
      return a < b
    end)
    if #added_expand_paths == 0 then added_focus_path = nil end
  end
  if subtree_edit then
    if plan.kind == 'DELETE' then
      local removed_roots = {}
      for _, line in ipairs(plan.removed or {}) do
        if is_dir_line(line) then
          removed_roots[#removed_roots + 1] = M.entry_path(self.root, line)
        end
      end
      local function under_removed_root(path)
        if type(path) ~= 'string' then return false end
        local candidate = vim.fs.normalize(path)
        for _, root_path in ipairs(removed_roots) do
          local normalized = vim.fs.normalize(root_path):gsub('/+$', '')
          if candidate == normalized or candidate:sub(1, #normalized + 1) == normalized .. '/' then
            return true
          end
        end
        return false
      end
      local kept_actions = {}
      for _, act in ipairs(subtree_edit.actions) do
        if act.name == 'mv' and under_removed_root(act.src)
          and not under_removed_root(act.dst) then
          kept_actions[#kept_actions + 1] = act -- a child explicitly moved out
        elseif not (act.name == 'rm' or act.name == 'rmdir'
            or act.name == 'mv') or not under_removed_root(act.src) then
          kept_actions[#kept_actions + 1] = act
        end
      end
      subtree_edit.actions = kept_actions
      local kept_yanks = {}
      for _, path in ipairs(subtree_edit.yanks) do
        if not under_removed_root(path) then kept_yanks[#kept_yanks + 1] = path end
      end
      subtree_edit.yanks = kept_yanks
    end
    local combined_actions = {}
    for _, act in ipairs(subtree_edit.actions) do
      combined_actions[#combined_actions + 1] = act
    end
    for _, act in ipairs(actions) do combined_actions[#combined_actions + 1] = act end
    actions = combined_actions
    for _, path in ipairs(subtree_edit.yanks) do yanks[#yanks + 1] = path end
    local priority = { mkdir = 1, mv = 2, touch = 3, rm = 4, rmdir = 4 }
    table.sort(actions, function(a, b)
      local ap, bp = priority[a.name] or 5, priority[b.name] or 5
      if ap ~= bp then return ap < bp end
      local adst, bdst = a.dst or a.src or '', b.dst or b.src or ''
      local adepth = select(2, adst:gsub('/', ''))
      local bdepth = select(2, bdst:gsub('/', ''))
      if a.name == 'mkdir' and adepth ~= bdepth then return adepth < bdepth end
      return adst < bdst
    end)
    local destinations = {}
    for _, act in ipairs(actions) do
      if act.name == 'mv' or act.name == 'touch' or act.name == 'mkdir' then
        for _, destination in ipairs(destinations) do
          if fs.same_path(destination, act.dst) then
            vim.bo[bufnr].modified = true
            local reason = 'multiple subtree actions target the same path: ' .. act.dst
            ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
              vim.log.levels.ERROR)
            return nil, reason
          end
        end
        destinations[#destinations + 1] = act.dst
      end
      local _, serialize_err = action_mod.serialize(act)
      if serialize_err then
        vim.bo[bufnr].modified = true
        ui.notify('Unsafe action (' .. tostring(serialize_err)
          .. '); nothing was changed.', vim.log.levels.ERROR)
        return nil, serialize_err
      end
    end
  end

  -- A visible directory row does not authorize moving its ignored contents.
  -- Refuse directory deletes and renames before yanking or other side effects.
  for _, act in ipairs(actions) do
    if (act.name == 'rmdir' or act.name == 'mv') and is_real_directory(act.src) then
      local hidden_path, inspect_err = hidden_descendant(act.src, snapshot, state)
      if hidden_path or inspect_err then
        local reason = hidden_path
          and ('directory contains hidden entry: ' .. hidden_path)
          or ('cannot inspect directory descendants: ' .. tostring(inspect_err))
        vim.bo[bufnr].modified = true
        ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
          vim.log.levels.ERROR)
        return nil, reason
      end
    end
  end

  -- Fail the whole batch before auto-yank/history or staging when an action
  -- would land on an occupied path. Move destinations that are also move
  -- sources are safe: stage_moves vacates those paths before applying moves.
  -- Compare filesystem-entry identity as well as spelling for case-only moves.
  local move_sources, sources_by_inode = {}, {}
  local function move_key(path)
    path = path:gsub('/+$', '')
    if path == '' then path = '/' end
    return vim.fs.normalize(path)
  end
  for _, act in ipairs(actions) do
    if act.name == 'mv' and fs.taken(act.src) then
      move_sources[move_key(act.src)] = true
      local identity = fs.entry_identity(act.src)
      if identity and identity.inode then
        local bucket = sources_by_inode[identity.inode]
        if not bucket then
          bucket = {}
          sources_by_inode[identity.inode] = bucket
        end
        bucket[#bucket + 1] = act.src
      end
    end
  end
  for _, act in ipairs(actions) do
    local destination = act.dst
    if destination and fs.taken(destination) then
      local key = move_key(destination)
      local is_move_source = act.name == 'mv' and move_sources[key] == true
      if act.name == 'mv' and not is_move_source then
        local identity = fs.entry_identity(destination)
        local bucket = identity and identity.inode and sources_by_inode[identity.inode]
        for _, source in ipairs(bucket or {}) do
          if fs.same_entry(destination, source) then
            is_move_source = true
            break
          end
        end
      end
      if not is_move_source then
        vim.bo[bufnr].modified = true
        local reason = 'destination already exists: ' .. destination
        ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
          vim.log.levels.ERROR)
        return nil, reason
      end
    end
  end

  -- Classify both raw history stacks only after the complete sync plan has
  -- passed its read-only checks, but before auto-yank or filesystem mutation.
  if #actions > 0 or #yanks > 0 then
    local inputs = {}
    for _, act in ipairs(actions) do
      if type(act.src) == 'string' then inputs[#inputs + 1] = act.src end
      if type(act.dst) == 'string' then inputs[#inputs + 1] = act.dst end
      for _, member in ipairs(act.actions or {}) do
        if type(member.src) == 'string' then inputs[#inputs + 1] = member.src end
        if type(member.dst) == 'string' then inputs[#inputs + 1] = member.dst end
      end
    end
    for _, path in ipairs(yanks) do inputs[#inputs + 1] = path end
    local preflight, preflight_err = history.preflight(inputs)
    if not preflight then
      vim.bo[bufnr].modified = true
      return nil, preflight_err
    end
  end

  -- Yank removed paths before applying actions. If yanking is refused, leave
  -- the filesystem untouched.
  if #yanks > 0 then
    local ok, yerr = register.yank(yanks)
    if not ok then
      ui.notify('Action failed - could not yank deleted entries: '
        .. tostring(yerr), vim.log.levels.ERROR)
      return nil, yerr
    end
  end

  -- swap/chain renames are staged before the real moves.
  local staging, stage_err, stage_temps, stage_overrides, stage_identities =
    stage_moves(actions)
  if staging == nil and stage_err ~= nil then
    ui.notify('Action failed - could not stage renames: ' .. tostring(stage_err),
      vim.log.levels.ERROR)
    -- Restore only with atomic no-replace. Never delete a staged path: if its
    -- original name was reoccupied or the primitive is unavailable, preserve
    -- and report the exact stranded temp for manual recovery.
    local staged_identities = stage_identities or {}
    local reported = {}
    for _, act in ipairs(actions) do
      local tmp = act.src ~= nil and stage_overrides
        and stage_overrides[act.src] or nil
      if tmp and fs.taken(tmp) then
        local expected = staged_identities[act.src]
        local restored, restore_err = fs.rename_noreplace(tmp, act.src, expected)
        if not restored then
          reported[tmp] = true
          ui.notify('direct: could not restore staged entry ' .. tmp .. ' to '
            .. tostring(act.src) .. ' (' .. tostring(restore_err)
            .. '); temp preserved; manual recovery required', vim.log.levels.ERROR)
        end
      end
    end
    for _, tmp in ipairs(stage_temps or {}) do
      if fs.taken(tmp) and not reported[tmp] then
        ui.notify('direct: a failed rename left the staged entry ' .. tmp,
          vim.log.levels.ERROR)
      end
    end
    return nil, stage_err
  end

  -- Apply each action and record successful work in history, grouping dependent
  -- moves into one entry. `history.log` reports write failures without raising.
  local failed, applied, failure_reason = {}, {}, nil
  for i, act in ipairs(actions) do
    local exec_action = act
    if staging ~= nil and act.name == 'mv'
      and staging.overrides[act.src] ~= nil then
      exec_action = action_mod.Move(staging.overrides[act.src], act.dst)
    end
    local ok, res, aerr = pcall(action_mod.execute, exec_action)
    if ok and res then
      applied[i] = true
      self.current_entry = result_entry(act)
    else
      ui.notify('Action failed - ' .. action_mod.describe_action(act),
        vim.log.levels.ERROR)
      failed[#failed + 1] = act
      if failure_reason == nil then
        failure_reason = (ok and aerr) or res
          or ('action failed: ' .. action_mod.describe_action(act))
      end
    end
  end
  log_applied(actions, applied)

  -- Every staged temp is expected to be consumed by a successful no-replace
  -- move. If a temp path remains, preserve and report it; never recursively
  -- remove by pathname because it may now contain foreign user data.
  if staging ~= nil then
    for _, tmp in ipairs(staging.temps) do
      if fs.taken(tmp) then
        ui.notify('direct: a staged entry remains at ' .. tmp
          .. '; preserved for manual recovery', vim.log.levels.ERROR)
      end
    end
  end

  -- Re-list so the buffer reflects the filesystem, restore the cursor, and
  -- mark it unmodified only after the refresh succeeds.
  local reopen = {}
  -- Root directory/file renames retain their row identity even when an
  -- expanded subtree is present. Refresh the root record's path before list()
  -- rebuilds its inode index, so the expansion follows the renamed directory.
  local state_before_list = states[bufnr]
  if state_before_list then
    for row, line in ipairs(visible) do
      local id = row_id_at(bufnr, row - 1)
      local rec = id and state_before_list.rows[id]
      if rec and rec.kind == 'root' and not line:match('^%s') then
        local path = M.entry_path(self.root, line)
        if fs.exists(path) then
          rec.name, rec.text, rec.path = line, line, path
        end
      end
    end
  end
  if subtree_edit then
    local state = states[bufnr]
    reopen = vim.deepcopy(subtree_edit.expanded_targets or {})
    for id in pairs(subtree_edit.changed_parents) do
      local rec = state and state.rows[id]
      if rec then
        remove_expanded_subtree(bufnr, state, id)
      end
    end
    if #reopen == 0 then
      for id in pairs(subtree_edit.changed_parents) do
        local rec = state and state.rows[id]
        if rec then reopen[#reopen + 1] = { path = rec.path, depth = rec.depth or 0 } end
      end
      table.sort(reopen, function(a, b) return a.depth < b.depth end)
    end
  end
  self:list()
  -- Re-materialize only the edited scopes, now from the filesystem's committed
  -- state. Other expanded branches retain their original identities and view.
  for _, target in ipairs(reopen) do
    local state = states[bufnr]
    for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
      local rec = current_row_record(bufnr, row)
      if rec and rec.kind == 'child' and is_dir_line(rec.name)
        and fs.same_path(rec.path, target.path) then
        self:expand(row + 1)
        break
      elseif rec and rec.kind == 'root' and is_dir_line(rec.name)
        and fs.same_path(rec.path, target.path) then
        self:expand(row + 1)
        break
      end
    end
  end

  -- Open every parent directory on newly added nested paths, including parents
  -- that already existed, then put the cursor on the last added row.
  for _, path in ipairs(added_expand_paths) do
    for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
      local rec = current_row_record(bufnr, row)
      if rec and is_dir_line(rec.name) and fs.same_path(rec.path, path) then
        self:expand(row + 1)
        break
      end
    end
  end
  if added_focus_path then
    for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
      local rec = current_row_record(bufnr, row)
      if rec and fs.same_path(rec.path, added_focus_path) then
        pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, (rec.depth or 0) * 2 })
        break
      end
    end
  end

  if #actions > 0 then
    -- Emit one joined summary for the classified actions.
    ui.notify(action_mod.summarize(actions), vim.log.levels.INFO)
  end
  if #failed > 0 then
    -- Emit one additional error summary naming the failed actions.
    local names = {}
    for _, act in ipairs(failed) do
      names[#names + 1] = action_mod.describe_action(act)
    end
    ui.notify(string.format('%d action(s) failed: %s', #failed,
      table.concat(names, ', ')), vim.log.levels.ERROR)
    return nil, failure_reason
  end
  return true
end

-- ---------------------------------------------------------------------------
-- open / get_paths
-- ---------------------------------------------------------------------------

-- Open directories with a direct listing and files with `:edit`. Pass paths
-- through fnameescape so special characters cannot become Ex syntax. Remove
-- the old direct buffer only after another buffer is current.
-- Child paths resolve from their row identities rather than their display text.
function Buffer:open(line)
  local bufnr = vim.api.nvim_get_current_buf()
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
  local path = row_path(self.root, record, line)
  if not path and type(line) == 'string' and not line:match('^%s') then
    path = M.entry_path(self.root, line)
  end
  if not path then return nil, 'row identity is unavailable' end
  local direct_buf = vim.api.nvim_get_current_buf()
  if is_dir_line(record and record.name or line) then
    M.list(path)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  end
  if vim.api.nvim_buf_is_valid(direct_buf)
    and vim.api.nvim_get_current_buf() ~= direct_buf then
    pcall(vim.api.nvim_buf_delete, direct_buf, { force = true })
  end
  return true
end

-- Buffer:get_paths(firstline, lastline) -> the absolute path of every line in
-- the inclusive 1-based range (Python's buffer slice). Used by `:DirectYank`.
function Buffer:get_paths(firstline, lastline)
  local bufnr = vim.api.nvim_get_current_buf()
  local safe, integrity_err = children_integrity(bufnr,
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if not safe then return nil, integrity_err end
  local lines = vim.api.nvim_buf_get_lines(bufnr, firstline - 1, lastline, false)
  local out = {}
  for offset, line in ipairs(lines) do
    local row = firstline + offset - 2
    local record = current_row_record(bufnr, row)
    if record and record.kind == 'child' then
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

-- Buffer:paste_destination([row]) -> the directory represented by the row.
-- A directory row is itself the destination; a file row uses its parent.
-- Resolve through the row record so expanded child rows never rely on their
-- indented display text for filesystem paths.
function Buffer:paste_destination(row)
  local bufnr = vim.api.nvim_get_current_buf()
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
  path = vim.fs.normalize(path):gsub('/+$', '')
  return path == '' and '/' or path
end

local function path_is_within(parent, candidate)
  parent, candidate = normalized_path(parent), normalized_path(candidate)
  if candidate == parent then return true end
  local prefix = parent == '/' and '/' or parent .. '/'
  return candidate:sub(1, #prefix) == prefix
end

-- Refresh the root listing after a paste. Reopen existing folds and the path to
-- the destination so the last pasted entry is visible; place the cursor on its
-- name and expand it when it is a directory.
function Buffer:refresh_after_paste(destination, pasted_entry)
  local bufnr = vim.api.nvim_get_current_buf()
  local state = states[bufnr]
  if not state then return self:list() end

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

  local ok, err = self:list()
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
      and (record.depth or 0) * 2 or 0
    pcall(vim.api.nvim_win_set_cursor, 0, { pasted_row, col })
    local expanded, expand_err = self:expand(pasted_row)
    if expanded == nil then return nil, expand_err end
  elseif cursor_path then
    local row = visible_row(cursor_path)
    if row then pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 }) end
  end
  return true
end

return M
