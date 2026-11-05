-- Operation-specific restart recovery. The history coordinator owns locks and
-- stack commits; this module classifies and resumes recorded filesystem steps.
local M = {}

function M.new(deps)
  local action = deps.action
  local header = deps.header
  local ui = deps.ui
  local write_transaction = deps.write_transaction
  local clear_transaction = deps.clear_transaction
  local commit_stacks = deps.commit_stacks

  local function identities_equal(expected, actual)
    if expected == vim.NIL then expected = nil end
    if actual == vim.NIL then actual = nil end
    if expected == nil or actual == nil then return expected == actual end
    if expected.inode and actual.inode then return expected.inode == actual.inode end
    return expected.path == actual.path
  end

  local function reverse_operation_status(transaction)
    if transaction.direction == 'apply'
      and (transaction.source == vim.NIL or transaction.source == nil) then
      local _, destination_stat = action.fs.entry_identity(transaction.destination)
      if not destination_stat and transaction.destination_identity == vim.NIL then
        return 'not-started'
      end
      return 'ambiguous'
    end
    local source_now, source_stat = action.fs.entry_identity(transaction.source)
    local destination_now, destination_stat = action.fs.entry_identity(transaction.destination)
    if not source_stat then source_now = nil end
    if not destination_stat then destination_now = nil end
    if identities_equal(transaction.source_identity, source_now)
      and identities_equal(transaction.destination_identity, destination_now) then
      return 'not-started'
    end
    if source_now == nil and destination_now ~= nil
      and destination_now.inode == transaction.source_identity.inode then
      return 'completed'
    end
    return 'ambiguous'
  end

  local function move_step_status(step)
    local source_now, source_stat = action.fs.entry_identity(step.src)
    local destination_now, destination_stat = action.fs.entry_identity(step.dst)
    if not source_stat then source_now = nil end
    if not destination_stat then destination_now = nil end
    if identities_equal(step.identity, source_now) and destination_now == nil then
      return 'not-started'
    end
    if identities_equal(step.identity, destination_now)
      and (source_now == nil or not identities_equal(step.identity, source_now)) then
      return 'completed'
    end
    return 'ambiguous'
  end

  local function rollback_staging_steps(transaction, transaction_path, last_completed)
    for index = last_completed, 1, -1 do
      local step = transaction.steps[index]
      if move_step_status(step) ~= 'completed' then
        return nil, 'staged move changed; preserved at ' .. step.dst
      end
      local restored, restore_err = action.fs.rename_noreplace(
        step.dst, step.src, step.identity)
      if not restored then
        local message = 'could not restore staged entry ' .. step.dst .. ' to '
          .. step.src .. ' (' .. tostring(restore_err)
          .. '); temp preserved; manual recovery required before retry'
        ui.notify('direct: ' .. message, vim.log.levels.ERROR)
        return nil, message
      end
    end
    transaction.next_step = 1
    local persisted, persist_err = write_transaction(transaction_path, transaction)
    if not persisted then return nil, persist_err end
    return true
  end

  local function complete_move_steps(transaction, transaction_path)
    while transaction.next_step <= #transaction.steps do
      local index = transaction.next_step
      local step = transaction.steps[index]
      local status = move_step_status(step)
      if status == 'ambiguous' then
        return nil, 'grouped move step identity is ambiguous (source identity changed '
          .. 'or destination is occupied): ' .. step.src .. ' -> ' .. step.dst
      end
      if status == 'not-started' then
        local move = action.Move(step.src, step.dst)
        local called, result, execute_err = pcall(action.execute, move)
        if not called or result == nil then
          status = move_step_status(step)
          if status ~= 'completed' then
            if index <= transaction.staging_count then
              local rolled_back, rollback_err = rollback_staging_steps(
                transaction, transaction_path, index - 1)
              if not rolled_back then
                return nil, tostring(execute_err or result or 'action failed')
                  .. '; ' .. tostring(rollback_err)
              end
              local failure = tostring(execute_err or result or 'action failed')
              if transaction.kind == 'reverse' then
                failure = 'could not stage renames: ' .. failure
              end
              return nil, failure
            end
            return nil, 'grouped move step failed: '
              .. tostring(called and execute_err or result)
          end
        end
        status = move_step_status(step)
        if status ~= 'completed' then
          return nil, 'grouped move step identity is ambiguous (source identity changed '
            .. 'or destination is occupied): ' .. step.src .. ' -> ' .. step.dst
        end
      end
      transaction.next_step = transaction.next_step + 1
      local persisted, persist_err = write_transaction(transaction_path, transaction)
      if not persisted then return nil, persist_err end
    end
    return true
  end

  local function paste_action_for_pairs(paste_action, completed)
    local sources, destinations = {}, {}
    for _, pair in ipairs(completed) do
      sources[#sources + 1] = pair.src
      destinations[#destinations + 1] = pair.dst
    end
    return action.Paste(paste_action.src, paste_action.dst, sources, destinations)
  end

  local function paste_stack_snapshot(transaction, completed)
    local undo, redo = {}, {}
    for index, line in ipairs(transaction.base_undo) do undo[index] = line end
    for index, line in ipairs(transaction.base_redo) do redo[index] = line end
    if #completed == 0 then return undo, redo end
    local paste_action = action.deserialize(transaction.action)
    local record, err = action.serialize(paste_action_for_pairs(paste_action, completed))
    if not record then return nil, nil, err end
    if transaction.direction == 'apply' then
      undo[#undo + 1] = record
      return undo, { header }
    end
    if transaction.direction == 'undo' then
      table.remove(undo)
      redo[#redo + 1] = record
    else
      table.remove(redo)
      undo[#undo + 1] = record
    end
    return undo, redo
  end

  local function settle_paste_pending(transaction)
    local completed = {}
    for index, pair in ipairs(transaction.completed) do
      completed[index] = { src = pair.src, dst = pair.dst }
    end
    local pending = transaction.pending
    if pending == vim.NIL then return completed end

    local current_source, source_stat = action.fs.entry_identity(pending.source)
    local _, destination_stat = action.fs.entry_identity(pending.destination)
    if not source_stat or not identities_equal(pending.source_identity, current_source) then
      return nil, 'paste source changed during an interrupted copy: ' .. pending.source
    end
    if not destination_stat then return completed end

    local matches, compare_err = action.fs.same_contents(
      pending.source, pending.destination)
    if matches ~= true then
      return nil, 'interrupted paste destination is ambiguous: '
        .. pending.destination .. (compare_err and (' (' .. tostring(compare_err) .. ')') or '')
    end
    completed[#completed + 1] = { src = pending.src, dst = pending.dst }
    return completed
  end

  local function recover_paste_transaction(transaction, undo_path, redo_path,
      transaction_path)
    local completed, settle_err = settle_paste_pending(transaction)
    if not completed then
      local message = tostring(settle_err) .. '; recovery journal preserved at '
        .. transaction_path .. '; inspect the affected paths before retrying'
      ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    if #completed == 0 then return clear_transaction(transaction_path) end
    local undo, redo, stack_err = paste_stack_snapshot(transaction, completed)
    if not undo then return nil, stack_err end
    return commit_stacks(undo_path, redo_path, transaction_path, undo, redo)
  end

  local function unpaste_capture_status(item)
    local source_now, source_stat = action.fs.entry_identity(item.path)
    local quarantine_now, quarantine_stat = action.fs.entry_identity(item.quarantine)
    if not source_stat then source_now = nil end
    if not quarantine_stat then quarantine_now = nil end
    if identities_equal(item.identity, quarantine_now)
      and (source_now == nil or not identities_equal(item.identity, source_now)) then
      return 'completed'
    end
    if identities_equal(item.identity, source_now) and quarantine_now == nil then
      return 'not-started'
    end
    return 'ambiguous'
  end

  local function finish_unpaste_transaction(transaction, undo_path, redo_path,
      transaction_path)
    while transaction.phase == 'capture'
      and transaction.next_item <= #transaction.items do
      local item = transaction.items[transaction.next_item]
      local status = unpaste_capture_status(item)
      if status == 'ambiguous' then
        return nil, 'Unpaste capture is ambiguous: ' .. item.path
      end
      if status == 'not-started' then
        local _, capture_err = action.fs.rename_noreplace(
          item.path, item.quarantine, item.identity)
        status = unpaste_capture_status(item)
        if status ~= 'completed' then
          return nil, 'could not capture Unpaste entry '
            .. item.path .. ' (' .. tostring(capture_err) .. ')'
        end
      end
      transaction.next_item = transaction.next_item + 1
      local saved, save_err = write_transaction(transaction_path, transaction)
      if not saved then return nil, save_err end
    end

    if transaction.phase == 'capture' then
      transaction.phase, transaction.next_item = 'delete', 1
      local saved, save_err = write_transaction(transaction_path, transaction)
      if not saved then return nil, save_err end
    end

    while transaction.next_item <= #transaction.items do
      local item = transaction.items[transaction.next_item]
      local quarantine_identity, quarantine_stat = action.fs.entry_identity(item.quarantine)
      if quarantine_stat then
        if not identities_equal(item.identity, quarantine_identity) then
          return nil, 'Unpaste quarantine identity changed: ' .. item.quarantine
        end
        local matches, compare_err = action.fs.same_contents(item.quarantine, item.reference)
        if matches ~= true then
          return nil, 'Unpaste quarantine no longer matches register content: '
            .. item.quarantine .. (compare_err and (' (' .. tostring(compare_err) .. ')') or '')
        end
        local removed, remove_err
        if item.kind == 'directory' then
          removed, remove_err = action.fs.rm_tree(item.quarantine)
        else
          removed, remove_err = action.fs.rm_file(item.quarantine)
        end
        if not removed or action.fs.taken(item.quarantine) then
          return nil, 'could not remove Unpaste quarantine '
            .. item.quarantine .. ' (' .. tostring(remove_err) .. ')'
        end
      end
      transaction.next_item = transaction.next_item + 1
      local saved, save_err = write_transaction(transaction_path, transaction)
      if not saved then return nil, save_err end
    end
    return commit_stacks(undo_path, redo_path, transaction_path,
      transaction.undo, transaction.redo)
  end

  return {
    identities_equal = identities_equal,
    reverse_operation_status = reverse_operation_status,
    move_step_status = move_step_status,
    complete_move_steps = complete_move_steps,
    paste_stack_snapshot = paste_stack_snapshot,
    settle_paste_pending = settle_paste_pending,
    recover_paste_transaction = recover_paste_transaction,
    finish_unpaste_transaction = finish_unpaste_transaction,
  }
end

return M
