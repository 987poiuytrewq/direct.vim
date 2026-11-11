-- tests/git_restore_spec.lua -- confirmation and scope for worktree restores.
local H = require('tests.support.harness')
local git = require('direct.git')
local trash = require('direct.trash')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

local function git_command(root, ...)
  local argv = { 'git', '-C', root }
  for _, part in ipairs({ ... }) do argv[#argv + 1] = part end
  local result = vim.system(argv, { text = true }):wait()
  if result.code ~= 0 then error(result.stderr) end
  return result.stdout
end

local function init_repo(root)
  git_command(root, 'init', '-q')
  git_command(root, 'config', 'user.name', 'Direct Test')
  git_command(root, 'config', 'user.email', 'direct-test@example.invalid')
end

local function commit_all(root)
  git_command(root, 'add', '--all')
  git_command(root, 'commit', '-q', '-m', 'base')
end

local function row_of(name)
  for row, line in ipairs(H.buf_lines()) do
    if line == name then return row end
  end
end

H.describe('Git worktree restore confirmation', function()
  H.it('counts only unstaged tracked files under the selected path', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local directory = H.mkdir(root, 'dir')
    H.mkfile(directory, 'worktree.txt', { 'base' })
    H.mkfile(directory, 'staged.txt', { 'base' })
    H.mkfile(root, 'root.txt', { 'base' })
    init_repo(root)
    commit_all(root)
    H.mkfile(directory, 'worktree.txt', { 'changed' })
    H.mkfile(directory, 'staged.txt', { 'staged' })
    git_command(root, 'add', 'dir/staged.txt')
    H.mkfile(directory, 'untracked.txt', { 'untracked' })

    local changes = git.worktree_changes(root, directory, true)

    H.assert_eq(changes, { directory .. '/worktree.txt' },
      'staged-only and untracked entries are not included in worktree restore')
    H.assert_eq(git.worktree_changes(root, directory .. '/staged.txt', false), {},
      'a staged-only file has no unstaged worktree change')

    local original_system = vim.system
    vim.system = function(argv, options, on_exit)
      if argv[#argv] == '--version' then
        return { wait = function()
          return { code = 0, stdout = 'git version 2.30.0\n', stderr = '' }
        end }
      end
      return original_system(argv, options, on_exit)
    end
    local modern_command = git.worktree_restore_command(root)
    vim.system = function(argv, options, on_exit)
      if argv[#argv] == '--version' then
        return { wait = function()
          return { code = 0, stdout = 'git version 2.22.0\n', stderr = '' }
        end }
      end
      return original_system(argv, options, on_exit)
    end
    local legacy_command = git.worktree_restore_command(root)
    vim.system = original_system
    H.assert_eq(modern_command, 'git --literal-pathspecs restore --worktree -- {}',
      'new Git uses restore with literal pathspecs')
    H.assert_eq(legacy_command, 'git --literal-pathspecs checkout -- {}',
      'old Git falls back to checkout')
  end)

  H.it('asks before restoring a directory, declines safely, and applies after acceptance', function()
    clean_buffers()
    require('direct.config').setup({ map_default_keys = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local directory = H.mkdir(root, 'dir')
    H.mkfile(directory, 'one.txt', { 'one base' })
    H.mkfile(directory, 'two.txt', { 'two base' })
    H.mkfile(root, 'outside.txt', { 'outside base' })
    init_repo(root)
    commit_all(root)
    H.mkfile(directory, 'one.txt', { 'one changed' })
    H.mkfile(directory, 'two.txt', { 'two changed' })
    H.mkfile(root, 'outside.txt', { 'outside changed' })
    local listing = require('direct').list(root)
    vim.api.nvim_win_set_cursor(0, { row_of('dir/'), 0 })

    local prompts, original_confirm = {}, vim.fn.confirm
    vim.fn.confirm = function(message, buttons, default)
      prompts[#prompts + 1] = { message = message, buttons = buttons, default = default }
      return 2
    end
    H.capture_messages()
    local declined_ok, declined_err = pcall(vim.cmd, 'DirectGitRestore')
    vim.fn.confirm = original_confirm

    H.assert_true(declined_ok, 'decline is handled normally: ' .. tostring(declined_err))
    H.assert_eq(#prompts, 1, 'one confirmation is shown')
    H.assert_true(prompts[1].message:find(directory, 1, true) ~= nil,
      'the prompt names the selected directory')
    H.assert_true(prompts[1].message:find('2 changed files', 1, true) ~= nil,
      'the prompt states how many tracked files would change')
    H.assert_true(prompts[1].buttons:find('Restore', 1, true) ~= nil
      and prompts[1].buttons:find('Cancel', 1, true) ~= nil,
      'the prompt has restore and cancel choices')
    H.assert_eq(prompts[1].default, 2, 'cancel is the safe default')
    H.assert_eq(vim.fn.readfile(directory .. '/one.txt'), { 'one changed' },
      'declining leaves the first file untouched')
    H.assert_eq(vim.fn.readfile(directory .. '/two.txt'), { 'two changed' },
      'declining leaves the second file untouched')
    H.assert_eq(#trash.entries(), 0, 'declining does not create backups')

    vim.fn.confirm = function() return 1 end
    local notifications = {}
    local restore_notify = H.stub(vim, 'notify', function(message)
      notifications[#notifications + 1] = tostring(message)
      return true
    end)
    local accepted, accept_err = pcall(vim.cmd, 'DirectGitRestore')
    vim.fn.confirm = original_confirm
    local restored = vim.wait(5000, function()
      local ok_one, one = pcall(vim.fn.readfile, directory .. '/one.txt')
      local ok_two, two = pcall(vim.fn.readfile, directory .. '/two.txt')
      return ok_one and ok_two and one[1] == 'one base' and two[1] == 'two base'
    end)
    local backups = trash.entries()
    local backup_by_original = {}
    for _, backup in ipairs(backups) do backup_by_original[backup.original] = backup end
    local one_backup = backup_by_original[directory .. '/one.txt']
    local two_backup = backup_by_original[directory .. '/two.txt']
    local one_contents = one_backup and vim.fn.readfile(one_backup.path) or nil
    local two_contents = two_backup and vim.fn.readfile(two_backup.path) or nil
    restore_notify()
    H.assert_true(accepted, 'accepting starts the restore: ' .. tostring(accept_err))
    H.assert_true(restored, 'accepted restore resets the tracked files')
    H.assert_eq(#backups, 2, 'every changed worktree file has a trash backup')
    H.assert_eq(one_contents, { 'one changed' }, 'the first worktree contents are preserved in trash')
    H.assert_eq(two_contents, { 'two changed' }, 'the second worktree contents are preserved in trash')
    H.assert_true(table.concat(notifications, '\n'):find('pre-restore worktree copies saved', 1, true) ~= nil,
      'the restore notification names the trash backup location: '
        .. table.concat(notifications, '\n'))
    H.assert_eq(vim.fn.readfile(root .. '/outside.txt'), { 'outside changed' },
      'restore stays scoped to the selected directory')
    H.assert_not_nil(listing, 'the original listing object remains valid')
  end)

  H.it('does not prompt or discard a staged-only change', function()
    clean_buffers()
    require('direct.config').setup({ map_default_keys = true })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, 'staged.txt', { 'base' })
    init_repo(root)
    commit_all(root)
    H.mkfile(root, 'staged.txt', { 'staged version' })
    git_command(root, 'add', 'staged.txt')
    require('direct').list(root)
    vim.api.nvim_win_set_cursor(0, { row_of('staged.txt'), 0 })
    local calls, original_confirm = 0, vim.fn.confirm
    vim.fn.confirm = function() calls = calls + 1; return 1 end
    H.capture_messages()

    local result = require('direct').restore_git()

    vim.fn.confirm = original_confirm
    H.assert_false(result, 'no worktree restore is started for staged-only changes')
    H.assert_eq(calls, 0, 'staged-only changes do not prompt')
    H.assert_eq(vim.fn.readfile(root .. '/staged.txt'), { 'staged version' },
      'staged content is not discarded')
  end)
end)
