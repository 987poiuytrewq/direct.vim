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
