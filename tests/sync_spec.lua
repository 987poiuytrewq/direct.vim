-- tests/sync_spec.lua -- end-to-end sync classification and application.
-- Exercises filesystem changes, history, buffer state, and notifications.

local H = require('tests.support.harness')
local buffer = require('direct.buffer')
local fs = require('direct.fs')
local paths = require('direct.paths')
local history = require('direct.history')
local register = require('direct.register')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

-- history_lines(name) -> the lines of history/<name>, {} when absent.
local function history_lines(name)
  local dir = paths.data_dir('history')
  local path = paths.join(dir, name)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  return vim.fn.readfile(path)
end

-- list_edit_and_sync(ws, lines) -> buf, ok, reason. Lists ws, replaces the
-- buffer with `lines`, then syncs.
local function list_edit_and_sync(ws, lines)
  local buf = buffer.list(ws)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local ok, reason = buf:sync()
  return buf, ok, reason
end

H.describe('sync: classification', function()
  H.it('duplicate wins over every class; then ADD/DELETE/RENAME; else mixed', function()
    H.assert_eq(buffer.classify({ 'a', 'a' }, { 'a' }),
      { kind = 'AMBIGUOUS', reason = 'duplicate' }, 'duplicate is checked first')

    H.assert_eq(buffer.classify({ 'a', 'b' }, { 'a' }), { kind = 'ADD', added = { 'b' } })
    H.assert_eq(buffer.classify({ 'b', 'a/' }, {}), { kind = 'ADD', added = { 'a/', 'b' } },
      'ADD is emitted dirs-then-name')

    H.assert_eq(buffer.classify({ 'a' }, { 'a', 'b' }), { kind = 'DELETE', removed = { 'b' } })
    H.assert_eq(buffer.classify({}, { 'b', 'a/' }),
      { kind = 'DELETE', removed = { 'a/', 'b' } }, 'DELETE is emitted dirs-then-name')

    H.assert_eq(buffer.classify({ 'b' }, { 'a' }),
      { kind = 'RENAME', moves = { { src = 'a', dst = 'b' } } })

    H.assert_eq(buffer.classify({ 'a', 'x', 'y' }, { 'a', 'b' }),
      { kind = 'AMBIGUOUS', reason = 'mixed' }, 'neither subset nor equal length -> mixed')
  end)
end)

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
      { '#direct-history-v3', 'touch\t' .. ws .. '/b.txt' }, 'exactly one touch line')
    H.assert_eq(history_lines('redo.log'), { '#direct-history-v3' },
      'a new action resets the redo branch to its marker')
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
      '#direct-history-v3',
      'mkdir\t' .. ws .. '/adir/',
      'mkdir\t' .. ws .. '/zdir/',
      'touch\t' .. ws .. '/afile.txt',
    }, 'directories first, then files, each sorted')
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
    H.assert_eq(undo[1], '#direct-history-v3', 'the log is version-marked')
    H.assert_true(undo[2]:sub(1, 3) == 'rm\t', 'an rm line was logged')
    H.assert_true(undo[2]:find(ws .. '/b.txt\t', 1, true) ~= nil, 'the rm line names the source')
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
    H.assert_true(undo[2]:sub(1, 6) == 'rmdir\t', 'an rmdir line was logged')
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
    buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    H.capture_messages()
    vim.cmd('write')

    H.assert_fs_eq(ws, { 'keep.txt' }, 'a.txt was deleted through the :write sync')
    H.assert_not_nil(register.content(), 'the auto-yank recorded the register pointer')

    local dst = H.mkdir(sb.root, 'dst')
    H.assert_true(register.paste(dst, false) ~= nil, 'the auto-yanked entry pastes back')
    H.assert_fs_eq(dst, { 'a.txt' }, 'the deleted entry landed in the paste destination')
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'A' },
      'the entry content survived the delete/paste round trip')
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
      { '#direct-history-v3', 'mv\t' .. ws .. '/a.txt\t' .. ws .. '/b.txt' })
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
      { '#direct-history-v3', 'mv\t' .. ws .. '/old/\t' .. ws .. '/new/' })
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

H.describe('sync: ambiguous', function()
  H.it('mixed add+delete: notifies reason and both sides, changes nothing, stays modified', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b.txt', { 'b' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'x.txt', 'y.txt' })
    H.capture_messages()
    local ok, reason = buf:sync()

    H.assert_false(ok == true, 'nothing was applied')
    H.assert_eq(reason, 'mixed', 'the reason')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'no filesystem change')
    H.assert_eq(history_lines('undo.log'), {}, 'no history was written')
    H.assert_true(vim.bo.modified, 'the buffer stays modified')
    H.assert_buf_eq({ 'a.txt', 'x.txt', 'y.txt' }, 0, 'the buffer was NOT re-listed')
    H.assert_notified('Ambiguous buffer content (mixed)', vim.log.levels.ERROR)
    H.assert_notified('actual:   a.txt, x.txt, y.txt', vim.log.levels.ERROR)
    H.assert_notified('expected: a.txt, b.txt', vim.log.levels.ERROR)
  end)

  H.it('a duplicated line is reported as ambiguous, not collapsed', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b.txt', { 'b' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'a.txt' })
    H.capture_messages()
    local ok, reason = buf:sync()

    H.assert_false(ok == true, 'nothing was applied')
    H.assert_eq(reason, 'duplicate', 'the reason')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'no filesystem change')
    H.assert_eq(history_lines('undo.log'), {}, 'no history was written')
    H.assert_true(vim.bo.modified, 'the buffer stays modified')
    H.assert_notified('Ambiguous buffer content (duplicate)', vim.log.levels.ERROR)
  end)
