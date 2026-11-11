-- sync_plan_spec.lua -- sync: classification, sync: ambiguous.
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

  H.it('delete a first root row and add at the end without pairing by position', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'content a' })
    H.mkfile(ws, 'b.txt', { 'content b' })
    H.mkfile(ws, 'c.txt', { 'content c' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new.txt' })
    local synced, sync_err = buf:sync()

    H.assert_true(synced, 'the mixed delete/create save succeeds: ' .. tostring(sync_err))
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'a.txt')), 'a.txt is deleted')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'b.txt')), { 'content b' },
      'b.txt keeps its original contents instead of taking a.txt by position')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'c.txt')), { 'content c' },
      'c.txt keeps its original contents instead of taking b.txt by position')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'new.txt')), {},
      'new.txt is created empty instead of taking c.txt by position')
    H.assert_true(register.content() ~= nil, 'the deleted entry was yanked')

    local undo = history_lines('undo.log')
    H.assert_eq(#undo, 2, 'the mixed save is one history action')
    local batch_record = vim.json.decode(undo[2])
    H.assert_eq(batch_record.op, 'batch', 'the mixed save is persisted as one batch record')
    H.assert_eq(#batch_record.actions, 2, 'the batch contains both filesystem actions')
    H.assert_true(require('direct').undo() ~= nil, 'one undo starts for the whole save')
    H.assert_true(vim.wait(5000, function()
      return vim.uv.fs_stat(vim.fs.joinpath(ws, 'a.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'b.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'c.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) == nil
    end), 'one undo restores all three original files')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a.txt')), { 'content a' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'b.txt')), { 'content b' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'c.txt')), { 'content c' })
    H.assert_eq(#history_lines('redo.log'), 2, 'the one undo creates one redo entry')
    H.assert_true(require('direct').redo() ~= nil, 'one redo starts for the whole save')
    H.assert_true(vim.wait(5000, function()
      return vim.uv.fs_stat(vim.fs.joinpath(ws, 'a.txt')) == nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'b.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'c.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) ~= nil
    end), 'one redo reapplies the entire mixed save')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'b.txt')), { 'content b' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'c.txt')), { 'content c' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'new.txt')), {})
  end)
