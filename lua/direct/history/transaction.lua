-- Durable history transaction encoding and strict schema validation.
-- This module is deliberately side-effect free: it never reads or writes files.
local M = {}

local action = require('direct.action.action')
local paths = require('direct.paths')
local history_format = require('direct.history.format')
local platform = require('direct.platform')

M.FORMAT = 'direct-operation-journal'
M.VERSION = 1
M.HEADER = history_format.HEADER

local function exact_keys(value, expected)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if not expected[key] then return false end end
  for key in pairs(expected) do if value[key] == nil then return false end end
  return true
end

local function valid_stack(lines)
  if type(lines) ~= 'table' or lines[1] ~= M.HEADER then return false end
  for _, line in ipairs(lines) do
    if type(line) ~= 'string' or line:find('[\r\n]') then return false end
  end
  return history_format.classify(table.concat(lines, '\n') .. '\n', true).state == 'current'
end

local function valid_identity(identity)
  if identity == nil or identity == vim.NIL then return true end
  if type(identity) ~= 'table' or type(identity.path) ~= 'string'
    or (identity.inode ~= nil and type(identity.inode) ~= 'string') then
    return false
  end
  for key in pairs(identity) do
    if key ~= 'path' and key ~= 'inode' then return false end
  end
  return true
end

local function identity_path_matches(identity, path)
  if identity == nil or identity == vim.NIL then return true end
  return platform.identity_path(paths.canonical(identity.path))
    == platform.identity_path(paths.canonical(path))
end

