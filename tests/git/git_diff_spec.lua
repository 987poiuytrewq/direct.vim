-- Tests for PR-style committed Git comparisons and listing filters.
local H = require('tests.support.harness')
local git = require('direct.git')

local function git_at(root, ...)
  local args = { 'git', '-C', root }
  for _, arg in ipairs({ ... }) do args[#args + 1] = arg end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    error(string.format('git %s failed: %s', table.concat({ ... }, ' '), result.stderr))
  end
  return (result.stdout or ''):gsub('[\r\n]+$', '')
end

local function commit_all(root, message)
  git_at(root, 'add', '--all')
  git_at(root, 'commit', '-q', '-m', message)
end

local function make_repo(sb)
  local root = H.mkdir(sb.root, 'repo')
  H.mkfile(root, 'modified.txt', 'base contents\n')
  H.mkfile(root, 'deleted.txt', 'remove me\n')
  H.mkfile(root, 'rename-old.txt', 'rename this file\nwith enough contents\n')
  H.mkfile(root, 'unchanged.txt', 'not changed\n')
  git_at(root, 'init', '-q', '-b', 'main')
  git_at(root, 'config', 'user.name', 'Direct Test')
  git_at(root, 'config', 'user.email', 'direct-test@example.invalid')
  commit_all(root, 'base')

  git_at(root, 'checkout', '-q', '-b', 'feature')
  H.mkfile(root, 'modified.txt', 'committed feature contents\n')
  H.mkfile(root, 'rename-new.txt', 'rename this file\nwith enough contents\n')
  H.mkfile(root, 'nested/added.txt', 'added\n')
  H.assert_true(vim.uv.fs_unlink(vim.fs.joinpath(root, 'rename-old.txt')),
    'rename source is removed in the feature commit')
  H.assert_true(vim.uv.fs_unlink(vim.fs.joinpath(root, 'deleted.txt')),
    'deleted file is removed in the feature commit')
  git_at(root, 'add', '--all')
  git_at(root, 'commit', '-q', '-m', 'feature changes')

  git_at(root, 'checkout', '-q', 'main')
  H.mkfile(root, 'target-only.txt', 'only on the target branch\n')
  commit_all(root, 'target branch change')
  git_at(root, 'update-ref', 'refs/remotes/origin/main', 'main')
  git_at(root, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  git_at(root, 'checkout', '-q', 'feature')

  return root
end

local function entry_map(snapshot)
  local result = {}
  for _, entry in ipairs(snapshot.entries) do result[entry.path] = entry end
  return result
end

H.describe('Git branch diff filter', function()
  H.it('compares the merge base to HEAD and excludes local index and worktree changes', function()
    local sb = H.sandbox()
    local root = make_repo(sb)
    H.mkfile(root, 'modified.txt', 'uncommitted edit\n')
    H.mkfile(root, 'untracked.txt', 'not committed\n')
    H.mkfile(root, 'staged-only.txt', 'not committed\n')
    git_at(root, 'add', 'staged-only.txt')

    local snapshot, err = git.compare_snapshot(root)
    H.assert_not_nil(snapshot, 'the configured origin default is available')
    H.assert_nil(err, 'comparison succeeds')
    H.assert_eq(snapshot.ref, 'origin/main', 'origin/HEAD selects the default target')
    local entries = entry_map(snapshot)
    H.assert_eq(entries['modified.txt'].status, 'M', 'committed modification is included')
    H.assert_eq(entries['deleted.txt'].status, 'D', 'committed deletion is included')
    H.assert_eq(entries['nested/added.txt'].status, 'A', 'committed addition is included')
    H.assert_true(entries['rename-new.txt'] ~= nil
      and entries['rename-new.txt'].status == 'R', 'renames display the destination path')
    H.assert_nil(entries['rename-old.txt'], 'the old rename path is not a separate file row')
    H.assert_nil(entries['target-only.txt'], 'target-only commits are excluded by merge-base comparison')
    H.assert_nil(entries['untracked.txt'], 'untracked local files are excluded')
    H.assert_nil(entries['staged-only.txt'], 'staged local files are excluded')
  end)

  H.it('falls back to local main then master when origin/HEAD is missing', function()
    local sb = H.sandbox()
    local root = make_repo(sb)
    git_at(root, 'symbolic-ref', '--delete', 'refs/remotes/origin/HEAD')
    git_at(root, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/missing')

    local snapshot, err = git.compare_snapshot(root)
    H.assert_not_nil(snapshot, 'local main fallback can be resolved')
    H.assert_nil(err, 'fallback comparison succeeds')
    H.assert_eq(snapshot.ref, 'main', 'main is used when origin/HEAD is stale')

    local master = H.mkdir(sb.root, 'master-only')
    H.mkfile(master, 'file.txt', 'base\n')
    git_at(master, 'init', '-q', '-b', 'master')
    git_at(master, 'config', 'user.name', 'Direct Test')
    git_at(master, 'config', 'user.email', 'direct-test@example.invalid')
    commit_all(master, 'base')
    H.mkfile(master, 'file.txt', 'changed\n')
    commit_all(master, 'change')
    snapshot, err = git.compare_snapshot(master)
    H.assert_not_nil(snapshot, 'local master fallback can be resolved')
    H.assert_nil(err, 'master fallback comparison succeeds')
    H.assert_eq(snapshot.ref, 'master', 'master is used when main is absent')
  end)

  H.it('toggles the current listing filter on and off, including deleted paths', function()
    local sb = H.sandbox()
    local root = make_repo(sb)
    local buffer = require('direct.buffer.buffer')
    buffer.list(root)
    local bufnr = vim.api.nvim_get_current_buf()

    vim.cmd('DirectGitDiff main')
    local state = buffer._state_for_test(bufnr)
    H.assert_true(state.view_git_diff_only, 'an explicit ref enables diff filtering')
    H.assert_eq(state.git_diff_snapshot.ref, 'main', 'the requested ref is remembered')
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    H.assert_true(vim.tbl_contains(lines, 'modified.txt'), 'committed modifications remain visible')
    H.assert_true(vim.tbl_contains(lines, 'deleted.txt'), 'committed deletions remain visible')
    H.assert_true(vim.tbl_contains(lines, 'nested/'), 'changed parent directories remain visible')
    H.assert_true(vim.tbl_contains(lines, '  added.txt'), 'changed directories expand to changed descendants')
    H.assert_true(vim.tbl_contains(lines, 'rename-new.txt'), 'renamed destinations remain visible')
    H.assert_false(vim.tbl_contains(lines, 'unchanged.txt'), 'unchanged paths are filtered out')

    vim.cmd('DirectGitDiff main')
    state = buffer._state_for_test(bufnr)
    H.assert_false(state.view_git_diff_only, 'invoking the same ref again turns the filter off')
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    H.assert_true(vim.tbl_contains(lines, 'unchanged.txt'), 'the normal listing is restored')

    vim.cmd('DirectGitDiff')
    state = buffer._state_for_test(bufnr)
    H.assert_true(state.view_git_diff_only, 'no argument enables the default-branch filter')
    H.assert_eq(state.git_diff_snapshot.ref, 'origin/main', 'origin/HEAD supplies the default ref')
    vim.cmd('DirectGitDiff')
    H.assert_false(buffer._state_for_test(bufnr).view_git_diff_only,
      'no-argument invocation toggles the default filter off')
  end)

  H.it('refuses to toggle Git diff outside a Direct listing', function()
    local sb = H.sandbox()
    local root = make_repo(sb)
    vim.cmd('edit ' .. vim.fn.fnameescape(vim.fs.joinpath(root, 'modified.txt')))
    H.capture_messages()
    H.assert_nil(require('direct').git_diff('main'), 'the public action is refused')
    H.assert_eq(vim.api.nvim_buf_get_name(0), vim.fs.joinpath(root, 'modified.txt'),
      'ordinary file buffer remains current')
    H.assert_notified('DirectGitDiff can only be used in a direct buffer', vim.log.levels.ERROR)
  end)

  H.it('reports invalid refs and directories outside Git repositories', function()
    local sb = H.sandbox()
    local plain = H.mkdir(sb.root, 'plain')
    local snapshot, err = git.compare_snapshot(plain)
    H.assert_nil(snapshot, 'a non-repository has no comparison')
    H.assert_true(tostring(err):find('not a git repository', 1, true) ~= nil,
      'the Git error is surfaced')

    local root = make_repo(sb)
    snapshot, err = git.compare_snapshot(root, 'not-a-real-ref')
    H.assert_nil(snapshot, 'an unknown ref has no comparison')
    H.assert_true(tostring(err):find('cannot resolve Git ref', 1, true) ~= nil,
      'an invalid ref has a useful error')
  end)
end)
