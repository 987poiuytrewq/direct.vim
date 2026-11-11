-- Undo/redo execution and async history reversal orchestration.
-- Shared journal and lock primitives are injected from history.lua.

return function(context)
  local M = context.M
  local file_operations = context.file_operations
  local rename_files = context.rename_files
  local preflight_locked = context.preflight_locked
  local copy_lines = context.copy_lines
  local commit_stacks = context.commit_stacks
  local clear_transaction = context.clear_transaction
  local recovery = context.recovery
  local write_reverse_intent = context.write_reverse_intent
  local start_paste_reverse = context.start_paste_reverse
  local settle_failed_reverse = context.settle_failed_reverse
  local attach_unpaste_journal = context.attach_unpaste_journal
  local recoverable_rename_kinds = context.recoverable_rename_kinds
  local write_paste_journal = context.write_paste_journal
  local expand_batch_stack

  local function missing_source_hint(which, err)
    local message = tostring(err or ''):lower()
    if message:find('enoent', 1, true) or message:find('no such file', 1, true)
      or message:find('not found', 1, true) then
      return '; use :DirectHistory drop ' .. which
        .. ' to remove this irrecoverable step and continue with earlier history'
    end
    return ''
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
    why = why .. missing_source_hint(which, why)
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
      why = why .. missing_source_hint(which, why)
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

end
