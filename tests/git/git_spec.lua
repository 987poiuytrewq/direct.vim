-- tests/git_spec.lua -- Git status discovery and display in directory listings.

local H = require('tests.support.harness')
local git_status = require('direct.git')

local function git(root, ...)
  local args = { 'git', '-C', root }
  for _, arg in ipairs({ ... }) do args[#args + 1] = arg end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    error(string.format('git %s failed: %s', table.concat({ ... }, ' '), result.stderr))
  end
  return (result.stdout or ''):gsub('[\r\n]+$', '')
end

local function init_repo(root)
  git(root, 'init', '-q')
  git(root, 'config', 'user.name', 'Direct Test')
  git(root, 'config', 'user.email', 'direct-test@example.invalid')
end

local function commit_all(root, message)
  git(root, 'add', '--all')
  git(root, 'commit', '-q', '-m', message)
end

local function status_at(snapshot, root, path)
  return git_status.status_for(snapshot, vim.fs.joinpath(root, path))
end

local function mark_by_row(bufnr, namespace_name)
  local namespace = vim.api.nvim_get_namespaces()[namespace_name]
  if not namespace then return {} end
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
      { details = true })) do
    result[mark[2]] = mark
  end
  return result
end

local function marks_by_row(bufnr, namespace_name)
  local namespace = vim.api.nvim_get_namespaces()[namespace_name]
  if not namespace then return {} end
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1,
      { details = true })) do
    result[mark[2]] = result[mark[2]] or {}
    result[mark[2]][#result[mark[2]] + 1] = mark
  end
  for _, marks in pairs(result) do
    table.sort(marks, function(a, b)
      return (a[4].priority or 0) > (b[4].priority or 0)
    end)
  end
  return result
end

local function gutter_text(marks)
  if not marks then return nil end
  return table.concat(vim.tbl_map(function(mark)
    return mark[4].sign_text:sub(1, 1)
  end, marks))
end

H.describe('Git status display', function()
  H.it('preserves porcelain columns and aggregates each directory column independently', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, 'tracked.txt', 'before')
    H.mkfile(root, 'nested/deep.txt', 'before')
    init_repo(root)
    commit_all(root, 'base')

    H.mkfile(root, 'tracked.txt', 'staged modification')
    git(root, 'add', 'tracked.txt')
    H.mkfile(root, 'tracked.txt', 'unstaged modification too')
    H.mkfile(root, 'staged-add.txt', 'added')
    git(root, 'add', 'staged-add.txt')
    H.mkfile(root, 'untracked.txt', 'untracked')
    H.mkfile(root, 'nested/untracked.txt', 'nested untracked')
    git(root, 'mv', 'nested/deep.txt', 'nested/renamed.txt')

    local snapshot = git_status.read(root)
    H.assert_not_nil(snapshot, 'Git repository status is available')
    H.assert_eq(status_at(snapshot, root, 'tracked.txt'), 'MM',
      'both porcelain columns are preserved for a staged and unstaged modification')
    H.assert_eq(status_at(snapshot, root, 'staged-add.txt'), 'A ',
      'an index-only addition retains its second-column space')
    H.assert_eq(status_at(snapshot, root, 'untracked.txt'), ' A',
      'untracked ?? is normalized to a blank index column and worktree addition')
    H.assert_eq(status_at(snapshot, root, 'nested/renamed.txt'), 'R ',
      'Git-detected rename retains its porcelain code at the destination')
    H.assert_eq(status_at(snapshot, root, 'nested'), 'RA',
      'directory columns aggregate rename and untracked descendant statuses')
  end)

  H.it('recognizes unmerged paths as conflicted', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'conflict-repo')
    H.mkfile(root, 'conflict.txt', 'base')
    init_repo(root)
    commit_all(root, 'base')
    local main_branch = git(root, 'branch', '--show-current')
    git(root, 'checkout', '-q', '-b', 'feature')
    H.mkfile(root, 'conflict.txt', 'feature')
    commit_all(root, 'feature change')
    git(root, 'checkout', '-q', main_branch)
    H.mkfile(root, 'conflict.txt', 'main')
    commit_all(root, 'main change')
    local merge = vim.system({ 'git', '-C', root, 'merge', 'feature' }, { text = true }):wait()
    H.assert_true(merge.code ~= 0, 'merge creates the expected conflict')

    local snapshot = git_status.read(root)
    H.assert_eq(status_at(snapshot, root, 'conflict.txt'), 'UU',
      'both unmerged porcelain columns are preserved')
    require('direct.config').setup({ map_default_keys = false })
    require('direct.buffer').list(root)
    local row
    for index, line in ipairs(H.buf_lines()) do
      if line == 'conflict.txt' then row = index - 1 end
    end
    H.assert_not_nil(row, 'conflict file remains in the listing')
    local signs = marks_by_row(0, 'direct-listing-git-gutter')[row]
    H.assert_eq(gutter_text(signs), '||', 'unmerged status uses both cells')
    H.assert_eq(signs[1][4].sign_hl_group, 'DirectGitConflictedGutter',
      'first unmerged cell uses ErrorMsg')
    H.assert_eq(signs[2][4].sign_hl_group, 'DirectGitConflictedGutter',
      'second unmerged cell uses ErrorMsg')
  end)

  H.it('normalizes type changes to modifications in their original porcelain columns', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'type-change-repo')
    H.mkfile(root, 'staged-type.txt', 'regular file')
    H.mkfile(root, 'worktree-type.txt', 'regular file')
    init_repo(root)
    commit_all(root, 'base')

    for _, name in ipairs({ 'staged-type.txt', 'worktree-type.txt' }) do
      local path = vim.fs.joinpath(root, name)
      H.assert_true(vim.uv.fs_unlink(path), 'remove the tracked regular file')
      H.assert_true(vim.uv.fs_symlink('target', path), 'replace it with a symlink')
    end
    git(root, 'add', 'staged-type.txt')

    local porcelain = git(root, 'status', '--porcelain=v1')
    H.assert_true(porcelain:find('T  staged%-type%.txt') ~= nil,
      'Git reports the staged type change')
    H.assert_true(porcelain:find(' T worktree%-type%.txt') ~= nil,
      'Git reports the worktree type change')

    local snapshot = git_status.read(root)
    H.assert_eq(status_at(snapshot, root, 'staged-type.txt'), 'M ',
      'staged T is normalized to M in the index column')
    H.assert_eq(status_at(snapshot, root, 'worktree-type.txt'), ' M',
      'worktree T is normalized to M in the worktree column')
  end)

  H.it('DirectRun leaves status snapshots alone while DirectGit refreshes them', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'command-repo')
    H.mkfile(root, 'tracked.txt', 'committed content')
    init_repo(root)
    commit_all(root, 'base')
    H.mkfile(root, 'tracked.txt', 'working tree change')

    config.setup({ map_default_keys = false })
    buffer.list(root)
    local function select_file()
      for row, line in ipairs(H.buf_lines()) do
        if line == 'tracked.txt' then
          vim.api.nvim_win_set_cursor(0, { row, 0 })
          return
        end
      end
      H.fail('tracked.txt should remain in the listing')
    end
    local function run_command(command)
      H.capture_messages()
      select_file()
      vim.cmd(command)
      H.assert_true(vim.wait(3000, function()
        return H.messages():find('status 0', 1, true) ~= nil
      end), command .. ' completes successfully')
    end

    local function marker()
      for row, line in ipairs(H.buf_lines()) do
        if line == 'tracked.txt' then
          local marks = marks_by_row(0, 'direct-listing-git-gutter')[row - 1]
          return gutter_text(marks)
        end
      end
    end

    H.assert_eq(marker(), ' |', 'the initial worktree change uses the second gutter cell')
    run_command('DirectRun git add -- {}')
    H.assert_eq(marker(), ' |', 'DirectRun does not refresh cached Git status')

    run_command('DirectGit git add -- {}')
    H.assert_eq(marker(), '| ', 'DirectGit refreshes the indicator after staging')
  end)

  H.it('ga, gr, and gc update the staged/unstaged gutter indicators', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'mapping-repo')
    H.mkfile(root, 'tracked.txt', 'committed content')
    init_repo(root)
    commit_all(root, 'base')
    H.mkfile(root, 'tracked.txt', 'working tree change')

    config.setup({ map_default_keys = true })
    buffer.list(root)
    local function gutter_for(name)
      local line_row
      for row, line in ipairs(H.buf_lines()) do
        if line == name then line_row = row - 1 end
      end
      H.assert_not_nil(line_row, 'the tracked file remains in the listing')
      return marks_by_row(0, 'direct-listing-git-gutter')[line_row]
    end
    local function press_and_wait(lhs)
      local file_row
      for row, line in ipairs(H.buf_lines()) do
        if line == 'tracked.txt' then file_row = row end
      end
      H.assert_not_nil(file_row, 'the tracked file remains selectable')
      vim.api.nvim_win_set_cursor(0, { file_row, 0 })
      H.capture_messages()
      vim.api.nvim_feedkeys(lhs, 'mx', false)
      H.assert_true(vim.wait(3000, function()
        return H.messages():find('status 0', 1, true) ~= nil
      end), lhs .. ' completes its DirectRun Git command')
      H.assert_notified('status 0')
    end

    H.assert_eq(gutter_text(gutter_for('tracked.txt')), ' |',
      'an unstaged modification starts in the worktree cell')

    press_and_wait('ga')
    H.assert_eq(gutter_text(gutter_for('tracked.txt')), '| ',
      'ga moves the modification to the index cell')

    press_and_wait('gr')
    H.assert_eq(gutter_text(gutter_for('tracked.txt')), ' |',
      'gr moves the modification back to the worktree cell')

    press_and_wait('gc')
    H.assert_nil(gutter_for('tracked.txt'),
      'gc discards the working-tree change and clears the Git indicator')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(root, 'tracked.txt')),
      { 'committed content' }, 'gc restores the committed file contents')
  end)

  H.it('captures deleted tracked files and missing directory ancestors', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'deleted-repo')
    H.mkfile(root, 'gone.txt', 'gone')
    H.mkfile(root, 'removed/nested/deep.txt', 'deep')
    init_repo(root)
    commit_all(root, 'base')

    H.assert_true(vim.uv.fs_unlink(root .. '/gone.txt'), 'removes a tracked file')
    H.assert_true(vim.uv.fs_unlink(root .. '/removed/nested/deep.txt'),
      'removes a tracked descendant')
    H.assert_true(vim.uv.fs_rmdir(root .. '/removed/nested'), 'removes its nested directory')
    H.assert_true(vim.uv.fs_rmdir(root .. '/removed'), 'removes its parent directory')

    local snapshot = git_status.read(root)
    H.assert_eq(status_at(snapshot, root, 'gone.txt'), ' D',
      'unstaged file deletion retains its worktree column')
    H.assert_eq(status_at(snapshot, root, 'removed'), ' D',
      'directory status aggregates deleted descendants')
    H.assert_eq(snapshot.deleted[vim.fs.joinpath(root, 'gone.txt')].kind, 'file',
      'the deleted leaf is a file')
    H.assert_eq(snapshot.deleted[vim.fs.joinpath(root, 'removed')].kind, 'directory',
      'a missing tracked directory is derived from its descendants')
    H.assert_eq(snapshot.deleted[vim.fs.joinpath(root, 'removed/nested')].kind,
      'directory', 'nested missing directories are derived too')
    local root_children = git_status.deleted_children(snapshot, root)
    H.assert_eq(vim.tbl_map(function(entry) return entry.name end, root_children),
      { 'removed/', 'gone.txt' }, 'deleted children use normal directory-first ordering')

    git(root, 'add', '-u')
    snapshot = git_status.read(root)
    H.assert_eq(status_at(snapshot, root, 'gone.txt'), 'D ',
      'staged deletion is retained in the index column')
  end)

  H.it('git.show_deleted hides synthetic rows without disabling Git status', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'deleted-option-repo')
    H.mkfile(root, 'gone.txt', 'gone')
    H.mkfile(root, 'live.txt', 'before')
    H.mkfile(root, 'sub/gone-child.txt', 'gone child')
    H.mkfile(root, 'sub/keep.txt', 'keep')
    init_repo(root)
    commit_all(root, 'base')
    H.assert_true(vim.uv.fs_unlink(root .. '/gone.txt'), 'removes a tracked root file')
    H.assert_true(vim.uv.fs_unlink(root .. '/sub/gone-child.txt'),
      'removes a tracked child file')
    H.mkfile(root, 'live.txt', 'after')

    config.setup({ map_default_keys = false, git = { show_deleted = false } })
    local listing = buffer.list(root)
    H.assert_eq(H.buf_lines(), { '.git/', 'sub/', 'live.txt' },
      'the option hides missing tracked rows')
    local snapshot = buffer._state_for_test(vim.api.nvim_get_current_buf()).git_status
    H.assert_eq(git_status.status_for(snapshot, root .. '/gone.txt'), ' D',
      'hiding a row does not disable deleted status data')
    H.assert_eq(git_status.status_for(snapshot, root .. '/live.txt'), ' M',
      'existing Git status remains available')
    H.assert_true(listing:expand(2), 'the remaining real directory still expands')
    H.assert_eq(H.buf_lines(), { '.git/', 'sub/', '  keep.txt', 'live.txt' },
      'deleted children are hidden inside expanded directories too')

    config.setup({ map_default_keys = false, git = { show_deleted = true } })
    listing:list()
    H.assert_eq(H.buf_lines(), { '.git/', 'sub/', 'gone.txt', 'live.txt' },
      're-enabling the option restores root deleted rows')
    H.assert_true(listing:expand(2), 'the real directory can be expanded again')
    H.assert_eq(H.buf_lines(), {
      '.git/', 'sub/', '  gone-child.txt', '  keep.txt', 'gone.txt', 'live.txt',
    }, 're-enabling the option restores nested deleted rows')

    config.setup({ map_default_keys = false, git = {
      enabled = false, show_deleted = true,
    } })
    listing:list()
    H.assert_eq(H.buf_lines(), { '.git/', 'sub/', 'live.txt' },
      'deleted rows are not shown while Git status is disabled')
  end)

  H.it('renders two porcelain-order gutter cells with independent colors only', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'display-repo')
    H.mkfile(root, 'tracked.txt', 'before')
    H.mkfile(root, 'index-only.txt', 'before')
    H.mkfile(root, 'worktree-only.txt', 'before')
    H.mkfile(root, 'nested/clean.txt', 'clean')
    init_repo(root)
    commit_all(root, 'base')
    H.mkfile(root, 'tracked.txt', 'after')
    git(root, 'add', 'tracked.txt')
    H.mkfile(root, 'tracked.txt', 'staged and modified again')
    H.mkfile(root, 'staged-add.txt', 'new staged file')
    git(root, 'add', 'staged-add.txt')
    H.mkfile(root, 'index-only.txt', 'staged modification')
    git(root, 'add', 'index-only.txt')
    H.mkfile(root, 'worktree-only.txt', 'worktree modification')
    H.mkfile(root, 'nested/clean.txt', 'staged nested modification')
    git(root, 'add', 'nested/clean.txt')
    H.mkfile(root, 'nested/new.txt', 'new')

    config.setup({
      map_default_keys = false,
      show_folder_icons = true,
      show_file_icons = true,
    })
    H.assert_eq(config.options.git.gutter, { index = '|', worktree = '|' },
      'both porcelain columns default to the bar symbol')
    local previous_signcolumn = vim.wo.signcolumn
    local listing = buffer.list(root)
    local lines = H.buf_lines()
    local rows = {}
    for row, line in ipairs(lines) do rows[line] = row - 1 end
    local highlights = mark_by_row(0, 'direct-listing-highlights')
    local icons = mark_by_row(0, 'direct-listing-icons')
    local gutters = marks_by_row(0, 'direct-listing-git-gutter')

    H.assert_eq(lines, { '.git/', 'nested/', 'index-only.txt', 'staged-add.txt', 'tracked.txt',
      'worktree-only.txt' },
      'listing text remains ordinary paths')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitAddedGutter', link = true }),
      { default = true, link = 'DiffAdd' }, 'added gutter group links to DiffAdd')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitModifiedGutter', link = true }),
      { default = true, link = 'DiffChange' }, 'modified gutter group links to DiffChange')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitDeletedGutter', link = true }),
      { default = true, link = 'DiffDelete' }, 'deleted gutter group links to DiffDelete')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitConflictedGutter', link = true }),
      { default = true, link = 'ErrorMsg' }, 'conflict gutter group links to ErrorMsg')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '\u{f0214} ', 'DirectFileIcon' } },
      'Git status does not change the normal file icon')
    H.assert_nil(highlights[rows['tracked.txt']],
      'Git status never highlights entry names')
    H.assert_eq(gutter_text(gutters[rows['tracked.txt']]), '||',
      'MM renders two bars')
    H.assert_eq(gutters[rows['tracked.txt']][1][4].sign_hl_group,
      'DirectGitModifiedGutter', 'index modification has DiffChange styling')
    H.assert_eq(gutters[rows['tracked.txt']][2][4].sign_hl_group,
      'DirectGitModifiedGutter', 'worktree modification has independent DiffChange styling')
    H.assert_eq(gutter_text(gutters[rows['index-only.txt']]), '| ',
      'an index-only status leaves a space in the worktree cell')
    H.assert_eq(gutters[rows['index-only.txt']][1][4].sign_hl_group,
      'DirectGitModifiedGutter', 'index-only modification uses DiffChange')
    H.assert_eq(gutter_text(gutters[rows['staged-add.txt']]), '| ',
      'a staged addition uses only the index gutter cell')
    H.assert_eq(gutters[rows['staged-add.txt']][1][4].sign_hl_group,
      'DirectGitAddedGutter', 'index addition uses DiffAdd')
    H.assert_eq(gutter_text(gutters[rows['worktree-only.txt']]), ' |',
      'a worktree-only status leaves a space in the index cell')
    H.assert_eq(gutters[rows['worktree-only.txt']][2][4].sign_hl_group,
      'DirectGitModifiedGutter', 'worktree-only modification uses DiffChange')
    H.assert_eq(gutter_text(gutters[rows['nested/']]), '||',
      'directory columns aggregate statuses independently')
    H.assert_eq(gutters[rows['nested/']][1][4].sign_hl_group,
      'DirectGitModifiedGutter', 'directory index column reflects its staged change')
    H.assert_eq(gutters[rows['nested/']][2][4].sign_hl_group,
      'DirectGitAddedGutter', 'directory worktree column reflects its untracked child')
    H.assert_eq(vim.wo.signcolumn, 'auto:2', 'the listing reserves two sign cells')
    listing:list()
    vim.cmd('enew')
    H.assert_eq(vim.wo.signcolumn, previous_signcolumn,
      'the prior signcolumn setting is restored when leaving the listing')
  end)

  H.it('lists, highlights, expands, and protects Git-deleted entries', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local direct = require('direct')
    local register = require('direct.register')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'deleted-display-repo')
    H.mkfile(root, 'gone.txt', 'gone')
    H.mkfile(root, 'removed/nested/deep.txt', 'deep')
    H.mkfile(root, 'live.txt', 'live')
    init_repo(root)
    commit_all(root, 'base')
    H.assert_true(vim.uv.fs_unlink(root .. '/gone.txt'), 'removes a tracked file')
    H.assert_true(vim.uv.fs_unlink(root .. '/removed/nested/deep.txt'),
      'removes a tracked descendant')
    H.assert_true(vim.uv.fs_rmdir(root .. '/removed/nested'), 'removes its nested directory')
    H.assert_true(vim.uv.fs_rmdir(root .. '/removed'), 'removes its parent directory')

    config.setup({ map_default_keys = false, show_folder_icons = true, show_file_icons = true })
    local listing = buffer.list(root)
    local lines = H.buf_lines()
    H.assert_eq(lines, { '.git/', 'removed/', 'gone.txt', 'live.txt' },
      'deleted paths appear beside normal filesystem entries')
    local row_for = function(text)
      for row, line in ipairs(lines) do if line == text then return row end end
    end
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-highlights']
    local marks = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1,
        { details = true })) do
      marks[mark[2]] = mark
    end
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitDeletedFile', link = true }),
      { default = true, link = 'ErrorMsg' }, 'deleted-file group defaults to ErrorMsg')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitDeletedDirectory', link = true }),
      { default = true, link = 'ErrorMsg' }, 'deleted-directory group defaults to ErrorMsg')
    H.assert_eq(marks[row_for('removed/') - 1][4].hl_group, 'DirectGitDeletedDirectory',
      'missing directory name uses its dedicated highlight')
    H.assert_eq(marks[row_for('gone.txt') - 1][4].hl_group, 'DirectGitDeletedFile',
      'missing file name uses its dedicated highlight')
    local gutters = marks_by_row(0, 'direct-listing-git-gutter')
    H.assert_eq(gutter_text(gutters[row_for('gone.txt') - 1]), ' |',
      'deleted worktree entries use the second gutter cell')
    H.assert_eq(gutters[row_for('gone.txt') - 1][2][4].sign_hl_group,
      'DirectGitDeletedGutter', 'deleted status uses DiffDelete')

    H.assert_true(listing:expand(row_for('removed/')), 'expands a missing Git directory')
    lines = H.buf_lines()
    H.assert_eq(lines, { '.git/', 'removed/', '  nested/', 'gone.txt', 'live.txt' },
      'deleted directory exposes its deleted child directory')
    H.assert_true(listing:expand(3), 'recursively expands a deleted directory child')
    H.assert_eq(H.buf_lines(), {
      '.git/', 'removed/', '  nested/', '    deep.txt', 'gone.txt', 'live.txt',
    }, 'deleted descendants remain navigable by their rows')

    local state = buffer._state_for_test(vim.api.nvim_get_current_buf())
    local nested_id = state.display_ids[3]
    H.assert_eq(state.rows[nested_id].deleted_kind, 'directory',
      'expanded missing directory retains a protected row identity')
    local deep_path = listing:get_entry_path(4)
    H.assert_eq(deep_path, root .. '/removed/nested/deep.txt',
      'the deleted row resolves to its tracked path')
    H.assert_false(listing:open('removed/'), 'deleted entries cannot be opened')
    H.assert_eq(listing:get_paths(4, 4), {}, 'deleted paths are excluded from yanks')
    H.assert_eq(listing:paste_destination(4), false,
      'pasting on a deleted file row is a silent no-op')
    H.assert_true(listing:collapse(2), 'z-style collapse works on a deleted directory')
    H.assert_eq(H.buf_lines(), { '.git/', 'removed/', 'gone.txt', 'live.txt' },
      'collapsing removes only the virtual descendants')
    H.assert_true(listing:expand(2), 'z-style expansion can reopen the deleted directory')
    H.assert_true(listing:expand(3), 'nested deleted directories remain expandable')

    local yank_calls = 0
    local restore_yank = H.stub(register, 'yank', function()
      yank_calls = yank_calls + 1
      return true
    end)
    local deleted_row = 5
    H.assert_true(direct.yank(deleted_row, deleted_row), 'yanking a deleted row is ignored')
    restore_yank()
    H.assert_eq(yank_calls, 0, 'deleted rows do not enter the yank register')
    vim.api.nvim_win_set_cursor(0, { deleted_row, 0 })
    H.assert_true(direct.paste(), 'pasting onto a deleted row is ignored')

    vim.api.nvim_buf_set_lines(0, deleted_row - 1, deleted_row, false, { 'forged.txt' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
    H.assert_eq(vim.api.nvim_buf_get_lines(0, deleted_row - 1, deleted_row, false)[1],
      'gone.txt', 'text edits to a deleted row are silently restored')
    H.assert_true(listing:sync(), 'sync treats restored deleted rows as view-only')
    H.assert_nil(vim.uv.fs_stat(root .. '/forged.txt'),
      'sync never creates the edited tombstone name')
    H.assert_nil(vim.uv.fs_stat(root .. '/gone.txt'),
      'sync never turns the Git deletion into a filesystem action')
    vim.api.nvim_buf_set_lines(0, deleted_row - 1, deleted_row, false, {})
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
    H.assert_eq(vim.api.nvim_buf_get_lines(0, deleted_row - 1, deleted_row, false)[1],
      'gone.txt', 'deleting a tombstone row is silently undone')
  end)

  H.it('does not classify directories outside Git repositories', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'plain')
    H.mkfile(root, 'file.txt', 'plain')
    H.assert_nil(git_status.read(root), 'non-repository status is silently unavailable')
  end)
end)
