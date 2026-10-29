-- tests/log_spec.lua -- whole-file line log contract.

local H = require('tests.support.harness')
local log = require('direct.log')

H.describe('log', function()
  H.it('read_raw distinguishes absence and preserves bytes without line decoding', function()
    local sb = H.sandbox()
    local path = sb.root .. '/raw.log'
    local missing, missing_err, exists = log.read_raw(path)
    H.assert_nil(missing, 'missing file has no bytes')
    H.assert_nil(missing_err, 'missing file is not an IO error')
    H.assert_false(exists, 'missing file is explicitly distinguished')

    local raw = '\239\187\191line\0\r\n'
    H.assert_true(log.write_raw_atomic(path, raw) == true, 'raw fixture written')
    local bytes, err, found = log.read_raw(path)
    H.assert_eq(bytes, raw, 'BOM, NUL, CRLF, and final LF are byte-identical')
    H.assert_nil(err, 'raw read succeeds')
    H.assert_true(found, 'existing file is reported')
  end)

  H.it('read_raw fails closed on a non-regular history path', function()
    local sb = H.sandbox()
    local path = H.mkdir(sb.root, 'not-a-file')
    local bytes, err, exists = log.read_raw(path)
    H.assert_nil(bytes, 'a directory is not returned as history bytes')
    H.assert_true(type(err) == 'string', 'the invalid path carries a reason')
    H.assert_true(exists, 'the non-regular path is present')
  end)

  H.it('push/pop round trip over 20 lines', function()
    local sb = H.sandbox()
    local path = sb.root .. '/undo.log'
    for i = 1, 20 do
      H.assert_true(log.push(path, 'line' .. i) == true, 'push ' .. i)
    end
    H.assert_eq(#vim.fn.readfile(path), 20, '20 lines appended')
    for i = 20, 1, -1 do
      H.assert_eq(log.pop(path), 'line' .. i, 'pop returns line ' .. i)
    end
    H.assert_true(vim.fn.filereadable(path) == 1, 'file still exists')
    H.assert_eq(vim.fn.readfile(path), {}, 'empty after popping every line')
  end)

  H.it('popping the only line leaves an empty file and returns the line', function()
    local sb = H.sandbox()
    local path = sb.root .. '/undo.log'
    log.push(path, 'only')
    H.assert_eq(log.pop(path), 'only', 'the line is returned')
    H.assert_true(vim.fn.filereadable(path) == 1, 'file still exists')
    H.assert_eq(vim.fn.readfile(path), {}, 'file is left empty')
  end)

  H.it('popping an empty or missing log returns nil without E484', function()
    local sb = H.sandbox()
    local path = sb.root .. '/missing.log'
    H.assert_false(vim.fn.filereadable(path) == 1, 'precondition: file missing')
    H.assert_nil(log.pop(path), 'pop on a missing file returns nil')
    log.push(path, 'x')
    log.pop(path)
    H.assert_nil(log.pop(path), 'pop on an empty file returns nil')
    H.assert_eq(log.read(path), {}, 'read of an empty file is {}')
  end)

  H.it('write() can create and empty a log', function()
    local sb = H.sandbox()
    local path = sb.root .. '/redo.log'
    H.assert_true(log.write(path, {}) == true, 'empty write creates the file')
    H.assert_true(vim.fn.filereadable(path) == 1, 'file exists after empty write')
    log.push(path, 'a')
    log.push(path, 'b')
    H.assert_eq(vim.fn.readfile(path), { 'a', 'b' }, 'pushed lines present')
    H.assert_true(log.write(path, {}) == true, 'empty write succeeds')
    H.assert_eq(vim.fn.readfile(path), {}, 'log emptied')
  end)

  H.it('push() rejects a non-string line without writing', function()
    local sb = H.sandbox()
    local path = sb.root .. '/typecheck.log'
    local r, e = log.push(path, 42)
    H.assert_nil(r, 'push(non-string) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'push(non-string) carries an err')
    H.assert_eq(vim.fn.filereadable(path), 0, 'nothing was appended or created')
    log.push(path, 'ok')
    H.assert_eq(vim.fn.readfile(path), { 'ok' }, 'only the valid push reached the file')
  end)

  -- The history version marker has to control the FIRST line of the file, so the
  -- history module needs a whole-file write that is neither an append nor
  -- clear({'a','b'}).
  H.it('write() replaces the whole file with the given lines', function()
    local sb = H.sandbox()
    local path = sb.root .. '/undo.log'
    H.assert_true(log.write(path, { '#direct-history-v2' }) == true,
      'write creates the file')
    H.assert_eq(vim.fn.readfile(path), { '#direct-history-v2' },
      'the given lines are the whole file')
    log.push(path, 'mv\ta\tb')
    H.assert_eq(vim.fn.readfile(path), { '#direct-history-v2', 'mv\ta\tb' },
      'precondition: an appended entry follows the marker')
    H.assert_true(log.write(path, { '#direct-history-v2' }) == true, 'overwrite succeeds')
    H.assert_eq(vim.fn.readfile(path), { '#direct-history-v2' },
      'the previous content is gone, not appended to')
  end)

  H.it('write() rejects a non-table without touching the file', function()
    local sb = H.sandbox()
    local path = sb.root .. '/typecheck2.log'
    local r, e = log.write(path, 'not a table')
    H.assert_nil(r, 'write(non-table) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'write(non-table) carries an err')
    H.assert_eq(vim.fn.filereadable(path), 0, 'nothing was created')
    log.write(path, { 'keep' })
    local r2 = log.write(path, nil)
    H.assert_nil(r2, 'write(nil) returns nil')
    H.assert_eq(vim.fn.readfile(path), { 'keep' }, 'the existing file is untouched')
  end)

  H.it('atomic rewrite retries an exclusive temp collision without touching it', function()
    local sb = H.sandbox()
    local path = sb.root .. '/undo.log'
    H.assert_true(log.write(path, { 'original' }) == true, 'initial log')
    local real_open, real_write, real_close = log.uv.fs_open,
      log.uv.fs_write, log.uv.fs_close
    local collision, injected = nil, false
    local restore = H.stub(log.uv, 'fs_open', function(candidate, flags, mode)
      if not injected and flags == 'wx' then
        injected, collision = true, candidate
        local fd = real_open(candidate, 'wx', mode)
        assert(fd)
        assert(real_write(fd, 'foreign-temp-bytes', 0))
        assert(real_close(fd))
        return nil, 'file exists', 'EEXIST'
      end
      return real_open(candidate, flags, mode)
    end)

    H.assert_true(log.write(path, { 'replacement' }) == true,
      'write retries with another unique temp')
    restore()

    H.assert_eq(log.read_raw(path), 'replacement\n', 'owned history was replaced')
    H.assert_eq(log.read_raw(collision), 'foreign-temp-bytes',
      'the colliding temp belongs to someone else and remains untouched')
  end)

  H.it('partial write, fsync, close, and rename failures preserve old bytes and clean own temps', function()
    local sb = H.sandbox()
    local path = sb.root .. '/undo.log'
    local faults = { 'partial write', 'fsync', 'close', 'rename' }
    for _, fault in ipairs(faults) do
      H.assert_true(log.write(path, { 'original-' .. fault }) == true,
        'initial ' .. fault .. ' content')
      local before = log.read_raw(path)
      local restores = {}
      if fault == 'partial write' then
        local real = log.uv.fs_write
        restores[#restores + 1] = H.stub(log.uv, 'fs_write', function(fd, bytes, offset)
          real(fd, bytes:sub(1, math.min(2, #bytes)), offset)
          return nil, 'forced partial write failure'
        end)
      elseif fault == 'fsync' then
        restores[#restores + 1] = H.stub(log.uv, 'fs_fsync',
          function() return nil, 'forced fsync failure' end)
      elseif fault == 'close' then
        local real = log.uv.fs_close
        restores[#restores + 1] = H.stub(log.uv, 'fs_close', function(fd)
          real(fd)
          return nil, 'forced close failure'
        end)
      else
        restores[#restores + 1] = H.stub(log.uv, 'fs_rename',
          function() return nil, 'forced rename failure' end)
      end

      local ok, err = log.write(path, { 'replacement' })
      for i = #restores, 1, -1 do restores[i]() end

      H.assert_nil(ok, fault .. ' is reported')
      H.assert_true(type(err) == 'string' and #err > 0, fault .. ' has an error')
      H.assert_eq(log.read_raw(path), before, fault .. ' leaves original bytes unchanged')
      H.assert_eq(vim.fn.glob(path .. '.direct-tmp-*'), '',
        fault .. ' removes only its own temp')
    end
  end)
end)
