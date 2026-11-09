-- Undo/redo over strict, canonical JSONL logs. Both stacks are classified by
-- raw bytes before any register access, directory creation, or filesystem change.
local M = {}

local log_mod = require('direct.log')
local format = require('direct.history.format')
local transaction_codec = require('direct.history.transaction')
local platform = require('direct.platform')
local recovery
M.action = require('direct.action.action')
M.paths = require('direct.paths')
M.ui = require('direct.ui')
M.pending = require('direct.pending')
M.lock = require('direct.history.lock')
local file_operations = require('direct.file_operations')

local TRANSACTION_FORMAT = transaction_codec.FORMAT
local TRANSACTION_VERSION = transaction_codec.VERSION
local backup_sequence = 0

local function identity_paths_equal(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then return false end
  return platform.identity_path(M.paths.canonical(a))
    == platform.identity_path(M.paths.canonical(b))
end

local function rename_files(action, files, paths)
  if action.name == 'mv' then
    files[#files + 1] = {
      oldUri = vim.uri_from_fname(M.action.fs.abspath(action.src)),
      newUri = vim.uri_from_fname(M.action.fs.abspath(action.dst)),
    }
    paths[#paths + 1] = action.src
    paths[#paths + 1] = action.dst
  elseif action.name == 'g' or action.name == 'batch' then
    for _, member in ipairs(action.actions or {}) do
      rename_files(member, files, paths)
    end
  end
end

M.HEADER = format.HEADER

local function log_paths()
  local dir = M.paths.data_dir_path('history')
  return M.paths.join(dir, 'undo.log'), M.paths.join(dir, 'redo.log'),
    M.paths.join(dir, 'transaction.json')
end

local function notify_unavailable(err)
  M.ui.notify('direct: history unavailable: ' .. tostring(err),
    vim.log.levels.ERROR)
end

function M.with_lock(callback)
  local acquired, acquire_err = M.lock.acquire()
  if not acquired then
    notify_unavailable(acquire_err)
    return nil, acquire_err
  end
  local ok, first, second = xpcall(callback, debug.traceback)
  local released, release_err = M.lock.release()
  if not ok then return nil, first end
  if not released then
    notify_unavailable(release_err)
    return nil, release_err
  end
  return first, second
end

local function notify_preserved(path, reason)
  local message = 'direct: refusing operation; history was preserved at '
    .. path .. ' (' .. tostring(reason) .. ')'
  M.ui.notify(message, vim.log.levels.ERROR)
  return nil, message
end

local function validate_user_paths(user_paths)
  for _, path in ipairs(user_paths or {}) do
    local ok, err = M.paths.validate_canonical_path(path)
    if not ok then return nil, 'invalid path: ' .. tostring(err) end
  end
  return true
end

local function classify_path(path)
  local bytes, err, exists = log_mod.read_raw(path)
  if err then
    return { state = 'preserve', reason = err, read_error = true }
  end
  local state = format.classify(bytes, exists)
  state.bytes, state.exists = bytes, exists
  return state
end

local function write_stack(path, lines)
  return log_mod.write(path, lines)
end

local commit_stacks

local function backup_history(path, bytes)
  local stamp = os.date('!%Y%m%dT%H%M%SZ')
  local pid = tostring(log_mod.uv.os_getpid())
  for _ = 1, 100 do
    backup_sequence = backup_sequence + 1
    local backup_path = string.format('%s.backup-%s-%s-%d', path, stamp, pid,
      backup_sequence)
    local ok, err, code = log_mod.write_raw_exclusive(backup_path, bytes)
    if ok then return backup_path end
    if code ~= 'EEXIST' then return nil, err end
  end
  return nil, 'could not allocate a unique history backup path'
end

local function backup_history_files(entries)
  local backups = {}
  for _, entry in ipairs(entries) do
    if type(entry.bytes) == 'string' and entry.bytes ~= '' then
      local backup, err = backup_history(entry.path, entry.bytes)
      if not backup then return nil, err end
      backups[#backups + 1] = backup
    end
  end
  return backups
end

local function reset_stacks(undo_path, redo_path, transaction_path)
  return commit_stacks(undo_path, redo_path, transaction_path,
    { M.HEADER }, { M.HEADER })
end

local copy_lines
local expand_batch_stack
local parse_transaction = transaction_codec.parse

local function write_operation_transaction(path, transaction)
  local called, ok, err = pcall(function()
    return log_mod.write_raw_atomic(path, vim.json.encode(transaction) .. '\n')
  end)
  if not called then return nil, tostring(ok) end
  if not ok then return nil, err end
  return true
end

local function attach_unpaste_journal(action, transaction, transaction_path)
  action._journal_items = transaction.items
  action._on_unpaste_begin = function(items)
    if #items ~= #transaction.items then return nil, 'Unpaste plan length changed' end
    for index, item in ipairs(items) do
      local expected = transaction.items[index]
      if item.path ~= expected.path or item.reference ~= expected.reference
        or item.quarantine ~= expected.quarantine
        or item.identity.inode ~= expected.identity.inode then
        return nil, 'Unpaste plan changed at ' .. item.path
      end
    end
    transaction.phase, transaction.next_item = 'capture', 1
    return write_operation_transaction(transaction_path, transaction)
  end
  action._after_unpaste_capture = function(index)
    transaction.next_item = index + 1
    return write_operation_transaction(transaction_path, transaction)
  end
  action._before_unpaste_delete = function()
    transaction.phase, transaction.next_item = 'delete', 1
    return write_operation_transaction(transaction_path, transaction)
  end
  action._after_unpaste_delete = function(index)
    transaction.next_item = index + 1
    return write_operation_transaction(transaction_path, transaction)
  end
end

local clear_transaction

local recoverable_rename_kinds = {
  mv = true, rm = true, rmdir = true, rs = true, rsdir = true,
  g = true, up = true,
}

local recoverable_apply_kinds = {
  mv = true, rm = true, rmdir = true, rs = true, rsdir = true,
  touch = true, mkdir = true,
}

local function reverse_intent(state, which, reversal, inverse)
  if reversal.name == 'up' then
    local unpaste_action, deserialize_err = M.action.deserialize(inverse)
    if not unpaste_action or unpaste_action.name ~= 'up' then
      return false, deserialize_err or 'could not construct Unpaste recovery action'
    end
    local items, reserved = {}, {}
    for _, pair in ipairs(reversal.renames or {}) do
      local path = M.action.fs.join(reversal.src, pair.src)
      local reference = M.action.fs.join(reversal.dst, pair.dst)
      local identity, stat = M.action.fs.entry_identity(path)
      if not stat or not identity or not identity.inode
        or (stat.type ~= 'file' and stat.type ~= 'directory' and stat.type ~= 'link') then
        return false, 'cannot identify Unpaste entry: ' .. path
      end
      local quarantine = M.action.fs.unique_temp_path(
        M.action.fs.dirname(path), 'unpaste')
      while quarantine and (reserved[quarantine] or M.action.fs.taken(quarantine)) do
        quarantine = M.action.fs.unique_temp_path(M.action.fs.dirname(path), 'unpaste')
      end
      if not quarantine then return false, 'could not allocate Unpaste quarantine' end
      reserved[quarantine] = true
      items[#items + 1] = {
        src = pair.src, dst = pair.dst,
        path = M.paths.canonical(path),
        reference = M.paths.canonical(reference),
        quarantine = M.paths.canonical(quarantine),
        identity = identity,
        kind = stat.type,
      }
    end
    local next_src = copy_lines(which == 'undo' and state.undo_lines or state.redo_lines)
    local next_dst = copy_lines(which == 'undo' and state.redo_lines or state.undo_lines)
    table.remove(next_src)
    next_dst[#next_dst + 1] = inverse
    local next_undo = which == 'undo' and next_src or next_dst
    local next_redo = which == 'undo' and next_dst or next_src
    return {
      format = TRANSACTION_FORMAT,
      version = TRANSACTION_VERSION,
      kind = 'unpaste',
      direction = which,
      action = inverse,
      undo = next_undo,
      redo = next_redo,
      items = items,
      phase = 'preflight',
      next_item = 1,
    }
  end
  if reversal.name == 'g' then
    local steps, staging_count = M.action.plan_move_steps(reversal.actions)
    if not steps then
      return false, staging_count
    end
    local next_src = copy_lines(which == 'undo' and state.undo_lines or state.redo_lines)
    local next_dst = copy_lines(which == 'undo' and state.redo_lines or state.undo_lines)
    table.remove(next_src)
    next_dst[#next_dst + 1] = inverse
    local next_undo = which == 'undo' and next_src or next_dst
    local next_redo = which == 'undo' and next_dst or next_src
    return {
      format = TRANSACTION_FORMAT,
      version = TRANSACTION_VERSION,
      kind = 'reverse',
      direction = which,
      undo = next_undo,
      redo = next_redo,
      action = inverse,
      steps = steps,
      staging_count = staging_count,
      next_step = 1,
    }
  end
  if not recoverable_rename_kinds[reversal.name]
    or type(reversal.src) ~= 'string' or type(reversal.dst) ~= 'string' then
    return nil
  end
  local source_identity, source_stat = M.action.fs.entry_identity(reversal.src)
  local destination_identity, destination_stat = M.action.fs.entry_identity(reversal.dst)
  if not destination_stat then destination_identity = nil end
  if not source_stat or not source_identity or not source_identity.inode
    or (destination_stat and (not destination_identity or not destination_identity.inode))
    or (destination_identity and destination_identity.inode == source_identity.inode) then
    return nil
  end

  local next_src = copy_lines(which == 'undo' and state.undo_lines or state.redo_lines)
  local next_dst = copy_lines(which == 'undo' and state.redo_lines or state.undo_lines)
  table.remove(next_src)
  next_dst[#next_dst + 1] = inverse
  local next_undo = which == 'undo' and next_src or next_dst
  local next_redo = which == 'undo' and next_dst or next_src
  return {
    format = TRANSACTION_FORMAT,
    version = TRANSACTION_VERSION,
    kind = 'reverse',
    direction = which,
    undo = next_undo,
    redo = next_redo,
    action = inverse,
    source = M.paths.record_path(reversal.src),
    destination = M.paths.record_path(reversal.dst),
    source_identity = source_identity,
    destination_identity = destination_identity or vim.NIL,
  }
end

local function write_reverse_intent(state, which, reversal, inverse)
  local transaction, plan_err = reverse_intent(state, which, reversal, inverse)
  if transaction == false then return false, plan_err end
  if not transaction then return nil end
  local ok, err = log_mod.write_raw_atomic(state.transaction_path,
    vim.json.encode(transaction) .. '\n')
  if not ok then return false, err end
  return transaction
end

local function write_paste_reverse_intent(state, which, reversal, inverse, source_record)
  if reversal.name ~= 'p' then return nil end
  local source_action = M.action.deserialize(source_record)
  if not source_action or source_action.name ~= 'up' then return nil end
  local source_lines = which == 'undo' and state.undo_lines or state.redo_lines
  if source_lines[#source_lines] ~= source_record then
    return false, 'history changed before preparing async paste reversal'
  end
  local transaction = {
    format = TRANSACTION_FORMAT,
    version = TRANSACTION_VERSION,
    kind = 'paste',
    direction = which,
    action = inverse,
    source_action = source_record,
    base_undo = copy_lines(state.undo_lines),
    base_redo = copy_lines(state.redo_lines),
    completed = {},
    pending = vim.NIL,
  }
  local ok, err = log_mod.write_raw_atomic(state.transaction_path,
    vim.json.encode(transaction) .. '\n')
  if not ok then return false, err end
  return transaction
end

local function start_paste_reverse(state, which, reversal, source_record)
  local inverse, serialize_err = M.action.serialize(reversal)
  if not inverse then return false, serialize_err end
  local transaction, transaction_err = write_paste_reverse_intent(
    state, which, reversal, inverse, source_record)
  if transaction == false then return false, transaction_err end
  if not transaction then return nil end
  return {
    transaction = transaction,
    transaction_path = state.transaction_path,
    locked = true,
  }
end

local function write_apply_intent(state, action, record)
  if action.name == 'g' then
    local steps, staging_count = M.action.plan_move_steps(action.actions)
    if not steps then
      return false, staging_count
    end
    local next_undo = copy_lines(state.undo_lines)
    next_undo[#next_undo + 1] = record
    local transaction = {
      format = TRANSACTION_FORMAT,
      version = TRANSACTION_VERSION,
      kind = 'apply',
      direction = 'apply',
      undo = next_undo,
      redo = { M.HEADER },
      action = record,
      steps = steps,
      staging_count = staging_count,
      next_step = 1,
    }
    local ok, err = log_mod.write_raw_atomic(state.transaction_path,
      vim.json.encode(transaction) .. '\n')
    if not ok then return false, err end
    return transaction
  end
  if not recoverable_apply_kinds[action.name] then return nil end
  local source = action.src
  local destination = action.dst
  if type(destination) ~= 'string' then return nil end
  local source_identity, source_stat
  if source ~= nil then
    source_identity, source_stat = M.action.fs.entry_identity(source)
    if not source_stat or not source_identity or not source_identity.inode then return nil end
  end
  local destination_identity, destination_stat = M.action.fs.entry_identity(destination)
  if not destination_stat then destination_identity = nil end
  if destination_stat and (not destination_identity or not destination_identity.inode) then
    return nil
  end
  if source_identity and destination_identity
    and source_identity.inode == destination_identity.inode then
    return nil
  end
  local next_undo = copy_lines(state.undo_lines)
  next_undo[#next_undo + 1] = record
  local next_redo = { M.HEADER }
  local transaction = {
    format = TRANSACTION_FORMAT,
    version = TRANSACTION_VERSION,
    kind = 'apply',
    direction = 'apply',
    undo = next_undo,
    redo = next_redo,
    action = record,
    source = source and M.paths.record_path(source) or vim.NIL,
    destination = M.paths.record_path(destination),
    source_identity = source_identity or vim.NIL,
    destination_identity = destination_identity or vim.NIL,
  }
  local ok, err = log_mod.write_raw_atomic(state.transaction_path,
    vim.json.encode(transaction) .. '\n')
  if not ok then return false, err end
  return transaction
end

local function settle_failed_reverse(state, transaction)
  if not transaction then return true end
  if transaction.kind == 'unpaste' then
    if transaction.phase == 'preflight' then
      return clear_transaction(state.transaction_path)
    end
    local message = 'Unpaste is incomplete; recovery journal preserved at '
      .. state.transaction_path .. '; inspect the affected paths before retrying'
    M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
    return nil, message
  end
  if transaction.steps then
    if transaction.next_step == 1
      and recovery.move_step_status(transaction.steps[1]) == 'not-started' then
      return clear_transaction(state.transaction_path)
    end
    local message = 'grouped filesystem action is incomplete; recovery journal preserved at '
      .. state.transaction_path .. '; inspect the affected paths before retrying'
    M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
    return nil, message
  end
  local outcome = recovery.reverse_operation_status(transaction)
  if outcome == 'not-started' then
    return clear_transaction(state.transaction_path)
  end
  local message = 'failed ' .. transaction.direction .. ' left an ambiguous filesystem state; '
    .. 'recovery journal preserved at ' .. state.transaction_path
    .. '; inspect the affected paths before retrying'
  M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
  return nil, message
end

clear_transaction = function(transaction_path)
  local removed, remove_err = M.lock.uv.fs_unlink(transaction_path)
  if not removed then return nil, tostring(remove_err or 'could not clear history transaction') end
  return log_mod.sync_parent(transaction_path)
end

-- The transaction file is a write-ahead snapshot for the two history stacks.
-- Replaying it is idempotent, so a crash between either stack rename and journal
-- removal completes the same paired update on the next history access.
local function recover_transaction(undo_path, redo_path, transaction_path)
  local bytes, read_err, exists = log_mod.read_raw(transaction_path)
  if read_err then return nil, read_err end
  if not exists then return true end
  local transaction = parse_transaction(bytes)
  if not transaction then
    local message = 'history recovery journal is malformed; preserved at '
      .. transaction_path .. ' for manual inspection'
    M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
    return nil, message
  end
  if transaction.kind == 'paste' then
    return recovery.recover_paste_transaction(transaction, undo_path, redo_path,
      transaction_path)
  end
  if transaction.kind == 'unpaste' then
    if transaction.phase == 'preflight' then
      return clear_transaction(transaction_path)
    end
    local finished, finish_err = recovery.finish_unpaste_transaction(transaction,
      undo_path, redo_path, transaction_path)
    if not finished then
      local message = 'interrupted Unpaste is ambiguous or incomplete; '
        .. 'recovery journal preserved at ' .. transaction_path .. ' ('
        .. tostring(finish_err) .. ')'
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    return true
  end
  if transaction.kind == 'reverse' or transaction.kind == 'apply' then
    if transaction.steps then
      local completed, step_err = recovery.complete_move_steps(transaction, transaction_path)
      if not completed then
        local message = 'interrupted grouped move is ambiguous or incomplete; '
          .. 'recovery journal preserved at ' .. transaction_path .. ' ('
          .. tostring(step_err) .. ')'
        M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
        return nil, message
      end
      local committed, commit_err = commit_stacks(undo_path, redo_path,
        transaction_path, transaction.undo, transaction.redo)
      if not committed then return nil, commit_err end
      return true
    end
    local status = recovery.reverse_operation_status(transaction)
    if status == 'ambiguous' then
      local operation = transaction.kind == 'apply' and 'filesystem action'
        or transaction.direction
      local message = 'interrupted ' .. operation
        .. ' is ambiguous; recovery journal preserved at ' .. transaction_path
        .. '; inspect the affected paths before retrying'
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    if status == 'not-started' then
      local action, action_err = M.action.deserialize(transaction.action)
      if not action then
        return nil, 'recovery journal action is invalid: ' .. tostring(action_err)
      end
      local called, result, execute_err = pcall(M.action.execute, action)
      if not called or result == nil then
        status = recovery.reverse_operation_status(transaction)
        if status == 'not-started' then return clear_transaction(transaction_path) end
        local operation = transaction.kind == 'apply' and 'filesystem action'
          or transaction.direction
        local message = 'automatic ' .. operation .. ' recovery failed; journal '
          .. 'preserved at ' .. transaction_path .. ' ('
          .. tostring(called and execute_err or result) .. ')'
        M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
        return nil, message
      end
    end
    local ok, err = commit_stacks(undo_path, redo_path, transaction_path,
      transaction.undo, transaction.redo)
    if not ok then return nil, err end
    return true
  end
  local ok, err = write_stack(undo_path, transaction.undo)
  if not ok then return nil, err end
  ok, err = write_stack(redo_path, transaction.redo)
  if not ok then return nil, err end
  return clear_transaction(transaction_path)
end

commit_stacks = function(undo_path, redo_path, transaction_path, undo_lines, redo_lines)
  local ok, err = log_mod.write_raw_atomic(transaction_path,
    transaction_codec.stack_bytes(undo_lines, redo_lines))
  if not ok then return nil, err end
  ok, err = write_stack(undo_path, undo_lines)
  if not ok then return nil, err end
  ok, err = write_stack(redo_path, redo_lines)
  if not ok then return nil, err end
  return clear_transaction(transaction_path)
end

recovery = require('direct.history.recovery').new({
  action = M.action,
  header = M.HEADER,
  ui = M.ui,
  identity_paths_equal = identity_paths_equal,
  write_transaction = write_operation_transaction,
  clear_transaction = clear_transaction,
  commit_stacks = commit_stacks,
})

copy_lines = function(lines)
  local result = {}
  for i, line in ipairs(lines) do result[i] = line end
  return result
end

-- preflight(paths) validates user inputs, recovers any journal, then classifies
-- BOTH history stacks from raw bytes. Unsupported formats are silently reset;
-- unreadable files and ambiguous recovery states fail closed.
local function preflight_locked(user_paths)
  local valid, validation_err = validate_user_paths(user_paths)
  if not valid then
    M.ui.notify('direct: refusing operation: ' .. tostring(validation_err),
      vim.log.levels.ERROR)
    return nil, validation_err
  end

  local undo_path, redo_path, transaction_path = log_paths()
  local recovered, recover_err = recover_transaction(undo_path, redo_path, transaction_path)
  if not recovered then
    notify_unavailable(recover_err)
    return nil, recover_err
  end
  local undo_state = classify_path(undo_path)
  local redo_state = classify_path(redo_path)
  for _, entry in ipairs({
    { path = undo_path, state = undo_state },
    { path = redo_path, state = redo_state },
  }) do
    if entry.state.state == 'preserve' then
      return notify_preserved(entry.path, entry.state.reason)
    end
  end

  local entries = {
    { path = undo_path, state = undo_state },
    { path = redo_path, state = redo_state },
  }
  local has_legacy = undo_state.state == 'legacy' or redo_state.state == 'legacy'
  if has_legacy then
    local dir, dir_err = M.paths.ensure_data_dir('history')
    if not dir then
      notify_unavailable(dir_err)
      return nil, dir_err
    end
    -- Back up both existing non-empty stacks before a paired reset so even a
    -- valid sibling stack is recoverable if the other one is from an old format.
    local backup_entries = {}
    for _, entry in ipairs(entries) do
      backup_entries[#backup_entries + 1] = {
        path = entry.path, bytes = entry.state.bytes,
      }
    end
    local backups, backup_err = backup_history_files(backup_entries)
    if not backups then
      notify_unavailable('could not back up legacy history: ' .. tostring(backup_err))
      return nil, backup_err
    end
    local ok, err = reset_stacks(undo_path, redo_path, transaction_path)
    if not ok then
      notify_unavailable(err)
      return nil, err
    end
    undo_state.lines, redo_state.lines = { M.HEADER }, { M.HEADER }
    local warning = #backups > 0
      and ('; backup: ' .. table.concat(backups, ', ')) or ''
    M.ui.notify('direct: recognized legacy history was backed up and reset' .. warning,
      vim.log.levels.WARN)
  else
    local initialized = false
    for _, entry in ipairs(entries) do
      if entry.state.state == 'fresh' then initialized = true; break end
    end
    if initialized then
      local dir, dir_err = M.paths.ensure_data_dir('history')
      if not dir then
        notify_unavailable(dir_err)
        return nil, dir_err
      end
      for _, entry in ipairs(entries) do
        if entry.state.state == 'fresh' then
          local ok, err = write_stack(entry.path, { M.HEADER })
          if not ok then
            notify_unavailable(err)
            return nil, err
          end
          entry.state.lines = { M.HEADER }
        end
      end
    end
  end

  return {
    undo_path = undo_path,
    redo_path = redo_path,
    transaction_path = transaction_path,
    undo_lines = undo_state.lines,
    redo_lines = redo_state.lines,
  }
end

function M.preflight(user_paths)
  -- Validate before creating the lock/data directory, preserving preflight's
  -- no-side-effect contract for invalid caller paths.
  local valid, validation_err = validate_user_paths(user_paths)
  if not valid then
    M.ui.notify('direct: refusing operation: ' .. tostring(validation_err),
      vim.log.levels.ERROR)
    return nil, validation_err
  end
  return M.with_lock(function()
    return preflight_locked(user_paths)
  end)
end

-- reset_history() intentionally replaces the undo and redo stacks, but first
-- preserves every readable non-empty log byte-for-byte in a unique backup.
local function reset_history_locked()
  local undo_path, redo_path, transaction_path = log_paths()
  local recovered, recover_err = recover_transaction(undo_path, redo_path, transaction_path)
  if not recovered then
    notify_unavailable(recover_err)
    return nil, recover_err
  end

  local entries = {
    { path = undo_path, state = classify_path(undo_path) },
    { path = redo_path, state = classify_path(redo_path) },
  }
  for _, entry in ipairs(entries) do
    if entry.state.read_error then
      return notify_preserved(entry.path, entry.state.reason)
    end
  end

  local dir, dir_err = M.paths.ensure_data_dir('history')
  if not dir then
    notify_unavailable(dir_err)
    return nil, dir_err
  end
  local backup_entries = {}
  for _, entry in ipairs(entries) do
    backup_entries[#backup_entries + 1] = {
      path = entry.path, bytes = entry.state.bytes,
    }
  end
  local backups, backup_err = backup_history_files(backup_entries)
  if not backups then
    notify_unavailable('could not back up history: ' .. tostring(backup_err))
    return nil, backup_err
  end

  local reset, reset_err = reset_stacks(undo_path, redo_path, transaction_path)
  if not reset then
    notify_unavailable(reset_err)
    return nil, reset_err
  end
  if #backups > 0 then
    M.ui.notify('direct: history reset; backups: ' .. table.concat(backups, ', '),
      vim.log.levels.INFO)
  else
    M.ui.notify('direct: history reset; no history files needed backup',
      vim.log.levels.INFO)
  end
  return true, backups
end

function M.reset_history()
  return M.with_lock(reset_history_locked)
end

local function action_paths(action)
  local result = {}
  local function visit(current)
    if type(current) ~= 'table' then return end
    if type(current.src) == 'string' then result[#result + 1] = current.src end
    if type(current.dst) == 'string' then result[#result + 1] = current.dst end
    for _, member in ipairs(current.actions or {}) do visit(member) end
  end
  if type(action) == 'table' then
    visit(action)
  end
  return result
end

local function trash_references(state)
  local references = {}
  local function add(path)
    if type(path) == 'string' and path ~= '' then
      references[M.paths.canonical(path)] = true
    end
  end
  local function visit(action)
    if type(action) ~= 'table' then return end
    if action.name == 'g' or action.name == 'batch' then
      for _, member in ipairs(action.actions or {}) do visit(member) end
    elseif action.name == 'rm' or action.name == 'rmdir' then
      add(action.dst)
    elseif action.name == 'rs' or action.name == 'rsdir' then
      add(action.src)
    end
  end
  for _, lines in ipairs({ state.undo_lines, state.redo_lines }) do
    for index = 2, #lines do
      local action = M.action.deserialize(lines[index])
      if action then visit(action) end
    end
  end
  return references
end

-- Run a trash operation while holding the history lock and with a verified
-- snapshot of every undo/redo reference to trash paths.
function M.with_trash_references(callback)
  if type(callback) ~= 'function' then
    return nil, 'history.with_trash_references: callback is required'
  end
  return M.with_lock(function()
    local state, err = preflight_locked()
    if not state then return nil, err end
    return callback(trash_references(state), state)
  end)
end

-- Paths changed on disk by a reversal, excluding the private trash/register
-- storage roots. These are the paths shown in the confirmation before an
-- operation that is outside the current listing.
local function affected_paths(action, result)
  result = result or {}
  if type(action) ~= 'table' then return result end
  local function add(path)
    if type(path) ~= 'string' or path == '' then return end
    for _, existing in ipairs(result) do
      if M.paths.canonical(existing) == M.paths.canonical(path) then return end
    end
    result[#result + 1] = path
  end
  local name = action.name
  if name == 'g' or name == 'batch' then
    for _, member in ipairs(action.actions or {}) do
      affected_paths(member, result)
    end
  elseif name == 'mv' then
    add(action.src)
    add(action.dst)
  elseif name == 'rm' or name == 'rmdir' then
    add(action.src)
  elseif name == 'rs' or name == 'rsdir' then
    add(action.dst)
  elseif name == 'touch' or name == 'mkdir' then
    add(action.dst)
  elseif name == 'p' then
    if #(action.renames or {}) == 0 then add(action.dst) end
    for _, pair in ipairs(action.renames or {}) do
      add(M.action.fs.join(action.dst, pair.dst))
    end
  elseif name == 'up' then
    if #(action.renames or {}) == 0 then add(action.src) end
    for _, pair in ipairs(action.renames or {}) do
      add(M.action.fs.join(action.src, pair.src))
    end
  else
    add(action.src)
    add(action.dst)
  end
  return result
end

-- preview_reverse(which) reads the current top action without applying it. The
-- returned record can be passed back to _reverse_async as expected_record so a
-- confirmation can never approve one action and execute a different one.
function M.preview_reverse(which)
  if which ~= 'undo' and which ~= 'redo' then
    return nil, 'history.preview_reverse: expected undo or redo'
  end
  local state, preflight_err = M.preflight()
  if not state then return nil, preflight_err end
  local lines = which == 'undo' and state.undo_lines or state.redo_lines
  if #lines <= 1 then return { empty = true } end
  local record = lines[#lines]
  local reversal, reverse_err = M.action.reverse(record)
  if not reversal then return nil, reverse_err end
  return {
    record = record,
    action = reversal,
    summary = M.action.summarize({ reversal }),
    paths = affected_paths(reversal),
  }
end

-- apply(action, execute) runs one synchronous filesystem action and commits its
-- history while holding the process lock for the entire critical section. The
-- durable intent journal supports restart recovery; keeping
-- the lock across execute prevents it from replaying that intent concurrently.
function M.apply(action, execute, preflight_guard)
  if type(action) ~= 'table' then
    return nil, 'history.apply: an action is required'
  end
  if type(execute) ~= 'function' then
    return nil, 'history.apply: an executor is required'
  end
  local record, serialize_err = M.action.serialize(action)
  if not record then return nil, serialize_err end

  return M.with_lock(function()
    local state, preflight_err = preflight_locked(action_paths(action))
    if not state then return nil, preflight_err end
    if type(preflight_guard) == 'function' then
      local allowed, guard_err = preflight_guard(state, trash_references(state))
      if not allowed then return nil, guard_err end
    end

    local transaction, transaction_err = write_apply_intent(state, action, record)
    if transaction == false then
      notify_unavailable(transaction_err)
      return nil, transaction_err
    end

    local called, result, execute_err
    if transaction and transaction.steps then
      called = true
      result, execute_err = recovery.complete_move_steps(transaction, state.transaction_path)
    else
      called, result, execute_err = pcall(execute)
    end
    if not called or result == nil then
      local why = not called and tostring(result)
        or tostring(execute_err or 'action failed')
      if transaction then
        if transaction.steps then
          if transaction.next_step == 1
            and recovery.move_step_status(transaction.steps[1]) == 'not-started' then
            clear_transaction(state.transaction_path)
          else
            why = why .. '; grouped move recovery journal preserved at '
              .. state.transaction_path
          end
        else
          local status = recovery.reverse_operation_status(transaction)
          if status == 'not-started' then
            clear_transaction(state.transaction_path)
          elseif status == 'completed' then
            local committed, commit_err = commit_stacks(state.undo_path,
              state.redo_path, state.transaction_path,
              transaction.undo, transaction.redo)
            if not committed then why = why .. '; ' .. tostring(commit_err) end
          else
            why = why .. '; filesystem outcome is ambiguous; recovery journal preserved at '
              .. state.transaction_path
          end
        end
      end
      return nil, why
    end

    local undo_lines, redo_lines
    if transaction then
      undo_lines, redo_lines = transaction.undo, transaction.redo
    else
      undo_lines = copy_lines(state.undo_lines)
      undo_lines[#undo_lines + 1] = record
      redo_lines = { M.HEADER }
    end
    local committed, commit_err = commit_stacks(state.undo_path, state.redo_path,
      state.transaction_path, undo_lines, redo_lines)
    if not committed then
      return nil, 'action completed but history commit is pending recovery: '
        .. tostring(commit_err)
    end
    return result
  end)
end

-- apply_async keeps the same process lock and durable intent across an
-- asynchronous filesystem executor. The callback receives result, err.
function M.apply_async(action, execute_async, callback, preflight_guard)
  if type(action) ~= 'table' then return nil, 'history.apply_async: an action is required' end
  if type(execute_async) ~= 'function' then
    return nil, 'history.apply_async: an executor is required'
  end
  if type(callback) ~= 'function' then
    return nil, 'history.apply_async: a completion callback is required'
  end
  local record, serialize_err = M.action.serialize(action)
  if not record then return nil, serialize_err end

  local acquired, acquire_err = M.lock.acquire()
  if not acquired then
    notify_unavailable(acquire_err)
    return nil, acquire_err
  end
  local called, state, preflight_err = xpcall(function()
    return preflight_locked(action_paths(action))
  end, debug.traceback)
  if not called or not state then
    M.lock.release()
    return nil, called and preflight_err or state
  end
  if type(preflight_guard) == 'function' then
    local guard_ok, allowed, guard_err = pcall(preflight_guard, state, trash_references(state))
    if not guard_ok or not allowed then
      M.lock.release()
      return nil, guard_ok and guard_err or allowed
    end
  end

  local transaction, transaction_err = write_apply_intent(state, action, record)
  if transaction == false then
    M.lock.release()
    notify_unavailable(transaction_err)
    return nil, transaction_err
  end

  local finished = false
  local function finish(result, execute_err)
    if finished then return end
    finished = true
    local final_result, final_err = result, execute_err

    if result == nil then
      local why = tostring(execute_err or 'action failed')
      if transaction then
        if transaction.steps then
          if transaction.next_step == 1
            and recovery.move_step_status(transaction.steps[1]) == 'not-started' then
            clear_transaction(state.transaction_path)
          else
            why = why .. '; grouped move recovery journal preserved at '
              .. state.transaction_path
          end
        else
          local status = recovery.reverse_operation_status(transaction)
          if status == 'not-started' then
            clear_transaction(state.transaction_path)
          elseif status == 'completed' then
            local committed, commit_err = commit_stacks(state.undo_path,
              state.redo_path, state.transaction_path,
              transaction.undo, transaction.redo)
            if not committed then why = why .. '; ' .. tostring(commit_err) end
          else
            why = why .. '; filesystem outcome is ambiguous; recovery journal preserved at '
              .. state.transaction_path
          end
        end
      end
      final_err = why
    else
      local undo_lines, redo_lines
      if transaction then
        undo_lines, redo_lines = transaction.undo, transaction.redo
      else
        undo_lines = copy_lines(state.undo_lines)
        undo_lines[#undo_lines + 1] = record
        redo_lines = { M.HEADER }
      end
      local committed, commit_err = commit_stacks(state.undo_path, state.redo_path,
        state.transaction_path, undo_lines, redo_lines)
      if not committed then
        final_result = nil
        final_err = 'action completed but history commit is pending recovery: '
          .. tostring(commit_err)
      end
    end

    local released, release_err = M.lock.release()
    if not released then
      notify_unavailable('could not release history lock: ' .. tostring(release_err))
      if final_result ~= nil then
        final_result = nil
        final_err = 'action completed but the history lock could not be released: '
          .. tostring(release_err)
      end
    end
    local callback_ok, callback_err = pcall(callback, final_result, final_err)
    if not callback_ok then
      M.ui.report_error('finish asynchronous history action', callback_err)
    end
  end

  if transaction and transaction.steps then
    recovery.complete_move_steps_async(transaction, state.transaction_path,
      function(result, execute_err) finish(result, execute_err) end)
    return true
  end

  local started, start_err = pcall(execute_async, function(ok, result, execute_err)
    if ok and result ~= nil then finish(result, nil)
    else finish(nil, execute_err or result or 'action failed') end
  end)
  if not started then finish(nil, start_err) end
  return true
end

local function write_paste_journal(operation)
  local called, ok, err = pcall(function()
    return log_mod.write_raw_atomic(operation.transaction_path,
      vim.json.encode(operation.transaction) .. '\n')
  end)
  if not called then return nil, tostring(ok) end
  if not ok then return nil, err end
  return true
end

local function release_paste_lock(operation)
  if not operation.locked then return true end
  operation.locked = false
  return M.lock.release()
end

-- begin_paste holds the same-host history lock until finish_paste. The initial
-- journal is durable before the async executor can create its first destination.
function M.begin_paste(action)
  if type(action) ~= 'table' or action.name ~= 'p' then
    return nil, 'history.begin_paste: a Paste action is required'
  end
  local record, serialize_err = M.action.serialize(action)
  if not record then return nil, serialize_err end
  local acquired, acquire_err = M.lock.acquire()
  if not acquired then
    notify_unavailable(acquire_err)
    return nil, acquire_err
  end
  local called, state, preflight_err = xpcall(function()
    return preflight_locked(action_paths(action))
  end, debug.traceback)
  if not called or not state then
    M.lock.release()
    return nil, called and preflight_err or state
  end
  local transaction = {
    format = TRANSACTION_FORMAT,
    version = TRANSACTION_VERSION,
    kind = 'paste',
    direction = 'apply',
    action = record,
    source_action = vim.NIL,
    base_undo = copy_lines(state.undo_lines),
    base_redo = copy_lines(state.redo_lines),
    completed = {},
    pending = vim.NIL,
  }
  local operation = {
    transaction = transaction,
    transaction_path = state.transaction_path,
    undo_path = state.undo_path,
    redo_path = state.redo_path,
    locked = true,
  }
  local written, write_err = write_paste_journal(operation)
  if not written then
    release_paste_lock(operation)
    notify_unavailable(write_err)
    return nil, write_err
  end
  return operation
end

function M.note_paste_pending(operation, pair, source, destination)
  if type(operation) ~= 'table' or not operation.locked
    or type(pair) ~= 'table' or type(source) ~= 'string'
    or type(destination) ~= 'string' then
    return nil, 'invalid pending paste update'
  end
  if M.action.entry_name_reason(pair.src) or M.action.entry_name_reason(pair.dst) then
    return nil, 'invalid paste entry name'
  end
  local source_identity, source_stat = M.action.fs.entry_identity(source)
  if not source_stat or not source_identity or not source_identity.inode then
    return nil, 'cannot identify paste source: ' .. source
  end
  local previous = operation.transaction.pending
  if previous ~= vim.NIL then return nil, 'another paste entry is already pending' end
  operation.transaction.pending = {
    src = pair.src,
    dst = pair.dst,
    source = M.paths.canonical(source),
    destination = M.paths.canonical(destination),
    source_identity = source_identity,
  }
  local written, write_err = write_paste_journal(operation)
  if not written then
    operation.transaction.pending = previous
    return nil, write_err
  end
  return true
end

function M.note_paste_complete(operation, pair)
  if type(operation) ~= 'table' or not operation.locked
    or type(pair) ~= 'table' then
    return nil, 'invalid completed paste update'
  end
  local transaction = operation.transaction
  local pending = transaction.pending
  if type(pending) ~= 'table' or pending.src ~= pair.src or pending.dst ~= pair.dst then
    return nil, 'completed paste entry does not match its durable intent'
  end
  transaction.completed[#transaction.completed + 1] = { src = pair.src, dst = pair.dst }
  transaction.pending = vim.NIL
  local written, write_err = write_paste_journal(operation)
  if not written then
    table.remove(transaction.completed)
    transaction.pending = pending
    return nil, write_err
  end
  return true
end

function M.cancel_paste_pending(operation, pair)
  if type(operation) ~= 'table' or not operation.locked then
    return nil, 'paste history operation is not active'
  end
  local transaction = operation.transaction
  local pending = transaction.pending
  if type(pending) ~= 'table' or pending.src ~= pair.src or pending.dst ~= pair.dst then
    return nil, 'paste conflict does not match the pending destination'
  end
  transaction.pending = vim.NIL
  local written, write_err = write_paste_journal(operation)
  if not written then
    transaction.pending = pending
    return nil, write_err
  end
  return true
end

function M.finish_paste(operation)
  if type(operation) ~= 'table' or not operation.locked then
    return nil, 'paste history operation is not active'
  end
  local called, result, result_err = xpcall(function()
    local completed, settle_err = recovery.settle_paste_pending(operation.transaction)
    if not completed then return nil, settle_err end
    if #completed == 0 then return clear_transaction(operation.transaction_path) end
    local undo, redo, stack_err = recovery.paste_stack_snapshot(
      operation.transaction, completed)
    if not undo then return nil, stack_err end
    return commit_stacks(operation.undo_path, operation.redo_path,
      operation.transaction_path, undo, redo)
  end, debug.traceback)
  if not called then
    result, result_err = nil, result
  end
  local released, release_err = release_paste_lock(operation)
  if result and not released then return nil, release_err end
  if not result then return nil, result_err end
  return true
end

-- log(action) appends one action and clears redo through a recoverable paired
-- stack transaction.
local function log_locked(action)
  if type(action) ~= 'table' then
    return nil, 'history.log: an action is required'
  end
  local record, serialize_err = M.action.serialize(action)
  if not record then
    M.ui.notify('direct: cannot write history: ' .. tostring(serialize_err),
      vim.log.levels.ERROR)
    return nil, serialize_err
  end
  local state, preflight_err = M.preflight(action_paths(action))
  if not state then
    return nil, preflight_err
  end
  local undo_lines = copy_lines(state.undo_lines)
  undo_lines[#undo_lines + 1] = record
  local ok, err = commit_stacks(state.undo_path, state.redo_path,
    state.transaction_path, undo_lines, { M.HEADER })
  if not ok then
    M.ui.notify('direct: cannot write history: ' .. tostring(err),
      vim.log.levels.ERROR)
    return nil, err
  end
  return true
end

function M.log(action)
  return M.with_lock(function()
    return log_locked(action)
  end)
end

-- Replace the most recently logged independent actions with one durable batch
-- record. Sync holds the process lock across execution and calls this only after
-- every member has already committed its ordinary journaled history entry.
function M.combine_recent(actions, stack_name)
  if type(actions) ~= 'table' or #actions < 2 then
    return nil, 'history.combine_recent: at least two actions are required'
  end
  stack_name = stack_name or 'undo'
  if stack_name ~= 'undo' and stack_name ~= 'redo' then
    return nil, "history.combine_recent: stack must be 'undo' or 'redo'"
  end
  local batch = M.action.Batch(actions)
  local batch_record, serialize_err = M.action.serialize(batch)
  if not batch_record then return nil, serialize_err end

  return M.with_lock(function()
    local state, preflight_err = preflight_locked()
    if not state then return nil, preflight_err end
    local source = stack_name == 'undo' and state.undo_lines or state.redo_lines
    local next_source = copy_lines(source)
    local first = #next_source - #actions + 1
    if first <= 1 then
      return nil, 'the recent history entries changed before they could be grouped'
    end
    local records = {}
    for index, action in ipairs(actions) do
      local record, err = M.action.serialize(action)
      if not record then return nil, err end
      records[index] = record
      if next_source[first + index - 1] ~= record then
        return nil, 'the recent history entries changed before they could be grouped'
      end
    end
    for _ = 1, #records do table.remove(next_source) end
    next_source[#next_source + 1] = batch_record
    local next_undo = stack_name == 'undo' and next_source or copy_lines(state.undo_lines)
    local next_redo = stack_name == 'redo' and next_source or copy_lines(state.redo_lines)
    local committed, commit_err = commit_stacks(state.undo_path, state.redo_path,
      state.transaction_path, next_undo, next_redo)
    if not committed then return nil, commit_err end
    return true
  end)
end

function M.undo()
  return M._reverse('undo')
end

function M.redo()
  return M._reverse('redo')
end

-- Keep the source record durable while the filesystem action runs. The paired
-- stack commit happens only after success, so a failed action (or a crash before
-- it starts) cannot lose its undo record.
local function reverse_locked(which)
  if M.pending.refuse(which) then return nil, 'another direct operation is pending' end
  local state, preflight_err = M.preflight()
  if not state then
    return nil, preflight_err
  end
  local src_path, dst_path, src_lines, dst_lines
  if which == 'undo' then
    src_path, dst_path = state.undo_path, state.redo_path
    src_lines, dst_lines = state.undo_lines, state.redo_lines
  elseif which == 'redo' then
    src_path, dst_path = state.redo_path, state.undo_path
    src_lines, dst_lines = state.redo_lines, state.undo_lines
  else
    return nil, 'history._reverse: expected undo or redo'
  end
  if #src_lines > 1 then
    local top = M.action.deserialize(src_lines[#src_lines])
    if top and top.name == 'batch' then
      local expanded, expand_err = expand_batch_stack(which, src_lines[#src_lines])
      if not expanded then return nil, expand_err end
      local reversed = {}
      for _ = 1, #expanded do
        local result, reverse_err = reverse_locked(which)
        if result == nil then return nil, reverse_err end
        reversed[#reversed + 1] = result
      end
      local compacted, compact_err = M.combine_recent(reversed,
        which == 'undo' and 'redo' or 'undo')
      if not compacted then
        M.ui.notify('direct: history operation completed, but its entries could not '
          .. 'be grouped: ' .. tostring(compact_err), vim.log.levels.WARN)
      end
      return M.action.Batch(reversed)
    end
  end
  if #src_lines <= 1 then
    M.ui.notify(which == 'undo' and 'Nothing to undo' or 'Nothing to redo',
      vim.log.levels.INFO)
    return nil
  end

  local record = src_lines[#src_lines]
  local reversal, reverse_err = M.action.reverse(record)
  if not reversal then
    M.ui.notify('Failed to ' .. which .. ' action - ' .. tostring(reverse_err),
      vim.log.levels.ERROR)
    return nil, reverse_err
  end

  local files, paths = {}, {}
  rename_files(reversal, files, paths)
  if #files > 0 and #file_operations.clients('workspace/willRenameFiles', paths) > 0 then
    -- Preserve the synchronous no-client path, but route a real LSP rename
    -- through the same guarded async preflight used by Direct's public commands.
    return M._reverse_async(which, nil)
  end

  local inverse, serialize_err = M.action.serialize(reversal)
  if not inverse then
    M.ui.notify('Failed to ' .. which .. ' action - cannot serialize reversal: '
      .. tostring(serialize_err), vim.log.levels.ERROR)
    return nil, serialize_err
  end

  local reverse_transaction, transaction_err = write_reverse_intent(
    state, which, reversal, inverse)
  if reverse_transaction == false then
    M.ui.notify('Failed to ' .. which .. ' action - cannot write recovery journal: '
      .. tostring(transaction_err), vim.log.levels.ERROR)
    return nil, transaction_err
  end

  if reverse_transaction and reverse_transaction.kind == 'unpaste' then
    attach_unpaste_journal(reversal, reverse_transaction, state.transaction_path)
  end

  local ran, result, execute_err
  if reverse_transaction and reverse_transaction.steps then
    ran = true
    result, execute_err = recovery.complete_move_steps(reverse_transaction,
      state.transaction_path)
  else
    ran, result, execute_err = pcall(M.action.execute, reversal)
  end
  if not ran or result == nil then
    if reversal.name == 'g' and #(reversal._completed_actions or {}) > 0
      or reversal.name == 'up' and #(reversal._completed_renames or {}) > 0 then
      file_operations.emit_actions({ reversal })
    end
    local settled, recovery_err = settle_failed_reverse(state, reverse_transaction)
    local why = not ran and tostring(result)
      or (execute_err ~= nil and tostring(execute_err) or 'action failed')
    if not settled then why = why .. '; ' .. tostring(recovery_err) end
    M.ui.notify('Failed to ' .. which .. ' action - '
      .. M.action.summarize({ reversal }) .. ' (' .. why .. ')',
      vim.log.levels.ERROR)
    return nil, why
  end

  file_operations.emit_actions({ reversal })

  local next_src, next_dst = copy_lines(src_lines), copy_lines(dst_lines)
  table.remove(next_src)
  next_dst[#next_dst + 1] = inverse
  local next_undo, next_redo = which == 'undo' and next_src or next_dst,
    which == 'undo' and next_dst or next_src
  local appended, append_err = commit_stacks(state.undo_path, state.redo_path,
    state.transaction_path, next_undo, next_redo)
  if not appended then
    M.ui.notify('Failed to ' .. which .. ' action - cannot write history: '
      .. tostring(append_err), vim.log.levels.ERROR)
  end
  M.ui.notify(M.action.summarize({ reversal }), vim.log.levels.INFO)
  return reversal
end

function M._reverse(which)
  return M.with_lock(function()
    return reverse_locked(which)
  end)
end

local function finish_callback(callback, result, err)
  if type(callback) ~= 'function' then return end
  local ok, callback_err = pcall(callback, result, err)
  if not ok then
    M.ui.notify('direct: history completion callback failed: '
      .. tostring(callback_err), vim.log.levels.ERROR)
  end
end

expand_batch_stack = function(which, expected_record)
  return M.with_lock(function()
    local state, preflight_err = preflight_locked()
    if not state then return nil, preflight_err end
    local source_lines = which == 'undo' and state.undo_lines or state.redo_lines
    if source_lines[#source_lines] ~= expected_record then
      return nil, 'history changed before the batch operation started'
    end
    local batch, decode_err = M.action.deserialize(expected_record)
    if not batch or batch.name ~= 'batch' then
      return nil, decode_err or 'history batch is malformed'
    end
    local member_records = {}
    for _, member in ipairs(batch.actions) do
      local record, serialize_err = M.action.serialize(member)
      if not record then return nil, serialize_err end
      member_records[#member_records + 1] = record
    end
    local next_source = copy_lines(source_lines)
    table.remove(next_source)
    vim.list_extend(next_source, member_records)
    local next_undo = which == 'undo' and next_source or copy_lines(state.undo_lines)
    local next_redo = which == 'redo' and next_source or copy_lines(state.redo_lines)
    local committed, commit_err = commit_stacks(state.undo_path, state.redo_path,
      state.transaction_path, next_undo, next_redo)
    if not committed then return nil, commit_err end
    return member_records
  end)
end

function M.undo_async(callback, options)
  return M._reverse_async('undo', callback, options)
end

function M.redo_async(callback, options)
  return M._reverse_async('redo', callback, options)
end

function M._reverse_async(which, callback, options)
  options = options or {}
  local token = options.pending_token
  if token and not M.pending.is_active(token) then
    finish_callback(callback, nil, 'pending history operation was canceled')
    return nil, 'pending history operation was canceled'
  end
  if not token and M.pending.refuse(which) then
    return nil, 'another direct operation is pending'
  end
  local state, preflight_err = M.preflight()
  if not state then
    if token then M.pending.finish(token) end
    finish_callback(callback, nil, preflight_err)
    return nil, preflight_err
  end
  local src_path, dst_path, src_lines, dst_lines
  if which == 'undo' then
    src_path, dst_path = state.undo_path, state.redo_path
    src_lines, dst_lines = state.undo_lines, state.redo_lines
  elseif which == 'redo' then
    src_path, dst_path = state.redo_path, state.undo_path
    src_lines, dst_lines = state.redo_lines, state.undo_lines
  else
    if token then M.pending.finish(token) end
    return nil, 'history._reverse_async: expected undo or redo'
  end
  if #src_lines <= 1 then
    M.ui.notify(which == 'undo' and 'Nothing to undo' or 'Nothing to redo',
      vim.log.levels.INFO)
    if token then M.pending.finish(token) end
    finish_callback(callback, nil, nil)
    return nil
  end

  local record = src_lines[#src_lines]
  if options.expected_record and record ~= options.expected_record then
    local why = 'history changed while waiting for LSP willRenameFiles'
    M.ui.notify('Failed to ' .. which .. ' action - ' .. why, vim.log.levels.WARN)
    if token then M.pending.finish(token) end
    finish_callback(callback, nil, why)
    return nil, why
  end
  local decoded = M.action.deserialize(record)
  if decoded and decoded.name == 'batch' then
    if not options.skip_will then
      local reversal, reverse_err = M.action.reverse(record)
      if not reversal then
        finish_callback(callback, nil, reverse_err)
        return nil, reverse_err
      end
      local files, paths = {}, {}
      rename_files(reversal, files, paths)
      if #files > 0 and #file_operations.clients('workspace/willRenameFiles', paths) > 0 then
        local began, batch_token = M.pending.begin('willRenameFiles')
        if not began then
          finish_callback(callback, nil, 'another direct operation is pending')
          return nil, 'another direct operation is pending'
        end
        file_operations.will_rename(files, function(ok, suppressed_or_err)
          if not ok then
            M.ui.notify('Failed to ' .. which .. ' after LSP WorkspaceEdit failure '
              .. '(earlier server edits may already have applied): '
              .. tostring(suppressed_or_err), vim.log.levels.ERROR)
            M.pending.finish(batch_token)
            finish_callback(callback, nil, suppressed_or_err)
            return
          end
          M.pending.finish(batch_token)
          M._reverse_async(which, callback, {
            expected_record = record,
            skip_will = true,
            suppressed = suppressed_or_err,
          })
        end, nil, function() return M.pending.is_active(batch_token) end)
        return true
      end
    end
    if token then
      M.pending.finish(token)
      finish_callback(callback, nil, 'cannot start a history batch while another operation is pending')
      return nil, 'cannot start a history batch while another operation is pending'
    end
    local member_records, expand_err = expand_batch_stack(which, record)
    if not member_records then
      finish_callback(callback, nil, expand_err)
      return nil, expand_err
    end
    local index, results = #member_records, {}
    local function next_member()
      if index < 1 then
        local compacted, compact_err = M.combine_recent(results,
          which == 'undo' and 'redo' or 'undo')
        if not compacted then
          M.ui.notify('direct: history operation completed, but its entries could not '
            .. 'be grouped: ' .. tostring(compact_err), vim.log.levels.WARN)
        end
        finish_callback(callback, M.action.Batch(results), nil)
        return
      end
      local expected = member_records[index]
      index = index - 1
      M._reverse_async(which, function(result, reverse_err)
        if result == nil or reverse_err ~= nil then
          local completed = #results > 0 and M.action.Batch(results) or nil
          finish_callback(callback, completed, reverse_err)
          return
        end
        results[#results + 1] = result
        next_member()
      end, {
        expected_record = expected,
        skip_will = options.skip_will,
        suppressed = options.suppressed,
      })
    end
    next_member()
    return true
  end
  local reversal, reverse_err = M.action.reverse(record)
  if not reversal then
    M.ui.notify('Failed to ' .. which .. ' action - ' .. tostring(reverse_err),
      vim.log.levels.ERROR)
    if token then M.pending.finish(token) end
    finish_callback(callback, nil, reverse_err)
    return nil, reverse_err
  end

  local files, paths = {}, {}
  rename_files(reversal, files, paths)
  if not token and not options.skip_will and #files > 0
    and #file_operations.clients('workspace/willRenameFiles', paths) > 0 then
    local began, begin_token = M.pending.begin('willRenameFiles')
    if not began then
      M.ui.notify('direct: cannot ' .. which .. ': another operation is pending',
        vim.log.levels.WARN)
      finish_callback(callback, nil, 'another direct operation is pending')
      return nil, 'another direct operation is pending'
    end
    token = begin_token
    file_operations.will_rename(files, function(ok, suppressed_or_err)
      if not ok then
        M.ui.notify('Failed to ' .. which .. ' after LSP WorkspaceEdit failure '
          .. '(earlier server edits may already have applied): '
          .. tostring(suppressed_or_err), vim.log.levels.ERROR)
        M.pending.finish(token)
        finish_callback(callback, nil, suppressed_or_err)
        return
      end
      M._reverse_async(which, callback, {
        pending_token = token,
        skip_will = true,
        expected_record = record,
        suppressed = suppressed_or_err,
      })
    end, nil, function() return M.pending.is_active(token) end)
    return true
  end

  if not token then
    local began, begin_token = M.pending.begin(which)
    if not began then
      M.ui.notify('direct: cannot ' .. which .. ': another operation is pending',
        vim.log.levels.WARN)
      finish_callback(callback, nil, 'another direct operation is pending')
      return nil, 'another direct operation is pending'
    end
    token = begin_token
  end

  if not M.pending.is_active(token) then
    M.pending.finish(token)
    finish_callback(callback, nil, 'pending history operation was canceled')
    return nil, 'pending history operation was canceled'
  end

  -- Keep the process lock from the last history re-read through the async action
  -- callback and the paired stack update. A process crash releases flock, while
  -- the in-memory pending token still blocks overlapping operations in this one.
  local locked, lock_err = M.lock.acquire()
  if not locked then
    M.pending.finish(token)
    M.ui.notify('direct: cannot ' .. which .. ': ' .. tostring(lock_err),
      vim.log.levels.ERROR)
    finish_callback(callback, nil, lock_err)
    return nil, lock_err
  end
  local lock_released = false
  local function release_lock()
    if lock_released then return true end
    lock_released = true
    local released, release_err = M.lock.release()
    if not released then
      M.ui.notify('direct: could not release history lock: '
        .. tostring(release_err), vim.log.levels.ERROR)
    end
    return released, release_err
  end

  local latest, latest_err = preflight_locked()
  if not latest then
    release_lock()
    M.pending.finish(token)
    finish_callback(callback, nil, latest_err)
    return nil, latest_err
  end
  local latest_src = which == 'undo' and latest.undo_lines or latest.redo_lines
  if latest_src[#latest_src] ~= record then
    local why = 'history changed while waiting for another process'
    release_lock()
    M.pending.finish(token)
    M.ui.notify('Failed to ' .. which .. ' action - ' .. why, vim.log.levels.WARN)
    finish_callback(callback, nil, why)
    return nil, why
  end
  state = latest
  if which == 'undo' then
    src_path, dst_path = state.undo_path, state.redo_path
    src_lines, dst_lines = state.undo_lines, state.redo_lines
  else
    src_path, dst_path = state.redo_path, state.undo_path
    src_lines, dst_lines = state.redo_lines, state.undo_lines
  end

  local inverse, reverse_transaction, paste_operation
  if recoverable_rename_kinds[reversal.name] then
    local inverse_err
    inverse, inverse_err = M.action.serialize(reversal)
    if not inverse then
      release_lock()
      M.pending.finish(token)
      M.ui.notify('Failed to ' .. which .. ' action - cannot serialize reversal: '
        .. tostring(inverse_err), vim.log.levels.ERROR)
      finish_callback(callback, nil, inverse_err)
      return nil, inverse_err
    end
    local journal_result, journal_err = write_reverse_intent(
      state, which, reversal, inverse)
    if journal_result == false then
      release_lock()
      M.pending.finish(token)
      M.ui.notify('Failed to ' .. which .. ' action - cannot write recovery journal: '
        .. tostring(journal_err), vim.log.levels.ERROR)
      finish_callback(callback, nil, journal_err)
      return nil, journal_err
    end
    reverse_transaction = journal_result
    if reverse_transaction and reverse_transaction.kind == 'unpaste' then
      attach_unpaste_journal(reversal, reverse_transaction, state.transaction_path)
    end
  elseif reversal.name == 'p' then
    local operation, journal_or_err = start_paste_reverse(
      state, which, reversal, record)
    if operation == false then
      release_lock()
      M.pending.finish(token)
      M.ui.notify('Failed to ' .. which .. ' action - cannot write recovery journal: '
        .. tostring(journal_or_err), vim.log.levels.ERROR)
      finish_callback(callback, nil, journal_or_err)
      return nil, journal_or_err
    end
    if operation then
      paste_operation = operation
      inverse = nil
      reversal._before_copy = function(pair, source, destination)
        return M.note_paste_pending(paste_operation, pair, source, destination)
      end
      reversal._after_copy = function(pair)
        return M.note_paste_complete(paste_operation, pair)
      end
      reversal._on_copy_conflict = function(pair)
        return M.cancel_paste_pending(paste_operation, pair)
      end
    end
  end

  local settled = false
  local function complete_inner(ok, result, execution_err)
    if paste_operation then
      local completed, settle_err = recovery.settle_paste_pending(paste_operation.transaction)
      if not completed then
        local why = tostring(settle_err)
          .. '; recovery journal preserved at ' .. paste_operation.transaction_path
        M.ui.notify('direct: ' .. why, vim.log.levels.ERROR)
        release_lock()
        M.pending.finish(token)
        finish_callback(callback, nil, why)
        return
      end
      paste_operation.transaction.completed = completed
      paste_operation.transaction.pending = vim.NIL
      reversal.renames = completed
      local persisted, persist_err = write_paste_journal(paste_operation)
      if not persisted then
        local why = 'could not update paste recovery journal: ' .. tostring(persist_err)
        M.ui.notify('direct: ' .. why, vim.log.levels.ERROR)
        release_lock()
        M.pending.finish(token)
        finish_callback(callback, nil, why)
        return
      end
    end
    local copied = reversal.name == 'p' and #(reversal.renames or {}) > 0
    local all_skipped = reversal.name == 'p' and #(reversal.renames or {}) == 0
      and result == nil
    if (not ok and not copied) or all_skipped then
      if reversal.name == 'g' and #(reversal._completed_actions or {}) > 0
        or reversal.name == 'up' and #(reversal._completed_renames or {}) > 0 then
        file_operations.emit_actions({ reversal }, nil, options.suppressed)
      end
      local why = execution_err ~= nil and tostring(execution_err)
        or 'action failed or all paste entries were skipped'
      if paste_operation then
        local cleared, clear_err = clear_transaction(state.transaction_path)
        if not cleared then why = why .. '; ' .. tostring(clear_err) end
      else
        local recovered, recovery_err = settle_failed_reverse(state, reverse_transaction)
        if not recovered then why = why .. '; ' .. tostring(recovery_err) end
      end
      if not all_skipped then
        M.ui.notify('Failed to ' .. which .. ' action - '
          .. M.action.summarize({ reversal }) .. ' (' .. why .. ')',
          vim.log.levels.ERROR)
      end
      release_lock()
      M.pending.finish(token)
      finish_callback(callback, nil, all_skipped and nil or why)
      return
    end

    file_operations.emit_actions({ reversal }, nil, options.suppressed)

    -- Async Paste may choose a collision-safe basename in its callback, so its
    -- final inverse record can only be serialized once execution has settled.
    local inverse_err
    if not inverse then inverse, inverse_err = M.action.serialize(reversal) end
    if not inverse then
      M.ui.notify('Failed to ' .. which .. ' action - cannot serialize reversal: '
        .. tostring(inverse_err), vim.log.levels.ERROR)
      release_lock()
      M.pending.finish(token)
      finish_callback(callback, nil, inverse_err)
      return
    end
    local next_src, next_dst = copy_lines(src_lines), copy_lines(dst_lines)
    table.remove(next_src)
    next_dst[#next_dst + 1] = inverse
    local next_undo, next_redo = which == 'undo' and next_src or next_dst,
      which == 'undo' and next_dst or next_src
    local appended, append_err = commit_stacks(state.undo_path, state.redo_path,
      state.transaction_path, next_undo, next_redo)
    if not appended then
      M.ui.notify('Failed to ' .. which .. ' action - cannot write history: '
        .. tostring(append_err), vim.log.levels.ERROR)
    end
    if not ok then
      M.ui.notify('Partially completed ' .. which .. ' action: '
        .. tostring(execution_err), vim.log.levels.ERROR)
    end
    M.ui.notify(M.action.summarize({ reversal }), vim.log.levels.INFO)
    release_lock()
    M.pending.finish(token)
    finish_callback(callback, reversal, appended and nil or append_err)
  end
  local function complete(ok, result, execution_err)
    if settled then return end
    settled = true
    local finished, completion_err = xpcall(function()
      complete_inner(ok, result, execution_err)
    end, debug.traceback)
    if not finished then
      release_lock()
      M.pending.finish(token)
      M.ui.notify('Failed to complete async ' .. which .. ' history action: '
        .. tostring(completion_err), vim.log.levels.ERROR)
      finish_callback(callback, nil, completion_err)
    end
  end

  if reverse_transaction and reverse_transaction.steps then
    local called, result, step_err = pcall(recovery.complete_move_steps,
      reverse_transaction, state.transaction_path)
    if not called then
      complete(false, nil, result)
    else
      complete(result ~= nil, result, step_err)
    end
  else
    local called, start_result, start_err = pcall(
      M.action.execute_async, reversal, complete)
    if not called then
      complete(false, nil, start_result)
    elseif start_result == nil then
      complete(false, nil, start_err or 'could not start action')
    end
  end
  return true
end

return M
