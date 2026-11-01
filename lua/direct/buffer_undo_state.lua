-- Reconcile extmark-backed expanded rows across Neovim undo/redo transitions.
-- The buffer adapter supplies the state store and row/listing operations.
return function(deps)
  local states = deps.states
  local namespace = deps.namespace
  local fs = deps.fs
  local path_identity = deps.path_identity
  local same_lines = deps.same_lines
  local row_id_at = deps.row_id_at
  local set_row_mark = deps.set_row_mark
  local refresh_display_ids = deps.refresh_display_ids
  local is_dir_line = deps.is_dir_line
  local recorded_row_text = deps.recorded_row_text
  local ignore_set = deps.ignore_set
  local read = deps.read
  local entry_path = deps.entry_path
  local highlight = deps.highlight
  local refresh_icons = deps.refresh_icons
  local remove_expanded_subtree = deps.remove_expanded_subtree

  local function restore_redone_materialization(bufnr, state, materialization, lines)
    local parent = state.rows[materialization.parent_id]
    if not parent or state.expanded[parent.id] then return false end
    local parent_row
    for row = 0, #lines - 1 do
      if row_id_at(bufnr, row) == parent.id then
        parent_row = row
        break
      end
    end
    if parent_row == nil or lines[parent_row + 1] ~= parent.text then return false end
    if type(parent.path) ~= 'string'
      or vim.fs.normalize(parent.path) ~= vim.fs.normalize(materialization.parent_path)
      or not fs.path_identities_match(path_identity(parent.path), materialization.parent_identity) then
      return false
    end

    -- An empty ignore set is a valid captured filter. Require the saved filter
    -- snapshot, and pass its match-set explicitly so nil means unfiltered rather
    -- than falling back to the current option.
    if type(materialization.wildignore) ~= 'string' then return false end
    local ignored = ignore_set(parent.path, materialization.wildignore)
    local listed = read(parent.path, ignored)
    if not listed or not same_lines(listed, materialization.listing_lines or {}) then
      return false
    end

    local children = vim.deepcopy(materialization.children_snapshot or {})
    local child_ids, expected_rows = {}, {}
    local previous_order = 0
    for offset, child in ipairs(children) do
      local expected_path = entry_path(parent.path, child.name)
      local expected_row = parent_row + offset
      if child.kind ~= 'child' or child.parent ~= parent.id
        or type(child.order) ~= 'number' or child.order <= previous_order
        or child.depth ~= (parent.depth or 0) + 1
        or child.path ~= expected_path
        or child.text ~= string.rep('  ', child.depth) .. child.name
        or lines[expected_row + 1] ~= child.text
        or not child.identity
        or not fs.path_identities_match(path_identity(child.path), child.identity)
        or child_ids[child.id] then
        return false
      end
      previous_order = child.order
      child_ids[child.id] = true
      expected_rows[child.id] = expected_row
    end

    -- The original IDs may have been removed from the namespace during undo
    -- reconciliation. Any surviving marks must still be unique and in the exact
    -- rows implied by this materialization; no row is adopted by spelling alone.
    local seen_ids, seen_rows = {}, {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
        { details = true })) do
      local id, row, details = mark[1], mark[2], mark[4] or {}
      if seen_ids[id] then return false end
      seen_ids[id] = true
      if not details.invalid then
        if seen_rows[row] then return false end
        seen_rows[row] = id
        if child_ids[id] and row ~= expected_rows[id] then return false end
        if row >= parent_row + 1 and row <= parent_row + #children
          and not child_ids[id] then return false end
      end
    end

    for _, child in ipairs(children) do
      child.kind, child.parent = 'child', parent.id
      state.rows[child.id] = child
    end
    state.expanded[parent.id] = {
      children = children,
      listing_lines = vim.deepcopy(materialization.listing_lines or {}),
      wildignore = materialization.wildignore or '',
    }
    for _, child in ipairs(children) do
      local ok = pcall(set_row_mark, bufnr, expected_rows[child.id], child.id)
      if not ok then
        state.expanded[parent.id] = nil
        for _, restored in ipairs(children) do state.rows[restored.id] = nil end
        return false
      end
    end
    refresh_display_ids(bufnr, state)
    return true
  end

  -- Undoing a collapse restores rows through Neovim's undo tree. Reattach their
  -- saved identities and expansion records only if both the materialized text
  -- and every previously-expanded directory snapshot still match the filesystem.
  local function restore_undone_collapse(bufnr, state, snapshot)
    local parent = state.rows[snapshot.parent_id]
    local display = snapshot.display_snapshot
    if not parent or state.expanded[parent.id] or not display then return false end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if not same_lines(lines, display.lines or {}) then return false end

    -- Validate a complete saved rendering before assigning any marks. A collapse
    -- can coexist with other expanded siblings; their rows are outside the
    -- collapsed subtree but still have to be restored after undo invalidates the
    -- re-listed extmarks.
    local records, expected_rows, expected_order = {}, {}, {}
    for index, item in ipairs(display.rows or {}) do
      local row = index - 1
      local rec = item.record
      if item.row ~= row or item.id == nil or records[item.id]
        or item.text ~= lines[index]
        or not rec or rec.id ~= item.id or type(rec.path) ~= 'string'
        or not item.identity
        or not fs.path_identities_match(path_identity(rec.path), item.identity) then
        return false
      end
      if rec.kind == 'child' then
        if not rec.identity
          or not fs.path_identities_match(path_identity(rec.path), rec.identity) then
          return false
        end
      elseif rec.kind ~= 'root' then
        return false
      end
      records[item.id] = vim.deepcopy(rec)
      expected_rows[item.id] = row
      expected_order[#expected_order + 1] = item.id
    end
    if #expected_order ~= #lines then return false end

    local parent_row = expected_rows[parent.id]
    if parent_row == nil or lines[parent_row + 1] ~= snapshot.parent_text
      or vim.fs.normalize(parent.path) ~= vim.fs.normalize(snapshot.parent_path)
      or not fs.path_identities_match(path_identity(parent.path), snapshot.parent_identity) then
      return false
    end

    -- Verify the saved root order and every expansion edge, so duplicate or
    -- orphaned child records cannot be adopted by their spelling alone.
    local expansion_map = display.expansions or {}
    local ordered, visited = {}, {}
    local function append_children(parent_id)
      local expansion = expansion_map[parent_id]
      if not expansion then return true end
      local parent_record = records[parent_id]
      if not parent_record or not is_dir_line(parent_record.name) then return false end
      local previous_order = 0
      for _, child in ipairs(expansion.children or {}) do
        local rec = records[child.id]
        if not rec or rec.kind ~= 'child' or rec.parent ~= parent_id
          or type(rec.order) ~= 'number' or rec.order <= previous_order
          or rec.depth ~= (parent_record.depth or 0) + 1
          or rec.path ~= entry_path(parent_record.path, rec.name)
          or rec.text ~= recorded_row_text(rec) or child.id == parent_id
          or visited[child.id] then
          return false
        end
        previous_order = rec.order
        visited[child.id] = true
        ordered[#ordered + 1] = child.id
        if not append_children(child.id) then return false end
      end
      return true
    end
    local seen_roots = {}
    for _, root_id in ipairs(display.root_ids or {}) do
      local rec = records[root_id]
      if not rec or rec.kind ~= 'root' or seen_roots[root_id] then return false end
      seen_roots[root_id] = true
      ordered[#ordered + 1] = root_id
      if not append_children(root_id) then return false end
    end
    if #ordered ~= #expected_order then return false end
    for index, id in ipairs(ordered) do
      if expected_order[index] ~= id then return false end
    end
    for id, expansion in pairs(expansion_map) do
      local rec = records[id]
      if not rec or not is_dir_line(rec.name) or not expansion then return false end
    end

    for id, expected in pairs(display.directory_snapshots or {}) do
      local rec = records[id]
      if not rec then return false end
      local current = fs.read_dir_lines(rec.path,
        ignore_set(rec.path, expected.wildignore or ''))
      if not current or not same_lines(current, expected.listing_lines or {}) then return false end
    end

    -- The collapsed subtree snapshot must agree with the full display snapshot.
    for offset, item in ipairs(snapshot.rows or {}) do
      local row = parent_row + offset
      if item.row ~= row or expected_rows[item.id] ~= row
        or item.text ~= lines[row + 1] then
        return false
      end
    end
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
        { details = true })) do
      local id, row, details = mark[1], mark[2], mark[4] or {}
      if not details.invalid then
        if expected_rows[id] ~= row then return false end
      end
    end

    local restored_expanded = {}
    for id, expansion in pairs(expansion_map) do
      local restored = {
        children = {},
        listing_lines = vim.deepcopy(expansion.listing_lines or {}),
        wildignore = expansion.wildignore or '',
      }
      for _, child in ipairs(expansion.children or {}) do
        local rec = records[child.id]
        if not rec then return false end
        restored.children[#restored.children + 1] = rec
      end
      restored_expanded[id] = restored
    end
    -- Matching is complete before the first identity is changed. If Neovim
    -- rejects any mark recreation, clear the namespace rather than leave a
    -- partially attributed display that could be mistaken for safe to sync.
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    for _, item in ipairs(display.rows) do
      local ok = pcall(set_row_mark, bufnr, item.row, item.id)
      if not ok then
        vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
        state.display_ids = {}
        return false
      end
    end
    state.rows = records
    state.root_ids = vim.deepcopy(display.root_ids or {})
    state.expanded = restored_expanded
    state.display_ids = vim.deepcopy(expected_order)
    state.materialization_seq = vim.fn.undotree(bufnr).seq_cur
    highlight.render(bufnr)
    refresh_icons(bufnr, state)
    return true
  end

  local function forget_collapsed_state(bufnr, state, snapshot)
    remove_expanded_subtree(bufnr, state, snapshot.parent_id)
    refresh_display_ids(bufnr, state)
    state.materialization_seq = vim.fn.undotree(bufnr).seq_cur
  end

  -- If undo returns exactly to the sequence that preceded a view materialization,
  -- Neovim has removed that insertion block. Reconcile only when each surviving
  -- child still has its original identity and text. Root rows may have changed;
  -- children_integrity() continues to protect any surviving materialized subtree.
  local function reconcile_undone_materialization(bufnr)
    local state = states[bufnr]
    if not state then return false end
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

    -- Collapse snapshots include full child records. Keep them only while both
    -- the collapse node and its base remain reachable for undo/redo; discarded
    -- Neovim branches can no longer replay the corresponding view transition.
    local function undo_node_reachable(seq)
      return seq == 0 or active[seq] or alternate[seq]
    end
    local retained_collapses = {}
    for _, collapse in ipairs(state.collapse_undos or {}) do
      if collapse.seq and undo_node_reachable(collapse.seq)
        and undo_node_reachable(collapse.base_seq) then
        retained_collapses[#retained_collapses + 1] = collapse
      end
    end
    state.collapse_undos = retained_collapses

    -- Collapsing is an ordinary Neovim text change, but its row records are
    -- intentionally removed while collapsed. Rebuild those records when undo
    -- restores the exact expanded rows, and discard them again on redo.
    for index = #(state.collapse_undos or {}), 1, -1 do
      local collapse = state.collapse_undos[index]
      if collapse.status == 'collapsed' and collapse.base_seq == seq_cur then
        if restore_undone_collapse(bufnr, state, collapse) then
          collapse.status = 'expanded'
          return true
        end
      elseif collapse.status == 'expanded' and collapse.seq == seq_cur then
        forget_collapsed_state(bufnr, state, collapse)
        collapse.status = 'collapsed'
        return true
      end
    end

    -- A redo returns to the materialization's original undo node. Its child
    -- records were intentionally removed while the insertion was undone, so
    -- restore them from the retained snapshot only at that exact sequence.
    local recovery, recovery_index, recovery_count
    recovery_count = 0
    for index, materialization in ipairs(state.materialization_recoveries or {}) do
      if materialization.seq == seq_cur and active[materialization.seq] then
        recovery, recovery_index = materialization, index
        recovery_count = recovery_count + 1
      end
    end
    if recovery_count > 0 then
      if recovery_count ~= 1 then return false end
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if not restore_redone_materialization(bufnr, state, recovery, lines) then
        return false
      end
      table.remove(state.materialization_recoveries, recovery_index)
      state.materialization_undos[#state.materialization_undos + 1] = recovery
      state.materialization_seq = seq_cur
      return true
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
      local materialization = undos[index]
      forget_subtree(undos[index].parent_id)
      state.materialization_recoveries = state.materialization_recoveries or {}
      state.materialization_recoveries[#state.materialization_recoveries + 1] =
        vim.deepcopy(materialization)
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

  -- ambiguous_message(plan, actual, expected) names the reason and both sides of
  -- the comparison so the user can see what desynced.
  return reconcile_undone_materialization
end
