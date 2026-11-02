-- tests/direct_run_spec.lua -- current-entry shell command execution.

local H = require('tests.support.harness')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

local function find_line(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == text then return row end
  end
end

H.describe('DirectRun', function()
  H.it('shell-quotes every placeholder and launches from the listing root', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'workspace')
    local name = "file with spaces;$(touch nope).txt"
    local path = H.mkfile(ws, name, { 'content' })
    require('direct').list(ws)
    vim.api.nvim_win_set_cursor(0, { find_line(name), 0 })

    local launched
    local process = {}
    local restore = H.stub(vim, 'system', function(argv, opts, on_exit)
      launched = { argv = argv, opts = opts }
      on_exit({ code = 0, stdout = 'staged\n', stderr = 'warning\n' })
      return process
    end)
    local result = require('direct').run('git add {} && printf %s {}')
    restore()

    H.assert_eq(result, process, 'returns the asynchronous process handle')
    H.assert_eq(launched.argv[1], vim.o.shell, 'uses the configured shell')
    local expected = ('git add {} && printf %s {}'):gsub('%{%}', function()
      return vim.fn.shellescape(path)
    end)
    H.assert_eq(launched.argv[#launched.argv], expected,
      'replaces each placeholder with one shell-escaped absolute path')
    H.assert_eq(launched.opts.cwd, ws, 'runs in the listing directory')
    H.assert_true(launched.opts.text, 'captures text output')
    H.assert_true(vim.wait(1000, function()
      return H.messages():find('warning', 1, true) ~= nil
    end), 'reports captured output when the process completes')
    H.assert_notified('status 0')
    H.assert_notified('staged')
    H.assert_notified('warning')
  end)

  H.it('resolves an expanded child row and reports a nonzero exit status', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'workspace')
    local sub = H.mkdir(ws, 'sub')
    local path = H.mkfile(sub, 'child with spaces.txt', { 'child' })
    local listing = require('direct').list(ws)
    listing:expand(1)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    H.capture_messages()

    vim.cmd([[DirectRun printf '%s' {} ; exit 7]])
    H.assert_true(vim.wait(3000, function()
      return H.messages():find(path, 1, true) ~= nil
    end), 'shell receives the expanded child path as one argument')
    H.assert_notified('status 7')
  end)

  H.it('rejects commands without a placeholder and rows without an entry', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'workspace')
    local file = H.mkfile(ws, 'present.txt', { 'content' })
    require('direct').list(ws)
    H.capture_messages()

    local system_calls = 0
    local restore = H.stub(vim, 'system', function()
      system_calls = system_calls + 1
      return {}
    end)
    local no_placeholder = require('direct').run('git status')
    H.assert_nil(no_placeholder)
    H.assert_notified('command must contain {}')

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.assert_true(vim.uv.fs_unlink(file), 'removes the listed file externally')
    local missing_entry = require('direct').run('git add {}')
    restore()

    H.assert_nil(missing_entry)
    H.assert_notified('does not name an existing entry')

    local row = vim.api.nvim_buf_line_count(0) + 1
    vim.api.nvim_buf_set_lines(0, row - 1, row - 1, false, { '' })
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    local blank_row = require('direct').run('git add {}')
    H.assert_nil(blank_row)
    H.assert_notified('row identity is unavailable')

    local pending = require('direct.pending')
    H.assert_true(pending.begin('another operation'))
    local blocked = require('direct').run('git add {}')
    pending.finish()
    H.assert_nil(blocked)
    H.assert_notified('cannot run a shell command while another operation is pending')
    H.assert_eq(system_calls, 0, 'invalid invocations never launch a process')
  end)
end)
