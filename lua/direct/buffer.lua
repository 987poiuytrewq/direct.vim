-- lua/direct/buffer.lua -- directory buffer model, listing, sync, and open operations.
-- Path identity uses fs.same_path. Sync validates edits, stages dependent
-- moves, records only successful actions, and re-lists the filesystem state.
-- Unfolded child rows retain their filesystem identities; sync classifies only
-- root entries and refuses directory mutations while descendants are loaded.

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
local reconcile_undone_materialization

local Buffer = {}
Buffer.__index = Buffer

-- Display rows are identified by extmarks rather than their spelling.  In
-- particular, child rows are never interpreted as root-relative filenames.
local states = {}
local namespace = vim.api.nvim_create_namespace('direct-listing-rows')
-- Private inspection seam for lifecycle specs; callers must not depend on the
-- shape or contents of these records.
M._state_for_test = function(bufnr) return states[bufnr] end
local function next_id(state)
  state.next_id = (state.next_id or 0) + 1
  return state.next_id
end

local function set_row_mark(bufnr, row, id)
  vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
    id = id,
    right_gravity = true,
    invalidate = true,
    undo_restore = true,
  })
end

local function row_id_at(bufnr, row)
  local state = states[bufnr]
  if not state then return nil end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace,
      { row, 0 }, { row, -1 }, { details = true })) do
    if mark[2] == row and not (mark[4] and mark[4].invalid) then
      return mark[1]
    end
  end
  return nil
end

local function row_path(root, record, line)
  if not record then return nil end
  if record.kind == 'root' then
    return M.entry_path(root, line)
  end
  return record.path
end

local function current_row_record(bufnr, row)
  local state = states[bufnr]
  local id = row_id_at(bufnr, row)
  return state and id and state.rows[id] or nil
end

