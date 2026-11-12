-- tests/events_spec.lua -- public User autocmd lifecycle events.

local H = require('tests.support.harness')

H.describe('plugin User events', function()
  H.it('emits list, sync, undo, and paste events with roots and action data', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local destination = H.mkdir(sb.root, 'destination')
    H.mkfile(ws, 'old.txt', { 'old' })

    local seen = {}
    local group = vim.api.nvim_create_augroup('direct_events_spec', { clear = true })
    for _, event in ipairs({ 'DirectListPost', 'DirectSyncPre', 'DirectSyncPost',
        'DirectUndoPost', 'DirectRedoPost', 'DirectPastePost' }) do
      vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = event,
        callback = function(args)
          local data = vim.deepcopy(args.data)
          seen[#seen + 1] = { name = args.match, data = data }
          if args.match == 'DirectSyncPre' and args.data.actions[1] then
            -- Event handlers receive a detached copy, not Direct's live plan.
            args.data.actions[1].name = 'tampered'
          end
        end,
      })
    end

    local api = require('direct')
    local fs = require('direct.fs')
    api.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    H.set_direct_rows(bufnr, { 'new.txt' })
    H.assert_true(api.sync(), 'sync completes after the pre event')
    H.assert_true(vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) ~= nil,
      'the sync applies its original plan despite event-data mutation')

    local sync_pre, sync_post, sync_pre_index, sync_post_index, refreshed_index
    for index, event in ipairs(seen) do
      if event.name == 'DirectSyncPre' then sync_pre, sync_pre_index = event, index end
      if event.name == 'DirectSyncPost' then sync_post, sync_post_index = event, index end
      if sync_pre_index and event.name == 'DirectListPost'
        and index > sync_pre_index and not refreshed_index then
        refreshed_index = index
      end
    end
    H.assert_true(sync_pre ~= nil, 'DirectSyncPre was sent')
    H.assert_true(fs.same_path(sync_pre.data.root, ws), 'pre event identifies the listing root')
    H.assert_eq(sync_pre.data.actions[1].name, 'mv',
      'pre event provides the planned action')
    H.assert_true(sync_post ~= nil, 'DirectSyncPost was sent')
    H.assert_true(fs.same_path(sync_post.data.root, ws), 'post event identifies the listing root')
    H.assert_true(sync_post.data.success, 'post event reports sync success')
    H.assert_eq(sync_post.data.actions[1].name, 'mv',
      'the handler could not mutate the operation plan')
    H.assert_eq(sync_post.data.applied[1].name, 'mv',
      'post event reports the applied action')
    H.assert_true(sync_pre_index < refreshed_index and refreshed_index < sync_post_index,
      'sync events bracket the committed listing refresh')

    local undo_post, undo_post_index
    api.undo()
    H.assert_true(vim.wait(5000, function()
      for index, event in ipairs(seen) do
        if event.name == 'DirectUndoPost' then
          undo_post, undo_post_index = event, index
          return true
        end
      end
      return false
    end), 'DirectUndoPost arrives after asynchronous undo')
    H.assert_true(fs.same_path(undo_post.data.root, ws), 'undo event identifies the listing root')
    H.assert_eq(undo_post.data.actions[1].name, 'mv', 'undo event includes its reversal')
    H.assert_true(undo_post.data.success, 'undo event reports success')
    local undo_refresh_index
    for index, event in ipairs(seen) do
      if event.name == 'DirectListPost' and index < undo_post_index then
        undo_refresh_index = index
      end
    end
    H.assert_true(undo_refresh_index ~= nil and undo_refresh_index < undo_post_index,
      'undo post follows the refreshed listing')

    api.redo()
    local redo_post
    H.assert_true(vim.wait(5000, function()
      for _, event in ipairs(seen) do
        if event.name == 'DirectRedoPost' then redo_post = event; return true end
      end
      return false
    end), 'DirectRedoPost arrives after asynchronous redo')
    H.assert_true(fs.same_path(redo_post.data.root, ws), 'redo event identifies the listing root')
    H.assert_eq(redo_post.data.actions[1].name, 'mv', 'redo event includes its action')
    H.assert_true(redo_post.data.success, 'redo event reports success')

    api.undo()
    H.assert_true(vim.wait(5000, function()
      local undo_count = 0
      for _, event in ipairs(seen) do
        if event.name == 'DirectUndoPost' then undo_count = undo_count + 1 end
      end
      return undo_count >= 2
    end), 'the listing is restored for the paste test')

    H.assert_true(api.yank(1, 1), 'yank the restored file for paste')
    api.paste(destination)
    local paste_post
    H.assert_true(vim.wait(5000, function()
      for _, event in ipairs(seen) do
        if event.name == 'DirectPastePost' then paste_post = event; return true end
      end
      return false
    end), 'DirectPastePost arrives after paste')
    H.assert_true(fs.same_path(paste_post.data.root, destination),
      'paste event root is the destination directory')
    H.assert_eq(paste_post.data.actions[1].name, 'p', 'paste event includes the paste action')
    H.assert_true(paste_post.data.success, 'paste event reports success')

    local first_list
    for _, event in ipairs(seen) do
      if event.name == 'DirectListPost' then first_list = event; break end
    end
    H.assert_true(first_list ~= nil, 'DirectListPost was sent after listing')
    H.assert_true(fs.same_path(first_list.data.root, ws), 'list event identifies the listed root')
    H.assert_eq(first_list.data.actions, {}, 'list event includes an empty actions array')
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end)

  H.it('refuses a sync if a DirectSyncPre handler edits the listing', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', { 'old' })
    local api = require('direct')
    local fs = require('direct.fs')
    api.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    H.set_direct_rows(bufnr, { 'new.txt' })

    local post
    local group = vim.api.nvim_create_augroup('direct_sync_pre_edit_spec', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'DirectSyncPre',
      callback = function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'callback-edit.txt' })
      end,
    })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'DirectSyncPost',
      callback = function(args) post = vim.deepcopy(args.data) end,
    })

    local synced, sync_err = api.sync()

    H.assert_nil(synced, 'the stale action plan is refused')
    H.assert_true(tostring(sync_err):find('DirectSyncPre', 1, true) ~= nil,
      'the error identifies the listing edit')
    H.assert_true(vim.uv.fs_stat(vim.fs.joinpath(ws, 'old.txt')) ~= nil,
      'the original file remains in place')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')),
      'no stale rename is applied')
    H.assert_buf_eq({ 'callback-edit.txt' }, bufnr,
      'the callback edit remains visible for review')
    H.assert_true(vim.bo[bufnr].modified, 'the listing remains modified')
    H.assert_true(post ~= nil and not post.success,
      'DirectSyncPost reports the refused sync')
    H.assert_true(fs.same_path(post.root, ws), 'the post event identifies the root')
    H.assert_true(type(post.actions) == 'table' and #post.actions == 1,
      'the post event includes the planned actions')
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end)

  H.it('lets DirectSyncPre cancel without changing disk or clearing the listing edit', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', { 'old' })
    local api = require('direct')
    api.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    H.set_direct_rows(bufnr, { 'new.txt' })
    local post
    local group = vim.api.nvim_create_augroup('direct_sync_pre_cancel_spec', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'DirectSyncPre',
      callback = function(args)
        require('direct.events').cancel(args.data, 'test veto')
      end,
    })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'DirectSyncPost',
      callback = function(args) post = vim.deepcopy(args.data) end,
    })

    local synced, sync_err = api.sync()

    H.assert_nil(synced, 'the handler can refuse the save')
    H.assert_true(tostring(sync_err):find('DirectSyncPre', 1, true) ~= nil,
      'the refusal identifies the event')
    H.assert_true(tostring(sync_err):find('test veto', 1, true) ~= nil,
      'the refusal includes the handler reason')
    H.assert_true(H.exists(ws, 'old.txt'), 'cancellation preserves the original file')
    H.assert_false(H.exists(ws, 'new.txt'), 'cancellation applies no filesystem actions')
    H.assert_buf_eq({ 'new.txt' }, bufnr, 'the listing edit stays visible')
    H.assert_true(vim.bo[bufnr].modified, 'the listing remains modified')
    H.assert_true(post ~= nil and not post.success and post.cancelled,
      'DirectSyncPost reports the cancelled sync')
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end)

  H.it('emits DirectTrashPost and DirectHistoryResetPost with operation results', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local first = H.mkfile(ws, 'restore.txt', { 'restore' })
    local second = H.mkfile(ws, 'empty.txt', { 'empty' })
    local action = require('direct.action.action')
    H.assert_true(action.Remove(first)['do'](), 'create a restorable trash entry')
    H.assert_true(action.Remove(second)['do'](), 'create an emptyable trash entry')
    local entries = require('direct.trash').entries()
    local by_original = {}
    for _, entry in ipairs(entries) do by_original[entry.original] = entry end
    local seen = {}
    local group = vim.api.nvim_create_augroup('direct_trash_events_spec', { clear = true })
    for _, pattern in ipairs({ 'DirectTrashPost', 'DirectHistoryResetPost' }) do
      local event_name = pattern
      vim.api.nvim_create_autocmd('User', {
        group = group,
        pattern = event_name,
        callback = function(args)
          seen[#seen + 1] = { name = args.match, data = vim.deepcopy(args.data) }
        end,
      })
    end

    local restored = require('direct').trash_restore(by_original[first].id)
    local emptied = require('direct').trash_empty()
    local reset, backups = require('direct').reset_history()

    H.assert_true(restored, 'trash restore succeeds')
    H.assert_true(emptied, 'trash empty succeeds')
    H.assert_true(reset, 'history reset succeeds')
    H.assert_eq(#seen, 3, 'each operation emits one post event')
    H.assert_eq(seen[1].name, 'DirectTrashPost', 'restore emits the trash post event')
    H.assert_eq(seen[1].data.operation, 'restore', 'restore event names its operation')
    H.assert_eq(seen[1].data.id, by_original[first].id, 'restore event carries the ID')
    H.assert_true(seen[1].data.success, 'restore event reports success')
    H.assert_nil(seen[1].data.error, 'successful restore has no error')
    H.assert_eq(seen[2].data.operation, 'empty', 'empty event names its operation')
    H.assert_true(seen[2].data.success, 'empty event reports success')
    H.assert_eq(seen[2].data.removed, 1, 'empty event reports the removed count')
    H.assert_nil(seen[2].data.error, 'successful empty has no error')
    H.assert_eq(seen[3].name, 'DirectHistoryResetPost', 'history reset emits its post event')
    H.assert_true(seen[3].data.success, 'history reset event reports success')
    H.assert_eq(seen[3].data.backups, backups, 'history reset event includes backup files')
    H.assert_nil(seen[3].data.error, 'successful history reset has no error')
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end)
end)
