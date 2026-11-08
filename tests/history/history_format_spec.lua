-- Classify fresh, current, known legacy, and damaged history without mutation.
local H = require('tests.support.harness')
local format = require('direct.history.format')
local fixtures = require('tests.support.history_fixtures')

local function bytes(lines)
  return table.concat(lines, '\n') .. '\n'
end

local function legacy(version, records)
  local lines = { '#direct-history-v' .. version }
  for _, record in ipairs(records or {}) do lines[#lines + 1] = record end
  return bytes(lines)
end

H.describe('history format classifier', function()
  local function assert_fresh(raw, label, exists)
    H.assert_eq(format.classify(raw, exists ~= false).state, 'fresh',
      label .. ' starts with empty history')
  end

  local function assert_legacy(raw, label)
    local result = format.classify(raw, true)
    H.assert_eq(result.state, 'legacy', label .. ' is recognized as legacy')
    H.assert_true(result.legacy, label .. ' is marked for backup before reset')
  end

  local function assert_preserved(raw, label)
    local result = format.classify(raw, true)
    H.assert_eq(result.state, 'preserve', label .. ' is preserved and blocks operations')
    H.assert_true(type(result.reason) == 'string' and result.reason ~= '',
      label .. ' has a diagnostic reason')
  end

  H.it('treats absent and empty files as fresh history', function()
    assert_fresh(nil, 'absent file', false)
    assert_fresh('', 'empty file')
  end)

  H.it('recognizes valid v2/v3 tab logs and markerless Python logs as legacy', function()
    assert_legacy(legacy(2, {
      'mv\t/a\t/b', 'rm\t/a\t/trash', 'rmdir\t/a/\t/trash',
      'rs\t/trash\t/a', 'rsdir\t/trash\t/a/', 'touch\t/a', 'mkdir\t/a',
      'p\t/reg\t/dst\t\t', 'up\t/dst\t/reg\t\t',
    }), 'valid v2 log')
    assert_legacy(legacy(3, { 'g\t2\t/a\t/b\t/b\t/c' }), 'valid v3 group log')
    assert_legacy(bytes({ 'mv\t/a\t/b', 'touch\t/t', 'mkdir\t/d' }),
      'valid markerless Python log')
  end)

  H.it('preserves malformed legacy bodies rather than treating them as resettable', function()
    assert_preserved(legacy(2, { 'g\t2\t/a\t/b\t/b\t/c' }), 'v2 group')
    assert_preserved(legacy(3, { 'g\t3\t/a\t/b\t/b\t/c' }), 'bad v3 group count')
    assert_preserved(legacy(3, { 'mv\t\t/b' }), 'empty mandatory field')
    assert_preserved(legacy(3, { 'mv\t/a\t/b\textra' }), 'extra field')
    assert_preserved(legacy(3, { 'mv\t/a' }), 'missing field')
    assert_preserved(bytes({ 'future\t/a' }), 'unknown markerless verb')
  end)

  H.it('preserves newer, malformed, invalid-byte, and unterminated logs', function()
    assert_preserved(bytes({ '#direct-history-v4' }), 'future marker')
    assert_preserved('#direct-history-v3', 'missing final LF')
    assert_preserved('#direct-history-v3\r\n', 'CRLF log')
    assert_preserved('\239\187\191' .. legacy(3), 'BOM log')
    assert_preserved('#direct-history-v3\n\0\n', 'NUL log')
    assert_preserved('#direct-history-v3\n\255\n', 'invalid UTF-8')
  end)

  H.it('accepts canonical current JSONL and preserves malformed current records', function()
    H.assert_eq(format.HEADER, fixtures.header, 'current header is exact')
    local good = bytes({ fixtures.header, '{"op":"mv","src":"/a","dst":"/b"}' })
    H.assert_eq(format.classify(good, true).state, 'current', 'canonical JSONL')
    assert_preserved(bytes({ fixtures.header, '{"op":"mv","src":"/a"}' }),
      'current JSONL with a missing key')
    assert_preserved(bytes({ fixtures.header, '{ "op":"touch","dst":"/t"}' }),
      'non-canonical current JSONL')
  end)
end)