local function install_fold_options(bufnr)
  _G.__direct_listing_foldexpr = function(lnum) return M.foldexpr(lnum) end
  local expr = 'v:lua.__direct_listing_foldexpr(v:lnum)'
  local state = states[bufnr]
  if not state then return end
  state.fold_windows = state.fold_windows or {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr and not state.fold_windows[win] then
      pcall(vim.api.nvim_set_option_value, 'foldmethod', 'expr',
        { win = win, scope = 'local' })
      pcall(vim.api.nvim_set_option_value, 'foldexpr', expr,
        { win = win, scope = 'local' })
      pcall(vim.api.nvim_set_option_value, 'foldenable', true,
        { win = win, scope = 'local' })
      pcall(vim.api.nvim_set_option_value, 'foldlevel', 99,
        { win = win, scope = 'local' })
      state.fold_windows[win] = true
    end
  end
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- is_dir_line(line) -> true for a directory entry. The trailing slash is the
-- convention: a directory is never distinguished from a file by a
-- filesystem stat here.
local function is_dir_line(line)
  return type(line) == 'string' and line:sub(-1) == '/'
end

-- dirs_then_name(lines) -> a copy ordered directories first, each group sorted
-- ascending by byte-wise comparison. A directory line carries its
-- trailing '/', so the two groups never interleave.
local function dirs_then_name(lines)
  local dirs, files = {}, {}
  for _, line in ipairs(lines or {}) do
    if is_dir_line(line) then
      dirs[#dirs + 1] = line
    else
      files[#files + 1] = line
    end
  end
  table.sort(dirs)
  table.sort(files)
  local out = {}
  for _, line in ipairs(dirs) do
    out[#out + 1] = line
  end
  for _, line in ipairs(files) do
    out[#out + 1] = line
  end
  return out
end

-- entry_path(root, line) -> the absolute entry a buffer line denotes. The
-- spelling is `root.. '/'.. line`, so a directory line keeps its trailing '/'
-- (Python `os.path.join` parity): the delete auto-yank path and the trash
-- digest are therefore the trailing-slash string, exactly as in the Python
-- version. The only root that already ends in a separator is '/'.
function M.entry_path(root, line)
  if type(root) ~= 'string' or type(line) ~= 'string' then
    return root
  end
  if root:sub(-1) == '/' then
    return root .. line
  end
  return root .. '/' .. line
end

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

-- ignore_set(root) -> the ignore set: the union of
-- `glob(root.. '/'.. pattern, true, true, true)` over the comma-separated
-- trimmed, non-empty `&wildignore` patterns, or nil when there are none. The
-- four glob arguments are {expr}, {nosuf}, {list}, {alllinks}: `nosuf` must be
-- passed or 'suffixes'/'wildmenu' would fabricate matches, `{list}` makes the
-- result an array, and `{alllinks}` follows symlinks while globbing. The
-- comparison itself is `same_path` (hardening), which is correct for
-- every root spelling.
function M.ignore_set(root, wildignore)
  if wildignore == nil then wildignore = vim.o.wildignore or '' end
  if wildignore == '' then
    return nil
  end
  local set = {}
  for pattern in wildignore:gmatch('[^,]+') do
    pattern = vim.trim(pattern)
    if pattern ~= '' then
      local matches = vim.fn.glob(M.entry_path(root, pattern), true, true, true)
      if type(matches) == 'table' then
        for _, match in ipairs(matches) do
          set[#set + 1] = match
        end
      end
    end
  end
  if #set == 0 then
    return nil
  end
  return set
end

-- read(root[, ignored]) -> listing lines, or nil, err when root is not readable.
-- `ignored`, when supplied, is the exact list-time &wildignore match set.
function M.read(root, ignored)
  if ignored == nil then ignored = M.ignore_set(root) end
  return fs.read_dir_lines(root, ignored)
end

-- list_with_snapshot(root) returns the current filtered listing and the names
-- omitted by that exact list-time wildignore value. Sync uses the captured names
-- later instead of consulting a possibly changed option.
local function list_with_snapshot(root)
  local wildignore = vim.o.wildignore or ''
  local ignored = M.ignore_set(root, wildignore)
  local visible, err = M.read(root, ignored)
  if not visible then return nil, nil, err end
  local scan, scan_err = vim.uv.fs_scandir(root)
  if not scan then return nil, nil, scan_err end
  local all_names = {}
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if name == nil then break end
    all_names[#all_names + 1] = name
  end
  local visible_set = {}
  for _, line in ipairs(visible) do
    visible_set[line:gsub('/+$', '')] = true
  end
  local hidden = {}
  for _, name in ipairs(all_names) do
    if not visible_set[name] then hidden[#hidden + 1] = name end
  end
  table.sort(hidden)
  return visible, { path = root, hidden = hidden, wildignore = wildignore }
end

local function set_directory_snapshot(state, snapshot)
  state.directory_snapshots = state.directory_snapshots or {}
  for index, previous in ipairs(state.directory_snapshots) do
    if fs.same_path(previous.path, snapshot.path) then
      state.directory_snapshots[index] = snapshot
      return
    end
  end
  state.directory_snapshots[#state.directory_snapshots + 1] = snapshot
end

local function get_directory_snapshot(state, path)
  for _, snapshot in ipairs(state and state.directory_snapshots or {}) do
    if fs.same_path(snapshot.path, path) then return snapshot end
  end
  return nil
end

local function path_is_ignored(path, ignored)
  for _, ignored_path in ipairs(ignored or {}) do
    if fs.same_path(path, ignored_path) then return true end
  end
  return false
end

local function compile_wildignore(wildignore)
  local patterns = {}
  for pattern in (wildignore or ''):gmatch('[^,]+') do
    pattern = vim.trim(pattern)
    if pattern ~= '' then
      local ok, matched = pcall(function()
        local directory_only = pattern:sub(-1) == '/'
        local comparable = directory_only and pattern:gsub('/+$', '') or pattern
        return {
          regex = vim.fn.glob2regpat(pattern),
          comparable_regex = vim.fn.glob2regpat(comparable),
          directory_only = directory_only,
          basename_only = not comparable:find('/', 1, true),
        }
      end)
      if not ok then return nil, matched end
      patterns[#patterns + 1] = matched
    end
  end
  return patterns
end

local function wildignore_matches(name, relative_name, path, stat, patterns)
  local is_directory = stat.type == 'directory'
  if stat.type == 'link' then
    local target = fs.stat(path)
    is_directory = target ~= nil and target.type == 'directory'
  end
  for _, pattern in ipairs(patterns) do
    if not pattern.directory_only or is_directory then
      local candidates
      if pattern.directory_only then
        if pattern.basename_only then
          candidates = { name }
        else
          candidates = { relative_name }
        end
      else
        candidates = { name, relative_name }
      end
      for _, candidate in ipairs(candidates) do
        local regex = pattern.directory_only
          and pattern.comparable_regex or pattern.regex
        local ok, matched = pcall(function()
          return vim.fn.match(candidate, regex) >= 0
        end)
        if not ok then return nil, matched end
        if matched then return true end
      end
    end
  end
  return false
end

local function apply_snapshot(root, lines, snapshot)
  local hidden = {}
  for _, line in ipairs(snapshot.hidden or {}) do hidden[line] = true end
  -- Retain the list-time patterns as well as names seen at list time. Reapply
  -- those patterns to the current directory so matching entries that appeared
  -- after listing cannot be mistaken for user-visible DELETE sources.
  local ignored = M.ignore_set(root, snapshot.wildignore or '')
  local visible = {}
  for _, line in ipairs(lines) do
    local identity = line:gsub('/+$', '')
    if not hidden[identity]
      and not path_is_ignored(M.entry_path(root, line), ignored) then
      visible[#visible + 1] = line
    end
  end
  return visible
end

local function path_without_marker(path)
  local trimmed = tostring(path):gsub('/+$', '')
  if trimmed == '' then return '/' end
  return trimmed
end

local function relative_path(root, path)
  local function normalize(value)
    value = vim.fs.normalize(tostring(value)):gsub('\\', '/')
    if value:match('^%a:/$') then return value end
    value = value:gsub('/+$', '')
    return value == '' and '/' or value
  end
  root, path = normalize(root), normalize(path)
  if path == root then return '' end
  local prefix = root
  if prefix:sub(-1) ~= '/' then prefix = prefix .. '/' end
  if path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1)
end

local function lstat(path)
  local ok, result, err = pcall(vim.uv.fs_lstat, path_without_marker(path))
  if not ok then return nil, tostring(result) end
  return result, err
end

local function is_real_directory(path)
  local stat = lstat(path)
  return stat ~= nil and stat.type == 'directory'
end

-- Return a hidden descendant path (or an inspection error) when moving/removing
-- a visible directory would carry a list-time-wildignored entry with it. The
-- walk uses raw scandir names: the filtered entry may be a dangling symlink or
-- an unsupported filesystem type that the display listing intentionally omits.
local function hidden_descendant(directory, root_snapshot, state)
  local visited = {}
  local filters = {}
  local initial_relative = relative_path(root_snapshot.path, directory)
  if initial_relative == nil then
    return nil, 'directory is outside its list-time snapshot'
  end
  local function visit(path, inherited_snapshot, relative_directory)
    local real = fs.realpath(path)
    if visited[real] then return nil end
    visited[real] = true

    local local_snapshot = get_directory_snapshot(state, path)
    local snapshot = local_snapshot or inherited_snapshot
    if local_snapshot then relative_directory = '' end
    local filter = snapshot and filters[snapshot]
    if not filter then
      local wildignore = snapshot and snapshot.wildignore or ''
      local patterns, pattern_err = compile_wildignore(wildignore)
      if not patterns then return nil, pattern_err end
      filter = {
        ignored = M.ignore_set(snapshot and snapshot.path or path, wildignore),
        patterns = patterns,
      }
      if snapshot then filters[snapshot] = filter end
    end
    local names, scan_err = {}, nil
    local scan
    scan, scan_err = vim.uv.fs_scandir(path_without_marker(path))
    if not scan then return nil, scan_err end
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if name == nil then break end
      names[#names + 1] = name
    end
    table.sort(names)

    local hidden = {}
    if snapshot and fs.same_path(snapshot.path, path) then
      for _, name in ipairs(snapshot.hidden or {}) do
        hidden[name:gsub('/+$', '')] = true
      end
    end
    for _, name in ipairs(names) do
      local child_path = M.entry_path(path_without_marker(path), name)
      local relative_name = relative_directory == '' and name
        or (relative_directory .. '/' .. name)
      if hidden[name] or path_is_ignored(child_path, filter.ignored) then
        return child_path
      end

      local child_stat, stat_err = lstat(child_path)
      if not child_stat then return nil, stat_err or ('cannot inspect ' .. child_path) end
      local matches, match_err = wildignore_matches(name, relative_name,
        child_path, child_stat, filter.patterns)
      if matches == nil then return nil, match_err end
      if matches then return child_path end
      if child_stat.type == 'link' then
        local target_stat = fs.stat(child_path)
        if not target_stat
          or (target_stat.type ~= 'file' and target_stat.type ~= 'directory') then
          return child_path
        end
      elseif child_stat.type ~= 'file' and child_stat.type ~= 'directory' then
        return child_path
      end
      -- A directory symlink is a leaf, not permission to inspect its target.
      if child_stat.type == 'directory' then
        local found, child_err = visit(child_path, snapshot or root_snapshot,
          relative_name)
        if found or child_err then return found, child_err end
      end
    end
    return nil
  end
  return visit(directory, root_snapshot, initial_relative)
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
function M.classify(actual, expected)
  actual = actual or {}
  expected = expected or {}

  local seen = {}
  for _, line in ipairs(actual) do
    if seen[line] then
      return { kind = 'AMBIGUOUS', reason = 'duplicate' }
    end
    seen[line] = true
  end

  local actual_set, expected_set = {}, {}
  for _, line in ipairs(actual) do
    actual_set[line] = true
  end
  for _, line in ipairs(expected) do
    expected_set[line] = true
  end
  local function subset(x, y)
    for key in pairs(x) do
      if not y[key] then
        return false
      end
    end
    return true
  end

  if #actual > #expected and subset(expected_set, actual_set) then
    local added = {}
    for _, line in ipairs(actual) do
      if not expected_set[line] then
        added[#added + 1] = line
      end
    end
    return { kind = 'ADD', added = dirs_then_name(added) }
  end

  if #actual < #expected and subset(actual_set, expected_set) then
    local removed = {}
    for _, line in ipairs(expected) do
      if not actual_set[line] then
        removed[#removed + 1] = line
      end
    end
    return { kind = 'DELETE', removed = dirs_then_name(removed) }
  end

  if #actual == #expected then
    local moves = {}
    for i = 1, #actual do
      if actual[i] ~= expected[i] then
        moves[#moves + 1] = { src = expected[i], dst = actual[i] }
      end
    end
    return { kind = 'RENAME', moves = moves }
  end

  return { kind = 'AMBIGUOUS', reason = 'mixed' }
end

-- ---------------------------------------------------------------------------
-- the sync-boundary framing guard
-- ---------------------------------------------------------------------------

-- unsafe_path_reason(path) -> the shared `action.path_reason`: nil
-- when `path` can round-trip through the `NAME\tfield...` history framing, else
-- a short reason. A tab IS the field separator, so it would split one path into
-- two fields; any other control character (a newline included) cannot survive
-- `vim.fn.writefile`'s line handling either. A space is legal here: only the
-- `p`/`up` name lists use the ' ' ENTRY_SEPARATOR, and the sync classification
-- never builds those. This boundary keeps its own early refusal for the user
-- `action.serialize` applies the SAME shared guard to every emitted field, so a
-- path outside the sync path can never bypass it.
local function unsafe_path_reason(path)
  return action_mod.path_reason(path)
end

local function component_reason(line, path_style)
  if type(line) ~= 'string' then return 'invalid component' end
  local control_reason = action_mod.path_reason(line)
  if control_reason then return control_reason end
  if line:find('\0', 1, true) then return 'contains NUL' end
  if line:match('^%s') then return 'root names may not begin with whitespace' end
  local component = line
  if is_dir_line(component) then component = component:sub(1, -2) end
  if component == '' or component == '.' or component == '..'
    or component:find('/', 1, true) then
    return 'invalid path component'
  end
  local windows = path_style == 'win32'
    or (path_style == nil and package.config:sub(1, 1) == '\\')
  if windows then
    if component:find('\\', 1, true) or component:match('^%a:') then
      return 'invalid Windows path component'
    end
    if component:match('[%. ]$') then
      return 'Windows path components may not end in a dot or space'
    end
    local device = component:match('^([^%.]+)') or component
    device = device:gsub('[%. ]+$', '')
    device = device:upper()
    if device == 'CON' or device == 'PRN' or device == 'AUX' or device == 'NUL'
      or device:match('^COM[1-9]$') or device:match('^LPT[1-9]$') then
      return 'reserved Windows device name'
    end
  end
  return nil
end

-- Kept visible for platform-independent unit coverage of Win32 component rules.
M._component_reason = component_reason

-- first_unsafe(root, lines) -> { path, reason } for the first line whose path
-- is unrepresentable, else nil. Both the edited lines and the on-disk listing
-- are checked: either side can be an OS-chosen name.
local function first_unsafe(root, lines)
  for _, line in ipairs(lines) do
    local component_error = component_reason(line)
    if component_error then
      return { path = line, reason = component_error }
    end
    local path = M.entry_path(root, line)
    local reason = unsafe_path_reason(path)
    if reason ~= nil then
      return { path = path, reason = reason }
    end
  end
  return nil
end

local function children_integrity(bufnr, lines)
  local state = states[bufnr]
  if not state then return lines end
  local expected_order, child_count = {}, 0
  for _, id in ipairs(state.display_ids or {}) do
    local rec = state.rows[id]
    if rec and rec.kind == 'child' then
      expected_order[#expected_order + 1] = rec
      child_count = child_count + 1
    end
  end
  if child_count == 0 then return lines end

  local mark_rows, seen_id, seen_row, invalid_child_ids = {}, {}, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
      { details = true })) do
    local id, row, details = mark[1], mark[2], mark[4] or {}
    local rec = state.rows[id]
    if not rec then
      return nil, 'child identity marks are invalid or duplicated'
    end
    if details.invalid then
      if rec.kind == 'child' then
        if invalid_child_ids[id] then
          return nil, 'child identity marks are invalid or duplicated'
        end
        invalid_child_ids[id] = true
      end
      -- Root identities may be invalidated by deletion or rename. Keep that
      -- intent for root-only classification below; loaded-directory mutations
      -- are refused by blocks_loaded_directory before any side effects.
    else
      local other_id = seen_row[row]
      local other = other_id and state.rows[other_id]
      if seen_id[id] or (other_id and (rec.kind == 'child'
          or other and other.kind == 'child')) then
        return nil, 'child identity marks are invalid or duplicated'
      end
      seen_id[id], seen_row[row] = true, id
      mark_rows[id] = row
    end
  end

  local recovered_rows = {}
  local missing_children = 0
  for _, rec in ipairs(expected_order) do
    if mark_rows[rec.id] == nil then
      if not invalid_child_ids[rec.id] then
        return nil, 'child identity marks are invalid or duplicated'
      end
      missing_children = missing_children + 1
    end
  end
  if missing_children > 0 then
    if vim.fn.undotree().seq_cur ~= state.materialization_seq then
      return nil, 'child identity marks were lost outside an undo to their materialization baseline'
    end
    -- Undo can invalidate child extmarks even when the restored lines are still
    -- exactly the rows that were materialized. Reattach only against each
    -- expanded root's live identity and its complete, ordered subtree baseline.
    -- No filename/basename search is used: parent, sibling order, depth, count,
    -- and the exact rendered line all participate in attribution.
    local root_rows = {}
    local previous_root_row = -1
    for _, root_id in ipairs(state.root_ids or {}) do
      local row = mark_rows[root_id]
      if row == nil or row <= previous_root_row then
        return nil, 'child rows cannot be uniquely associated with their root identity'
      end
      root_rows[root_id] = row
      previous_root_row = row
    end

    local expected_child_ids = {}
    local function append_subtree(parent_id, parent_depth, out)
      local expansion = state.expanded[parent_id]
      if not expansion then return true end
      local previous_order = 0
      for _, child in ipairs(expansion.children) do
        if child.kind ~= 'child' or child.parent ~= parent_id
          or state.rows[child.id] ~= child or child.order <= previous_order
          or child.depth ~= parent_depth + 1
          or child.text ~= string.rep('  ', child.depth) .. child.name then
          return false
        end
        previous_order = child.order
        expected_child_ids[child.id] = true
        out[#out + 1] = child
        if not append_subtree(child.id, child.depth, out) then return false end
      end
      return true
    end

    for _, root_id in ipairs(state.root_ids or {}) do
      local root = state.rows[root_id]
      local expansion = state.expanded[root_id]
      if root and expansion and #expansion.children > 0 then
        local subtree = {}
        if not append_subtree(root_id, root.depth or 0, subtree) then
          return nil, 'child materialization baseline is inconsistent'
        end
        local parent_row = root_rows[root_id]
        for offset, child in ipairs(subtree) do
          local row = parent_row + offset
          if lines[row + 1] ~= child.text then
            return nil, 'child row text differs from its materialization baseline'
          end
          local occupied_by_root = false
          for _, other_root_id in ipairs(state.root_ids or {}) do
            if root_rows[other_root_id] == row then
              occupied_by_root = true
              break
            end
          end
          if occupied_by_root then
            return nil, 'child order no longer follows its owning root row'
          end
          local existing_row = mark_rows[child.id]
          if existing_row ~= nil and existing_row ~= row then
            return nil, 'child row identity moved from its materialization baseline'
          end
          if existing_row == nil and not invalid_child_ids[child.id] then
            return nil, 'child identity marks are invalid or duplicated'
          end
          if existing_row == nil then recovered_rows[child.id] = row end
          mark_rows[child.id] = row
        end
      end
    end
    for id in pairs(invalid_child_ids) do
      if not expected_child_ids[id] then
        return nil, 'child identity marks are invalid or duplicated'
      end
    end
    for _, rec in ipairs(expected_order) do
      if mark_rows[rec.id] == nil then
        return nil, 'child rows were added, deleted, reordered, or lost identity'
      end
    end
  end

  local previous_row = -1
  for _, rec in ipairs(expected_order) do
    local row = mark_rows[rec.id]
    if row == nil or row <= previous_row then
      return nil, 'child rows were added, deleted, reordered, or lost identity'
    end
    if lines[row + 1] ~= rec.text then
      return nil, 'child row text differs from its materialization baseline'
    end
    previous_row = row
  end

  -- Every expanded parent with children must retain its identity.  For each
  -- subtree, unmarked inserted lines between the parent and its last child are
  -- not root entries and may never reach the positional classifier.
  local protected = {}
  for parent_id, expansion in pairs(state.expanded or {}) do
    if #expansion.children > 0 then
      local parent_row = mark_rows[parent_id]
      -- A missing expanded parent can be a deleted or renamed root directory;
      -- its independently marked descendants stay excluded from classification.
      if parent_row ~= nil then
        local last = parent_row
        for _, rec in ipairs(expected_order) do
          local ancestor = rec.parent
          while ancestor do
            if ancestor == parent_id then
              local child_row = mark_rows[rec.id]
              if child_row == nil or child_row <= parent_row then
                return nil, 'child order no longer follows its parent'
              end
              last = math.max(last, child_row)
              break
            end
            local ancestor_rec = state.rows[ancestor]
            ancestor = ancestor_rec and ancestor_rec.parent or nil
          end
        end
        for row = parent_row + 1, last do protected[row] = true end
      end
    end
  end

  local row_ids = {}
  for id, row in pairs(mark_rows) do
    if row_ids[row] ~= nil then
      return nil, 'child identity marks are invalid or duplicated'
    end
    row_ids[row] = id
  end
  local actual_children = 0
  for row, line in ipairs(lines) do
    local id = row_ids[row - 1]
    local rec = id and state.rows[id]
    if rec and rec.kind == 'child' then
      actual_children = actual_children + 1
    elseif protected[row - 1] or (not rec and line:match('^%s')) then
      return nil, 'unidentified child row is present'
    end
  end
  if actual_children ~= child_count then
    return nil, 'child row count differs from its materialization baseline'
  end

  local root_lines = {}
  for row, line in ipairs(lines) do
    local id = row_ids[row - 1]
    local rec = id and state.rows[id]
    if not rec or rec.kind ~= 'child' then
      root_lines[#root_lines + 1] = line
    end
  end
  for id, row in pairs(recovered_rows) do
    local ok = pcall(set_row_mark, bufnr, row, id)
    if not ok then
      return nil, 'child identity marks could not be restored safely'
    end
  end
  return root_lines
end

-- If undo returns exactly to the sequence that preceded a view materialization,
-- Neovim has removed that insertion block. Reconcile only when each surviving
-- child still has its original identity and text. Root rows may have changed;
-- children_integrity() continues to protect any surviving materialized subtree.
reconcile_undone_materialization = function(bufnr)
  local state = states[bufnr]
  local undos = state and state.materialization_undos or {}
  local undo_tree = vim.fn.undotree(bufnr)
  local seq_cur = undo_tree.seq_cur
  local prune_from

  -- TextChanged is not guaranteed to run between `:undo` and the next edit.
  -- When that edit creates a new branch, the materialization sequence remains
  -- under an `alt` branch in undotree(), while the new root edit becomes the
  -- active head.  Recognize that transition as well as the exact baseline
  -- sequence; only consider it when the materialization's base remains on the
  -- active path and the materialization itself is now on an alternate path.
  local active, alternate = {}, {}
  local function collect_alternates(entries)
    local pending = {}
    for _, entry in ipairs(entries or {}) do pending[#pending + 1] = entry end
    while #pending > 0 do
      local entry = table.remove(pending)
      alternate[entry.seq] = true
      for _, alt in ipairs(entry.alt or {}) do
        pending[#pending + 1] = alt
      end
    end
  end
  local current_path = false
  for _, entry in ipairs(undo_tree.entries or {}) do
    if current_path then
      collect_alternates({ entry })
    else
      active[entry.seq] = true
      collect_alternates(entry.alt)
      if entry.seq == seq_cur then current_path = true end
    end
  end
  for index, materialization in ipairs(undos) do
    local returned_to_base = materialization.base_seq == seq_cur
    local branched_from_base = (materialization.base_seq == 0
        or active[materialization.base_seq])
      and not active[materialization.seq]
      and alternate[materialization.seq]
    if returned_to_base or branched_from_base then
      prune_from = index
      break
    end
  end
  if not prune_from then return false end

  local removed_ids = {}
  local function mark_removed_subtree(parent_id)
    local expansion = state.expanded[parent_id]
    if not expansion then return end
    for _, child in ipairs(expansion.children) do
      if not removed_ids[child.id] then
        removed_ids[child.id] = true
        mark_removed_subtree(child.id)
      end
    end
  end
  for index = prune_from, #undos do
    mark_removed_subtree(undos[index].parent_id)
  end
  local expected_ids = {}
  for _, id in ipairs(state.display_ids or {}) do
    if not removed_ids[id] then expected_ids[#expected_ids + 1] = id end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local expected_children, found_children = {}, {}
  for _, id in ipairs(expected_ids) do
    local rec = state.rows[id]
    if not rec then return false end
    if rec.kind == 'child' then expected_children[id] = rec end
  end
  local marks, seen_ids, seen_rows = {}, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
      { details = true })) do
    local id, row, details = mark[1], mark[2], mark[4] or {}
    local rec = state.rows[id]
    if not rec or seen_ids[id] then return false end
    seen_ids[id] = true
    if rec.kind == 'child' then
      if removed_ids[id] then
        if not details.invalid then return false end
      elseif not expected_children[id] or details.invalid then
        return false
      else
        if lines[row + 1] ~= rec.text or seen_rows[row] then return false end
        found_children[id] = row
        seen_rows[row] = true
      end
    elseif not details.invalid then
      if seen_rows[row] then return false end
      seen_rows[row] = true
      marks[#marks + 1] = { row = row, id = id }
    end
  end
  for id in pairs(expected_children) do
    if found_children[id] == nil then return false end
  end
  local child_rows = {}
  for id, row in pairs(found_children) do child_rows[row] = id end
  for row, line in ipairs(lines) do
    if not child_rows[row - 1] and line:match('^%s') then return false end
  end

  local function forget_subtree(parent_id)
    local expansion = state.expanded[parent_id]
    if not expansion then return end
    state.expanded[parent_id] = nil
    for _, child in ipairs(expansion.children) do
      forget_subtree(child.id)
      state.rows[child.id] = nil
    end
  end
  for index = #undos, prune_from, -1 do
    forget_subtree(undos[index].parent_id)
    undos[index] = nil
  end

  -- Undo may leave invalid extmarks for deleted child lines. Rebuild the marks
  -- from the verified surviving row identities so no stale child identity can
  -- poison a later root-only sync.
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for _, mark in ipairs(marks) do set_row_mark(bufnr, mark.row, mark.id) end
  for id, row in pairs(found_children) do set_row_mark(bufnr, row, id) end
  state.display_ids = expected_ids
  state.materialization_seq = seq_cur
  return true
end

local function blocks_loaded_directory(bufnr, plan)
  local state = states[bufnr]
  if not state then return nil end
  for root_id, expansion in pairs(state.expanded or {}) do
    if #expansion.children > 0 then
      local root = state.rows[root_id]
      if root and root.kind == 'root' then
        local protected_path = M.entry_path(state.root, root.name)
        for _, move in ipairs(plan.moves or {}) do
          if fs.same_path(M.entry_path(state.root, move.src), protected_path) then
            return root.name
          end
        end
        for _, removed in ipairs(plan.removed or {}) do
          if fs.same_path(M.entry_path(state.root, removed), protected_path) then
            return root.name
          end
        end
      end
    end
  end
  return nil
end

-- ambiguous_message(plan, actual, expected) names the reason and both sides of
-- the comparison so the user can see what desynced.
local function ambiguous_message(plan, actual, expected)
  return string.format(
    'Ambiguous buffer content (%s). '
      .. 'You must only add, remove or rename in each edit.'
      .. '\nactual:   %s\nexpected: %s',
    plan.reason, table.concat(actual, ', '), table.concat(expected, ', '))
end

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

local function set_options(bufnr)
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'direct'
  -- BufWriteCmd <buffer> DirectSync: a `:write` in a direct
  -- buffer routes to the sync instead of writing a file. Recreated per listing
  -- (the augment `direct`) after clearing this buffer's own autocmds, matching
  -- the retired `autocmd! * <buffer>` so repeated listings cannot stack handlers.
  local group = vim.api.nvim_create_augroup('direct', { clear = false })
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
    command = 'DirectSync',
    desc = 'direct: sync the listing on :write',
  })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = bufnr,
    callback = function() install_fold_options(bufnr) end,
    desc = 'direct: configure listing folds in each window',
  })
  vim.api.nvim_create_autocmd('TextChanged', {
    group = group,
    buffer = bufnr,
    callback = function() reconcile_undone_materialization(bufnr) end,
    desc = 'direct: reconcile child rows when undo removes a materialization',
  })
  vim.keymap.set('n', 'zo', function() M.fold_open(false) end,
    { buffer = bufnr, silent = true, desc = 'Unfold one direct directory level' })
  vim.keymap.set('n', 'za', function() M.fold_open(true) end,
    { buffer = bufnr, silent = true, desc = 'Toggle one direct directory fold' })
  install_fold_options(bufnr)
end

-- Return the destination left by a successful create/move, or nil for removals.
-- Use the original action so a staging temp can never become current_entry.
local function result_entry(act)
  if act.name == 'mv' or act.name == 'touch' or act.name == 'mkdir' then
    return act.dst
  end
  return nil
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
function Buffer:place_cursor(lines)
  if self.current_entry == nil then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  for index, line in ipairs(lines) do
    local record = current_row_record(bufnr, index - 1)
    local path = row_path(self.root, record, line)
      or M.entry_path(self.root, line)
    if fs.same_path(path, self.current_entry) then
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
  local lines, snapshot, err = list_with_snapshot(self.root)
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

  local bufnr = vim.api.nvim_get_current_buf()
  local old_state = states[bufnr]
  local old_root_candidates, old_expanded = {}, {}
  if old_state then
    old_expanded = old_state.expanded or {}
    local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for row, line in ipairs(old_lines) do
      local id = row_id_at(bufnr, row - 1)
      local rec = id and old_state.rows[id]
      -- Reuse a root only while its extmark still identifies the unchanged
      -- row and its prior path is the same filesystem entry. Edited text may
      -- happen to equal another root's name; that is not an identity change.
      if rec and rec.kind == 'root' and line == rec.text and line == rec.name
        and rec.path
        and fs.same_path(rec.path, M.entry_path(old_state.root, rec.name)) then
        old_root_candidates[#old_root_candidates + 1] = rec
      end
    end
  end

  local state = {
    root = self.root,
    rows = {},
    expanded = old_expanded,
    root_ids = {},
    next_id = old_state and old_state.next_id or 0,
    display_ids = {},
    fold_windows = old_state and old_state.fold_windows or {},
    materialization_undos = {},
    directory_snapshots = old_state and vim.deepcopy(old_state.directory_snapshots or {}) or {},
  }
  set_directory_snapshot(state, snapshot)
  local roots = {}
  local used_root = {}
  for _, line in ipairs(safe) do
    local path = M.entry_path(self.root, line)
    local rec, candidate_count = nil, 0
    for _, candidate in ipairs(old_root_candidates) do
      if fs.same_path(candidate.path, path) then
        rec = candidate
        candidate_count = candidate_count + 1
      end
    end
    local path_count = 0
    for _, other_line in ipairs(safe) do
      if fs.same_path(path, M.entry_path(self.root, other_line)) then
        path_count = path_count + 1
      end
    end
    -- Equivalent spellings may occur more than once (for example two symlink
    -- aliases). Reuse only a unique prior identity for a unique new row.
    if candidate_count == 1 and path_count == 1 and not used_root[rec.id] then
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
      rendered[#rendered + 1] = { text = child.text, id = child.id }
      state.display_ids[#state.display_ids + 1] = child.id
      render_children(child.id, child.path, depth + 1)
    end
  end
  for _, rec in ipairs(roots) do
    rendered[#rendered + 1] = { text = rec.text, id = rec.id }
    state.display_ids[#state.display_ids + 1] = rec.id
    if is_dir_line(rec.name) then
      render_children(rec.id, rec.path, 1)
    end
  end
  for id in pairs(state.expanded) do
    if not state.rows[id] then state.expanded[id] = nil end
  end

  local display = {}
  for _, row in ipairs(rendered) do display[#display + 1] = row.text end
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
  highlight.render(bufnr)
  state.materialization_seq = vim.fn.undotree().seq_cur
  set_options(bufnr)
  self:place_cursor(display)
  if self.current_entry == nil then
    pcall(vim.api.nvim_win_set_cursor, 0, {
      math.max(1, math.min(cursor[1], #display)), cursor[2],
    })
  end
  vim.bo[bufnr].modified = false
  return true
end

-- Expr-fold levels use the stable string form supported by Neovim: a
-- directory starts a level and its immediate children occupy that level.
function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  local rec = current_row_record(bufnr, lnum - 1)
  if not rec then return '0' end
  if is_dir_line(rec.name) then
    return '>' .. tostring((rec.depth or 0) + 1)
  end
  return tostring(rec.depth or 0)
end

function Buffer:unfold(row)
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
    local children, snapshot, err = list_with_snapshot(path)
    if not children then
      ui.notify('direct: cannot unfold ' .. tostring(path) .. ': '
        .. tostring(err), vim.log.levels.ERROR)
      return nil, err
    end
    local materialized = {}
    for order, child_name in ipairs(children) do
      local child_path = M.entry_path(path, child_name)
      local reason = action_mod.path_reason(child_path)
      if not reason then
        materialized[#materialized + 1] = {
          id = next_id(state), kind = 'child', name = child_name,
          text = string.rep('  ', (rec.depth or 0) + 1) .. child_name,
          parent = rec.id, order = order, depth = (rec.depth or 0) + 1,
          path = child_path,
        }
      else
        ui.notify('direct: skipping unlistable entry (' .. reason .. '): '
          .. child_name, vim.log.levels.ERROR)
      end
    end
    state.expanded[rec.id] = { children = materialized }
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
      highlight.render(bufnr)
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
        }
        state.materialization_undos = state.materialization_undos or {}
        state.materialization_undos[#state.materialization_undos + 1] = materialization
      end
      vim.bo[bufnr].modified = modified
      pcall(vim.api.nvim_win_set_cursor, 0, cursor)
    end
  end

  pcall(vim.api.nvim_win_call, vim.api.nvim_get_current_win(), function()
    if just_materialized then vim.cmd('normal! zx') end
    if self.toggle and not just_materialized then
      vim.cmd('normal! za')
    elseif vim.fn.foldclosed(row) ~= -1 then
      vim.cmd('normal! zo')
    end
  end)
  return true
end

function M.fold_open(toggle)
  local buffer = M.restore()
  buffer.toggle = toggle
  return buffer:unfold(vim.api.nvim_win_get_cursor(0)[1])
end

-- ---------------------------------------------------------------------------
-- sync
-- ---------------------------------------------------------------------------

-- build_actions returns actions and yanks. ADD/DELETE follow dirs-then-name
-- order; deleted directory paths retain their trailing slash in the auto-yank.
local function build_actions(root, plan)
  local actions, yanks = {}, {}
  if plan.kind == 'ADD' then
    for _, line in ipairs(plan.added) do
      local path = M.entry_path(root, line)
      if is_dir_line(line) then
        actions[#actions + 1] = action_mod.MakeDirectory(path)
      else
        actions[#actions + 1] = action_mod.Touch(path)
      end
    end
  elseif plan.kind == 'DELETE' then
    for _, line in ipairs(plan.removed) do
      local path = M.entry_path(root, line)
      yanks[#yanks + 1] = path
      if is_dir_line(line) then
        actions[#actions + 1] = action_mod.RemoveDirectory(path)
      else
        actions[#actions + 1] = action_mod.Remove(path)
      end
    end
  elseif plan.kind == 'RENAME' then
    for _, move in ipairs(plan.moves) do
      local src = M.entry_path(root, move.src)
      local dst = M.entry_path(root, move.dst)
      -- Directory symlinks are displayed with the directory marker, but the
      -- marker would make rename follow the link instead of moving the link.
      local source_stat = lstat(src)
      if source_stat and source_stat.type == 'link' then
        src = path_without_marker(src)
        dst = path_without_marker(dst)
      end
      actions[#actions + 1] = action_mod.Move(src, dst)
    end
  end
  return actions, yanks
end

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
  local visible = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local actual, child_err = children_integrity(bufnr, visible)
  if not actual then
    vim.bo[bufnr].modified = true
    ui.notify('Refusing to sync: ' .. tostring(child_err)
      .. '; nothing was changed.', vim.log.levels.ERROR)
    return nil, child_err
  end
  -- Neovim represents an empty buffer with one empty string.  A clean empty
  -- direct listing denotes zero root entries, not an empty filename.
  if #actual == 1 and actual[1] == '' and not vim.bo[bufnr].modified then
    actual = {}
  end
  local expected, read_err = fs.read_dir_lines(self.root)
  if not expected then
    ui.notify('direct: cannot read ' .. tostring(self.root) .. ': '
      .. tostring(read_err), vim.log.levels.ERROR)
    return nil, read_err
  end
  expected = apply_snapshot(self.root, expected, snapshot)

  -- refuse a path the history framing cannot represent, before any
  -- action or history write. The buffer is not re-listed and stays modified.
  local unsafe = first_unsafe(self.root, actual) or first_unsafe(self.root, expected)
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

  local blocked_dir = blocks_loaded_directory(bufnr, plan)
  if blocked_dir then
    vim.bo[bufnr].modified = true
    local reason = 'directory has unfolded descendants: ' .. blocked_dir
    ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
      vim.log.levels.ERROR)
    return nil, reason
  end

  local actions, yanks = build_actions(self.root, plan)

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
  local move_sources = {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and fs.taken(act.src) then
      move_sources[vim.fs.normalize((act.src:gsub('/+$', '')))] = true
    end
  end
  for _, act in ipairs(actions) do
    local destination = act.dst
    if destination and fs.taken(destination) then
      local normalized = vim.fs.normalize((destination:gsub('/+$', '')))
      if not (act.name == 'mv' and move_sources[normalized]) then
        vim.bo[bufnr].modified = true
        local reason = 'destination already exists: ' .. destination
        ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
          vim.log.levels.ERROR)
        return nil, reason
      end
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
  local staging, stage_err, stage_temps = stage_moves(actions)
  if staging == nil and stage_err ~= nil then
    ui.notify('Action failed - could not stage renames: ' .. tostring(stage_err),
      vim.log.levels.ERROR)
    -- a failed staging rename leaves every already-staged entry at
    -- its temp path. Report each one -- the same treatment the post-execution
    -- leftover block below gives -- instead of returning on the error alone
    -- and orphaning the temps silently.
    for _, tmp in ipairs(stage_temps or {}) do
      if fs.exists(tmp) then
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
    local ok, res, aerr = pcall(exec_action['do'])
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

  -- remove any staged temp that was not consumed. On the all-success path
  -- every temp is consumed, so this is normally a no-op. On the failure path a
  -- temp left over is reported instead of force-removed: deleting it could
  -- discard the very entry a failed move could not place, and requires
  -- failures to be reported without losing data.
  if staging ~= nil then
    for _, tmp in ipairs(staging.temps) do
      if fs.exists(tmp) then
        if #failed == 0 then
          fs.rm_tree(tmp)
        else
          ui.notify('direct: a failed rename left the staged entry ' .. tmp,
            vim.log.levels.ERROR)
        end
      end
    end
  end

  -- Re-list so the buffer reflects the filesystem, restore the cursor, and
  -- mark it unmodified only after the refresh succeeds.
  self:list()

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

return M
