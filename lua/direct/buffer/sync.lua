-- Sync planning and execution for the Direct buffer.
-- Dependencies are injected from buffer.lua to keep this a code-only split.

return function(context)
  local M = context.M
  local Buffer = context.Buffer
  local action_mod = context.action_mod
  local history = context.history
  local register = context.register
  local ui = context.ui
  local fs = context.fs
  local paths = context.paths
  local git = context.git
  local pending = context.pending
  local file_operations = context.file_operations
  local states = context.states
  local pending_sync = context.pending_sync
  local restore_deleted_rows = context.restore_deleted_rows
  local reconcile_undone_materialization = context.reconcile_undone_materialization
  local get_directory_snapshot = context.get_directory_snapshot
  local children_integrity = context.children_integrity
  local row_ids_by_row = context.row_ids_by_row
  local indent_size = context.indent_size
  local edited_subtrees = context.edited_subtrees
  local first_unsafe = context.first_unsafe
  local ambiguous_message = context.ambiguous_message
  local classify_identity = context.classify_identity
  local build_actions = context.build_actions
  local apply_snapshot = context.apply_snapshot
  local filter_git_status_lines = context.filter_git_status_lines
  local filter_git_diff_lines = context.filter_git_diff_lines
  local is_dir_line = context.is_dir_line
  local is_real_directory = context.is_real_directory
  local hidden_descendant = context.hidden_descendant
  local result_entry = context.result_entry
  local current_row_record = context.current_row_record
  local remove_expanded_subtree = context.remove_expanded_subtree
  local collapse_single_entry_paths = context.collapse_single_entry_paths

-- ---------------------------------------------------------------------------
-- sync
-- ---------------------------------------------------------------------------

