-- tests/log_spec.lua -- whole-file line log contract.

local H = require('tests.support.harness')
local log = require('direct.log')

H.describe('log', function()
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

  H.it('clear() empties the log and creates it when absent', function()
    local sb = H.sandbox()
    local path = sb.root .. '/redo.log'
    H.assert_true(log.clear(path) == true, 'clear creates the file')
    H.assert_true(vim.fn.filereadable(path) == 1, 'file exists after clear')
    log.push(path, 'a')
    log.push(path, 'b')
    H.assert_eq(vim.fn.readfile(path), { 'a', 'b' }, 'pushed lines present')
    H.assert_true(log.clear(path) == true, 'clear succeeds')
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
end)
