-- Action-kind dispatch, async execution, and canonical history record encoding.
-- The action facade is injected to keep factories and record handling acyclic.
return function(M)
  -- Serialization
  -- ---------------------------------------------------------------------------

  local function encode_string(value) return vim.json.encode(value) end

  local function encode_array(values)
    local encoded = {}
    for i, value in ipairs(values) do
      encoded[i] = encode_string(value)
    end
    return '[' .. table.concat(encoded, ',') .. ']'
  end

  -- Object fields are supplied as ordered { key, already_encoded_value } pairs;
  -- JSON table iteration order is never used for persisted records.
  local function encode_object(fields)
    local encoded = {}
    for i, field in ipairs(fields) do
      encoded[i] = encode_string(field[1]) .. ':' .. field[2]
    end
    return '{' .. table.concat(encoded, ',') .. '}'
  end

  -- A group is one connected component of interlinked moves. Use path spelling
  -- only, rather than filesystem identity: replay and preflight must be pure with
  -- respect to the current filesystem state.
  local function group_is_connected(moves)
    if type(moves) ~= 'table' or #moves < 2 then return false end
    local endpoints, visited = {}, { [1] = true }
    local function key(path) return M.paths.canonical(path) end
    for i, move in ipairs(moves) do
      endpoints[i] = { key(move.src), key(move.dst) }
    end
    local changed = true
    while changed do
      changed = false
      for i, candidate in ipairs(endpoints) do
        if not visited[i] then
          for j in pairs(visited) do
            if
              candidate[1] == endpoints[j][1]
              or candidate[1] == endpoints[j][2]
              or candidate[2] == endpoints[j][1]
              or candidate[2] == endpoints[j][2]
            then
              visited[i] = true
              changed = true
              break
            end
          end
        end
      end
    end
    for i = 1, #moves do
      if not visited[i] then return false end
    end
    return true
  end

  local function checked_string(value, what)
    local reason = M.path_reason(value)
    if not reason then
      local valid, path_err = M.paths.validate_canonical_path(value)
      if not valid then reason = path_err end
    end
    if reason then return nil, 'cannot serialize action: ' .. reason .. ': ' .. tostring(value) end
    return encode_string(M.paths.record_path(value))
  end

  local function encoded_move(src, dst)
    local es, serr = checked_string(src, 'src')
    if not es then return nil, serr end
    local ed, derr = checked_string(dst, 'dst')
    if not ed then return nil, derr end
    return encode_object({
      { 'src', es },
      { 'dst', ed },
    })
  end

  -- serialize_group(action) -> canonical JSONL record | nil, err.
  function M.serialize_group(action)
    local members = action.actions
    if type(members) ~= 'table' or #members < 2 then
      return nil, 'cannot serialize group: at least two actions are required'
    end
    local moves = {}
    for _, member in ipairs(members) do
      if
        type(member) ~= 'table'
        or member.name ~= 'mv'
        or type(member.src) ~= 'string'
        or type(member.dst) ~= 'string'
      then
        return nil, 'cannot serialize group: only move actions can be grouped'
      end
      local move, err = encoded_move(member.src, member.dst)
      if not move then return nil, err end
      moves[#moves + 1] = move
    end
    if not group_is_connected(members) then return nil, 'cannot serialize group: moves are not interlinked' end
    return encode_object({
      { 'op', encode_string('g') },
      { 'moves', '[' .. table.concat(moves, ',') .. ']' },
    })
  end

  local function serialize_batch(action)
    local members = action.actions
    if type(members) ~= 'table' or #members < 2 then
      return nil, 'cannot serialize batch: at least two actions are required'
    end
    local records = {}
    for _, member in ipairs(members) do
      local record, err = M.serialize(member)
      if not record then return nil, 'cannot serialize batch member: ' .. tostring(err) end
      records[#records + 1] = record
    end
    return encode_object({
      { 'op', encode_string('batch') },
      { 'actions', encode_array(records) },
    })
  end

  -- Every action kind declares its serialized fields, parser, and reversal in one
  -- place. Factories keep the behavior on each action instance; execute dispatch
  -- uses this table so callers do not need to know that implementation detail.
  local function object_has_exact_fields(value, expected)
    if type(value) ~= 'table' then return false end
    local count = 0
    for key in pairs(value) do
      if type(key) ~= 'string' or not expected[key] then return false end
      count = count + 1
    end
    for key in pairs(expected) do
      if value[key] == nil then return false end
    end
    return count == vim.tbl_count(expected)
  end

  local function is_array(value)
    if type(value) ~= 'table' then return false end
    local count, max = 0, 0
    for key in pairs(value) do
      if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end
      count = count + 1
      max = math.max(max, key)
    end
    return count == max
  end

  local KINDS = {
    mv = {
      fields = { 'src', 'dst' },
      record_fields = { 'op', 'src', 'dst' },
      deserialize = function(record) return M.Move(record.src, record.dst) end,
      reverse = function(action) return M.Move(action.dst, action.src) end,
    },
    rm = {
      fields = { 'src', 'dst' },
      record_fields = { 'op', 'src', 'dst' },
      deserialize = function(record) return M.Remove(record.src, record.dst) end,
      reverse = function(action) return M.Restore(action.dst, action.src) end,
    },
    rmdir = {
      fields = { 'src', 'dst' },
      record_fields = { 'op', 'src', 'dst' },
      deserialize = function(record) return M.RemoveDirectory(record.src, record.dst) end,
      reverse = function(action) return M.RestoreDirectory(action.dst, action.src) end,
    },
    rs = {
      fields = { 'src', 'dst' },
      record_fields = { 'op', 'src', 'dst' },
      deserialize = function(record) return M.Restore(record.src, record.dst) end,
      reverse = function(action) return M.Remove(action.dst) end,
    },
    rsdir = {
      fields = { 'src', 'dst' },
      record_fields = { 'op', 'src', 'dst' },
      deserialize = function(record) return M.RestoreDirectory(record.src, record.dst) end,
      reverse = function(action) return M.RemoveDirectory(action.dst) end,
    },
    touch = {
      fields = { 'dst' },
      record_fields = { 'op', 'dst' },
      deserialize = function(record) return M.Touch(record.dst) end,
      reverse = function(action) return M.Remove(action.dst) end,
    },
    mkdir = {
      fields = { 'dst' },
      record_fields = { 'op', 'dst' },
      deserialize = function(record) return M.MakeDirectory(record.dst) end,
      reverse = function(action) return M.RemoveDirectory(action.dst) end,
    },
    p = {
      fields = { 'src', 'dst' },
      name_lists = true,
      record_fields = { 'op', 'src', 'dst', 'src_names', 'dst_names' },
      deserialize = function(record) return M.Paste(record.src, record.dst, record.src_names, record.dst_names) end,
      reverse = function(action)
        local src_names, dst_names = M.split_pairs(action.renames)
        return M.Unpaste(action.dst, action.src, dst_names, src_names)
      end,
    },
    up = {
      fields = { 'src', 'dst' },
      name_lists = true,
      record_fields = { 'op', 'src', 'dst', 'src_names', 'dst_names' },
      deserialize = function(record) return M.Unpaste(record.src, record.dst, record.src_names, record.dst_names) end,
      reverse = function(action)
        local src_names, dst_names = M.split_pairs(action.renames)
        return M.Paste(action.dst, action.src, dst_names, src_names)
      end,
    },
    g = {
      fields = { 'actions' },
      record_fields = { 'op', 'moves' },
      serialize = M.serialize_group,
      deserialize = function(record)
        if not is_array(record.moves) or #record.moves < 2 then
          return nil, 'invalid group record: at least two moves are required'
        end
        local members = {}
        for _, move in ipairs(record.moves) do
          if
            not object_has_exact_fields(move, { src = true, dst = true })
            or type(move.src) ~= 'string'
            or type(move.dst) ~= 'string'
          then
            return nil, 'invalid group record: each move needs src and dst strings'
          end
          members[#members + 1] = M.Move(move.src, move.dst)
        end
        return M.Group(members)
      end,
      reverse = function(action)
        local members = {}
        for i = #(action.actions or {}), 1, -1 do
          local rev, err = M.reverse_action(action.actions[i])
          if not rev then return nil, err end
          members[#members + 1] = rev
        end
        if #members < 2 then return nil, 'no reversal for group: fewer than two actions' end
        return M.Group(members)
      end,
    },
    batch = {
      fields = {},
      record_fields = { 'op', 'actions' },
      serialize = serialize_batch,
      deserialize = function(record)
        local members = {}
        for _, nested in ipairs(record.actions) do
          local member, err = M.deserialize(nested)
          if not member then return nil, err end
          members[#members + 1] = member
        end
        return M.Batch(members)
      end,
      reverse = function(action)
        local members = {}
        for i = #(action.actions or {}), 1, -1 do
          local reversed, err = M.reverse_action(action.actions[i])
          if not reversed then return nil, err end
          members[#members + 1] = reversed
        end
        return M.Batch(members)
      end,
    },
  }

  for name, kind in pairs(KINDS) do
    local expected = name
    kind.execute = function(action)
      if action._kind ~= expected then
        return nil, 'action kind mismatch: expected ' .. expected .. ', got ' .. tostring(action._kind)
      end
      if type(action._execute) ~= 'function' then return nil, 'action has no executor: ' .. expected end
      return action._execute()
    end
  end

  function M.execute(action)
    if type(action) ~= 'table' then return nil, 'invalid action' end
    local kind = KINDS[action.name]
    if kind == nil then return nil, 'no executor for action: ' .. tostring(action.name) end
    return kind.execute(action)
  end

  -- execute_async(action, callback) dispatches callback-capable actions without
  -- changing their factory contract. Non-prompt actions execute immediately, so
  -- grouped moves retain their existing synchronous staging behavior.
  function M.execute_async(action, callback)
    if type(callback) ~= 'function' then return nil, 'execute_async requires a completion callback' end
    local completed = false
    local function finish(ok, result, err)
      if completed then return end
      completed = true
      local called, callback_err = pcall(callback, ok, result, err)
      if not called then M.ui.report_error('finish the filesystem action', callback_err) end
    end
    if type(action) == 'table' and type(action._execute_async) == 'function' then
      local ok, err = pcall(action._execute_async, finish)
      if not ok then finish(false, nil, err) end
      return true
    end
    local ok, result, err = pcall(M.execute, action)
    if not ok then
      finish(false, nil, result)
    else
      finish(result ~= nil, result, err)
    end
    return true
  end

  function M.Batch(actions)
    local self = { name = 'batch', _kind = 'batch', actions = actions or {} }
    self._execute = function()
      local completed = {}
      for _, member in ipairs(self.actions) do
        local called, result, err = pcall(M.execute, member)
        if not called or result == nil then
          local failure = not called and tostring(result) or tostring(err or 'action failed')
          for index = #completed, 1, -1 do
            local inverse, reverse_err = M.reverse_action(completed[index])
            local rolled, rollback_result, rollback_err
            if inverse then
              rolled, rollback_result, rollback_err = pcall(M.execute, inverse)
            end
            if not inverse or not rolled or rollback_result == nil then
              failure = failure
                .. '; batch rollback failed: '
                .. tostring(reverse_err or (not rolled and rollback_result) or rollback_err or 'action failed')
            end
          end
          return nil, failure
        end
        completed[#completed + 1] = member
      end
      return true
    end

    self._execute_async = function(callback)
      local completed, settled = {}, false
      local function finish(ok, result, err)
        if settled then return end
        settled = true
        callback(ok, result, err)
      end
      local function rollback(original_err)
        local inverses = {}
        for index = #completed, 1, -1 do
          local inverse, reverse_err = M.reverse_action(completed[index])
          if not inverse then
            finish(
              false,
              nil,
              tostring(original_err) .. '; batch rollback could not be planned: ' .. tostring(reverse_err)
            )
            return
          end
          inverses[#inverses + 1] = inverse
        end
        local index = 1
        local function next_inverse()
          if index > #inverses then
            finish(false, nil, tostring(original_err))
            return
          end
          local inverse = inverses[index]
          index = index + 1
          local started, start_err = M.execute_async(inverse, function(ok, result, rollback_err)
            if not ok or result == nil then
              finish(
                false,
                nil,
                tostring(original_err) .. '; batch rollback failed: ' .. tostring(rollback_err or 'action failed')
              )
              return
            end
            next_inverse()
          end)
          if not started then
            finish(false, nil, tostring(original_err) .. '; batch rollback failed: ' .. tostring(start_err))
          end
        end
        next_inverse()
      end
      local index = 1
      local function next_action()
        if index > #self.actions then
          finish(true, true)
          return
        end
        local member = self.actions[index]
        index = index + 1
        local started, start_err = M.execute_async(member, function(ok, result, err)
          if not ok or result == nil then
            rollback(err or 'action failed')
            return
          end
          completed[#completed + 1] = member
          next_action()
        end)
        if not started then rollback(start_err or 'could not start action') end
      end
      next_action()
      return true
    end

    function self.describe()
      local descriptions = {}
      for _, member in ipairs(self.actions) do
        descriptions[#descriptions + 1] = M.describe_action(member)
      end
      return table.concat(descriptions, ', ')
    end
    return self
  end

  -- serialize(action) -> a canonical JSON record with fixed key order | nil, err.
  function M.serialize(action)
    if type(action) ~= 'table' or type(action.name) ~= 'string' then return nil, 'cannot serialize action' end
    local kind = KINDS[action.name]
    if kind == nil then return nil, 'cannot serialize action' end
    if action._kind ~= action.name then return nil, 'cannot serialize action: action kind mismatch' end
    if kind.serialize ~= nil then return kind.serialize(action) end
    local fields = { { 'op', encode_string(action.name) } }
    for _, field in ipairs(kind.fields) do
      local encoded, err = checked_string(action[field], field)
      if not encoded then return nil, err end
      fields[#fields + 1] = { field, encoded }
    end
    if kind.name_lists then
      local src_names, dst_names = M.split_pairs(action.renames)
      if #src_names ~= #dst_names then return nil, 'cannot serialize action: name arrays must have equal lengths' end
      for _, name in ipairs(src_names) do
        local reason = M.entry_name_reason(name)
        if reason then return nil, 'cannot serialize action: ' .. reason .. ': ' .. tostring(name) end
      end
      for _, name in ipairs(dst_names) do
        local reason = M.entry_name_reason(name)
        if reason then return nil, 'cannot serialize action: ' .. reason .. ': ' .. tostring(name) end
      end
      fields[#fields + 1] = { 'src_names', encode_array(src_names) }
      fields[#fields + 1] = { 'dst_names', encode_array(dst_names) }
    end
    return encode_object(fields)
  end

  local function duplicate_object_keys(json)
    local at = 1
    local function whitespace()
      while json:sub(at, at):match('%s') do
        at = at + 1
      end
    end
    local function string_token()
      local start = at
      if json:sub(at, at) ~= '"' then return nil end
      at = at + 1
      while at <= #json do
        local char = json:sub(at, at)
        if char == '\\' then
          at = at + 2
        elseif char == '"' then
          at = at + 1
          local ok, value = pcall(vim.json.decode, json:sub(start, at - 1))
          if not ok then return nil end
          return value
        else
          at = at + 1
        end
      end
      return nil
    end
    local parse_value
    local function parse_object()
      at = at + 1
      whitespace()
      if json:sub(at, at) == '}' then
        at = at + 1
        return true
      end
      local seen = {}
      while at <= #json do
        local key = string_token()
        if key == nil then return nil, 'malformed object key' end
        if seen[key] then return nil, 'duplicate JSON object key: ' .. key end
        seen[key] = true
        whitespace()
        if json:sub(at, at) ~= ':' then return nil, 'missing object colon' end
        at = at + 1
        local ok, err = parse_value()
        if not ok then return nil, err end
        whitespace()
        local separator = json:sub(at, at)
        if separator == '}' then
          at = at + 1
          return true
        end
        if separator ~= ',' then return nil, 'malformed object separator' end
        at = at + 1
        whitespace()
      end
      return nil, 'unterminated object'
    end
    local function parse_array()
      at = at + 1
      whitespace()
      if json:sub(at, at) == ']' then
        at = at + 1
        return true
      end
      while at <= #json do
        local ok, err = parse_value()
        if not ok then return nil, err end
        whitespace()
        local separator = json:sub(at, at)
        if separator == ']' then
          at = at + 1
          return true
        end
        if separator ~= ',' then return nil, 'malformed array separator' end
        at = at + 1
        whitespace()
      end
      return nil, 'unterminated array'
    end
    parse_value = function()
      whitespace()
      local char = json:sub(at, at)
      if char == '{' then return parse_object() end
      if char == '[' then return parse_array() end
      if char == '"' then
        if string_token() == nil then return nil, 'malformed JSON string' end
        return true
      end
      local start = at
      while at <= #json do
        local char = json:sub(at, at)
        if char == ',' or char == ']' or char == '}' or char:match('%s') then break end
        at = at + 1
      end
      if at == start then return nil, 'malformed JSON value' end
      return true
    end
    local ok, err = parse_value()
    if not ok then return nil, err end
    whitespace()
    if at <= #json then return nil, 'trailing JSON data' end
    return true
  end

  local function exact_fields(record, keys)
    local expected = {}
    for _, key in ipairs(keys) do
      expected[key] = true
    end
    return object_has_exact_fields(record, expected)
  end

  local function validate_json_action(record, kind)
    if not exact_fields(record, kind.record_fields) then return nil, 'action record has unknown or missing keys' end
    if record.op ~= 'g' then
      for _, field in ipairs(kind.fields) do
        local valid, reason = M.paths.validate_canonical_path(record[field])
        if valid and M.paths.record_path(record[field]) ~= record[field] then
          reason = 'path must be absolute and canonical'
        end
        if reason then return nil, reason .. ': ' .. tostring(record[field]) end
      end
    end
    if kind.name_lists then
      if not is_array(record.src_names) or not is_array(record.dst_names) or #record.src_names ~= #record.dst_names then
        return nil, 'name arrays must be arrays of equal length'
      end
      for _, names in ipairs({ record.src_names, record.dst_names }) do
        for _, name in ipairs(names) do
          local reason = M.entry_name_reason(name)
          if reason then return nil, reason .. ': ' .. tostring(name) end
        end
      end
    elseif record.op == 'g' then
      if not is_array(record.moves) or #record.moves < 2 then return nil, 'a group requires at least two move pairs' end
      for _, move in ipairs(record.moves) do
        if not exact_fields(move, { 'src', 'dst' }) then return nil, 'a group move requires exactly src and dst' end
        for _, field in ipairs({ 'src', 'dst' }) do
          local valid, reason = M.paths.validate_canonical_path(move[field])
          if valid and M.paths.record_path(move[field]) ~= move[field] then
            reason = 'path must be absolute and canonical'
          end
          if reason then return nil, reason .. ': ' .. tostring(move[field]) end
        end
      end
      if not group_is_connected(record.moves) then return nil, 'group moves are not interlinked' end
    elseif record.op == 'batch' then
      if not is_array(record.actions) or #record.actions < 2 then
        return nil, 'a batch requires at least two actions'
      end
      for _, nested in ipairs(record.actions) do
        if type(nested) ~= 'string' then return nil, 'a batch action must be a serialized action record' end
        local decoded, decode_err = M.deserialize(nested)
        if not decoded then return nil, 'invalid batch action: ' .. tostring(decode_err) end
      end
    end
    return true
  end

  -- deserialize(line) -> action, or nil, err. Re-encoding the parsed record and
  -- comparing bytes enforces canonical key order, escaping, and whitespace.
  function M.deserialize(line)
    if type(line) ~= 'string' or line == '' then return nil, 'invalid action line' end
    if not M.paths.valid_utf8(line) then return nil, 'invalid action line: invalid UTF-8' end
    local scan_ok, scan_err = duplicate_object_keys(line)
    if not scan_ok then return nil, 'invalid action line: ' .. tostring(scan_err) end
    local decoded_ok, record = pcall(vim.json.decode, line)
    if not decoded_ok or type(record) ~= 'table' then return nil, 'invalid action line: malformed JSON' end
    if type(record.op) ~= 'string' then return nil, 'invalid action line: op must be a string' end
    local kind = KINDS[record.op]
    if kind == nil then return nil, 'unknown action name: ' .. tostring(record.op) end
    local valid, validation_err = validate_json_action(record, kind)
    if not valid then return nil, 'invalid action line: ' .. tostring(validation_err) end
    local action, build_err = kind.deserialize(record)
    if not action then return nil, build_err or 'invalid action line' end
    local canonical, encode_err = M.serialize(action)
    if not canonical then return nil, encode_err end
    if canonical ~= line then return nil, 'invalid action line: non-canonical JSON' end
    return action
  end

  -- reverse_action(action) -> the reversal per the exact mapping
  -- mv -> mv (src/dst swapped)
  -- rm -> rs
  -- rmdir -> rsdir
  -- rs -> rm
  -- rsdir -> rmdir
  -- touch -> rm
  -- mkdir -> rmdir
  -- p -> up (src/dst swapped, renames inverted)
  -- up -> p (src/dst swapped, renames inverted)
  -- g -> g (every member reversed, in reverse order)
  --
  -- A group reversal applies all its members through the staging path, so the
  -- recorded order cannot change the filesystem outcome; reversing order as well
  -- keeps the pair a true involution (undo -> redo -> undo reproduces the original
  -- record), which is what makes the redo log entry byte-identical for a swap.
  function M.reverse_action(action)
    if type(action) ~= 'table' then return nil, 'invalid action' end
    local kind = KINDS[action.name]
    if kind ~= nil then return kind.reverse(action) end
    return nil, 'no reversal for action: ' .. tostring(action.name)
  end

  -- reverse(line) -> the reversal of the action serialized on `line`, or
  -- nil, err. Accepts an already-deserialized action table as well.
  function M.reverse(line)
    local action = line
    if type(action) ~= 'table' then
      local err
      action, err = M.deserialize(line)
      if not action then return nil, err or 'invalid action line' end
    end
    return M.reverse_action(action)
  end

  -- ---------------------------------------------------------------------------
end