-- log_applied(actions, applied) records successful actions in history. History
-- is written per GROUP of interlinked moves: a swap or an N-way rotation is one
-- entry. Independent actions keep their own entries unless a successful sync
-- mixes create, delete, and rename categories; those records are compacted into
-- one durable batch so a single `DirectUndo` reverses the mixed save.
--
-- A group with any member that did NOT apply is not recorded at all: its
-- reversal would pass through a colliding name (the reported defect), and
-- already never records a reversal for entries that were never written (the
-- Paste precedent). A singleton group is logged only when its action applied.
local function log_applied(actions, applied, already_logged)
  local records, all_recorded = {}, true
  for _, group in ipairs(action_mod.move_groups(actions)) do
    local members, complete, already_recorded = {}, true, true
    for _, index in ipairs(group) do
      if not applied[index] then
        complete = false
      end
      if not already_logged or not already_logged[index] then
        already_recorded = false
      end
      members[#members + 1] = actions[index]
    end
    if complete and not already_recorded then
      local record_action
      if #members == 1 then
        record_action = members[1]
      else
        record_action = action_mod.Group(members)
      end
      local logged, log_err = history.log(record_action)
      if not logged then
        all_recorded = false
        ui.notify('direct: could not record a completed action: ' .. tostring(log_err),
          vim.log.levels.ERROR)
      end
    end
    if complete then
      records[#records + 1] = #members == 1 and members[1] or action_mod.Group(members)
    end
  end

  if all_recorded and #records > 1 then
    local categories = {}
    local function categorize(action)
      if action.name == 'g' or action.name == 'batch' then
        for _, member in ipairs(action.actions or {}) do categorize(member) end
      elseif action.name == 'mv' then
        categories.rename = true
      elseif action.name == 'rm' or action.name == 'rmdir' then
        categories.delete = true
      elseif action.name == 'touch' or action.name == 'mkdir' then
        categories.create = true
      end
    end
    for _, record in ipairs(records) do categorize(record) end
    local category_count = 0
    for _ in pairs(categories) do category_count = category_count + 1 end
    if category_count > 1 then
      local combined, combine_err = history.combine_recent(records)
      if not combined then
        ui.notify('direct: sync completed, but its mixed actions remain in separate '
          .. 'history entries: ' .. tostring(combine_err), vim.log.levels.WARN)
      end
    end
  end
end

local function sync_signature(actions, yanks)
  local function action_signature(action)
    local result = {
      name = action.name,
      src = action.src,
      dst = action.dst,
      renames = vim.deepcopy(action.renames),
    }
    if action.actions then
      result.actions = {}
      for _, member in ipairs(action.actions) do
        result.actions[#result.actions + 1] = action_signature(member)
      end
    end
    return result
  end
  local signature = { actions = {}, yanks = vim.deepcopy(yanks or {}) }
  for _, action in ipairs(actions or {}) do
    signature.actions[#signature.actions + 1] = action_signature(action)
  end
  return signature
end

-- Buffer:sync -> true when all classified actions succeeded (the buffer was
-- re-listed and marked nomodified), nil, reason when preflight refused the
-- sync or any action failed. Failed action batches are still re-listed so the
-- buffer reflects any independent actions that did succeed.
local function sync_locked(self, options)
  options = options or {}
  if not options.bypass_pending and pending.refuse('sync') then
    return nil, 'another direct operation is pending'
  end
  local bufnr = vim.api.nvim_get_current_buf()
  restore_deleted_rows(bufnr)
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
    local row_ids = row_ids_by_row(bufnr)
    for row = 0, #visible - 1 do
      local id = row_ids[row]
      if id then visible_ids[id] = true end
    end
    for row, line in ipairs(visible) do
      local id = row_ids[row - 1]
      local rec = id and state.rows[id] or nil
      if not rec then
        local expected_id = state and state.display_ids[row]
        local expected_rec = expected_id and state.rows[expected_id]
        if expected_rec and line == expected_rec.text then rec = expected_rec end
      end
      local prefix = line:match('^( *)') or ''
      local spaces_per_level = indent_size()
      if #prefix > 0 then has_indented = true end
      if #prefix % spaces_per_level ~= 0 then
        has_tree_edit = true
        break
      end
      local depth = #prefix / spaces_per_level
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
  if state.view_git_status_only then
    expected = filter_git_status_lines(self.root, expected, state.git_status)
  end
  if state.view_git_diff_only then
    expected = filter_git_diff_lines(self.root, expected, state.git_diff_snapshot)
  end
  if state.collapse_single_entry_directories then
    local projected, _, _, project_err = collapse_single_entry_paths(self.root,
      expected, {
        state = state,
        show_hidden = snapshot.show_hidden,
        respect_gitignore = snapshot.respect_gitignore,
        status_only = state.view_git_status_only,
        git_status = state.git_status,
        git_diff_only = state.view_git_diff_only,
        git_diff = state.git_diff_snapshot,
      })
    if not projected then
      vim.bo[bufnr].modified = true
      local reason = 'could not validate collapsed directory view: '
        .. tostring(project_err)
      ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
        vim.log.levels.ERROR)
      return nil, reason
    end
    expected = projected
  end
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
  local current_root_rows = subtree_edit and subtree_edit.root_rows or {}
  if not subtree_edit and #actual > 0 then
    local row_ids = row_ids_by_row(bufnr)
    for row, line in ipairs(visible) do
      local id = row_ids[row - 1]
      local rec = id and state.rows[id]
      local prefix = line:match('^( *)') or ''
      if #prefix > 0 or (rec and rec.kind == 'child') then
        -- Root-only sync input excludes unchanged materialized descendants.
      elseif not (rec and rec.deleted_kind) then
        current_root_rows[#current_root_rows + 1] = { id = id, line = line }
      end
    end
  end
  local nested_added = {}
  for _, row in ipairs(current_root_rows) do
    if not row.id then
      nested_added[row.line] = true
    else
      local rec = state.rows[row.id]
      if rec and rec.collapsed_components then nested_added[row.line] = true end
    end
  end
  local expected_nested = {}
  if state.collapse_single_entry_directories then
    for _, line in ipairs(expected) do
      if line:find('/', 1, true) then expected_nested[line] = true end
    end
  end
  local unsafe = first_unsafe(self.root, actual, nested_added)
    or first_unsafe(self.root, expected, expected_nested)
  if unsafe ~= nil then
    vim.bo[bufnr].modified = true
    ui.notify('Unsafe entry in the buffer (' .. unsafe.reason
      .. '); nothing was changed: ' .. unsafe.path, vim.log.levels.ERROR)
    return nil, unsafe.reason
  end

  -- Keep the public legacy classifier observable for compatibility, but plan
  -- filesystem actions exclusively from row identity, never from line order.
  local classified = M.classify(actual, expected)
  if classified.kind == 'AMBIGUOUS' and classified.reason == 'duplicate' then
    -- notify, change nothing, write no history, do NOT re-list, and
    -- leave the buffer modified so the unsaved intent is not discarded.
    ui.notify(ambiguous_message(classified, actual, expected), vim.log.levels.ERROR)
    return nil, classified.reason
  end

  local original_root_rows = {}
  for _, id in ipairs(state.root_ids or {}) do
    local rec = state.rows[id]
    if rec and rec.kind == 'root' then
      original_root_rows[#original_root_rows + 1] = {
        id = id, name = rec.name, path = rec.path, identity = rec.identity,
        deleted_kind = rec.deleted_kind,
        collapsed_components = rec.collapsed_components,
      }
    end
  end
  local plan, identity_err = classify_identity(self.root, original_root_rows,
    current_root_rows, expected, vim.b[bufnr].direct_text_undo_mode == true)
  if not plan then
    vim.bo[bufnr].modified = true
    ui.notify('Refusing to sync: ' .. tostring(identity_err)
      .. '; nothing was changed.', vim.log.levels.ERROR)
    return nil, identity_err
  end
  if plan.kind == 'AMBIGUOUS' then
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
  if #(plan.added or {}) > 0 then
    local added_set, expand_by_path = {}, {}
    for _, line in ipairs(plan.added or {}) do added_set[line] = true end
    -- Keep the cursor target in the user's row order, not the sorted action
    -- order. Nested parent directories are expanded for every new nested path.
    for _, line in ipairs(actual) do
      if added_set[line] then
        local relative = paths.strip_directory_marker(line)
        if paths.directory_separator() == '\\' then
          relative = relative:gsub('\\', '/')
        end
        added_focus_path = M.entry_path(self.root, line)
        if relative:find('/', 1, true) then
          local parts = vim.split(relative, '/', { plain = true })
          local directory_count = #parts - (is_dir_line(line) and 0 or 1)
          local parent = self.root
          for index = 1, directory_count do
            parent = fs.join(parent, parts[index])
            local normalized_parent = paths.strip_trailing_separator(parent)
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
    if #(plan.removed or {}) > 0 then
      local removed_roots = {}
      for _, line in ipairs(plan.removed or {}) do
        if is_dir_line(line) then
          removed_roots[#removed_roots + 1] = M.entry_path(self.root, line)
        end
      end
      local function under_removed_root(path)
        if type(path) ~= 'string' then return false end
        local candidate = vim.fs.normalize(path)
        candidate = paths.canonical(candidate)
        for _, root_path in ipairs(removed_roots) do
          local normalized = paths.canonical(root_path)
          local prefix = normalized:sub(-1) == '/' and normalized or normalized .. '/'
          if candidate == normalized or candidate:sub(1, #prefix) == prefix then
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
    -- A root-level delete may free the target of a root rename in the same
    -- mixed save. Keep mkdir dependencies intact, but place that file removal
    -- immediately before the move that reuses its path.
    local move_index = 1
    while move_index <= #actions do
      local move = actions[move_index]
      if move.name == 'mv' then
        for remove_index = move_index + 1, #actions do
          local removal = actions[remove_index]
          if removal.name == 'rm' and fs.same_entry(removal.src, move.dst) then
            table.remove(actions, remove_index)
            table.insert(actions, move_index, removal)
            move_index = move_index + 1
            break
          end
        end
      end
      move_index = move_index + 1
    end
    local destination_index = fs.path_identity_index()
    for _, act in ipairs(actions) do
      if act.name == 'mv' or act.name == 'touch' or act.name == 'mkdir' then
        if fs.path_identity_index_contains(destination_index, act.dst) then
          vim.bo[bufnr].modified = true
          local reason = 'multiple subtree actions target the same path: ' .. act.dst
          ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
            vim.log.levels.ERROR)
          return nil, reason
        end
        fs.path_identity_index_add(destination_index, act.dst)
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

  -- Fail the whole batch before auto-yank/history when an action
  -- would land on an occupied path. Move destinations that are also move
  -- sources are safe: grouped move execution stages them from its durable plan.
  -- Compare filesystem-entry identity as well as spelling for case-only moves.
  local vacated_sources, sources_by_inode = {}, {}
  local function move_key(path)
    path = paths.strip_trailing_separator(path)
    return vim.fs.normalize(path)
  end
  for _, act in ipairs(actions) do
    if (act.name == 'mv' or act.name == 'rm' or act.name == 'rmdir')
      and fs.taken(act.src) then
      vacated_sources[move_key(act.src)] = true
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
      local may_reuse_source = (act.name == 'mv' or act.name == 'touch'
        or act.name == 'mkdir') and vacated_sources[key] == true
      if (act.name == 'mv' or act.name == 'touch' or act.name == 'mkdir')
        and not may_reuse_source then
        local identity = fs.entry_identity(destination)
        local bucket = identity and identity.inode and sources_by_inode[identity.inode]
        for _, source in ipairs(bucket or {}) do
          if fs.same_entry(destination, source) then
            may_reuse_source = true
            break
          end
        end
      end
      if not may_reuse_source then
        vim.bo[bufnr].modified = true
        local reason = 'destination already exists: ' .. destination
        ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
          vim.log.levels.ERROR)
        return nil, reason
      end
    end
  end

  if options.expected_plan
    and not vim.deep_equal(sync_signature(actions, yanks), options.expected_plan) then
    vim.bo[bufnr].modified = true
    local reason = 'sync plan changed while waiting for LSP willRenameFiles; review and save again'
    ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
      vim.log.levels.WARN)
    return nil, reason
  end

  -- Ask workspace clients before the first history, register, staging, or
  -- filesystem side effect. The callback re-enters the ordinary sync planner so
  -- all path and snapshot checks run again after server edits have landed.
  if not options.skip_will then
    local files, changed_paths = {}, {}
    for _, act in ipairs(actions) do
      if act.name == 'mv' then
        files[#files + 1] = {
          oldUri = vim.uri_from_fname(fs.abspath(act.src)),
          newUri = vim.uri_from_fname(fs.abspath(act.dst)),
        }
        changed_paths[#changed_paths + 1] = act.src
        changed_paths[#changed_paths + 1] = act.dst
      end
    end
    if #files > 0 and #file_operations.clients('workspace/willRenameFiles', changed_paths) > 0 then
      local token, owns_token = options.pending_token, false
      if token == nil then
        local began, begin_token = pending.begin('willRenameFiles')
        if not began then
          ui.notify('direct: cannot rename while another operation is pending',
            vim.log.levels.WARN)
          return nil, 'another direct operation is pending'
        end
        token, owns_token = begin_token, true
      end
      if options.async_actions then options.async_started = true end
      local requested_plan = sync_signature(actions, yanks)
      local operation = {
        token = token, closed = false, guard_released = false,
        owns_token = owns_token, continuing = false,
      }
      pending_sync[bufnr] = operation
      operation.cleanup = function()
        operation.closed = true
        if pending_sync[bufnr] == operation then pending_sync[bufnr] = nil end
        if operation.owns_token and not operation.guard_released then
          operation.guard_released = true
          pending.finish(token)
        elseif not operation.owns_token and not operation.continuing
          and options.async_actions then
          operation.continuing = true
          options.async_complete(nil, 'pending rename was canceled')
        end
      end
      local function finish(ok, suppressed_or_err)
        if operation.closed then return end
        local active = pending.is_active(token) and pending_sync[bufnr] == operation
        operation.closed = true
        if pending_sync[bufnr] == operation then pending_sync[bufnr] = nil end
        local ran, callback_err = xpcall(function()
          if not active then return end
          if not vim.api.nvim_buf_is_valid(bufnr) then
            if options.async_actions then
              operation.continuing = true
              options.async_complete(nil, 'listing buffer was closed during sync')
            end
            return
          end
          if not ok then
            vim.bo[bufnr].modified = true
            ui.notify('Refusing to rename after LSP workspace edit failure '
              .. '(earlier server edits may already have applied): '
              .. tostring(suppressed_or_err), vim.log.levels.ERROR)
            if options.async_actions then
              operation.continuing = true
              options.async_complete(nil, tostring(suppressed_or_err))
            end
            return
          end
          if options.async_actions then operation.continuing = true end
          vim.api.nvim_buf_call(bufnr, function()
            if options.async_actions then
              local follow = {
                bypass_pending = true, skip_will = true,
                suppress_operations = suppressed_or_err,
                expected_plan = requested_plan,
                async_actions = true,
                pending_token = token,
                async_complete = options.async_complete,
              }
              local result, follow_err = sync_locked(self, follow)
              if not follow.async_started then options.async_complete(result, follow_err) end
            else
              self:sync({ bypass_pending = true, skip_will = true,
                suppress_operations = suppressed_or_err,
                expected_plan = requested_plan })
            end
          end)
        end, debug.traceback)
        operation.cleanup()
        if not ran then
          ui.report_error('finish the directory rename', callback_err)
          if options.async_actions then options.async_complete(nil, callback_err) end
        end
      end
      local started, cancel = pcall(file_operations.will_rename, files, finish, nil,
        function()
          return pending.is_active(token) and pending_sync[bufnr] == operation
        end)
      if started and type(cancel) == 'function' and not operation.closed then
        operation.cancel = cancel
      end
      if not started then finish(true, {}) end
      return true
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
      ui.notify('Refusing to sync: history preflight failed: '
        .. tostring(preflight_err), vim.log.levels.ERROR)
      return nil, preflight_err
    end
  end

  require('direct.events').emit('DirectSyncPre', {
    root = self.root,
    actions = actions,
    yanks = yanks,
    bufnr = bufnr,
  })
  if not vim.api.nvim_buf_is_valid(bufnr)
    or not vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), visible) then
    local reason = 'listing changed during DirectSyncPre; review and save again'
    if vim.api.nvim_buf_is_valid(bufnr) then vim.bo[bufnr].modified = true end
    ui.notify('Refusing to sync: ' .. reason .. '; nothing was changed.',
      vim.log.levels.WARN)
    require('direct.events').emit('DirectSyncPost', {
      root = self.root,
      actions = actions,
      applied = {},
      failed = {},
      yanks = yanks,
      success = false,
      error = reason,
      bufnr = bufnr,
    })
    return nil, reason
  end

  -- Yank removed paths before applying actions. If yanking is refused, leave
  -- the filesystem untouched.
  if #yanks > 0 then
    local ok, yerr = register.yank(yanks, { bypass_pending = options.bypass_pending })
    if not ok then
      ui.notify('Action failed - could not yank deleted entries: '
        .. tostring(yerr), vim.log.levels.ERROR)
      require('direct.events').emit('DirectSyncPost', {
        root = self.root,
        actions = actions,
        applied = {},
        failed = {},
        yanks = yanks,
        success = false,
        error = tostring(yerr),
        bufnr = bufnr,
      })
      return nil, yerr
    end
  end

  -- Interlinked moves use a durable staging plan instead of mutating names
  -- before journaling.
  local group_at, processed = {}, {}
  for _, indices in ipairs(action_mod.move_groups(actions)) do
    if #indices > 1 then
      local members = {}
      for _, index in ipairs(indices) do members[#members + 1] = actions[index] end
      local info = { first = indices[1], indices = indices,
        action = action_mod.Group(members) }
      for _, index in ipairs(indices) do group_at[index] = info end
    end
  end
  local failed, applied, failure_reason, already_logged = {}, {}, nil, {}
  local function emit_sync_post()
    local applied_actions = {}
    for index, action in ipairs(actions) do
      if applied[index] then applied_actions[#applied_actions + 1] = action end
    end
    require('direct.events').emit('DirectSyncPost', {
      root = self.root,
      actions = actions,
      applied = applied_actions,
      failed = failed,
      yanks = yanks,
      success = #failed == 0,
      error = failure_reason,
      bufnr = bufnr,
    })
  end
  local function finalize_sync()
    log_applied(actions, applied, already_logged)
    file_operations.emit_actions(actions, applied, options.suppress_operations)

    if not vim.api.nvim_buf_is_valid(bufnr) then
      emit_sync_post()
      return #failed == 0, failure_reason
    end
    -- Re-list so the buffer reflects the filesystem, restore the cursor, and
    -- mark it unmodified only after the refresh succeeds.
    local reopen = {}
    local state_before_list = states[bufnr]
    if state_before_list then
      local row_ids = row_ids_by_row(bufnr)
      for row, line in ipairs(visible) do
        local id = row_ids[row - 1]
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
        if rec then remove_expanded_subtree(bufnr, state, id) end
      end
      if #reopen == 0 then
        for id in pairs(subtree_edit.changed_parents) do
          local rec = state and state.rows[id]
          if rec then reopen[#reopen + 1] = { path = rec.path, depth = rec.depth or 0 } end
        end
        table.sort(reopen, function(a, b) return a.depth < b.depth end)
      end
    end
    self:list({ allow_modified = true, reset_undo = true })
    for _, target in ipairs(reopen) do
      for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
        local rec = current_row_record(bufnr, row)
        if rec and ((rec.kind == 'child' and is_dir_line(rec.name))
            or (rec.kind == 'root' and is_dir_line(rec.name)))
          and fs.same_path(rec.path, target.path) then
          self:expand(row + 1)
          break
        end
      end
    end
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
          pcall(vim.api.nvim_win_set_cursor, 0,
            { row + 1, (rec.depth or 0) * indent_size() })
          break
        end
      end
    end
    if #actions > 0 then
      ui.notify(action_mod.summarize(actions), vim.log.levels.INFO)
    end
    if #failed > 0 then
      local names = {}
      for _, act in ipairs(failed) do names[#names + 1] = action_mod.describe_action(act) end
      ui.notify(string.format('%d action(s) failed: %s', #failed,
        table.concat(names, ', ')), vim.log.levels.ERROR)
      vim.bo[bufnr].modified = true
      emit_sync_post()
      return nil, failure_reason
    end
    emit_sync_post()
    return true
  end

  local function record_action_result(index, info, act, result, action_err)
    if result ~= nil then
      if info then
        for _, member_index in ipairs(info.indices) do
          processed[member_index], applied[member_index], already_logged[member_index] = true, true, true
          self.current_entry = result_entry(actions[member_index])
        end
      else
        processed[index], applied[index], already_logged[index] = true, true, true
        self.current_entry = result_entry(actions[index])
      end
    else
      local message = 'Action failed - ' .. action_mod.describe_action(act)
        .. (action_err and (': ' .. tostring(action_err)) or '')
      ui.notify(message, vim.log.levels.ERROR)
      if info then
        for _, member_index in ipairs(info.indices) do
          processed[member_index] = true
          failed[#failed + 1] = actions[member_index]
        end
      else
        processed[index] = true
        failed[#failed + 1] = actions[index]
      end
      if failure_reason == nil then failure_reason = action_err or message end
    end
  end

  if options.async_actions then
    options.async_started = true
    local index = 1
    local function next_action()
      while index <= #actions and processed[index] do index = index + 1 end
      if index > #actions then
        local complete = function()
          local ok, err = finalize_sync()
          options.async_complete(ok, err)
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_call(bufnr, complete)
        else
          complete()
        end
        return
      end
      local current = index
      local info = group_at[current]
      if info and info.first ~= current then
        processed[current] = true
        index = index + 1
        return vim.schedule(next_action)
      end
      local act = info and info.action or actions[current]
      local started, start_err = history.apply_async(act, function(done)
        action_mod.execute_async(act, done)
      end, function(result, action_err)
        record_action_result(current, info, act, result, action_err)
        index = current + 1
        vim.schedule(next_action)
      end)
      if not started then
        record_action_result(current, info, act, nil, start_err)
        index = current + 1
        vim.schedule(next_action)
      end
    end
    vim.schedule(next_action)
    return true
  end

  local i = 1
  while i <= #actions do
    if processed[i] then
      i = i + 1
    else
      local info = group_at[i]
      if info and info.first ~= i then
        i = i + 1
      else
        local act = info and info.action or actions[i]
        local result, action_err = history.apply(act, function()
          return action_mod.execute(act)
        end)
        record_action_result(i, info, act, result, action_err)
        i = i + 1
      end
    end
  end
  return finalize_sync()
end

function Buffer:sync(options)
  local synced, sync_err = history.with_lock(function()
    return sync_locked(self, options)
  end)
  if synced then
    local retained, retention_err = require('direct.trash').apply_retention()
    if not retained and retention_err then
      ui.notify('direct: trash retention was skipped: ' .. tostring(retention_err),
        vim.log.levels.WARN)
    end
  end
  return synced, sync_err
end

function Buffer:sync_async(callback)
  callback = callback or function() end
  local bufnr = vim.api.nvim_get_current_buf()
  if pending.refuse('sync') then return nil, 'another direct operation is pending' end
  local began, token = pending.begin('sync')
  if not began then
    ui.notify('direct: cannot sync while another operation is pending', vim.log.levels.WARN)
    return nil, token
  end
  local acquired, acquire_err = history.lock.acquire()
  if not acquired then
    pending.finish(token)
    ui.notify('direct: history unavailable: ' .. tostring(acquire_err), vim.log.levels.ERROR)
    return nil, acquire_err
  end

  local operation = { finished = false }
  local function complete(result, err)
    if operation.finished then return end
    operation.finished = true
    local released, release_err = history.lock.release()
    if not released and result ~= nil then
      result = nil
      err = 'could not release history lock: ' .. tostring(release_err)
      ui.notify('direct: history unavailable: ' .. err, vim.log.levels.ERROR)
    end
    if result then
      local retained, retention_err = require('direct.trash').apply_retention()
      if not retained and retention_err then
        ui.notify('direct: trash retention was skipped: ' .. tostring(retention_err),
          vim.log.levels.WARN)
      end
    end
    pending.finish(token)
    local called, callback_err = pcall(callback, result, err)
    if not called then ui.report_error('complete sync', callback_err) end
  end

  local options = {
    async_actions = true,
    bypass_pending = true,
    pending_token = token,
    async_complete = complete,
  }
  local called, result, sync_err = xpcall(function()
    return sync_locked(self, options)
  end, debug.traceback)
  if not called then
    complete(nil, result)
    ui.report_error('plan sync', result)
    return nil, result
  end
  if not options.async_started then
    complete(result, sync_err)
    return result, sync_err
  end
  return true
end

end