end)
H.describe('sync: mixed root edits', function()
  H.it('treats a whole-line replacement without its mark as delete plus create', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', { 'original contents' })
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new.txt' })

    local ok, err = listing:sync()

    H.assert_true(ok, tostring(err))
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'old.txt')),
      'the old marked entry is removed')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'new.txt')), {},
      'an unmarked replacement is a new empty entry, not a positional rename')
    local content = register.content()
    H.assert_not_nil(content, 'the removed source is auto-yanked')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(content, 'old.txt')), { 'original contents' },
      'the deleted contents remain available in the register')
    H.assert_eq(#history_lines('undo.log'), 2, 'delete and create are one history entry')

    require('direct').undo()
    H.assert_true(vim.wait(5000, function()
      return vim.uv.fs_stat(vim.fs.joinpath(ws, 'old.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) == nil
    end), 'one undo restores the original row')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'old.txt')), { 'original contents' })
  end)

  H.it('saves a rename after an unrelated root entry appears on disk', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', { 'original' })
    H.mkfile(ws, 'untouched.txt', { 'unchanged' })
    local listing = buffer.list(ws)
    H.mkfile(ws, 'external.txt', { 'external' })
    vim.fn.delete(vim.fs.joinpath(ws, 'untouched.txt'))
    vim.api.nvim_buf_set_text(0, 0, 0, 0, #('old.txt'), { 'renamed.txt' })

    local ok, err = listing:sync()

    H.assert_true(ok, 'unrelated external entries do not block a safe rename: ' .. tostring(err))
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'old.txt')), 'the source is renamed')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'renamed.txt')), { 'original' },
      'the original file contents follow the requested rename')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'external.txt')), { 'external' },
      'the unrelated external creation remains untouched')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'untouched.txt')),
      'the unrelated external deletion is reconciled by the final re-list')
    H.assert_false(vim.bo.modified, 'the listing refreshes after the save')
  end)

  H.it('refuses a rename when its source is replaced on disk', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', { 'original' })
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_text(0, 0, 0, 0, #('old.txt'), { 'renamed.txt' })
    vim.fn.delete(vim.fs.joinpath(ws, 'old.txt'))
    H.mkfile(ws, 'old.txt', { 'external replacement' })

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'a changed edited source remains a conflict')
    H.assert_true(tostring(reason):find('old.txt', 1, true) ~= nil, tostring(reason))
    H.assert_true(tostring(reason):find('re-list this directory', 1, true) ~= nil,
      'the refusal explains how to recover')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'old.txt')), { 'external replacement' },
      'the external replacement remains untouched')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'renamed.txt')),
      'the requested rename does not run')
    H.assert_true(vim.bo.modified, 'the requested edit remains available')
  end)

  H.it('refuses a rename when an external entry takes its destination name', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', { 'original' })
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_text(0, 0, 0, 0, #('old.txt'), { 'renamed.txt' })
    H.mkfile(ws, 'renamed.txt', { 'external destination' })

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'a newly occupied rename destination is refused')
    H.assert_true(tostring(reason):find('destination already exists', 1, true) ~= nil,
      tostring(reason))
    H.assert_true(tostring(reason):find('choose another name', 1, true) ~= nil,
      'the refusal offers a safe next step: ' .. tostring(reason))
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'old.txt')), { 'original' },
      'the rename source remains untouched')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'renamed.txt')), { 'external destination' },
      'the external target remains untouched')
    H.assert_true(vim.bo.modified, 'the requested edit remains available')
  end)

  H.it('combines mixed root edits with a rename inside an expanded directory', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(ws, 'a-root.txt', { 'root A' })
    H.mkfile(ws, 'b-root.txt', { 'root B' })
    H.mkfile(sub, 'inside.txt', { 'child' })
    local listing = buffer.list(ws)
    listing:expand(1)

    vim.api.nvim_buf_set_text(0, 2, 2, 2, #('a-root.txt'), { 'renamed.txt' })
    vim.api.nvim_buf_set_text(0, 1, 2, 1, #('  inside.txt'), { 'child-renamed.txt' })
    vim.api.nvim_buf_set_lines(0, 3, 4, false, {})
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new.txt' })

    local ok, err = listing:sync()

    H.assert_true(ok, tostring(err))
    H.assert_fs_eq(ws, {
      'a-renamed.txt', 'new.txt', 'sub/', 'sub/child-renamed.txt',
    }, 'root and expanded-child actions are applied together')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a-renamed.txt')), { 'root A' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'sub/child-renamed.txt')), { 'child' })
    local content = register.content()
    H.assert_not_nil(content, 'the root deletion is auto-yanked')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(content, 'b-root.txt')), { 'root B' })
    H.assert_eq(#history_lines('undo.log'), 2,
      'the combined root and child save is one undo entry')

    H.assert_true(require('direct').undo() ~= nil, 'one undo reverses the whole save')
    H.assert_true(vim.wait(5000, function()
      return vim.uv.fs_stat(vim.fs.joinpath(ws, 'a-root.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'b-root.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) == nil
        and vim.uv.fs_stat(vim.fs.joinpath(sub, 'inside.txt')) ~= nil
    end), 'the undo restores root and child paths')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a-root.txt')), { 'root A' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sub, 'inside.txt')), { 'child' })
  end)

  H.it('deletes an occupied root target before a mixed-save rename reuses it', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(ws, 'a.txt', { 'original a' })
    H.mkfile(ws, 'b.txt', { 'original b' })
    H.mkfile(sub, 'inside.txt', { 'child' })
    local listing = buffer.list(ws)
    listing:expand(1)

    -- Remove a, preserve b's row mark while renaming it into a, and also edit
    -- an expanded child. The new root entry has no mark and is a create.
    vim.api.nvim_buf_set_lines(0, 2, 3, false, {})
    vim.api.nvim_buf_set_text(0, 2, 0, 2, #('b.txt'), { 'a.txt' })
    vim.api.nvim_buf_set_text(0, 1, 2, 1, #('  inside.txt'), { 'child-renamed.txt' })
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new.txt' })

    local ok, err = listing:sync()

    H.assert_true(ok, tostring(err))
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a.txt')), { 'original b' },
      'the renamed entry replaces only the explicitly deleted destination')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'b.txt')))
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'new.txt')), {})
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sub, 'child-renamed.txt')), { 'child' })
    local content = register.content()
    H.assert_not_nil(content, 'the displaced destination is auto-yanked')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(content, 'a.txt')), { 'original a' })
    H.assert_eq(#history_lines('undo.log'), 2, 'the whole edit is one batch history entry')

    require('direct').undo()
    H.assert_true(vim.wait(5000, function()
      return vim.uv.fs_stat(vim.fs.joinpath(ws, 'a.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'b.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) == nil
        and vim.uv.fs_stat(vim.fs.joinpath(sub, 'inside.txt')) ~= nil
    end), 'one undo restores the original root and child entries')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a.txt')), { 'original a' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'b.txt')), { 'original b' })
  end)

  H.it('deletes an occupied destination before renaming another row into it', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'content a' })
    H.mkfile(ws, 'b.txt', { 'content b' })
    local buf = buffer.list(ws)

    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    vim.api.nvim_buf_set_text(0, 0, 0, 0, #('b.txt'), { 'a.txt' })
    local ok, err = buf:sync()

    H.assert_true(ok, tostring(err))
    H.assert_fs_eq(ws, { 'a.txt' }, 'only the renamed row remains')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a.txt')), { 'content b' },
      'the destination receives b.txt, not the deleted a.txt')
    H.assert_true(register.content() ~= nil, 'the removed destination is yanked')
    H.assert_eq(#history_lines('undo.log'), 2, 'delete and rename share one history entry')

    require('direct').undo()
    H.assert_true(vim.wait(5000, function()
      return vim.uv.fs_stat(vim.fs.joinpath(ws, 'a.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'b.txt')) ~= nil
    end), 'one undo restores both original names')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a.txt')), { 'content a' })
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'b.txt')), { 'content b' })
  end)

  H.it('combines a marked rename and an unmarked create in one save', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b.txt', { 'content b' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_text(0, 1, 0, 1, #('b.txt'), { 'x.txt' })
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'y.txt' })
    local ok, reason = buf:sync()

    H.assert_true(ok, tostring(reason))
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(ws, 'b.txt')),
      'the marked source is renamed')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'x.txt')), { 'content b' },
      'the rename preserves the marked file contents')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'y.txt')), {},
      'the unmarked row is created')
    H.assert_eq(#history_lines('undo.log'), 2, 'both actions share one undo record')
    H.assert_true(require('direct').undo() ~= nil, 'one undo reverses both actions')
    H.assert_true(vim.wait(5000, function()
      return vim.uv.fs_stat(vim.fs.joinpath(ws, 'b.txt')) ~= nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'x.txt')) == nil
        and vim.uv.fs_stat(vim.fs.joinpath(ws, 'y.txt')) == nil
    end), 'one undo restores the rename source and removes the create')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'b.txt')), { 'content b' })
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
