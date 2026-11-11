-- tests/ui_spec.lua -- injectable prompt routing and notification conventions.
-- Under `-l`, the real prompt would block or abort instead of failing safely.

local H = require('tests.support.harness')

H.describe('ui', function()
  H.it('with_prompt replaces ui.prompt so vim.fn.input is never reached', function()
    local ui = require('direct.ui')
    H.assert_true(type(ui.prompt) == 'function', 'ui.prompt exists')

    local restore_input = H.stub(vim.fn, 'input', function()
      error('vim.fn.input called under -l')
    end)
    local answer
    local saved_file_ui = H._file_ui
    H._file_ui = ui
    local ok, err = pcall(H.with_prompt, function()
      answer = require('direct.ui').prompt('paste as: ', 'default', 'file')
    end, { 'renamed.txt' })
    H._file_ui = saved_file_ui
    restore_input()
    if not ok then error(err, 0) end

    H.assert_eq(answer, 'renamed.txt', 'with_prompt answered through the seam')
  end)

  H.it('a stale ui stub loud-fails instead of truncating the run via vim.fn.input', function()
    local ui = require('direct.ui')
    local saved = package.loaded['direct.ui']
    package.loaded['direct.ui'] = nil
    local fresh = require('direct.ui')
    H.assert_true(fresh ~= ui, 'a fresh require yields a distinct ui table')

    local ok, err = pcall(function()
      H.with_prompt(function()
        ui.prompt('paste as: ', 'default', 'file')
      end, { 'x' })
    end)
    package.loaded['direct.ui'] = saved

    H.assert_false(ok, 'the stale stub could not silently miss and truncate')
    H.assert_true(type(err) == 'string' and err:find('vim.fn.input', 1, true) ~= nil,
      'the raise names the bypassed vim.fn.input')
    H.assert_true(type(vim.fn.input) == 'function', 'vim.fn.input is restored')
  end)

  H.it('with_prompt raises on a stale ui-module mismatch instead of missing the stub', function()
    local saved = H._file_ui
    H._file_ui = {}
    local ok, err = pcall(H.with_prompt, function() end, { 'x' })
    H._file_ui = saved

    H.assert_false(ok, 'a stale-module mismatch is refused')
    H.assert_true(type(err) == 'string' and err:find('stale direct.ui', 1, true) ~= nil,
      'the error explains the stale module')
  end)

  H.it('notify routes through vim.notify and applies the direct prefix', function()
    local ui = require('direct.ui')
    local seen = {}
    local restore = H.stub(vim, 'notify', function(msg, level)
      seen[#seen + 1] = { msg = msg, level = level }
    end)
    ui.notify('direct probe', vim.log.levels.WARN)
    restore()
    H.assert_eq(seen[1] and seen[1].msg, 'direct: direct probe', 'message is prefixed')
    H.assert_eq(seen[1] and seen[1].level, vim.log.levels.WARN, 'level forwarded')
  end)

  H.it('notify preserves multiline command output with one prefix', function()
    local ui = require('direct.ui')
    local seen
    local restore = H.stub(vim, 'notify', function(message) seen = message end)
    local output = 'command output:\nstack traceback:\nthis is literal output'

    ui.notify(output, vim.log.levels.INFO)

    restore()
    H.assert_eq(seen, 'direct: ' .. output, 'output is prefixed but otherwise preserved')
  end)

  H.it('does not add a duplicate direct prefix and prefixes ephemeral progress too', function()
    local ui = require('direct.ui')
    local seen
    local restore = H.stub(vim, 'notify', function(message) seen = message end)
    ui.notify('direct: already prefixed', vim.log.levels.INFO)
    restore()
    H.assert_eq(seen, 'direct: already prefixed', 'existing prefixes remain singular')

    local echoed
    local restore_echo = H.stub(vim.api, 'nvim_echo', function(chunks)
      echoed = chunks[1][1]
    end)
    ui.notify('copying 1/2 files', vim.log.levels.INFO, { ephemeral = true })
    restore_echo()
    H.assert_eq(echoed, 'direct: copying 1/2 files', 'ephemeral progress uses the same prefix')
  end)

  H.it('report_error shows the concise cause and keeps traceback details out of notices', function()
    local ui = require('direct.ui')
    local original = 'lua/direct/buffer.lua:12: injected listing failure\n'
      .. 'stack traceback:\n\t.../buffer.lua:12: in function ...'
    H.capture_messages()

    local result, err = ui.report_error('open the directory listing', original)

    H.assert_nil(result, 'error reporting returns nil')
    H.assert_eq(err, original, 'the original diagnostic remains available to callers')
    H.assert_notified('direct: Could not open the directory listing: injected listing failure')
    H.assert_false(H.messages():find('stack traceback', 1, true) ~= nil,
      'implementation traceback is not shown in the user notification')
  end)

  H.it('notify falls back to the editor message area if vim.notify fails', function()
    local ui = require('direct.ui')
    local restore = H.stub(vim, 'notify', function()
      error('injected notification backend failure')
    end)
    H.capture_messages()

    ui.notify('Direct could not finish the operation', vim.log.levels.ERROR)

    restore()
    H.assert_notified('direct: Direct could not finish the operation')
  end)

  H.it('public API catches unexpected errors and reports a readable message', function()
    local api = require('direct')
    local buffer = require('direct.buffer.buffer')
    local restore = H.stub(buffer, 'list', function()
      error('injected list failure')
    end)
    H.capture_messages()

    local result, err = api.list('/unimportant')

    restore()
    H.assert_nil(result, 'a raised implementation error becomes a normal API failure')
    H.assert_true(type(err) == 'string'
      and err:find('injected list failure', 1, true) ~= nil,
      'the original error is retained for Lua callers')
    H.assert_notified('direct: Could not open the directory listing: injected list failure')
    H.assert_false(H.messages():find('stack traceback', 1, true) ~= nil,
      'the public notification does not expose the stack trace')
  end)
end)
