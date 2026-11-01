-- Parse materialized tree edits and produce validated filesystem action plans.
-- Dependencies are injected by buffer.lua to keep the stateful editor adapter out
-- of the tree planner.
return function(deps)
  local fs = deps.fs
  local states = deps.states
  local namespace = deps.namespace
  local is_dir_line = deps.is_dir_line
  local component_reason = deps.component_reason
  local same_lines = deps.same_lines
  local entry_path = deps.entry_path
  local ignore_set = deps.ignore_set
  local action_mod = deps.action_mod

  -- edited_subtrees(bufnr, lines) -> a per-expanded-directory action plan, or
  -- nil, reason. The ordinary children_integrity path remains the fast path for
  -- an unchanged materialization. For edits, extmarks provide identity and the
  -- parsed indentation provides each row's desired parent and filesystem path.
  local function edited_subtrees(bufnr, lines)
    local state = states[bufnr]
    if not state then return nil, 'child identity state is unavailable' end
    local undo_tree = vim.fn.undotree(bufnr)
    local seq_cur = undo_tree.seq_cur
    if #(state.materialization_recoveries or {}) > 0 then
      return nil, 'redone child materialization could not be uniquely restored'
    end
    local active, undone_ids, current_path = {}, {}, false
    for _, entry in ipairs(undo_tree.entries or {}) do
      if not current_path then
        active[entry.seq] = true
        if entry.seq == seq_cur then current_path = true end
      end
    end
    for _, materialization in ipairs(state.materialization_undos or {}) do
      if not active[materialization.seq]
        and (materialization.base_seq == 0 or active[materialization.base_seq]) then
        for _, id in ipairs(materialization.child_ids or {}) do undone_ids[id] = true end
      end
    end
    local function expansion_is_live(parent_id)
      local expansion = state.expanded[parent_id]
      if not expansion then return false end
      if #(expansion.children or {}) == 0 then return true end
      for _, child in ipairs(expansion.children) do
        if not undone_ids[child.id] then return true end
      end
      return false
    end

    local marks_by_row, valid_ids, invalid_ids, invalid_rows = {}, {}, {}, {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
        { details = true })) do
      local id, row, details = mark[1], mark[2], mark[4] or {}
      if not state.rows[id] or valid_ids[id] or invalid_ids[id] then
        return nil, 'child identity marks are invalid or duplicated'
      end
      if details.invalid then
        invalid_ids[id], invalid_rows[id] = true, row
      else
        if marks_by_row[row] then
          return nil, 'child identity marks are invalid or duplicated'
        end
        marks_by_row[row], valid_ids[id] = id, true
      end
    end
    for _, id in ipairs(state.display_ids or {}) do
      if not undone_ids[id] and not valid_ids[id] and not invalid_ids[id] then
        return nil, 'child identity mark was lost'
      end
    end

    -- A modified listing may use Neovim's one-empty-line representation for an
    -- intentionally emptied tree. A clean empty listing is handled by sync's
    -- existing root-listing special case.
    if #lines == 1 and lines[1] == '' and vim.bo[bufnr].modified then
      lines = {}
    end

    local roots, nodes, nodes_by_id, nodes_by_key, children_by_parent = {}, {}, {}, {}, {}
    local stack, previous_depth = {}, 0
    for row, line in ipairs(lines) do
      local prefix = line:match('^( *)') or ''
      if #prefix % 2 ~= 0 then
        if not stack[1] or not is_dir_line(stack[1].name) then
          return nil, 'root names may not begin with whitespace'
        end
        return nil, 'child row indentation must use pairs of spaces'
      end
      local depth = #prefix / 2
      if depth > previous_depth + 1 then
        return nil, 'a child row skips a directory level'
      end
      local name = line:sub(#prefix + 1)
      if name == '' then return nil, 'empty child row' end

      local parent = depth > 0 and stack[depth] or nil
      if depth > 0 and not parent then
        return nil, 'child row has no parent directory'
      end
      if parent and not is_dir_line(parent.name) then
        return nil, 'child row parent is not a directory'
      end
      if parent and parent.id and not expansion_is_live(parent.id) then
        return nil, 'cannot edit child rows under a collapsed directory'
      end

      local id = marks_by_row[row - 1]
      local rec = id and state.rows[id] or nil

      local reason = component_reason(name)
      if reason then return nil, reason end
      local parent_key = parent and parent.key or nil
      local node = {
        id = id,
        rec = rec,
        name = name,
        depth = depth,
        parent_id = parent_key,
        parent_key = parent_key,
        key = id or ('new:' .. row),
        row = row - 1,
      }
      nodes[#nodes + 1] = node
      if id then nodes_by_id[id] = node end
      nodes_by_key[node.key] = node
      if depth == 0 then
        roots[#roots + 1] = name
      else
        children_by_parent[parent_key] = children_by_parent[parent_key] or {}
        children_by_parent[parent_key][#children_by_parent[parent_key] + 1] = node
      end
      stack[depth + 1] = node
      for level = depth + 2, #stack do stack[level] = nil end
      previous_depth = depth
    end

    -- Root classifier input excludes identity-preserving moves across the root
    -- boundary. A root moved into a child remains in its original virtual slot;
    -- a child moved to the root is handled by the tree Move action, not ADD.
    roots = {}
    local root_ids = {}
    for _, id in ipairs(state.root_ids or {}) do
      root_ids[id] = true
      local rec, now = state.rows[id], nodes_by_id[id]
      if now then roots[#roots + 1] = now.depth == 0 and now.name or rec.name end
    end
    for _, node in ipairs(nodes) do
      if node.depth == 0 and not node.id then roots[#roots + 1] = node.name end
    end
    for _, siblings in pairs(children_by_parent) do
      local seen_names = {}
      for _, node in ipairs(siblings) do
        local basename = node.name:gsub('/+$', '')
        if seen_names[basename] then
          return nil, 'duplicate child entry: ' .. basename
        end
        seen_names[basename] = true
      end
    end

    local nodes_by_row = {}
    for _, node in ipairs(nodes) do nodes_by_row[node.row] = node end
    for id in pairs(invalid_ids) do
      local rec = state.rows[id]
      local replacement = rec and rec.kind == 'child'
        and nodes_by_row[invalid_rows[id]] or nil
      if replacement and not replacement.id then
        if replacement.depth ~= rec.depth or replacement.parent_id ~= rec.parent then
          return nil, 'child identity was replaced outside its original directory row'
        end
        -- `cc`/line replacement invalidates extmarks in Neovim. Recover identity
        -- only at the exact original row, parent, and depth; never adopt by name.
        replacement.id, replacement.rec = id, rec
        nodes_by_id[id] = replacement
      elseif rec and rec.kind == 'child' then
        local preceding = nodes_by_row[invalid_rows[id] - 1]
        if preceding and not preceding.id and preceding.depth ~= rec.depth then
          return nil, 'child identity was replaced at a different tree depth'
        end
      end
    end

    -- `cc` and whole-line replacements can invalidate an extmark even though
    -- the edit is a rename. Reattach an invalid identity only inside an unbroken
    -- sibling interval where removed and new rows pair one-for-one, bounded by
    -- surviving identities. If counts differ, that interval mixes uncertain
    -- renames with creates/deletes and is refused rather than guessed.
    for parent_id, expansion in pairs(state.expanded or {}) do
      if expansion_is_live(parent_id) then
        local old_children, current = {}, children_by_parent[parent_id] or {}
        for _, child in ipairs(expansion.children or {}) do
          if not undone_ids[child.id] then old_children[#old_children + 1] = child end
        end
        local current_index, old_index = {}, {}
        for index, node in ipairs(current) do
          if node.id then current_index[node.id] = index end
        end
        for index, child in ipairs(old_children) do old_index[child.id] = index end
        local anchors = {}
        for id, oi in pairs(old_index) do
          local ni = current_index[id]
          if ni then anchors[#anchors + 1] = { old = oi, new = ni } end
        end
        table.sort(anchors, function(a, b) return a.old < b.old end)
        local anchors_reordered = false
        for index = 2, #anchors do
          if anchors[index].new <= anchors[index - 1].new then
            anchors_reordered = true
            break
          end
        end
        if anchors_reordered then
          local has_unidentified_change = false
          for _, child in ipairs(old_children) do
            if invalid_ids[child.id] and not nodes_by_id[child.id] then
              has_unidentified_change = true
              break
            end
          end
          if not has_unidentified_change then
            for _, node in ipairs(current) do
              if not node.id then has_unidentified_change = true; break end
            end
          end
          if has_unidentified_change then
            return nil, 'reordered child identities cannot be safely paired with line replacements'
          end
        end
        local old_after, new_after = 0, 0
        local function pair_interval(old_before, new_before)
          local removed, inserted = {}, {}
          for oi = old_after + 1, old_before - 1 do
            local child = old_children[oi]
            if invalid_ids[child.id] and not nodes_by_id[child.id] then
              removed[#removed + 1] = child
            end
          end
          for ni = new_after + 1, new_before - 1 do
            local node = current[ni]
            if not node.id then inserted[#inserted + 1] = node end
          end
          if #removed > 0 and #inserted > 0 then
            if #removed ~= #inserted then
              return nil, 'child row identities are ambiguous between rename and create/delete'
            end
            for pair = 1, #removed do
              local child, node = removed[pair], inserted[pair]
              node.id, node.rec = child.id, child
              nodes_by_id[child.id] = node
              invalid_ids[child.id] = nil
            end
          end
          return true
        end
        if not anchors_reordered then
          for _, anchor in ipairs(anchors) do
            local ok, pair_err = pair_interval(anchor.old, anchor.new)
            if not ok then return nil, pair_err end
            old_after, new_after = anchor.old, anchor.new
          end
          local ok, pair_err = pair_interval(#old_children + 1, #current + 1)
          if not ok then return nil, pair_err end
        end
      end
    end

    local lost_child_identity = false
    for id in pairs(invalid_ids) do
      local rec = state.rows[id]
      if rec and rec.kind == 'child' and not nodes_by_id[id] and not undone_ids[id] then
        lost_child_identity = true
        break
      end
    end
    if lost_child_identity then
      for id in pairs(invalid_ids) do
        local rec = state.rows[id]
        if rec and rec.kind == 'child' and not nodes_by_id[id] and not undone_ids[id] then
          for _, node in ipairs(nodes) do
            if node.depth == 0 and not node.id and node.row == invalid_rows[id] then
              return nil, 'child identity was lost while a root row was added'
            end
          end
        end
      end
    end

    local changed_parents = {}
    for parent_id, expansion in pairs(state.expanded or {}) do
      local parent = state.rows[parent_id]
      if parent and nodes_by_id[parent_id] and expansion_is_live(parent_id) then
        local current = children_by_parent[parent_id] or {}
        local current_by_id = {}
        local old_children = {}
        for _, child in ipairs(expansion.children or {}) do
          if not undone_ids[child.id] then
            old_children[#old_children + 1] = child
          end
        end
        for _, child in ipairs(current) do
          if child.id then current_by_id[child.id] = child end
        end

        local changed = #current ~= #old_children
        if not changed then
          for index, child in ipairs(old_children) do
            local now = current_by_id[child.id]
            if not now or now.name ~= child.name or current[index] ~= now then
              changed = true
              break
            end
          end
        end
        if changed then
          local ignored = ignore_set(parent.path, expansion.wildignore or '')
          local disk, read_err = fs.read_dir_lines(parent.path, ignored)
          if not disk or not same_lines(disk, expansion.listing_lines or {}) then
            return nil, 'expanded directory changed on disk since it was read'
              .. (read_err and (': ' .. tostring(read_err)) or '')
          end
          changed_parents[parent_id] = true

        end
      end
    end

    local function target_path(node)
      if node.depth == 0 then
        node.path = entry_path(state.root, node.name)
      else
        local parent = nodes_by_key[node.parent_key]
        if not parent or not is_dir_line(parent.name) then return nil end
        local parent_path = target_path(parent)
        if not parent_path then return nil end
        node.path = entry_path(parent_path, node.name)
      end
      return node.path
    end
    for _, node in ipairs(nodes) do
      if not target_path(node) then return nil, 'child row has no destination directory' end
    end

    local creates, moves, removals, yanks = {}, {}, {}, {}
    local deleted_ids, moving_ids = {}, {}
    for id in pairs(root_ids) do
      local rec, node = state.rows[id], nodes_by_id[id]
      if rec and node and is_dir_line(rec.name) and node.depth == 0
        and rec.name ~= node.name then
        -- Root-directory moves are emitted by the root classifier. Mark them
        -- here so separate descendant edits cannot be staged against stale paths.
        moving_ids[id] = true
      end
    end
    for _, id in ipairs(state.display_ids or {}) do
      local rec = state.rows[id]
      if rec and rec.kind == 'child' and not undone_ids[id] and not nodes_by_id[id] then
        deleted_ids[id] = true
      end
    end
    for id in pairs(deleted_ids) do
      local rec = state.rows[id]
      local ancestor = rec.parent
      local covered = false
      while ancestor do
        if deleted_ids[ancestor] then covered = true; break end
        local parent_rec = state.rows[ancestor]
        ancestor = parent_rec and parent_rec.parent or nil
      end
      if not covered then
        yanks[#yanks + 1] = rec.path
        if is_dir_line(rec.name) then
          removals[#removals + 1] = action_mod.RemoveDirectory(rec.path)
        else
          removals[#removals + 1] = action_mod.Remove(rec.path)
        end
      end
    end

    for _, node in ipairs(nodes) do
      if not node.id then
        if node.depth > 0 then
          local destination = node.path
          if is_dir_line(node.name) then
            creates[#creates + 1] = { depth = node.depth, action = action_mod.MakeDirectory(destination) }
          else
            creates[#creates + 1] = { depth = node.depth, action = action_mod.Touch(destination) }
          end
        end
      else
        local rec = node.rec
        local moved_from_root = rec.kind == 'root' and node.depth > 0
        local child_changed = rec.kind == 'child'
          and (rec.parent ~= node.parent_key or rec.name ~= node.name or rec.depth ~= node.depth)
        if moved_from_root or child_changed then
          if is_dir_line(rec.name) ~= is_dir_line(node.name)
            and state.expanded[node.id] then
            return nil, 'cannot change the type of an expanded directory'
          end
          moving_ids[node.id] = true
          moves[#moves + 1] = { depth = node.depth, action = action_mod.Move(rec.path, node.path) }
        end
      end
    end

    -- A descendant whose own name/parent changes while an ancestor also moves
    -- needs ordered, path-dependent staging. Refuse that combination until the
    -- transaction scheduler can express its dependency explicitly.
    for _, node in ipairs(nodes) do
      if node.id and moving_ids[node.id] then
        local ancestor = node.parent_key
        while ancestor do
          if moving_ids[ancestor] then
            return nil, 'edit moved directories and their descendants in separate syncs'
          end
          local parent = nodes_by_key[ancestor]
          ancestor = parent and parent.parent_key or nil
        end
      end
    end
    local function moved_ancestor(parent_key)
      local ancestor = parent_key
      while ancestor do
        if moving_ids[ancestor] then return ancestor end
        local parent = nodes_by_key[ancestor]
        ancestor = parent and parent.parent_key or nil
      end
      return nil
    end
    for _, node in ipairs(nodes) do
      if not node.id and moved_ancestor(node.parent_key) then
        return nil, 'edit a moved directory and its new children in separate syncs'
      end
    end
    for id in pairs(deleted_ids) do
      local rec = state.rows[id]
      local ancestor = rec.parent
      while ancestor do
        if moving_ids[ancestor] then
          return nil, 'edit a moved directory and its removed children in separate syncs'
        end
        local parent_rec = state.rows[ancestor]
        ancestor = parent_rec and parent_rec.parent or nil
      end
    end

    local source_paths = {}
    for _, item in ipairs(moves) do source_paths[item.action.src] = true end
    for _, item in ipairs(creates) do
      if fs.taken(item.action.dst) then
        return nil, 'destination already exists: ' .. item.action.dst
      end
    end
    for _, item in ipairs(moves) do
      local source_target = false
      for source in pairs(source_paths) do
        if fs.same_path(source, item.action.dst) then source_target = true; break end
      end
      if fs.taken(item.action.dst) and not source_target then
        return nil, 'move destination already exists: ' .. item.action.dst
      end
    end

    table.sort(creates, function(a, b) return a.depth < b.depth end)
    local actions = {}
    for _, item in ipairs(creates) do actions[#actions + 1] = item.action end
    for _, item in ipairs(moves) do actions[#actions + 1] = item.action end
    for _, action in ipairs(removals) do actions[#actions + 1] = action end
    local expanded_targets = {}
    for parent_id in pairs(state.expanded or {}) do
      local node = nodes_by_id[parent_id]
      if node and is_dir_line(node.name) then
        expanded_targets[#expanded_targets + 1] = {
          id = parent_id, path = target_path(node), depth = node.depth or 0,
        }
      end
    end
    table.sort(expanded_targets, function(a, b) return a.depth < b.depth end)
    return {
      root_lines = roots,
      actions = actions,
      yanks = yanks,
      changed_parents = changed_parents,
      nodes_by_id = nodes_by_id,
      expanded_targets = expanded_targets,
    }
  end
  return edited_subtrees
end