local function canonical_paths_match(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then return false end
  return platform.identity_path(paths.canonical(a))
    == platform.identity_path(paths.canonical(b))
end

local function canonical_optional_paths_match(a, b)
  if a == nil or a == vim.NIL then return b == nil or b == vim.NIL end
  if b == nil or b == vim.NIL then return false end
  return canonical_paths_match(a, b)
end

local function valid_move_steps(steps, next_step, staging_count)
  if type(steps) ~= 'table' or type(next_step) ~= 'number'
    or next_step % 1 ~= 0 or next_step < 1 or next_step > #steps + 1
    or type(staging_count) ~= 'number' or staging_count % 1 ~= 0
    or staging_count < 0 or staging_count > #steps then
    return false
  end
  for index, step in ipairs(steps) do
    if type(step) ~= 'table' then return false end
    for key in pairs(step) do
      if key ~= 'src' and key ~= 'dst' and key ~= 'identity' then return false end
    end
    if type(step.src) ~= 'string' or type(step.dst) ~= 'string'
      or not valid_identity(step.identity) or type(step.identity) ~= 'table'
      or type(step.identity.inode) ~= 'string'
      or not identity_path_matches(step.identity, step.src) then
      return false
    end
    local source_ok = paths.validate_canonical_path(step.src)
    local destination_ok = paths.validate_canonical_path(step.dst)
    if not source_ok or not destination_ok then return false end
    if index < next_step and step.src == step.dst then return false end
  end
  return true
end

local function valid_name_pairs(name_pairs, paste_action)
  if type(name_pairs) ~= 'table' then return false end
  local sources, destinations, allowed_sources = {}, {}, {}
  for _, pair in ipairs(paste_action.renames or {}) do
    allowed_sources[pair.src] = true
  end
  local count, max = 0, 0
  for key, pair in pairs(name_pairs) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return false end
    count, max = count + 1, math.max(max, key)
    if type(pair) ~= 'table' or type(pair.src) ~= 'string'
      or type(pair.dst) ~= 'string' then
      return false
    end
    for field in pairs(pair) do
      if field ~= 'src' and field ~= 'dst' then return false end
    end
    if action.entry_name_reason(pair.src) or action.entry_name_reason(pair.dst)
      or not allowed_sources[pair.src] or sources[pair.src] or destinations[pair.dst] then
      return false
    end
    sources[pair.src], destinations[pair.dst] = true, true
  end
  return count == max
end

local function valid_paste_pending(pending, paste_action)
  if pending == vim.NIL then return true end
  if type(pending) ~= 'table' then return false end
  if not exact_keys(pending, {
      src = true, dst = true, source = true, destination = true,
      source_identity = true,
    }) or type(pending.src) ~= 'string' or type(pending.dst) ~= 'string'
    or type(pending.source) ~= 'string' or type(pending.destination) ~= 'string'
    or not valid_identity(pending.source_identity)
    or type(pending.source_identity) ~= 'table'
    or type(pending.source_identity.inode) ~= 'string'
    or action.entry_name_reason(pending.src) or action.entry_name_reason(pending.dst)
    or not identity_path_matches(pending.source_identity, pending.source) then
    return false
  end
  local expected_source = action.fs.join(paste_action.src, pending.src)
  local expected_destination = action.fs.join(paste_action.dst, pending.dst)
  return paths.canonical(expected_source) == pending.source
    and paths.canonical(expected_destination) == pending.destination
end

local function valid_unpaste_items(items, next_item, phase, unpaste_action)
  if type(items) ~= 'table' or type(next_item) ~= 'number'
    or next_item % 1 ~= 0 or next_item < 1 or next_item > #items + 1
    or (phase ~= 'preflight' and phase ~= 'capture' and phase ~= 'delete') then
    return false
  end
  local pairs_by_names = {}
  for _, pair in ipairs(unpaste_action.renames or {}) do
    pairs_by_names[pair.src .. '\0' .. pair.dst] = true
  end
  local count, max = 0, 0
  for index, item in pairs(items) do
    if type(index) ~= 'number' or index < 1 or index % 1 ~= 0 then return false end
    count, max = count + 1, math.max(max, index)
    if not exact_keys(item, {
        src = true, dst = true, path = true, reference = true,
        quarantine = true, identity = true, kind = true,
      }) or type(item.src) ~= 'string' or type(item.dst) ~= 'string'
      or type(item.path) ~= 'string' or type(item.reference) ~= 'string'
      or type(item.quarantine) ~= 'string' or not valid_identity(item.identity)
      or type(item.identity) ~= 'table' or type(item.identity.inode) ~= 'string'
      or (item.kind ~= 'file' and item.kind ~= 'directory' and item.kind ~= 'link')
      or action.entry_name_reason(item.src) or action.entry_name_reason(item.dst)
      or not identity_path_matches(item.identity, item.path)
      or not pairs_by_names[item.src .. '\0' .. item.dst]
      or paths.canonical(action.fs.join(unpaste_action.src, item.src)) ~= item.path
      or paths.canonical(action.fs.join(unpaste_action.dst, item.dst)) ~= item.reference
      or paths.canonical(action.fs.dirname(item.path))
        ~= paths.canonical(action.fs.dirname(item.quarantine)) then
      return false
    end
  end
  return count == max
end

function M.stack_bytes(undo_lines, redo_lines)
  return vim.json.encode({
    format = M.FORMAT,
    version = M.VERSION,
    kind = 'stacks',
    undo = undo_lines,
    redo = redo_lines,
  }) .. '\n'
end

function M.parse(bytes)
  local ok, value = pcall(vim.json.decode, bytes)
  if not ok or type(value) ~= 'table' or value.format ~= M.FORMAT
    or value.version ~= M.VERSION then
    return nil
  end
  if value.kind == 'stacks' then
    if not exact_keys(value, {
        format = true, version = true, kind = true, undo = true, redo = true,
      }) or not valid_stack(value.undo) or not valid_stack(value.redo) then
      return nil
    end
  elseif value.kind == 'reverse' then
    if (value.direction ~= 'undo' and value.direction ~= 'redo')
      or not valid_stack(value.undo) or not valid_stack(value.redo) then
      return nil
    end
    local reversal = action.deserialize(value.action)
    if not reversal then return nil end
    if reversal.name == 'g' then
      if not exact_keys(value, {
          format = true, version = true, kind = true, direction = true,
          undo = true, redo = true, action = true, steps = true,
          staging_count = true, next_step = true,
        }) or not valid_move_steps(value.steps, value.next_step,
          value.staging_count) then
        return nil
      end
    elseif not exact_keys(value, {
        format = true, version = true, kind = true, direction = true,
        undo = true, redo = true, action = true,
        source = true, destination = true,
        source_identity = true, destination_identity = true,
      }) or (reversal.name ~= 'mv' and reversal.name ~= 'rm'
        and reversal.name ~= 'rmdir' and reversal.name ~= 'rs' and reversal.name ~= 'rsdir')
      or type(value.source) ~= 'string' or type(value.destination) ~= 'string'
      or not valid_identity(value.source_identity)
      or not valid_identity(value.destination_identity)
      or type(value.source_identity) ~= 'table'
      or type(value.source_identity.inode) ~= 'string'
      or not identity_path_matches(value.source_identity, value.source)
      or not identity_path_matches(value.destination_identity, value.destination)
      or not canonical_paths_match(reversal.src, value.source)
      or not canonical_paths_match(reversal.dst, value.destination) then
      return nil
    end
  elseif value.kind == 'apply' then
    if value.direction ~= 'apply' or not valid_stack(value.undo)
      or not valid_stack(value.redo) then
      return nil
    end
    local filesystem_action = action.deserialize(value.action)
    if not filesystem_action then return nil end
    if filesystem_action.name == 'g' then
      if not exact_keys(value, {
          format = true, version = true, kind = true, direction = true,
          undo = true, redo = true, action = true, steps = true,
          staging_count = true, next_step = true,
        }) or not valid_move_steps(value.steps, value.next_step,
          value.staging_count) then
        return nil
      end
    else
      local source = value.source
      if source == vim.NIL then source = nil end
      if not exact_keys(value, {
          format = true, version = true, kind = true, direction = true,
          undo = true, redo = true, action = true, source = true,
          destination = true, source_identity = true, destination_identity = true,
        }) or (filesystem_action.name ~= 'mv' and filesystem_action.name ~= 'rm'
          and filesystem_action.name ~= 'rmdir' and filesystem_action.name ~= 'rs'
          and filesystem_action.name ~= 'rsdir' and filesystem_action.name ~= 'touch'
          and filesystem_action.name ~= 'mkdir')
        or (value.source ~= vim.NIL and type(value.source) ~= 'string')
        or type(value.destination) ~= 'string'
        or not valid_identity(value.source_identity)
        or not valid_identity(value.destination_identity)
        or not identity_path_matches(value.source_identity, source)
        or not identity_path_matches(value.destination_identity, value.destination)
        or not canonical_optional_paths_match(filesystem_action.src, source)
        or not canonical_paths_match(filesystem_action.dst, value.destination) then
        return nil
      end
    end
  elseif value.kind == 'paste' then
    local paste_action = action.deserialize(value.action)
    if not exact_keys(value, {
        format = true, version = true, kind = true, direction = true,
        action = true, source_action = true, base_undo = true, base_redo = true,
        completed = true, pending = true,
      }) or (value.direction ~= 'apply' and value.direction ~= 'undo'
        and value.direction ~= 'redo') or not paste_action or paste_action.name ~= 'p'
      or not valid_stack(value.base_undo) or not valid_stack(value.base_redo)
      or not valid_name_pairs(value.completed, paste_action)
      or not valid_paste_pending(value.pending, paste_action) then
      return nil
    end
    if value.direction == 'apply' then
      if value.source_action ~= vim.NIL then return nil end
    else
      if type(value.source_action) ~= 'string' then return nil end
      local source_action = action.deserialize(value.source_action)
      local source_stack = value.direction == 'undo' and value.base_undo or value.base_redo
      local inverse = source_action and action.reverse(value.source_action)
      local inverse_record = inverse and action.serialize(inverse)
      if not source_action or source_action.name ~= 'up'
        or source_stack[#source_stack] ~= value.source_action
        or inverse_record ~= value.action then
        return nil
      end
    end
  elseif value.kind == 'unpaste' then
    local unpaste_action = action.deserialize(value.action)
    if not exact_keys(value, {
        format = true, version = true, kind = true, direction = true,
        action = true, undo = true, redo = true, items = true,
        phase = true, next_item = true,
      }) or (value.direction ~= 'undo' and value.direction ~= 'redo')
      or not unpaste_action or unpaste_action.name ~= 'up'
      or not valid_stack(value.undo) or not valid_stack(value.redo)
      or not valid_unpaste_items(value.items, value.next_item, value.phase,
        unpaste_action) then
      return nil
    end
  else
    return nil
  end
  return value
end

return M
