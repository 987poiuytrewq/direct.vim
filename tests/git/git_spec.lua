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
    H.mkfile(root, 'staged-add.txt', 'added')
    git(root, 'add', 'staged-add.txt')
    H.mkfile(root, 'untracked.txt', 'untracked')
    git(root, 'mv', 'nested/deep.txt', 'nested/renamed.txt')

    local snapshot = git_status.read(root)
    H.assert_not_nil(snapshot, 'Git repository status is available')
    H.assert_eq(status_at(snapshot, root, 'tracked.txt'), 'modified',
      'staged modification is classified')
    H.assert_eq(status_at(snapshot, root, 'staged-add.txt'), 'added',
      'staged addition is classified')
    H.assert_eq(status_at(snapshot, root, 'untracked.txt'), 'added',
      'untracked file is classified as added')
    H.assert_eq(status_at(snapshot, root, 'nested/renamed.txt'), 'renamed',
      'Git-detected rename is classified at the destination')
    H.assert_eq(status_at(snapshot, root, 'nested'), 'renamed',
      'directory inherits a status from a changed descendant')
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

  H.it('defaults to colored gutter symbols and supports inline display overrides', function()
    local buffer = require('direct.buffer')
    local config = require('direct.config')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'display-repo')
    H.mkfile(root, 'tracked.txt', 'before')
    H.mkfile(root, 'nested/clean.txt', 'clean')
    init_repo(root)
    commit_all(root, 'base')
    H.mkfile(root, 'tracked.txt', 'after')
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

    H.assert_eq(lines, { '.git/', 'nested/', 'tracked.txt' },
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
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_text, '┃ ',
      'modified entry receives the gutter symbol')
    H.assert_eq(gutters[rows['tracked.txt']][4].sign_hl_group, 'DirectGitModifiedGutter',
      'modified gutter uses its status color')
    H.assert_eq(gutters[rows['nested/']][4].sign_text, '┃ ',
      'added directory receives the same gutter symbol')
    H.assert_eq(gutters[rows['nested/']][4].sign_hl_group, 'DirectGitAddedGutter',
      'added gutter uses its status color')

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
    H.assert_not_nil(icons[rows['tracked.txt']], 'modified file has an icon extmark')
    H.assert_not_nil(highlights[rows['tracked.txt']], 'modified file has a text highlight')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '\u{f0214} ', 'DirectGitModifiedIcon' } },
      'modified file keeps its regular icon glyph and uses the Git icon group')
    H.assert_eq(highlights[rows['tracked.txt']][4].hl_group, 'DirectGitModified',
      'modified entry receives the Git text highlight')
    H.assert_eq(icons[rows['nested/']][4].virt_text,
      { { '\u{f024b} ', 'DirectGitAddedIcon' } },
      'directory status is aggregated while its folder glyph remains unchanged')
    H.assert_eq(gutters[rows['nested/']][4].sign_text, 'A ',
      'optional custom gutter symbol is rendered for the added directory')
    H.assert_nil(gutters[rows['tracked.txt']], 'disabled gutter is omitted')

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
      },
    })
    listing:list()
    icons = mark_by_row(0, 'direct-listing-icons')
    highlights = mark_by_row(0, 'direct-listing-highlights')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '! ', 'DirectGitModifiedIcon' } }, 'custom icon override is applied')
    H.assert_eq(icons[rows['nested/']][4].virt_text,
      { { '+ ', 'DirectGitAddedIcon' } }, 'directory icon variant can be overridden separately')
    H.assert_nil(highlights[rows['tracked.txt']],
      'icon-only display leaves entry text unhighlighted')

    config.setup({
      map_default_keys = false,
      show_folder_icons = true,
      show_file_icons = true,
      git = { display = 'text', statuses = {
        modified = { text_hl = 'DirectGitModified', gutter = false },
        added = { text_hl = 'DirectGitAdded', gutter = false },
      } },
    })
    listing:list()
    icons = mark_by_row(0, 'direct-listing-icons')
    highlights = mark_by_row(0, 'direct-listing-highlights')
    H.assert_eq(icons[rows['tracked.txt']][4].virt_text,
      { { '\u{f0214} ', 'DirectFileIcon' } },
      'text-only display leaves the regular icon and its highlight unchanged')
    H.assert_eq(highlights[rows['tracked.txt']][4].hl_group, 'DirectGitModified',
      'text-only display highlights the entry name')
  end)

  H.it('does not classify directories outside Git repositories', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'plain')
    H.mkfile(root, 'file.txt', 'plain')
    H.assert_nil(git_status.read(root), 'non-repository status is silently unavailable')
  end)
end)