end)

H.describe('sync: safety guards', function()
  H.it('swap rename (a<->b) completes with no data loss and no leftover temp', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })

    local _, ok = list_edit_and_sync(ws, { 'b.txt', 'a.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'exactly two files, no .direct-tmp-*')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'B' }, 'a.txt received the swapped content')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'A' }, 'b.txt received the swapped content')
  end)

  H.it('chain rename (a->b->c->d) completes with no leftovers', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })
    H.mkfile(ws, 'c.txt', { 'C' })

    local _, ok = list_edit_and_sync(ws, { 'b.txt', 'c.txt', 'd.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'b.txt', 'c.txt', 'd.txt' }, 'no .direct-tmp-* remains')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'A' })
    H.assert_eq(vim.fn.readfile(ws .. '/c.txt'), { 'B' })
    H.assert_eq(vim.fn.readfile(ws .. '/d.txt'), { 'C' })
  end)

  H.it('a failed staging rename reports the orphaned temp instead of leaving it silent', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b.txt', 'a.txt' })

    -- Fail the SECOND staging rename (b.txt -> .direct-tmp-2): the first
    -- staging rename (a.txt -> .direct-tmp-1) already succeeded, so a.txt is
    -- now parked at that temp path and MUST be reported rather than orphaned.
    local real_rename = fs.rename
    local staged = 0
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if staged == 2 then
          return nil, 'EACCES'
        end
      end
      return real_rename(src, dst)
    end)
    H.capture_messages()
    local ok, reason = buf:sync()
    restore()

    H.assert_nil(ok, 'the staging failure refuses the sync')
    H.assert_eq(reason, 'EACCES', 'the staging error is returned')
    H.assert_notified('could not stage renames')

    local tmp = ws .. '/.direct-tmp-1'
    H.assert_true(fs.exists(tmp), 'the first entry really was staged to a temp')
    H.assert_notified(tmp, 'the orphaned staged path is named, never silent')
    H.assert_eq(vim.fn.readfile(tmp), { 'A' },
      'the orphaned temp still holds the entry moved out of a.txt')
    -- No action ran after the failed staging and no history line was written.
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'B' },
      'b.txt is untouched (its staging rename failed before it moved)')
    H.assert_eq(history_lines('undo.log'), {}, 'no history was written')
    H.assert_true(vim.bo.modified, 'the refused sync leaves the buffer modified')
  end)

  H.it('a path the history framing cannot represent is refused before any change', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    local buf = buffer.list(ws)
    -- A tab would break the `NAME\tfield...` line framing of the history log.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'we\tird' })
    H.capture_messages()
    local ok, reason = buf:sync()

    H.assert_false(ok == true, 'nothing was applied')
    H.assert_eq(reason, 'contains a tab')
    H.assert_fs_eq(ws, { 'a.txt' }, 'no filesystem change')
    H.assert_eq(history_lines('undo.log'), {}, 'no history was written')
    H.assert_true(vim.bo.modified, 'the buffer stays modified')
    H.assert_notified('Unsafe entry', vim.log.levels.ERROR)
  end)

  H.it('an unsafe name on the DISK side is refused too', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    -- A file literally named with a tab; the fresh listing therefore carries an
    -- unrepresentable path even though the buffer was not edited.
    H.mkfile(ws, 'a\tb', { 'x' })

    local buf = buffer.list(ws)
    H.capture_messages()
    local ok, reason = buf:sync()

    H.assert_false(ok == true, 'nothing was applied')
    H.assert_eq(reason, 'contains a tab')
    H.assert_notified('Unsafe entry', vim.log.levels.ERROR)
  end)

  H.it('a failing action is reported, the others apply, and only successes are logged/undoable', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'b.txt', 'c.txt' })

    local real_touch = fs.touch
    local restore = H.stub(fs, 'touch', function(path)
      if path == ws .. '/c.txt' then
        return nil, 'boom'
      end
      return real_touch(path)
    end)
    H.capture_messages()
    local ok
    H.with_cwd(ws, function()
      ok = buf:sync()
    end)
    restore()

    H.assert_true(ok == true, 'the buffer is still re-listed and sync returns applied')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'b.txt applied, c.txt failed')
    H.assert_buf_eq({ 'a.txt', 'b.txt' }, 0, 'the buffer matches reality after partial failure')
    H.assert_notified('Action failed - Created c.txt', vim.log.levels.ERROR)
    H.assert_notified('1 action(s) failed', vim.log.levels.ERROR)
    H.assert_eq(history_lines('undo.log'),
      { '#direct-history-v3', 'touch\t' .. ws .. '/b.txt' },
      'only the successful action reached history')

    H.assert_true(history.undo() ~= nil, 'the logged success is undoable')
    H.assert_fs_eq(ws, { 'a.txt' }, 'undo reversed the created file')
  end)
end)
