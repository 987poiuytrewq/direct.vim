-- Integration tests for the read-only history gate and its side-effect order.
local H = require('tests.support.harness')
local history = require('direct.history')
local register = require('direct.register')
local action = require('direct.action')
local log = require('direct.log')
local buffer = require('direct.buffer')
local paths = require('direct.paths')
local fs = require('direct.fs')

local function history_dir(sb)
  return vim.fs.joinpath(sb.data_home, 'direct/history')
end

H.describe('history preflight', function()
  H.it('rejects invalid UTF-8 before creating data or register directories', function()
    local sb = H.sandbox()
    local bad = sb.root .. '/bad\255name'
    local ok, err = history.preflight({ bad })
    H.assert_nil(ok, 'invalid UTF-8 path is refused')
    H.assert_true(type(err) == 'string' and err:find('UTF-8', 1, true) ~= nil,
      'refusal explains invalid UTF-8')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct')), nil,
      'preflight creates no data directory')

    local yok = register.yank({ bad })
    H.assert_nil(yok, 'invalid path is rejected by yank before its register resolver')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct')), nil,
      'yank creates neither history nor register directories')
  end)

  H.it('an empty explicit paste destination is rejected before history or register access', function()
    local sb = H.sandbox()
    local content_calls = 0
    local restore = H.stub(register, 'content', function()
      content_calls = content_calls + 1
      return nil
    end)
    local result, err = register.paste('')
    restore()
    H.assert_nil(result, 'empty explicit destination is invalid')
    H.assert_true(type(err) == 'string', 'the error is returned')
    H.assert_eq(content_calls, 0, 'register pointer is not read')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct')),
      'no data directory is created')
  end)

  H.it('an invalid yank basename does not reset recognized legacy logs', function()
    local sb = H.sandbox()
    local hist = history_dir(sb)
    vim.fn.mkdir(hist, 'p')
    local undo_path = vim.fs.joinpath(hist, 'undo.log')
    local legacy = '#direct-history-v2\nmv\t/a\t/b\n'
    H.assert_true(log.write_raw_atomic(undo_path, legacy) == true,
      'recognized legacy fixture')

    local ok, err = register.yank({ '/' })

    H.assert_nil(ok, 'filesystem root is not a valid yank basename')
    H.assert_true(type(err) == 'string', 'validation returns a reason')
    H.assert_eq(log.read_raw(undo_path), legacy,
      'validation rejects the source before legacy classification/reset')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct/register')),
      'invalid yank creates no register directory')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(hist, 'redo.log')),
      'invalid yank creates no redo log')
  end)

  H.it('an unknown redo stack blocks paste before reading the register or changing files', function()
    local sb = H.sandbox()
    local hist = history_dir(sb)
    H.mkdir(sb.root, '')
    vim.fn.mkdir(hist, 'p')
    local redo_path = vim.fs.joinpath(hist, 'redo.log')
    local original = '#direct-history-v99\nfuture bytes\n'
    H.assert_true(log.write_raw_atomic(redo_path, original) == true,
      'unknown redo fixture')
    local dest = H.mkdir(sb.root, 'dest')
    local content_calls = 0
    local restore = H.stub(register, 'content', function()
      content_calls = content_calls + 1
      return nil
    end)

    H.capture_messages()
    local result = register.paste(dest)
    restore()

    H.assert_nil(result, 'paste is refused by preflight')
    H.assert_eq(content_calls, 0, 'register pointer was not read')
    H.assert_eq(log.read_raw(redo_path), original, 'unknown redo bytes remain exact')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(hist, 'undo.log')), nil,
      'the reset-eligible undo stack was not rewritten before the other stack was checked')
    H.assert_fs_eq(dest, {}, 'the destination tree is untouched')
    H.assert_notified('history was preserved')
  end)

  H.it('malformed history blocks sync before auto-yank or filesystem mutation', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'keep.txt', { 'keep' })
    H.mkfile(ws, 'delete.txt', { 'delete' })
    local hist = history_dir(sb)
    vim.fn.mkdir(hist, 'p')
    local redo_path = vim.fs.joinpath(hist, 'redo.log')
    local original = '#direct-history-v99\nopaque\n'
    H.assert_true(log.write_raw_atomic(redo_path, original) == true,
      'unknown redo fixture')

    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local yank_calls = 0
    local real_yank = register.yank
    local restore = H.stub(register, 'yank', function(...)
      yank_calls = yank_calls + 1
      return real_yank(...)
    end)

    H.capture_messages()
    local ok, err = listing:sync()
    restore()

    H.assert_nil(ok, 'sync is refused')
    H.assert_true(type(err) == 'string', 'sync carries the refusal reason')
    H.assert_eq(yank_calls, 0, 'auto-yank did not run')
    H.assert_eq(vim.fn.readfile(ws .. '/delete.txt'), { 'delete' },
      'the deleted entry remains on disk')
    H.assert_nil(register.content(), 'the register pointer was not changed')
    H.assert_eq(log.read_raw(redo_path), original, 'unknown redo bytes remain exact')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(hist, 'undo.log')), nil,
      'the other reset-eligible stack was not changed')
    H.assert_true(vim.bo.modified, 'the rejected edit remains in the buffer')
  end)

  H.it('undo classifies both stacks before popping or executing either one', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    vim.fn.mkdir(history_dir(sb), 'p')
    local undo_path = vim.fs.joinpath(history_dir(sb), 'undo.log')
    local redo_path = vim.fs.joinpath(history_dir(sb), 'redo.log')
    local valid = action.serialize(action.Move(ws .. '/a.txt', ws .. '/b.txt'))
    H.assert_true(log.write(undo_path, { history.HEADER, valid }) == true,
      'valid undo fixture')
    local unknown = '#direct-history-v100\nkeep me\n'
    H.assert_true(log.write_raw_atomic(redo_path, unknown) == true,
      'unknown redo fixture')

    H.capture_messages()
    H.assert_nil(history.undo(), 'both stacks are preflighted before pop')

    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'A' }, 'filesystem is untouched')
    H.assert_nil(vim.uv.fs_stat(ws .. '/b.txt'), 'the reversal did not run')
    H.assert_eq(log.read_raw(undo_path), history.HEADER .. '\n' .. valid .. '\n',
      'undo bytes are not popped')
    H.assert_eq(log.read_raw(redo_path), unknown, 'unknown redo bytes remain exact')
  end)

  H.it('reset failure aborts before auto-yank and leaves legacy bytes intact', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'delete.txt', { 'delete' })
    local hist = history_dir(sb)
    vim.fn.mkdir(hist, 'p')
    local undo_path = vim.fs.joinpath(hist, 'undo.log')
    local legacy = '#direct-history-v3\nmv\t/a\t/b\n'
    H.assert_true(log.write_raw_atomic(undo_path, legacy) == true,
      'recognized legacy fixture')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})

    local real_rename = log.uv.fs_rename
    local restore_rename = H.stub(log.uv, 'fs_rename', function()
      return nil, 'forced reset rename failure'
    end)
    local yank_calls = 0
    local restore_yank = H.stub(register, 'yank', function()
      yank_calls = yank_calls + 1
      return true
    end)
    local ok, err = listing:sync()
    restore_yank()
    restore_rename()
    H.assert_nil(ok, 'failed atomic reset aborts sync')
    H.assert_true(type(err) == 'string', 'failure reason is returned')
    H.assert_eq(yank_calls, 0, 'auto-yank did not run')
    H.assert_eq(log.read_raw(undo_path), legacy, 'old bytes remain unchanged')
    H.assert_eq(vim.fn.readfile(ws .. '/delete.txt'), { 'delete' },
      'filesystem mutation did not start')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(hist, 'redo.log')),
      'the second stack was not partially reset')
    -- Mention the capture so lint does not mistake this real syscall seam for an unused binding.
    H.assert_true(type(real_rename) == 'function', 'rename seam was captured')
  end)

  H.it('unreadable history fails closed before creating data directories', function()
    local sb = H.sandbox()
    local path = vim.fs.joinpath(sb.data_home, 'direct/history/undo.log')
    local restore = H.stub(log, 'read_raw', function()
      return nil, 'forced unreadable log', true
    end)
    local ok = history.preflight()
    restore()
    H.assert_nil(ok, 'unreadable log refuses the operation')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct')), nil,
      'unreadable history does not create its data directory')
    H.assert_true(type(path) == 'string', 'the absent history path was resolved purely')
  end)
end)
