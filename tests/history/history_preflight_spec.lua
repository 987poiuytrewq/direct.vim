-- Integration tests for the read-only history gate and its side-effect order.
local H = require('tests.support.harness')
local history = require('direct.history.history')
local register = require('direct.register')
local log = require('direct.log')
local buffer = require('direct.buffer.buffer')
local paths = require('direct.paths')
local fs = require('direct.fs')
local fixtures = require('tests.support.history_fixtures')

local function history_dir(sb)
  return vim.fs.joinpath(sb.data_home, 'direct/history')
end

H.describe('history preflight', function()
  H.it('acquires and releases the platform-native same-host process lock', function()
    local sb = H.sandbox()
    local ok, err = history.lock.acquire()
    H.assert_true(ok == true, 'process lock is acquired: ' .. tostring(err))
    H.assert_true(history.lock.release(), 'process lock is released')
    H.assert_true(vim.uv.fs_stat(sb.data_home) ~= nil,
      'the shared data home remains available after unlock')
  end)

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

  H.it('an unknown redo stack is silently discarded before paste reads the register', function()
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
    H.assert_eq(content_calls, 1, 'paste reads the register after history reset')
    H.assert_eq(log.read_raw(redo_path), fixtures.header .. '\n',
      'unknown redo bytes are discarded')
    H.assert_eq(log.read_raw(vim.fs.joinpath(hist, 'undo.log')),
      fixtures.header .. '\n', 'both stacks reset together')
    H.assert_fs_eq(dest, {}, 'the destination tree is untouched')
    H.assert_false(H.messages():find('resetting legacy', 1, true) ~= nil,
      'unsupported history is discarded silently')
  end)

  H.it('sync silently discards unsupported history before applying the requested edit', function()
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

    H.assert_true(ok == true, 'sync proceeds after unsupported history is discarded')
    H.assert_nil(err, 'sync has no error')
    H.assert_eq(yank_calls, 1, 'the deletion is auto-yanked')
    H.assert_nil(vim.uv.fs_stat(ws .. '/delete.txt'), 'the requested deletion applied')
    H.assert_true(type(register.content()) == 'string', 'the register pointer was written')
    H.assert_eq(log.read_raw(redo_path), fixtures.header .. '\n',
      'unsupported redo bytes were replaced')
    H.assert_true(log.read_raw(vim.fs.joinpath(hist, 'undo.log')):find(fixtures.header, 1, true) == 1,
      'the new action is recorded in the reset undo stack')
    H.assert_false(vim.bo.modified, 'successful sync clears the buffer')
    H.assert_false(H.messages():find('resetting legacy', 1, true) ~= nil,
      'unsupported history is discarded silently')
  end)

  H.it('unsupported redo history silently resets both stacks before undo', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    vim.fn.mkdir(history_dir(sb), 'p')
    local undo_path = vim.fs.joinpath(history_dir(sb), 'undo.log')
    local redo_path = vim.fs.joinpath(history_dir(sb), 'redo.log')
    local valid = fixtures.move(ws .. '/a.txt', ws .. '/b.txt')
    H.assert_true(log.write(undo_path, { fixtures.header, valid }) == true,
      'valid undo fixture')
    local unknown = '#direct-history-v100\nkeep me\n'
    H.assert_true(log.write_raw_atomic(redo_path, unknown) == true,
      'unknown redo fixture')

    H.capture_messages()
    H.assert_nil(history.undo(), 'the unsupported redo causes both histories to reset')

    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'A' }, 'filesystem is untouched')
    H.assert_nil(vim.uv.fs_stat(ws .. '/b.txt'), 'the reversal did not run')
    H.assert_eq(log.read_raw(undo_path), fixtures.header .. '\n',
      'the valid sibling stack is discarded too')
    H.assert_eq(log.read_raw(redo_path), fixtures.header .. '\n',
      'unsupported redo is discarded')
    H.assert_false(H.messages():find('resetting legacy', 1, true) ~= nil,
      'unsupported history is discarded silently')
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
