-- Durable async Paste history journal lifecycle.
-- Coordinator internals are injected; methods stay on the history API.

return function(context)
  local M = context.M
  local log_mod = context.log_mod
  local TRANSACTION_FORMAT = context.TRANSACTION_FORMAT
  local TRANSACTION_VERSION = context.TRANSACTION_VERSION
  local preflight_locked = context.preflight_locked
  local action_paths = context.action_paths
  local copy_lines = context.copy_lines
  local notify_unavailable = context.notify_unavailable
  local recovery = context.recovery
  local clear_transaction = context.clear_transaction
  local commit_stacks = context.commit_stacks

  local function write_paste_journal(operation)
    local called, ok, err = pcall(
      function()
        return log_mod.write_raw_atomic(operation.transaction_path, vim.json.encode(operation.transaction) .. '\n')
      end
    )
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
    local called, state, preflight_err = xpcall(
      function() return preflight_locked(action_paths(action)) end,
      debug.traceback
    )
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
    if
      type(operation) ~= 'table'
      or not operation.locked
      or type(pair) ~= 'table'
      or type(source) ~= 'string'
      or type(destination) ~= 'string'
    then
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
    if type(operation) ~= 'table' or not operation.locked or type(pair) ~= 'table' then
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
    if type(operation) ~= 'table' or not operation.locked then return nil, 'paste history operation is not active' end
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
    if type(operation) ~= 'table' or not operation.locked then return nil, 'paste history operation is not active' end
    local called, result, result_err = xpcall(function()
      local completed, settle_err = recovery.settle_paste_pending(operation.transaction)
      if not completed then return nil, settle_err end
      if #completed == 0 then return clear_transaction(operation.transaction_path) end
      local undo, redo, stack_err = recovery.paste_stack_snapshot(operation.transaction, completed)
      if not undo then return nil, stack_err end
      return commit_stacks(operation.undo_path, operation.redo_path, operation.transaction_path, undo, redo)
    end, debug.traceback)
    if not called then
      result, result_err = nil, result
    end
    local released, release_err = release_paste_lock(operation)
    if result and not released then return nil, release_err end
    if not result then return nil, result_err end
    return true
  end

  return { write_paste_journal = write_paste_journal }
end
