-- Pure classification and validation for converting edited listing rows to actions.
return function(deps)
  local paths = require('direct.paths')
  local platform = require('direct.platform')
  local action_mod = deps.action_mod
  local entry_path = deps.entry_path
  local is_dir_line = deps.is_dir_line
  local directory_separator = deps.directory_separator
  local dirs_then_name = deps.dirs_then_name
  local lstat = deps.lstat
  local path_without_marker = deps.path_without_marker
  local fs = deps.fs

  local function classify(actual, expected)
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

  -- Use extmark identities, not row position or set cardinality, to classify a
  -- root-level edit. `original_rows` are the rows captured at listing time;
  -- `current_rows` contains their surviving marks plus unmarked creates.
  local function classify_identity(root, original_rows, current_rows, expected,
      text_undo_mode)
    local expected_by_path, original_by_path, original_by_id = {}, {}, {}
    local expected_by_basename = {}
    local original_by_basename = {}
    local function basename(path)
      return paths.basename(path)
    end
    local function same_listing_path(a, b)
      return paths.canonical(a) == paths.canonical(b) or fs.same_path(a, b) == true
    end
    for _, line in ipairs(expected or {}) do
      local path = entry_path(root, line)
      local key = paths.canonical(path)
      if expected_by_path[key] then
        return nil, 'directory changed on disk since it was listed'
      end
      local entry = {
        path = path,
        line = line,
        identity = fs.path_identity(path, fs.stat(path)),
      }
      expected_by_path[key] = entry
      local name = basename(path)
      expected_by_basename[name] = expected_by_basename[name] or {}
      expected_by_basename[name][#expected_by_basename[name] + 1] = entry
    end

    local function expected_at(path)
      local direct = expected_by_path[paths.canonical(path)]
      if direct then return direct end
      for _, entry in ipairs(expected_by_basename[basename(path)] or {}) do
        if same_listing_path(path, entry.path) then return entry end
      end
    end

    local function original_at(path)
      local direct = original_by_path[paths.canonical(path)]
      if direct then return direct end
      for _, row in ipairs(original_by_basename[basename(path)] or {}) do
        if same_listing_path(path, row.path) then return row end
      end
    end

    local function collapsed_component_moves(original, line)
      local original_components = original.collapsed_components
      if not original_components or #original_components < 2 then return nil end
      local directory = is_dir_line(line)
      local relative = paths.strip_directory_marker(line)
      if directory_separator() == '\\' then relative = relative:gsub('\\', '/') end
      local names = {}
      for part in (relative .. '/'):gmatch('(.-)/') do
        if part == '' then
          return nil, 'collapsed paths must keep the same path components'
        end
        names[#names + 1] = part
      end
      if #names ~= #original_components
        or directory ~= original_components[#original_components].directory then
        return nil, 'collapsed paths must keep the same path components and entry type'
      end
      local moves, parent = {}, root
      for index, component in ipairs(original_components) do
        local target_name = names[index]
        if target_name == '.' or target_name == '..' or target_name == '' then
          return nil, 'invalid path component'
        end
        local source = fs.join(parent, component.name)
        local destination = fs.join(parent, target_name)
        if component.directory then
          source = source .. platform.separator
          destination = destination .. platform.separator
        end
        if target_name ~= component.name then
          moves[#moves + 1] = { src_path = source, dst_path = destination }
        end
        parent = fs.join(parent, target_name)
      end
      return moves
    end

    local current_by_id = {}
    for _, row in ipairs(current_rows or {}) do
      if row.id ~= nil then current_by_id[row.id] = row end
    end

    for _, row in ipairs(original_rows or {}) do
      if not row.deleted_kind then
        if row.id == nil or original_by_id[row.id] then
          return nil, 'root row identities are invalid or duplicated'
        end
        local key = paths.canonical(row.path)
        if original_at(row.path) then
          return nil, 'root row paths are ambiguous'
        end
        original_by_id[row.id] = row
        original_by_path[key] = row
        local name = basename(row.path)
        original_by_basename[name] = original_by_basename[name] or {}
        original_by_basename[name][#original_by_basename[name] + 1] = row
      end
    end
    for _, original in ipairs(original_rows or {}) do
      if not original.deleted_kind then
        local current_row = current_by_id[original.id]
        local edited = not current_row or current_row.line ~= original.name
        if not current_row then
          for _, candidate in ipairs(current_rows or {}) do
            if candidate.id == nil and candidate.line == original.name then
              local on_disk = expected_at(original.path)
              if on_disk and on_disk.line == original.name and original.identity
                and on_disk.identity
                and fs.path_identities_match(original.identity, on_disk.identity) then
                edited = false
                break
              end
            end
          end
        end
        if edited then
          local on_disk = expected_at(original.path)
          if not on_disk or on_disk.line ~= original.name or not original.identity
            or not on_disk.identity
            or not fs.path_identities_match(original.identity, on_disk.identity) then
            return nil, 'directory changed on disk since it was listed: '
              .. tostring(original.path) .. '; restore the entry or re-list this directory'
          end
        end
      end
    end

    local moves, removed, added, seen_ids, seen_lines = {}, {}, {}, {}, {}
    for _, row in ipairs(current_rows or {}) do
      local line = row.line
      if type(line) ~= 'string' then return nil, 'root row identity is unavailable' end
      if seen_lines[line] then return { kind = 'AMBIGUOUS', reason = 'duplicate' } end
      seen_lines[line] = true
      if row.id ~= nil then
        local original = original_by_id[row.id]
        if not original then
          return nil, 'root row identity is unavailable; re-list this directory'
        end
        if seen_ids[row.id] then
          return nil, 'root row identities are invalid or duplicated'
        end
        seen_ids[row.id] = true
        if line ~= original.name then
          local component_moves, component_err = collapsed_component_moves(original, line)
          if component_err then return nil, component_err end
          if component_moves then
            for _, move in ipairs(component_moves) do moves[#moves + 1] = move end
          else
            moves[#moves + 1] = { src = original.name, dst = line }
          end
        end
      else
        local path = entry_path(root, line)
        local original, on_disk = original_at(path), expected_at(path)
        if original and on_disk and on_disk.line == line then
          if text_undo_mode then
            return nil, 'root row identity is unavailable after text undo or redo; re-list this directory'
          end
          -- A same-text replacement can invalidate a root extmark. When the
          -- exact original path is still present, this is a no-op, not a
          -- positional rename or a destructive delete/recreate of that file.
          seen_ids[original.id] = true
        else
          local alias
          for id, candidate in pairs(original_by_id) do
            if not seen_ids[id] and is_dir_line(candidate.name) == is_dir_line(line)
              and fs.same_entry(path, candidate.path) then
              if alias then return nil, 'root row identity is ambiguous' end
              alias = candidate
            end
          end
          if alias then
            seen_ids[alias.id] = true
            moves[#moves + 1] = { src = alias.name, dst = line }
          else
            added[#added + 1] = line
          end
        end
      end
    end
    if text_undo_mode and #added > 0 then
      for _, original in ipairs(original_rows or {}) do
        if not original.deleted_kind and not seen_ids[original.id] then
          return nil, 'root row identity is unavailable after text undo or redo; re-list this directory'
        end
      end
    end
    for _, row in ipairs(original_rows or {}) do
      if not row.deleted_kind and not seen_ids[row.id] then
        removed[#removed + 1] = row.name
      end
    end
    return {
      kind = 'IDENTITY',
      moves = moves,
      removed = dirs_then_name(removed),
      added = dirs_then_name(added),
    }
  end

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
    local selected_separator = (path_style == nil or path_style == platform.path_style)
      and component:find(directory_separator(), 1, true) ~= nil
    if component == '' or component == '.' or component == '..'
      or component:find('/', 1, true) or selected_separator then
      return 'invalid path component'
    end
    return platform.component_path_reason(component, path_style)
  end

  -- A nested entry is still one root-buffer row, but its separator-delimited
  -- components must each be safe filenames. The configured trailing separator
  -- is the directory marker; empty, absolute, and dot components are
  -- never accepted.
  local function nested_path_reason(line, path_style)
    if type(line) ~= 'string' then return 'invalid path component' end
    local control_reason = action_mod.path_reason(line)
    if control_reason then return control_reason end
    local path = paths.strip_directory_marker(line)
    if directory_separator() == '\\' then path = path:gsub('\\', '/') end
    if path == '' or path:sub(1, 1) == '/' then return 'invalid path component' end
    local start = 1
    while true do
      local slash = path:find('/', start, true)
      local part = slash and path:sub(start, slash - 1) or path:sub(start)
      if part == '' then return 'invalid path component' end
      local reason = component_reason(part, path_style)
      if reason then return reason end
      if not slash then break end
      start = slash + 1
    end
    return nil
  end

  -- Kept visible for platform-independent unit coverage of Win32 component rules.
  -- first_unsafe(root, lines) -> { path, reason } for the first line whose path
  -- is unrepresentable, else nil. Both the edited lines and the on-disk listing
  -- are checked: either side can be an OS-chosen name.
  local function first_unsafe(root, lines, nested_allowed)
    for _, line in ipairs(lines) do
      local component_error
      if nested_allowed and nested_allowed[line] then
        component_error = nested_path_reason(line)
      else
        component_error = component_reason(line)
      end
      if component_error then
        return { path = line, reason = component_error }
      end
      local path = entry_path(root, line)
      local reason = unsafe_path_reason(path)
      if reason ~= nil then
        return { path = path, reason = reason }
      end
    end
    return nil
  end
  local function ambiguous_message(plan, actual, expected)
    return string.format(
      'Ambiguous buffer content (%s). '
        .. 'You must only add, remove or rename in each edit.'
        .. '\nactual:   %s\nexpected: %s',
      plan.reason, table.concat(actual, ', '), table.concat(expected, ', '))
  end
  -- Return the destination left by a successful create/move, or nil for removals.
  -- Use the original action so a staging temp can never become current_entry.
  local function result_entry(act)
    if act.name == 'mv' or act.name == 'touch' or act.name == 'mkdir' then
      return act.dst
    end
    return nil
  end
  -- build_actions returns actions and yanks. ADD/DELETE follow dirs-then-name
  -- order; deleted directory paths retain their trailing native separator in the auto-yank.
  local function build_actions(root, plan)
    local actions, yanks = {}, {}
    if plan.kind == 'ADD' then
      local planned, create_dirs, touches = {}, {}, {}
      local function normalized(path)
        return paths.canonical(path)
      end
      local function components(line)
        local path = paths.strip_directory_marker(line)
        if directory_separator() == '\\' then path = path:gsub('\\', '/') end
        local out, start = {}, 1
        while true do
          local slash = path:find('/', start, true)
          out[#out + 1] = slash and path:sub(start, slash - 1) or path:sub(start)
          if not slash then break end
          start = slash + 1
        end
        return out
      end

      -- Detect target/type collisions across the batch before making any
      -- directories, e.g. adding both `a` and `a/child.txt`.
      for _, line in ipairs(plan.added) do
        local key = normalized(entry_path(root, line))
        local kind = is_dir_line(line) and 'directory' or 'file'
        if planned[key] ~= nil and planned[key] ~= kind then
          return nil, nil, 'conflicting entries target the same path: ' .. key
        end
        planned[key] = kind
      end

      for _, line in ipairs(plan.added) do
        local path = entry_path(root, line)
        local parts = components(line)
        local is_directory = is_dir_line(line)
        local parent_count = #parts - 1
        local parent = root
        for i = 1, parent_count do
          parent = fs.join(parent, parts[i])
          local key = normalized(parent)
          if planned[key] == 'file' then
            return nil, nil, 'path parent is not a directory: ' .. parent
          end
          if fs.taken(parent) then
            if not fs.is_dir(parent) then
              if plan.vacated and plan.vacated[key] then
                create_dirs[key] = parent
              else
                return nil, nil, 'path parent is not a directory: ' .. parent
              end
            elseif plan.vacated and plan.vacated[key] then
              create_dirs[key] = parent
            end
          else
            if create_dirs[key] == nil then create_dirs[key] = parent end
          end
        end
        local target_key = normalized(path)
        if fs.taken(path) and not (plan.vacated and plan.vacated[target_key]) then
          return nil, nil, 'destination already exists: ' .. path
            .. '; choose another name or re-list the directory'
        end
        if is_directory then
          create_dirs[target_key] = path
        else
          touches[#touches + 1] = action_mod.Touch(path)
        end
      end

      local directories = {}
      for _, path in pairs(create_dirs) do
        directories[#directories + 1] = path
      end
      table.sort(directories, function(a, b)
        local da, db = select(2, a:gsub('/', '')), select(2, b:gsub('/', ''))
        if da ~= db then return da < db end
        return a < b
      end)
      for _, path in ipairs(directories) do
        actions[#actions + 1] = action_mod.MakeDirectory(path)
      end
      for _, action in ipairs(touches) do actions[#actions + 1] = action end
    elseif plan.kind == 'DELETE' then
      for _, line in ipairs(plan.removed) do
        local path = entry_path(root, line)
        yanks[#yanks + 1] = path
        if is_dir_line(line) then
          actions[#actions + 1] = action_mod.RemoveDirectory(path)
        else
          actions[#actions + 1] = action_mod.Remove(path)
        end
      end
    elseif plan.kind == 'RENAME' then
      for _, move in ipairs(plan.moves) do
        local src = move.src_path or entry_path(root, move.src)
        local dst = move.dst_path or entry_path(root, move.dst)
        -- Directory symlinks are displayed with the directory marker, but the
        -- marker would make rename follow the link instead of moving the link.
        local source_stat = lstat(src)
        if source_stat and source_stat.type == 'link' then
          src = path_without_marker(src)
          dst = path_without_marker(dst)
        end
        actions[#actions + 1] = action_mod.Move(src, dst)
      end
    elseif plan.kind == 'IDENTITY' then
      local removals, deleted_paths, remove_err = build_actions(root, {
        kind = 'DELETE', removed = plan.removed or {},
      })
      if not removals then return nil, nil, remove_err end
      local moves, _, move_err = build_actions(root, {
        kind = 'RENAME', moves = plan.moves or {},
      })
      if not moves then return nil, nil, move_err end
      local vacated = {}
      for _, act in ipairs(removals) do
        if act.src then vacated[paths.canonical(act.src)] = true end
      end
      for _, act in ipairs(moves) do
        if act.src then vacated[paths.canonical(act.src)] = true end
      end
      local creates, _, create_err = build_actions(root, {
        kind = 'ADD', added = plan.added or {}, vacated = vacated,
      })
      if not creates then return nil, nil, create_err end
      vim.list_extend(actions, removals)
      vim.list_extend(actions, moves)
      vim.list_extend(actions, creates)
      yanks = deleted_paths
    end
    return actions, yanks
  end
  return {
    classify = classify,
    classify_identity = classify_identity,
    component_reason = component_reason,
    first_unsafe = first_unsafe,
    ambiguous_message = ambiguous_message,
    result_entry = result_entry,
    build_actions = build_actions,
    nested_path_reason = nested_path_reason,
  }
end
