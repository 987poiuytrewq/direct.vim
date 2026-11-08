-- Shared setup and helpers for the sync-focused spec files.
local M = {}

function M.new()
  local H = require('tests.support.harness')
  local buffer = require('direct.buffer.buffer')
  local fs = require('direct.fs')
  local paths = require('direct.paths')
  local history = require('direct.history.history')
  local register = require('direct.register')
  local fixtures = require('tests.support.history_fixtures')

  local function decode_record(lines, index)
    return vim.json.decode(lines[index])
  end

  local function clean_buffers()
    pcall(vim.cmd, '%bwipeout!')
  end

  -- The command facade should share the test's captured buffer state module.
  local function route_write_to_test_buffer()
    package.loaded['direct.buffer.buffer'] = buffer
    package.loaded['direct.pending'] = buffer._pending_for_test
    package.loaded['direct'] = nil
    require('direct')
    assert(require('direct.buffer.buffer') == buffer,
      'DirectSync facade must share the test buffer state registry')
    assert(require('direct.pending') == buffer._pending_for_test,
      'DirectSync facade must share the test buffer pending-operation state')
  end

  local function history_lines(name)
    local dir = paths.data_dir('history')
    local file = paths.join(dir, name)
    if vim.fn.filereadable(file) ~= 1 then return {} end
    return vim.fn.readfile(file)
  end

  local function list_edit_and_sync(ws, lines)
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    local ok, reason = listing:sync()
    return listing, ok, reason
  end

  return {
    H = H,
    buffer = buffer,
    fs = fs,
    paths = paths,
    history = history,
    register = register,
    fixtures = fixtures,
    HEADER = fixtures.header,
    decode_record = decode_record,
    clean_buffers = clean_buffers,
    route_write_to_test_buffer = route_write_to_test_buffer,
    history_lines = history_lines,
    list_edit_and_sync = list_edit_and_sync,
  }
end

return M
