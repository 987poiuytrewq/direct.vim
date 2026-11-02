-- tests/ui_spec.lua -- injectable prompt routing and stale-module safeguards.
-- Under `-l`, the real prompt would block or abort instead of failing safely.

local H = require('tests.support.harness')

H.describe('ui', function()
  H.it('with_prompt replaces ui.prompt so vim.fn.input is never reached', function()
    local ui = require('direct.ui')
    H.assert_true(type(ui.prompt) == 'function', 'ui.prompt exists')

    -- Poison vim.fn.input: reaching the real prompt under -l would raise here.
    local restore_input = H.stub(vim.fn, 'input', function()
      error('vim.fn.input called under -l')
    end)
    local answer
    local ok, err = pcall(H.with_prompt, function()
      answer = require('direct.ui').prompt('paste as: ', 'default', 'file')
    end, { 'renamed.txt' })
    restore_input()
    if not ok then
      error(err, 0)
    end

    H.assert_eq(answer, 'renamed.txt', 'with_prompt answered through the seam')
  end)

  -- The stale-module trap. A spec that stubs a freshly-required ui table while
  -- the consumer modules captured an older one would miss the stub; the real
  -- ui.prompt then calls vim.fn.input, which under `--headless -l` terminates the
  -- whole process (truncated stdout, no RUN: line, exit 0). The poison must turn
  -- that into a loud, catchable Lua error instead.
  H.it('a stale ui stub loud-fails instead of truncating the run via vim.fn.input', function()
    local ui = require('direct.ui')     -- the consumer table this spec holds
    local saved = package.loaded['direct.ui']
    package.loaded['direct.ui'] = nil   -- simulate the harness per-file unload
    local fresh = require('direct.ui')  -- the table with_prompt will stub
    H.assert_true(fresh ~= ui, 'a fresh require yields a distinct ui table')

    local ok, err = pcall(function()
      H.with_prompt(function()
        -- The consumer keeps the REAL prompt; this must raise, not truncate.
        ui.prompt('paste as: ', 'default', 'file')
      end, { 'x' })
    end)
    package.loaded['direct.ui'] = saved

    H.assert_false(ok, 'the stale stub could not silently miss and truncate')
    H.assert_true(type(err) == 'string' and err:find('vim.fn.input', 1, true) ~= nil,
      'the raise names the bypassed vim.fn.input')
    H.assert_true(type(vim.fn.input) == 'function',
      'vim.fn.input is restored after the raise')
  end)

  -- with_prompt must refuse to run when the table it would stub is not the one
  -- the file captured before the unload.
  H.it('with_prompt raises on a stale ui-module mismatch instead of missing the stub', function()
    local saved = H._file_ui
    H._file_ui = {} -- a captured table distinct from the fresh require below
    local ok, err = pcall(H.with_prompt, function() end, { 'x' })
    H._file_ui = saved

    H.assert_false(ok, 'a stale-module mismatch is refused')
    H.assert_true(type(err) == 'string' and err:find('stale direct.ui', 1, true) ~= nil,
      'the error explains the stale module')
  end)

  H.it('notify() routes through vim.notify', function()
    local ui = require('direct.ui')
    local seen = {}
    local restore = H.stub(vim, 'notify', function(msg, level)
      seen[#seen + 1] = { msg = msg, level = level }
    end)
    ui.notify('direct probe', vim.log.levels.WARN)
    restore()
    H.assert_eq(seen[1] and seen[1].msg, 'direct probe', 'message forwarded')
    H.assert_eq(seen[1] and seen[1].level, vim.log.levels.WARN, 'level forwarded')
  end)
end)
