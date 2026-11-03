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

H.describe('Git status display', function()
  H.it('classifies staged and unstaged changes and aggregates directory statuses', function()
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
    H.assert_eq(status_at(snapshot, root, 'tracked.txt'), 'modified',
      'staged modification is classified')
    H.assert_eq(git_status.staging_for(snapshot, vim.fs.joinpath(root, 'tracked.txt')),
      'mixed', 'staged and unstaged changes to one path are distinguished')
    H.assert_eq(status_at(snapshot, root, 'staged-add.txt'), 'added',
      'staged addition is classified')
    H.assert_eq(git_status.staging_for(snapshot, vim.fs.joinpath(root, 'staged-add.txt')),
      'staged', 'index-only changes are marked staged')
    H.assert_eq(status_at(snapshot, root, 'untracked.txt'), 'added',
      'untracked file is classified as added')
    H.assert_eq(git_status.staging_for(snapshot, vim.fs.joinpath(root, 'untracked.txt')),
      'unstaged', 'untracked files are marked unstaged')
    H.assert_eq(status_at(snapshot, root, 'nested/renamed.txt'), 'renamed',
      'Git-detected rename is classified at the destination')
    H.assert_eq(status_at(snapshot, root, 'nested'), 'renamed',
      'directory inherits a status from a changed descendant')
    H.assert_eq(git_status.staging_for(snapshot, vim.fs.joinpath(root, 'nested')),
      'mixed', 'directory aggregates staged and unstaged descendants')
    H.assert_eq(git_status.staging_style_for(snapshot, vim.fs.joinpath(root, 'tracked.txt')),
      'mixed_file', 'mixed files select their dedicated display settings')
    H.assert_eq(git_status.staging_style_for(snapshot, vim.fs.joinpath(root, 'nested'), true),
      'mixed_folder', 'mixed folders select their dedicated display settings')
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
    H.assert_eq(status_at(snapshot, root, 'conflict.txt'), 'conflicted',
      'unmerged file is classified as conflicted')
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
          local mark = mark_by_row(0, 'direct-listing-git-gutter')[row - 1]
          return mark and mark[4].sign_text
        end
      end
    end

    H.assert_eq(marker(), '┃ ', 'the initial worktree change is marked unstaged')
    run_command('DirectRun git add -- {}')
    H.assert_eq(marker(), '┃ ', 'DirectRun does not refresh cached Git status')

    run_command('DirectGit git add -- {}')
    H.assert_eq(marker(), '┃•', 'DirectGit refreshes the indicator after staging')
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
      return mark_by_row(0, 'direct-listing-git-gutter')[line_row]
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

    H.assert_eq(gutter_for('tracked.txt')[4].sign_text, '┃ ',
      'an unstaged modification starts with the unstaged marker')

    press_and_wait('ga')
    H.assert_eq(gutter_for('tracked.txt')[4].sign_text, '┃•',
      'ga stages the file and changes the indicator')

    press_and_wait('gr')
    H.assert_eq(gutter_for('tracked.txt')[4].sign_text, '┃ ',
      'gr unstages the file and restores the unstaged indicator')

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
    H.assert_eq(status_at(snapshot, root, 'gone.txt'), 'deleted',
      'unstaged file deletion is classified')
    H.assert_eq(status_at(snapshot, root, 'removed'), 'deleted',
      'directory status aggregates its deleted descendants')
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
    local staged = snapshot.deleted[vim.fs.joinpath(root, 'gone.txt')]
    H.assert_true(staged.staged, 'staged deletion state is retained')
    H.assert_false(staged.unstaged, 'staged deletion is not reported as unstaged')
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
    H.assert_eq(git_status.status_for(snapshot, root .. '/gone.txt'), 'deleted',
      'hiding a row does not disable deleted status data')
    H.assert_eq(git_status.status_for(snapshot, root .. '/live.txt'), 'modified',
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

  H.it('defaults to colored gutters and supports staged display overrides', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'display-repo')
    H.mkfile(root, 'tracked.txt', 'before')
    H.mkfile(root, 'nested/clean.txt', 'clean')
    init_repo(root)
    commit_all(root, 'base')
    H.mkfile(root, 'tracked.txt', 'after')
    git(root, 'add', 'tracked.txt')
    H.mkfile(root, 'tracked.txt', 'staged and modified again')
    H.mkfile(root, 'nested/clean.txt', 'staged nested modification')
    git(root, 'add', 'nested/clean.txt')
    H.mkfile(root, 'staged.txt', 'staged')
    git(root, 'add', 'staged.txt')
    H.mkfile(root, 'nested/new.txt', 'new')

    config.setup({
      map_default_keys = false,
      show_folder_icons = true,
      show_file_icons = true,
    })
    H.assert_eq(config.options.git.display, 'gutter', 'gutter-only display is the default')
    local listing = buffer.list(root)
    local lines = H.buf_lines()
    local rows = {}
    for row, line in ipairs(lines) do rows[line] = row - 1 end
    local highlights = mark_by_row(0, 'direct-listing-highlights')
    local icons = mark_by_row(0, 'direct-listing-icons')
    local gutters = mark_by_row(0, 'direct-listing-git-gutter')

    H.assert_eq(lines, { '.git/', 'nested/', 'staged.txt', 'tracked.txt' },
      'listing text remains ordinary paths')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitAddedGutter', link = true }),
      { default = true, link = 'DiffAdd' }, 'added gutter group links to DiffAdd')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitModifiedGutter', link = true }),
      { default = true, link = 'DiffChange' }, 'modified gutter group links to DiffChange')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitConflictedGutter', link = true }),
      { default = true, link = 'ErrorMsg' }, 'conflict gutter group links to ErrorMsg')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '\u{f0214} ', 'DirectFileIcon' } },
      'default gutter display leaves the normal file icon unchanged')
    H.assert_nil(highlights[rows['tracked.txt']],
      'default gutter display leaves the entry name unhighlighted')
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_text, '┃•',
      'partly staged file receives the staged gutter symbol')
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_hl_group, 'DirectGitStagedGutter',
      'partly staged gutter uses its staged color')
    H.assert_eq(gutters[rows['nested/']][4].sign_text, '┃•',
      'mixed directory receives the staged gutter symbol')
    H.assert_eq(gutters[rows['nested/']][4].sign_hl_group, 'DirectGitStagedGutter',
      'mixed directory gutter uses its staged color')

    config.setup({
      map_default_keys = false,
      show_folder_icons = true,
      show_file_icons = true,
      git = {
        display = 'both',
        statuses = {
          added = {
            icon_hl = 'DirectGitAddedIcon',
            text_hl = 'DirectGitAdded',
            gutter = { symbol = 'A', highlight = 'DirectGitAddedGutter' },
          },
          modified = {
            icon_hl = 'DirectGitModifiedIcon',
            text_hl = 'DirectGitModified',
            gutter = false,
          },
        },
      },
    })
    listing:list()
    H.assert_true(config.options.show_file_icons, 'file icons are enabled for this listing')
    H.assert_true(config.options.show_folder_icons, 'folder icons are enabled for this listing')
    highlights = mark_by_row(0, 'direct-listing-highlights')
    icons = mark_by_row(0, 'direct-listing-icons')
    gutters = mark_by_row(0, 'direct-listing-git-gutter')

    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitAddedIcon', link = true }),
      { default = true, link = 'DiffAdd' }, 'added icon group links to DiffAdd')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitModified', link = true }),
      { default = true, link = 'DiffChange' }, 'modified text group links to DiffChange')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitRenamed', link = true }),
      { default = true, link = 'DiffChange' }, 'renamed text group links to DiffChange')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitConflictedIcon', link = true }),
      { default = true, link = 'ErrorMsg' }, 'conflict icon group links to ErrorMsg')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitStagedIcon', link = true }),
      { default = true, link = 'DiffAdd' }, 'staged icon group links to DiffAdd')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectGitUnstaged', link = true }),
      { default = true, link = 'DiffChange' }, 'unstaged text group links to DiffChange')
    H.assert_not_nil(icons[rows['tracked.txt']], 'modified file has an icon extmark')
    H.assert_not_nil(highlights[rows['tracked.txt']], 'modified file has a text highlight')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '\u{f0214} ', 'DirectGitStagedIcon' } },
      'modified file keeps its regular icon glyph and uses the Git icon group')
    H.assert_eq(highlights[rows['tracked.txt']][4].hl_group, 'DirectGitStaged',
      'partly staged entry uses the staged text highlight')
    H.assert_eq(icons[rows['nested/']][4].virt_text,
      { { '\u{f024b} ', 'DirectGitStagedIcon' } },
      'directory status is aggregated while its folder glyph remains unchanged')
    H.assert_eq(gutters[rows['staged.txt']][4].sign_text, '┃•',
      'staged files use the default pipe-and-bullet gutter symbol')
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_text, '┃•',
      'partly staged files use the staged gutter symbol')
    H.assert_eq(gutters[rows['nested/']][4].sign_text, '┃•',
      'mixed directories use the staged gutter symbol')

    config.setup({
      map_default_keys = false,
      git = {
        staging = { enabled = false },
        statuses = {
          added = { gutter = { symbol = 'A', highlight = 'DirectGitAddedGutter' } },
        },
      },
    })
    listing:list()
    gutters = mark_by_row(0, 'direct-listing-git-gutter')
    H.assert_eq(gutters[rows['nested/']][4].sign_text, 'A ',
      'status-specific gutter symbols remain available when staging markers are disabled')
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_text, '┃ ',
      'the modified status retains its default gutter when staging is disabled')

    config.setup({
      map_default_keys = false,
      show_folder_icons = true,
      show_file_icons = true,
      git = {
        display = 'icon',
        statuses = {
          modified = {
            icon = { file = '!' }, icon_hl = 'DirectGitModifiedIcon', gutter = false,
          },
          added = {
            icon = { folder = '+' }, icon_hl = 'DirectGitAddedIcon', gutter = false,
          },
        },
        staging = {
          mixed_file = {
            icon_hl = 'DirectGitMixedFileIcon',
            icon = { file = '!' },
            gutter = { symbol = 'F', highlight = 'DirectGitMixedFileGutter' },
          },
          mixed_folder = {
            icon_hl = 'DirectGitMixedFolderIcon',
            icon = { folder = '+' },
            gutter = { symbol = 'D', highlight = 'DirectGitMixedFolderGutter' },
          },
        },
      },
    })
    listing:list()
    icons = mark_by_row(0, 'direct-listing-icons')
    highlights = mark_by_row(0, 'direct-listing-highlights')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '! ', 'DirectGitMixedFileIcon' } },
      'mixed files apply their independent glyph and icon-color overrides')
    H.assert_eq(icons[rows['nested/']][4].virt_text,
      { { '+ ', 'DirectGitMixedFolderIcon' } },
      'mixed folders apply their independent glyph and icon-color overrides')
    gutters = mark_by_row(0, 'direct-listing-git-gutter')
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_text, 'F ',
      'mixed files use their independent gutter style')
    H.assert_eq(gutters[rows['nested/']][4].sign_text, 'D ',
      'mixed folders use their independent gutter style')
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_hl_group, 'DirectGitMixedFileGutter',
      'mixed-file gutter color is configurable')
    H.assert_eq(gutters[rows['nested/']][4].sign_hl_group, 'DirectGitMixedFolderGutter',
      'mixed-folder gutter color is configurable')
    H.assert_nil(highlights[rows['tracked.txt']],
      'icon-only display leaves entry text unhighlighted')

    config.setup({
      map_default_keys = false,
      show_folder_icons = true,
      show_file_icons = true,
      git = {
        display = 'text',
        statuses = {
          modified = { text_hl = 'DirectGitModified', gutter = false },
          added = { text_hl = 'DirectGitAdded', gutter = false },
        },
        staging = {
          mixed_file = { text_hl = 'DirectMixedFileText' },
          mixed_folder = { text_hl = 'DirectMixedFolderText' },
        },
      },
    })
    listing:list()
    icons = mark_by_row(0, 'direct-listing-icons')
    highlights = mark_by_row(0, 'direct-listing-highlights')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '\u{f0214} ', 'DirectFileIcon' } },
      'text-only display leaves the regular icon and its highlight unchanged')
    H.assert_eq(highlights[rows['tracked.txt']][4].hl_group, 'DirectMixedFileText',
      'mixed files can override their text color independently')
    H.assert_eq(highlights[rows['nested/']][4].hl_group, 'DirectMixedFolderText',
      'mixed folders can override their text color independently')
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
    local gutter_namespace = vim.api.nvim_get_namespaces()['direct-listing-git-gutter']
    local gutters = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, gutter_namespace, 0, -1,
        { details = true })) do
      gutters[mark[2]] = mark
    end
    H.assert_eq(gutters[row_for('gone.txt') - 1][4].sign_text, '┃ ',
      'deleted entries retain the regular Git gutter symbol')
    H.assert_eq(gutters[row_for('gone.txt') - 1][4].sign_hl_group,
      'DirectGitUnstagedGutter', 'deleted entries use the default unstaged gutter style')

    config.setup({ map_default_keys = false, git = { staging = { enabled = false } } })
    listing:list()
    gutters = mark_by_row(0, 'direct-listing-git-gutter')
    H.assert_eq(gutters[row_for('gone.txt') - 1][4].sign_hl_group,
      'DirectGitDeletedGutter', 'deleted status has its own gutter when staging is disabled')

    config.setup({ map_default_keys = false, git = {
      display = 'both',
      statuses = { deleted = { text_hl = 'DirectCustomDeletedText' } },
    } })
    listing:list()
    marks = mark_by_row(0, 'direct-listing-highlights')
    H.assert_eq(marks[row_for('gone.txt') - 1][4].hl_group, 'DirectGitDeletedFile',
      'deleted name groups take precedence over Git status text overrides')

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
