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

local function status_chunks(marks)
  return marks and marks[1] and marks[1][4].virt_text
end

local function status_text(marks)
  local chunks = status_chunks(marks)
  if not chunks then return nil end
  return table.concat(vim.tbl_map(function(chunk) return chunk[1] end, chunks))
end

H.describe('Git status display', function()
  H.it('does not send already-tracked paths to Git ignore queries', function()
    local original_system = vim.system
    local system_calls = 0
    vim.system = function(...)
      system_calls = system_calls + 1
      return original_system(...)
    end
    local ignored, err = git_status.ignored_paths({
      root = '/direct-ignore-query-test',
      scope_path = '/direct-ignore-query-test',
      repo_prefix = '',
      tracked = { ['tracked.txt'] = true },
    }, { '/direct-ignore-query-test/tracked.txt' })
    vim.system = original_system

    H.assert_eq(ignored, {}, 'tracked entries cannot be filtered by Git')
    H.assert_nil(err, 'the filtered query succeeds without Git')
    H.assert_eq(system_calls, 0, 'all-tracked input launches no check-ignore process')
  end)

  H.it('preserves porcelain columns and aggregates each directory column independently', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, 'tracked.txt', 'before')
    H.mkfile(root, 'nested/deep.txt', 'before')
    H.mkfile(root, 'mixed-deletions/index.txt', 'staged deletion')
    H.mkfile(root, 'mixed-deletions/worktree.txt', 'worktree deletion')
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
    H.assert_true(vim.uv.fs_unlink(root .. '/mixed-deletions/index.txt'),
      'remove a staged-deletion descendant')
    git(root, 'add', 'mixed-deletions/index.txt')
    H.assert_true(vim.uv.fs_unlink(root .. '/mixed-deletions/worktree.txt'),
      'remove an unstaged-deletion descendant')

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
    H.assert_eq(status_at(snapshot, root, 'mixed-deletions'), 'DD',
      'directory aggregation can form a DD pair from separate deletions')
    local _, conflict = git_status.status_for(snapshot,
      vim.fs.joinpath(root, 'mixed-deletions'))
    H.assert_false(conflict, 'aggregated DD is not itself a merge conflict')
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
    local status = marks_by_row(0, 'direct-listing-git-status')[row]
    H.assert_eq(status_text(status), '\u{f01f} \u{f00d}',
      'unmerged status uses the pen and conflict symbols')
    H.assert_eq(status_chunks(status)[1][2], 'DirectGitModified',
      'the change symbol uses the modified highlight')
    H.assert_eq(status_chunks(status)[3][2], 'DirectGitConflict',
      'the conflict symbol uses the conflict highlight')
    local name_highlights = mark_by_row(0, 'direct-listing-highlights')
    local icons = mark_by_row(0, 'direct-listing-icons')
    H.assert_eq(name_highlights[row][4].hl_group, 'DirectGitModified',
      'conflict filename follows the first, modified symbol')
    H.assert_eq(icons[row][4].virt_text, { { '\u{f15b} ', 'DirectGitModified' } },
      'conflict icon follows the first, modified symbol')
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

  H.it('shows ignored files with Neo-tree ignored status symbol', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'ignored-repo')
    H.mkfile(root, '.gitignore', 'ignored.txt\n')
    init_repo(root)
    commit_all(root, 'base')
    H.mkfile(root, 'ignored.txt', 'ignored')

    local snapshot = git_status.read(root)
    H.assert_eq(status_at(snapshot, root, 'ignored.txt'), '!!',
      'Git reports ignored entries in porcelain output')

    config.setup({ map_default_keys = false })
    buffer.list(root)
    local row
    for index, line in ipairs(H.buf_lines()) do
      if line == 'ignored.txt' then row = index - 1 end
    end
    H.assert_not_nil(row, 'ignored file remains listed when ignore filtering is disabled')
    local status = marks_by_row(0, 'direct-listing-git-status')[row]
    H.assert_eq(status_text(status), '\u{f070}  ',
      'ignored entry uses the eye-slash symbol')
    H.assert_eq(status_chunks(status)[1][2], 'DirectGitIgnored',
      'ignored entry uses the ignored highlight')
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
    local function marker()
      for row, line in ipairs(H.buf_lines()) do
        if line == 'tracked.txt' then
          local marks = marks_by_row(0, 'direct-listing-git-status')[row - 1]
          return status_text(marks)
        end
      end
    end

    local function run_command(command, completed)
      H.capture_messages()
      select_file()
      vim.cmd(command)
      H.assert_true(vim.wait(3000, completed), command .. ' completes successfully')
    end

    H.assert_eq(marker(), '\u{f01f}  ', 'worktree modification leaves the state slot blank')
    run_command('DirectRun git add -- {}', function()
      return H.messages():find('status 0', 1, true) ~= nil
    end)
    H.assert_eq(marker(), '\u{f01f}  ', 'DirectRun does not refresh cached Git status')

    run_command('DirectGit git add -- {}', function()
      return marker() == '\u{f01f} \u{f00c}'
    end)
    H.assert_eq(marker(), '\u{f01f} \u{f00c}',
      'DirectGit refreshes the indicator after staging')
    H.assert_eq(H.messages():find('status 0', 1, true), nil,
      'successful DirectGit commands do not notify in the command area')
  end)

  H.it('ga, gr, and gc update the staged/unstaged status symbols', function()
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
    local function status_for_line(name)
      local line_row
      for row, line in ipairs(H.buf_lines()) do
        if line == name then line_row = row - 1 end
      end
      H.assert_not_nil(line_row, 'the tracked file remains in the listing')
      return marks_by_row(0, 'direct-listing-git-status')[line_row]
    end
    local function press_and_wait(lhs, expected_status)
      local file_row
      for row, line in ipairs(H.buf_lines()) do
        if line == 'tracked.txt' then file_row = row end
      end
      H.assert_not_nil(file_row, 'the tracked file remains selectable')
      vim.api.nvim_win_set_cursor(0, { file_row, 0 })
      H.capture_messages()
      vim.api.nvim_feedkeys(lhs, 'mx', false)
      H.assert_true(vim.wait(3000, function()
        local status = status_for_line('tracked.txt')
        if expected_status == nil then return status == nil end
        return status_text(status) == expected_status
      end), lhs .. ' completes its DirectGit command')
      H.assert_eq(H.messages():find('status 0', 1, true), nil,
        lhs .. ' succeeds without a command-area notification')
    end

    H.assert_eq(status_text(status_for_line('tracked.txt')), '\u{f01f}  ',
      'an unstaged modification leaves the state slot blank')

    press_and_wait('ga', '\u{f01f} \u{f00c}')
    H.assert_eq(status_text(status_for_line('tracked.txt')), '\u{f01f} \u{f00c}',
      'ga moves the modification to the staged state')

    press_and_wait('gr', '\u{f01f}  ')
    H.assert_eq(status_text(status_for_line('tracked.txt')), '\u{f01f}  ',
      'gr moves the modification back to the blank worktree state')

    press_and_wait('gc', nil)
    H.assert_nil(status_for_line('tracked.txt'),
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

  H.it('renders Neo-tree-style right-aligned Git status components', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'display-repo')
    H.mkfile(root, 'tracked.txt', 'before')
    H.mkfile(root, 'index-only.txt', 'before')
    H.mkfile(root, 'worktree-only.txt', 'before')
    H.mkfile(root, 'nested/clean.txt', 'clean')
    H.mkfile(root, 'mixed-deletions/index.txt', 'staged deletion')
    H.mkfile(root, 'mixed-deletions/worktree.txt', 'worktree deletion')
    init_repo(root)
    commit_all(root, 'base')
    H.mkfile(root, 'untracked.txt', 'untracked')
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
    H.assert_true(vim.uv.fs_unlink(root .. '/mixed-deletions/index.txt'),
      'remove an index-side directory descendant')
    git(root, 'add', 'mixed-deletions/index.txt')
    H.assert_true(vim.uv.fs_unlink(root .. '/mixed-deletions/worktree.txt'),
      'remove a worktree-side directory descendant')

    config.setup({
      map_default_keys = false,
      show_folder_icons = true,
      show_file_icons = true,
    })
    H.assert_eq(config.options.git.symbols.modified, '\u{f01f}',
      'modified symbol uses the Neo-tree default')
    local previous_signcolumn = vim.wo.signcolumn
    local listing = buffer.list(root)
    local lines = H.buf_lines()
    local rows = {}
    for row, line in ipairs(lines) do rows[line] = row - 1 end
    local highlights = mark_by_row(0, 'direct-listing-highlights')
    local icons = mark_by_row(0, 'direct-listing-icons')
    local statuses = marks_by_row(0, 'direct-listing-git-status')

    for group, target in pairs({
      DirectGitAdded = 'DiffAdd',
      DirectGitDeleted = 'DiffDelete',
      DirectGitModified = 'DiffChange',
      DirectGitRenamed = 'DirectGitModified',
      DirectGitStaged = 'DirectGitAdded',
      DirectGitConflict = 'ErrorMsg',
      DirectGitIgnored = 'Comment',
    }) do
      H.assert_eq(vim.api.nvim_get_hl(0, { name = group, link = true }),
        { default = true, link = target }, group .. ' follows its colorscheme group')
    end

    H.assert_eq(lines, { '.git/', 'mixed-deletions/', 'nested/', 'index-only.txt',
      'staged-add.txt', 'tracked.txt',
      'untracked.txt', 'worktree-only.txt' },
      'listing text remains ordinary paths')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '\u{f15b} ', 'DirectGitModified' } },
      'the first status symbol colors the normal file icon')
    H.assert_eq(highlights[rows['tracked.txt']][4].hl_group, 'DirectGitModified',
      'the first status symbol colors the entry name')
    H.assert_eq(status_text(statuses[rows['tracked.txt']]), '\u{f01f} \u{f01f}',
      'MM displays both change symbols without a separate stage marker')
    H.assert_eq(status_chunks(statuses[rows['tracked.txt']])[1][2], 'DirectGitModified',
      'index change uses the modified highlight')
    H.assert_eq(status_chunks(statuses[rows['tracked.txt']])[3][2], 'DirectGitModified',
      'worktree change uses the modified highlight')
    H.assert_eq(status_text(statuses[rows['index-only.txt']]), '\u{f01f} \u{f00c}',
      'index-only changes show modified and staged symbols')
    H.assert_eq(highlights[rows['index-only.txt']][4].hl_group, 'DirectGitModified',
      'an index-only status colors the filename like its first symbol')
    H.assert_eq(icons[rows['index-only.txt']][4].virt_text,
      { { '\u{f15b} ', 'DirectGitModified' } },
      'an index-only status colors the icon like its first symbol')
    H.assert_eq(status_text(statuses[rows['staged-add.txt']]), '\u{f067} \u{f00c}',
      'staged additions show added and staged symbols')
    H.assert_eq(status_text(statuses[rows['worktree-only.txt']]), '\u{f01f}  ',
      'worktree-only changes leave the state slot blank')
    H.assert_eq(highlights[rows['worktree-only.txt']][4].hl_group, 'DirectGitModified',
      'worktree-only status colors the filename')
    H.assert_eq(icons[rows['worktree-only.txt']][4].virt_text,
      { { '\u{f15b} ', 'DirectGitModified' } },
      'worktree-only status colors the icon')
    H.assert_eq(status_text(statuses[rows['untracked.txt']]), '\u{f067}  ',
      'untracked ?? maps to added in the first slot')
    H.assert_eq(status_chunks(statuses[rows['untracked.txt']])[1][2], 'DirectGitAdded',
      'untracked entries use the added highlight')
    H.assert_eq(highlights[rows['untracked.txt']][4].hl_group, 'DirectGitAdded',
      'untracked first symbol colors the filename as added')
    H.assert_eq(status_text(statuses[rows['nested/']]), '\u{f01f} \u{f067}',
      'directories aggregate index and worktree change types')
    H.assert_eq(highlights[rows['nested/']][4].hl_group, 'DirectGitModified',
      'directory filename color follows its first aggregated status symbol')
    H.assert_eq(icons[rows['nested/']][4].virt_text,
      { { '\u{f07b} ', 'DirectGitModified' } },
      'directory icon color follows its first aggregated status symbol')
    H.assert_eq(status_text(statuses[rows['mixed-deletions/']]), '\u{f068} \u{f068}',
      'a directory DD aggregate is two deletions, not a conflict')
    H.assert_eq(highlights[rows['mixed-deletions/']][4].hl_group, 'DirectGitDeleted',
      'directory filename color follows the worktree deletion status')
    H.assert_eq(statuses[rows['tracked.txt']][1][4].virt_text_pos, 'eol_right_align',
      'Git status is right-aligned virtual text at the row end')
    H.assert_eq(vim.wo.signcolumn, previous_signcolumn,
      'Git status does not change the window signcolumn')

    config.setup({ git = { show_symbols = false } })
    listing:list()
    H.assert_eq(marks_by_row(0, 'direct-listing-git-status'), {},
      'show_symbols=false removes all Git status symbols')
    highlights = mark_by_row(0, 'direct-listing-highlights')
    icons = mark_by_row(0, 'direct-listing-icons')
    H.assert_eq(highlights[rows['worktree-only.txt']][4].hl_group, 'DirectGitModified',
      'hiding symbols keeps first-symbol filename colors')
    H.assert_eq(icons[rows['worktree-only.txt']][4].virt_text,
      { { '\u{f15b} ', 'DirectGitModified' } },
      'hiding symbols keeps worktree icon colors')

    config.setup({ git = { show_symbols = true } })
    listing:list()
    H.assert_true(#marks_by_row(0, 'direct-listing-git-status') > 0,
      'show_symbols=true restores Git status symbols')
    listing:list()
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
    local icons = mark_by_row(0, 'direct-listing-icons')
    H.assert_eq(icons[row_for('removed/') - 1][4].virt_text,
      { { '\u{f114} ', 'DirectGitDeleted' } },
      'collapsed deleted directories use the outlined folder glyph')
    H.assert_eq(icons[row_for('gone.txt') - 1][4].virt_text,
      { { '\u{f016} ', 'DirectGitDeleted' } },
      'deleted files use the outlined file glyph')
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
    H.assert_eq(marks[row_for('removed/') - 1][4].hl_group, 'DirectGitDeleted',
      'deleted directory name uses its worktree status highlight')
    H.assert_eq(marks[row_for('gone.txt') - 1][4].hl_group, 'DirectGitDeleted',
      'deleted file name uses its worktree status highlight')
    local statuses = marks_by_row(0, 'direct-listing-git-status')
    local deleted_status = statuses[row_for('gone.txt') - 1]
    H.assert_eq(status_text(deleted_status), '\u{f068}  ',
      'deleted worktree entries leave the state slot blank')
    H.assert_eq(status_chunks(deleted_status)[1][2], 'DirectGitDeleted',
      'deleted status uses its dedicated highlight')

    H.assert_true(listing:expand(row_for('removed/')), 'expands a missing Git directory')
    lines = H.buf_lines()
    icons = mark_by_row(0, 'direct-listing-icons')
    H.assert_eq(icons[1][4].virt_text, { { '\u{f115} ', 'DirectGitDeleted' } },
      'expanded deleted directories use the outlined open-folder glyph and worktree color')
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
