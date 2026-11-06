-- buffer_change_navigation_spec.lua -- navigation among changed listing rows.

local H = require('tests.support.harness')
local buffer = require('direct.buffer')

local function git(root, ...)
  local args = { 'git', '-C', root }
  for _, arg in ipairs({ ... }) do args[#args + 1] = arg end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    error(string.format('git %s failed: %s', table.concat({ ... }, ' '), result.stderr))
  end
  return (result.stdout or ''):gsub('[\r\n]+$', '')
end

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

H.describe('buffer navigation', function()
  H.it('moves through changed rows in either direction without wrapping', function()
    clean_buffers()
    require('direct.config').setup({ show_hidden = false, respect_gitignore = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    H.mkfile(root, 'a.txt', 'baseline a')
    H.mkfile(root, 'b.txt', 'baseline b')
    H.mkfile(root, 'c.txt', 'baseline c')
    H.mkfile(root, '.gitignore', 'ignored.txt\n')
    git(root, 'init', '-q')
    git(root, 'config', 'user.name', 'Direct Test')
    git(root, 'config', 'user.email', 'direct-test@example.invalid')
    git(root, 'add', '--all')
    git(root, 'commit', '-q', '-m', 'baseline')
    H.mkfile(root, 'a.txt', 'changed a')
    H.mkfile(root, 'c.txt', 'changed c')
    H.mkfile(root, 'ignored.txt', 'ignored')

    buffer.list(root)
    H.assert_buf_eq({ 'a.txt', 'b.txt', 'c.txt', 'ignored.txt' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    H.assert_true(buffer.next_change(), 'next change is found')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3, 'clean b.txt is skipped')
    H.assert_false(buffer.next_change(), 'navigation skips ignored entries and does not wrap')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3, 'boundary leaves the cursor in place')

    H.assert_true(buffer.previous_change(), 'previous change is found')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'previous change is a.txt')
    H.assert_false(buffer.previous_change(), 'navigation does not wrap before the first change')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'boundary leaves the cursor in place')
  end)

  H.it('only considers rows materialized in the current listing', function()
    clean_buffers()
    require('direct.config').setup({ show_hidden = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    local nested = H.mkdir(root, 'nested')
    H.mkfile(nested, 'file.txt', 'baseline')
    git(root, 'init', '-q')
    git(root, 'config', 'user.name', 'Direct Test')
    git(root, 'config', 'user.email', 'direct-test@example.invalid')
    git(root, 'add', '--all')
    git(root, 'commit', '-q', '-m', 'baseline')
    H.mkfile(nested, 'file.txt', 'changed')

    buffer.list(root)
    H.assert_buf_eq({ 'nested/' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.assert_false(buffer.next_change(), 'the collapsed descendant is not a row target')
  end)

  H.it('moves between visible files, skips directories, and does not wrap', function()
    clean_buffers()
    require('direct.config').setup({ show_hidden = false, respect_gitignore = false })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'files')
    local adir = H.mkdir(root, 'adir')
    H.mkfile(H.mkdir(adir, 'nested'), 'nested.txt', 'nested')
    H.mkfile(root, 'b.txt', 'b')
    H.mkfile(root, 'c.txt', 'c')

    buffer.list(root)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.assert_true(buffer.expand(), 'the first directory can be expanded')
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    H.assert_true(buffer.expand(), 'the nested directory can be expanded')
    H.assert_buf_eq({ 'adir/', '  nested/', '    nested.txt', 'b.txt', 'c.txt' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    H.assert_true(buffer.next_file(), 'next file is found after directory rows')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3,
      'expanded nested files are included and directories are skipped')
    H.assert_true(buffer.next_file(), 'the following file is found')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 4, 'navigation follows listing order')
    H.assert_true(buffer.next_file(), 'the last file is found')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5, 'root files follow nested files')
    H.assert_false(buffer.next_file(), 'navigation does not wrap at the end')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5, 'end boundary leaves cursor in place')

    H.assert_true(buffer.previous_file(), 'previous file is found')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 4, 'previous navigation finds b.txt')
    H.assert_true(buffer.previous_file(), 'previous navigation finds an expanded child file')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3, 'nested file is the prior target')
    H.assert_false(buffer.previous_file(), 'navigation does not wrap before the first file')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3,
      'start boundary leaves cursor in place')
  end)
end)
