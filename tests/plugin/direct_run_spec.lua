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

local function git(root, ...)
  local args = { 'git', '-C', root }
  for _, arg in ipairs({ ... }) do args[#args + 1] = arg end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then error(result.stderr) end
  return result.stdout
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

  H.it('runs Git commands for missing tracked entries and refreshes after gc', function()
    clean_buffers()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'deleted-repo')
    local path = H.mkfile(root, 'gone.txt', { 'tracked content' })
    local directory = H.mkdir(root, 'gone-dir')
    local child = H.mkfile(directory, 'child.txt', { 'nested tracked content' })
    git(root, 'init', '-q')
    git(root, 'config', 'user.name', 'Direct Test')
    git(root, 'config', 'user.email', 'direct-test@example.invalid')
    git(root, 'add', '--all')
    git(root, 'commit', '-q', '-m', 'base')
    H.assert_true(vim.uv.fs_unlink(path), 'removes the tracked working-tree file')
    H.assert_true(vim.uv.fs_unlink(child), 'removes the tracked directory child')
    H.assert_true(vim.uv.fs_rmdir(directory), 'removes its now-empty directory')

    require('direct').setup({ git = { enabled = true } })
    require('direct').list(root)
    local row = find_line('gone.txt')
    H.assert_not_nil(row, 'the deleted tracked row is visible')
    vim.api.nvim_win_set_cursor(0, { row, 0 })

    local direct = require('direct')
    local shell_command = direct.run('test ! -e {}')
    H.assert_not_nil(shell_command, 'DirectRun accepts a missing tracked row')
    H.assert_eq(shell_command:wait().code, 0,
      'DirectRun receives the absent path for an arbitrary command')

    local add = direct.git('git add -- {}')
    H.assert_not_nil(add, 'DirectGit accepts a missing Git-deleted row')
    add:wait()
    local staged = vim.wait(3000, function()
      local state = require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf())
      return state and state.git_status and state.git_status.paths[path] == 'D '
    end)
    local state = require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf())
    H.assert_true(staged, 'ga-style Git add updates the row status: '
      .. vim.inspect(state and state.git_status))

    local reset = direct.git('git reset -- {}')
    H.assert_not_nil(reset, 'reset runs for a deleted row')
    reset:wait()
    H.assert_true(vim.wait(3000, function()
      local state = require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf())
      return state and state.git_status and state.git_status.paths[path] == ' D'
    end), 'gr-style Git reset updates the row status')

    local directory_row = find_line('gone-dir/')
    H.assert_not_nil(directory_row, 'missing tracked directories are listed')
    vim.api.nvim_win_set_cursor(0, { directory_row, 0 })
    local add_directory = direct.git('git add -- {}')
    H.assert_not_nil(add_directory, 'ga accepts a missing tracked directory')
    add_directory:wait()
    H.assert_true(vim.wait(3000, function()
      local state = require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf())
      return state and state.git_status and state.git_status.paths[child] == 'D '
    end), 'ga stages a deleted directory through its pathspec')

    vim.api.nvim_win_set_cursor(0, { find_line('gone-dir/'), 0 })
    local reset_directory = direct.git('git reset -- {}')
    H.assert_not_nil(reset_directory, 'gr accepts a missing tracked directory')
    reset_directory:wait()
    H.assert_true(vim.wait(3000, function()
      local state = require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf())
      return state and state.git_status and state.git_status.paths[child] == ' D'
    end), 'gr unstages a deleted directory through its pathspec')

    vim.api.nvim_win_set_cursor(0, { find_line('gone-dir/'), 0 })
    local restore_directory = direct.git('git checkout -- {}')
    H.assert_not_nil(restore_directory, 'gc accepts a missing tracked directory')
    restore_directory:wait()
    H.assert_true(vim.wait(3000, function()
      return vim.uv.fs_stat(child) ~= nil
        and find_line('gone-dir/') ~= nil
        and not require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf()).rows[
          require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf()).display_ids[
            find_line('gone-dir/')
          ]
        ].deleted_kind
    end), 'gc restores the deleted directory subtree')

    vim.api.nvim_win_set_cursor(0, { find_line('gone.txt'), 0 })
    local restore = direct.git('git checkout -- {}')
    H.assert_not_nil(restore, 'checkout runs for a deleted row')
    restore:wait()
    H.assert_true(vim.wait(3000, function()
      return vim.uv.fs_stat(path) ~= nil and find_line('gone.txt') ~= nil
        and not require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf()).rows[
          require('direct.buffer')._state_for_test(vim.api.nvim_get_current_buf()).display_ids[find_line('gone.txt')]
        ].deleted_kind
    end), 'gc restores the file and re-lists it as an ordinary entry')
    H.assert_eq(vim.fn.readfile(path), { 'tracked content' },
      'checkout restores the tracked contents')
  end)
end)
