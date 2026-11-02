-- Pure classification and validation for converting edited listing rows to actions.
return function(deps)
  local action_mod = deps.action_mod
  local entry_path = deps.entry_path
  local is_dir_line = deps.is_dir_line
  local dirs_then_name = deps.dirs_then_name
  local lstat = deps.lstat
  local path_without_marker = deps.path_without_marker

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
  -- first_unsafe(root, lines) -> { path, reason } for the first line whose path
  -- is unrepresentable, else nil. Both the edited lines and the on-disk listing
  -- are checked: either side can be an OS-chosen name.
  local function first_unsafe(root, lines)
    for _, line in ipairs(lines) do
      local component_error = component_reason(line)
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
  -- order; deleted directory paths retain their trailing slash in the auto-yank.
  local function build_actions(root, plan)
    local actions, yanks = {}, {}
    if plan.kind == 'ADD' then
      for _, line in ipairs(plan.added) do
        local path = entry_path(root, line)
        if is_dir_line(line) then
          actions[#actions + 1] = action_mod.MakeDirectory(path)
        else
          actions[#actions + 1] = action_mod.Touch(path)
        end
      end
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
        local src = entry_path(root, move.src)
        local dst = entry_path(root, move.dst)
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
  return {
    classify = classify,
    component_reason = component_reason,
    first_unsafe = first_unsafe,
    ambiguous_message = ambiguous_message,
    result_entry = result_entry,
    build_actions = build_actions,
  }
end
