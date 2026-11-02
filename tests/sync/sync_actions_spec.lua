-- sync_actions_spec.lua -- sync: applying actions.
-- Exercises the sync facade and filesystem effects.

local sync = require('tests.support.sync_helpers').new()
local H = sync.H
local buffer = sync.buffer
local fs = sync.fs
local paths = sync.paths
local history = sync.history
local register = sync.register
local fixtures = sync.fixtures
local HEADER = sync.HEADER
local decode_record = sync.decode_record
local clean_buffers = sync.clean_buffers
local route_write_to_test_buffer = sync.route_write_to_test_buffer
local history_lines = sync.history_lines
local list_edit_and_sync = sync.list_edit_and_sync

H.describe('sync: applying actions', function()
  H.it('ADD (file): creates the file and logs one touch action', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    local _, ok = list_edit_and_sync(ws, { 'a.txt', 'b.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' })
    H.assert_false(vim.bo.modified, 're-listed and nomodified')
    H.assert_eq(history_lines('undo.log'),
      { HEADER, fixtures.touch(ws .. '/b.txt') }, 'exactly one touch record')
    H.assert_eq(history_lines('redo.log'), { HEADER },
      'a new action resets the redo branch to its header')
  end)

  H.it('ADD (directory + dirs-then-name ordering): mkdir lines are logged first', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'keep.txt', { 'k' })

    local _, ok = list_edit_and_sync(ws, { 'zdir/', 'afile.txt', 'adir/', 'keep.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'adir/', 'zdir/', 'afile.txt', 'keep.txt' })
    H.assert_eq(history_lines('undo.log'), {
      HEADER,
      fixtures.mkdir(ws .. '/adir/'),
      fixtures.mkdir(ws .. '/zdir/'),
      fixtures.touch(ws .. '/afile.txt'),
    }, 'directories first, then files, each sorted')
  end)

  H.it('ADD (nested paths): creates missing parents before files and directories', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'keep.txt', { 'keep' })

    local _, ok, reason = list_edit_and_sync(ws, {
      'keep.txt', 'archive/2026/', 'archive/2026/summary.txt',
    })

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), {
      'archive/', 'archive/2026/', 'archive/2026/summary.txt', 'keep.txt',
    }, 'nested directory and file paths are materialized')
    H.assert_eq(history_lines('undo.log'), {
      HEADER,
      fixtures.mkdir(ws .. '/archive'),
      fixtures.mkdir(ws .. '/archive/2026/'),
      fixtures.touch(ws .. '/archive/2026/summary.txt'),
    }, 'each created directory and file is independently undoable')
    H.assert_buf_eq({ 'archive/', '  2026/', '    summary.txt', 'keep.txt' }, 0,
      'the new parent directories are expanded after the root refresh')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 3, 4 },
      'the cursor lands on the last nested entry')
  end)

  H.it('ADD (nested path): reuses existing parent directories', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'reports')
    H.mkfile(ws, 'keep.txt', { 'keep' })

    local _, ok, reason = list_edit_and_sync(ws, {
      'reports/', 'keep.txt', 'reports/summary.txt', 'reports/2026/final.txt',
    })

    H.assert_true(ok == true, tostring(reason))
    H.assert_true(H.exists(ws, 'reports/summary.txt'), 'file uses the existing parent')
    H.assert_true(H.exists(ws, 'reports/2026/final.txt'), 'missing deeper parent is created')
    H.assert_eq(history_lines('undo.log'), {
      HEADER,
      fixtures.mkdir(ws .. '/reports/2026'),
      fixtures.touch(ws .. '/reports/2026/final.txt'),
      fixtures.touch(ws .. '/reports/summary.txt'),
    }, 'only missing parent directories receive mkdir history')
    H.assert_buf_eq({
      'reports/', '  2026/', '    final.txt', '  summary.txt', 'keep.txt',
    }, 0, 'existing and newly created parent directories are expanded')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 3, 4 },
      'the cursor lands on the last added entry')
  end)

  H.it('ADD (nested path): undo and redo remove and restore parents in order', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'keep.txt', { 'keep' })
    local _, ok, reason = list_edit_and_sync(ws, { 'keep.txt', 'deep/more/file.txt' })
    H.assert_true(ok == true, tostring(reason))

    H.assert_not_nil(history.undo(), 'first undo removes the file')
    H.assert_not_nil(history.undo(), 'second undo removes the inner directory')
    H.assert_not_nil(history.undo(), 'third undo removes the outer directory')
    H.assert_false(H.exists(ws, 'deep'), 'undo removes every newly created parent')
    H.assert_fs_eq(ws, { 'keep.txt' }, 'undo restores the original directory state')

    H.assert_not_nil(history.redo(), 'first redo recreates the outer directory')
    H.assert_not_nil(history.redo(), 'second redo recreates the inner directory')
    H.assert_not_nil(history.redo(), 'third redo recreates the file')
    H.assert_true(H.exists(ws, 'deep/more/file.txt'), 'redo restores the full path')
  end)

  H.it('ADD (nested path): refuses traversal, malformed separators, and file parents', function()
    local invalid = { '../outside.txt', '/absolute.txt', 'bad//path.txt',
      'bad/../path.txt', 'blocked/child.txt' }
    for _, entry in ipairs(invalid) do
      clean_buffers()
      local sb = H.sandbox()
      local ws = H.mkdir(sb.root, 'ws')
      H.mkfile(ws, 'keep.txt', { 'keep' })
      H.mkfile(ws, 'blocked', { 'not a directory' })
      local listing = buffer.list(ws)
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { entry })
      local ok, reason = listing:sync()
      H.assert_nil(ok, entry .. ' is refused: ' .. tostring(reason))
      H.assert_true(vim.bo.modified, 'refusal keeps the edit visible')
      H.assert_eq(H.fs_snapshot(ws), { 'blocked', 'keep.txt' },
        entry .. ' makes no filesystem changes')
      H.assert_eq(history_lines('undo.log'), {}, entry .. ' writes no action history')
      H.assert_false(H.exists(sb.root, 'outside.txt'), 'traversal did not escape the root')
    end

    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'keep.txt', { 'keep' })
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, -1, -1, false,
      { 'node', 'node/child.txt' })
    local ok, reason = listing:sync()
    H.assert_nil(ok, 'a file cannot also be a parent directory: ' .. tostring(reason))
    H.assert_fs_eq(ws, { 'keep.txt' }, 'conflicting planned paths make no changes')
    H.assert_eq(history_lines('undo.log'), {}, 'conflicting paths write no history')
  end)

  H.it('DELETE (file): moves it to trash, auto-yanks it, and logs an rm line', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b.txt', { 'b' })

    H.capture_messages()
    local _, ok = list_edit_and_sync(ws, { 'a.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'a.txt' }, 'b.txt is gone from the workspace')
    local content = register.content()
    H.assert_not_nil(content, 'the register content pointer was written by the auto-yank')
    H.assert_eq(vim.fn.readfile(content .. '/b.txt'), { 'b' },
      'the deleted file was copied into the register before removal')
    H.assert_notified('Yanked ' .. ws .. '/b.txt', vim.log.levels.INFO)
    local undo = history_lines('undo.log')
    H.assert_eq(undo[1], HEADER, 'the JSONL header is first')
    local record = decode_record(undo, 2)
    H.assert_eq(record.op, 'rm', 'an rm record was logged')
    H.assert_eq(record.src, ws .. '/b.txt', 'the rm record names the source')
  end)

  H.it('DELETE (last file): leaves the directory empty and records the deletion', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'only.txt', { 'only entry' })

    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, {}, 'the last file is removed')
    H.assert_buf_eq({ '' }, 0, 'an empty directory is represented by the buffer empty line')
    H.assert_false(vim.bo.modified, 'successful sync clears modified state')
    local content = register.content()
    H.assert_not_nil(content, 'the deleted file was auto-yanked')
    H.assert_eq(vim.fn.readfile(content .. '/only.txt'), { 'only entry' },
      'the deleted file is preserved in the register')
    local undo = history_lines('undo.log')
    H.assert_eq(undo[1], HEADER, 'the JSONL header is first')
    H.assert_eq(decode_record(undo, 2).src, ws .. '/only.txt',
      'the final deletion is recorded for undo')
  end)

  H.it('DELETE (directory): trashes the tree and yanks it with its trailing slash', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inner.txt', { 'i' })
    H.mkfile(ws, 'a.txt', { 'a' })

    H.capture_messages()
    local _, ok = list_edit_and_sync(ws, { 'a.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'a.txt' }, 'the sub tree is gone')
    local content = register.content()
    H.assert_not_nil(content, 'the directory was auto-yanked')
    H.assert_eq(vim.fn.readfile(content .. '/sub/inner.txt'), { 'i' },
      'the yanked directory keeps its contents')
    H.assert_notified('Yanked ' .. ws .. '/sub/', vim.log.levels.INFO)
    local undo = history_lines('undo.log')
    H.assert_eq(decode_record(undo, 2).op, 'rmdir', 'an rmdir record was logged')
  end)

  -- Exercise both halves end to end: delete through `:write`, then paste the
  -- auto-yanked entry into another directory using the real register path.
  H.it('delete via :write then paste the auto-yanked entry into another dir', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'keep.txt', { 'k' })

    -- Real buffer + :write path: the BufWriteCmd routes to the sync, which
    -- removes a.txt and auto-yanks it into the register.
    route_write_to_test_buffer()
    buffer.list(ws)
    H.assert_not_nil(buffer._state_for_test(vim.api.nvim_get_current_buf()),
      'the listing stores sync safety state')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    H.capture_messages()
    vim.cmd('write')

    H.assert_fs_eq(ws, { 'keep.txt' }, 'a.txt was deleted through the :write sync')
    H.assert_not_nil(register.content(), 'the auto-yank recorded the register pointer')

    local dst = H.mkdir(sb.root, 'dst')
    H.assert_true(register.paste(dst) ~= nil, 'the auto-yanked entry pastes back')
    H.assert_fs_eq(dst, { 'a.txt' }, 'the deleted entry landed in the paste destination')
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'A' },
      'the entry content survived the delete/paste round trip')
  end)

  H.it(':write on a clean listing reloads external filesystem changes', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'existing.txt', { 'existing' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    H.mkfile(ws, 'external.txt', { 'external' })

    vim.cmd('write')

    H.assert_fs_eq(ws, { 'existing.txt', 'external.txt' },
      'writing an unchanged buffer does not delete an external entry')
    H.assert_buf_eq({ 'existing.txt', 'external.txt' }, 0,
      ':write reloads rows from the current filesystem contents')
    H.assert_false(vim.bo.modified, ':write leaves the reloaded listing clean')
    H.assert_eq(listing:get_paths(1, 2), {
      ws .. '/existing.txt', ws .. '/external.txt',
    }, 'row paths match the reloaded entries')
  end)

  H.it('RENAME (file): moves it and logs one mv action', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    local _, ok = list_edit_and_sync(ws, { 'b.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'b.txt' })
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'a' }, 'content survived the move')
    H.assert_eq(history_lines('undo.log'),
      { HEADER, fixtures.move(ws .. '/a.txt', ws .. '/b.txt') })
  end)

  H.it('EXDEV commit with source-remove failure is still recorded as completed', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local src, dst = H.mkfile(ws, 'a.txt', { 'PAYLOAD' }), ws .. '/b.txt'
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b.txt' })

    local real_rename, real_remove = fs.rename_noreplace, fs.rm_file
    local restore_rename = H.stub(fs, 'rename_noreplace', function(from, to)
      if from == src and to == dst then
        return nil, 'EXDEV: forced cross-device move', 'EXDEV'
      end
      return real_rename(from, to)
    end)
    local restore_remove = H.stub(fs, 'rm_file', function(path)
      if path:find('/.direct-exdev-source-', 1, true)
        and path:sub(-#'/source') == '/source' then
        return nil, 'forced source remove failure'
      end
      return real_remove(path)
    end)

    H.capture_messages()
    local ok, err = listing:sync()
    restore_remove()
    restore_rename()

    H.assert_true(ok == true, 'the committed destination is a completed action: ' .. tostring(err))
    H.assert_eq(vim.fn.readfile(src), { 'PAYLOAD' }, 'the source copy remains')
    H.assert_eq(vim.fn.readfile(dst), { 'PAYLOAD' }, 'the destination copy committed')
    H.assert_notified(src, vim.log.levels.ERROR)
    H.assert_notified(dst, vim.log.levels.ERROR)
    H.assert_eq(history_lines('undo.log'), { HEADER, fixtures.move(src, dst) },
      'history records the committed destination for later recovery')
  end)

  H.it('RENAME (directory): moves the tree with trailing slashes on both ends', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'old')
    H.mkfile(ws, 'old/inner.txt', { 'i' })

    local _, ok = list_edit_and_sync(ws, { 'new/' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'new/', 'new/inner.txt' })
    H.assert_eq(history_lines('undo.log'),
      { HEADER, fixtures.move(ws .. '/old/', ws .. '/new/') })
  end)

  H.it('notifies a single joined summary of the applied actions', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'b.txt', 'c.txt' })
    H.capture_messages()
    H.with_cwd(ws, function()
      buf:sync()
    end)

    H.assert_notified('Created b.txt, Created c.txt', vim.log.levels.INFO)
  end)
end)
