-- Legacy history is classified from raw bytes. Only recognized predecessors
-- are reset; malformed and unknown content must stay byte-identical.
local H = require('tests.support.harness')
local format = require('direct.history_format')
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
  local function assert_reset(raw, label)
    local result = format.classify(raw, true)
    H.assert_eq(result.state, 'reset', label .. ' is reset-eligible')
    H.assert_true(result.warn == true, label .. ' requests a warning')
  end

  local function assert_preserved(raw, label)
    local result = format.classify(raw, true)
    H.assert_eq(result.state, 'preserve', label .. ' is preserved')
    H.assert_true(type(result.reason) == 'string', label .. ' has a reason')
  end

  H.it('L-01 to L-03 reset absent, zero-byte, and marker-only logs', function()
    local absent = format.classify(nil, false)
    H.assert_eq(absent.state, 'reset', 'absent log resets')
    H.assert_true(absent.warn, 'absent log requests a warning')
    assert_reset('', 'zero-byte log')
    assert_reset(legacy(2), 'marker-only v2')
    assert_reset(legacy(3), 'marker-only v3')
  end)

  H.it('L-04 resets a valid v2 log containing all old action kinds', function()
    assert_reset(legacy(2, {
      'mv\t/a\t/b', 'rm\t/a\t/trash', 'rmdir\t/a/\t/trash',
      'rs\t/trash\t/a', 'rsdir\t/trash\t/a/', 'touch\t/a', 'mkdir\t/a',
      'p\t/reg\t/dst\t\t', 'up\t/dst\t/reg\t\t',
    }), 'valid v2 log')
  end)

  H.it('L-05 resets valid v3 groups and L-06/L-07 preserve bad groups', function()
    assert_reset(legacy(3, { 'g\t2\t/a\t/b\t/b\t/c' }), 'valid v3 group')
    assert_preserved(legacy(3, { 'g\t3\t/a\t/b\t/b\t/c' }),
      'count-mismatched v3 group')
    assert_preserved(legacy(2, { 'g\t2\t/a\t/b\t/b\t/c' }), 'v2 group')
  end)

  H.it('L-08 to L-10 preserve empty mandatory, extra, and missing fields', function()
    assert_preserved(legacy(3, { 'mv\t\t/b' }), 'empty mandatory field')
    assert_preserved(legacy(3, { 'mv\t/a\t/b\textra' }), 'extra field')
    assert_preserved(legacy(3, { 'mv\t/a' }), 'missing field')
  end)

  H.it('L-11 preserves ambiguous Lua names and L-12 accepts empty name fields', function()
    assert_preserved(legacy(3, { 'p\t/reg\t/dst\tmy file\tmy file' }),
      'ambiguous Lua name list')
    assert_reset(legacy(3, { 'p\t/reg\t/dst\t\t' }), 'empty Lua name lists')
    assert_reset(legacy(3, { 'p\t/reg\t/dst\tname\tname' }),
      'single unambiguous Lua name pair')
  end)

  H.it('L-13/L-14 recognize markerless Python framing without decoding names', function()
    assert_reset(bytes({ 'mv\t/a\t/b', 'touch\t/t', 'mkdir\t/d' }),
      'markerless Python log')
    assert_reset(bytes({ 'p\t/reg\t/dst\tmy file\tmy file',
      'up\t/dst\t/reg\tother name\tother name' }),
      'markerless Python log with opaque p/up name fields')
  end)

  H.it('L-15/L-16 preserve unknown verbs, groups, and old space-framed logs', function()
    assert_preserved(bytes({ 'g\t2\t/a\t/b\t/b\t/c' }), 'markerless group')
    assert_preserved(bytes({ 'future\t/a' }), 'markerless unknown verb')
    assert_preserved('#direct-history-v2\n/a b c\n', 'space-framed predecessor')
  end)

  H.it('L-17 to L-21 preserve byte-hygiene failures and unknown markers', function()
    assert_preserved('#direct-history-v3\r\n', 'CRLF log')
    assert_preserved('\239\187\191' .. legacy(3), 'BOM log')
    assert_preserved('#direct-history-v3\n\0\n', 'NUL log')
    assert_preserved('#direct-history-v3', 'missing final LF')
    assert_preserved(bytes({ '#direct-history-v4' }), 'future marker')
    assert_preserved('#direct-history-v3\n\255\n', 'invalid UTF-8')
  end)

  H.it('L-23 preserves a known marker with a malformed body', function()
    assert_preserved(legacy(3, { 'mv\t/a\t/b\textra' }),
      'known marker and malformed body')
  end)

  H.it('current JSONL accepts canonical records and preserves malformed records', function()
    H.assert_eq(format.HEADER, fixtures.header, 'the current header is an exact fixture')
    local good = bytes({ fixtures.header, '{"op":"mv","src":"/a","dst":"/b"}' })
    H.assert_eq(format.classify(good, true).state, 'current', 'canonical JSONL')
    local bad = bytes({ fixtures.header, '{"op":"mv","src":"/a"}' })
    assert_preserved(bad, 'JSONL with a missing key')
    local noncanonical = bytes({ fixtures.header, '{ "op":"touch","dst":"/t"}' })
    assert_preserved(noncanonical, 'non-canonical JSONL record')
  end)
end)
