-- tests/highlight_spec.lua -- listing filename highlight lifecycle.

local H = require('tests.support.harness')
local buffer = require('direct.buffer')
local highlight = require('direct.highlight')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

local function highlight_marks(bufnr)
  local ns = vim.api.nvim_get_namespaces()['direct-listing-highlights']
  H.assert_not_nil(ns, 'filename highlights have their own namespace')
  return vim.api.nvim_buf_get_extmarks(bufnr or 0, ns, 0, -1, { details = true })
end

local function row_mark(bufnr, row)
  for _, mark in ipairs(highlight_marks(bufnr)) do
    if mark[2] == row then return mark end
  end
end

local function syntax_group(row, col)
  return vim.fn.synIDattr(vim.fn.synID(row, col, true), 'name')
end

local function folder_icon_marks(bufnr)
  local ns = vim.api.nvim_get_namespaces()['direct-listing-icons']
  if not ns then return {} end
  return vim.api.nvim_buf_get_extmarks(bufnr or 0, ns, 0, -1, { details = true })
end

local function assert_folder_icon(bufnr, row, column, glyph)
  local found
  for _, mark in ipairs(folder_icon_marks(bufnr)) do
    if mark[2] == row then found = mark; break end
  end
  H.assert_not_nil(found, 'directory row ' .. row .. ' has a folder icon')
  if found then
    H.assert_eq(found[3], column, 'icon is placed at the indentation column')
    H.assert_eq(found[4].virt_text, { { glyph .. ' ', 'DirectFolderIcon' } },
      'icon glyph and highlight group')
    H.assert_eq(found[4].virt_text_pos, 'inline', 'icon is inline virtual text')
  end
end


H.describe('listing filename highlights', function()
  H.it('matches hidden entries at every indentation depth without visible filename groups', function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd('syntax on')
    vim.bo[bufnr].syntax = 'direct'
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      '.root-dir/', '.root-file', '  .child-dir/', '    .deep-file',
      'visible-dir/', 'visible-file', '  child-dir/', 'sample.js', 'Dockerfile',
      'Makefile', 'README.md',
    })

    H.assert_eq(syntax_group(1, 1), 'DirectHiddenDirectory', 'root hidden directory')
    H.assert_eq(syntax_group(2, 1), 'DirectHiddenFile', 'root hidden file')
    H.assert_eq(syntax_group(3, 3), 'DirectHiddenDirectory', 'indented hidden directory')
    H.assert_eq(syntax_group(4, 5), 'DirectHiddenFile', 'deeply indented hidden file')
    H.assert_eq(syntax_group(5, 1), 'DirectDirectory', 'visible directory')
    H.assert_true(syntax_group(6, 1) ~= 'DirectFile', 'visible file has no Direct group')
    H.assert_eq(syntax_group(7, 3), 'DirectDirectory', 'indented visible directory')
    for _, case in ipairs({
      { 6, 'visible-file' }, { 8, 'sample.js' }, { 9, 'Dockerfile' },
      { 10, 'Makefile' }, { 11, 'README.md' },
    }) do
      H.assert_eq(syntax_group(case[1], 1), '', case[2] .. ' has no filename syntax highlight')
    end
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectDirectory', link = true }), {
      link = 'Directory',
    }, 'visible directory group links to Directory by default')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectFile', link = true }), {},
      'visible file group is not defined')
  end)

  H.it('leaves the icon namespace uncreated when folder icons are disabled', function()
    clean_buffers()
    local config = require('direct.config')
    H.assert_false(config.options.show_folder_icons == true, 'icons default off')
    H.assert_nil(vim.api.nvim_get_namespaces()['direct-listing-icons'],
      'disabled rendering does not create the icon namespace')
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'directory')
    H.mkfile(ws, 'file.txt', '')
    local listing = buffer.list(ws)
    H.assert_eq(H.buf_lines(), { 'directory/', 'file.txt' })
    H.assert_nil(vim.api.nvim_get_namespaces()['direct-listing-icons'],
      'listing with the option off still creates no icon namespace')
    H.assert_eq(folder_icon_marks(0), {}, 'there are no icon extmarks')
    H.assert_eq(listing:get_paths(1, 2), { ws .. '/directory/', ws .. '/file.txt' })
  end)

  H.it('renders closed/open icons idempotently without changing buffer lines', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({ show_folder_icons = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(ws, 'empty')
    H.mkdir(sub, 'nested')
    H.mkfile(sub, 'inside.txt', '')
    H.mkfile(ws, 'file.txt', '')
    local listing = buffer.list(ws)
    local plain_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    config.setup({ show_folder_icons = true })
    listing:list()

    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), plain_lines,
      'icons do not alter buffer text')
    local closed, opened = '\u{f024b}', '\u{f0770}'
    H.assert_eq(#folder_icon_marks(0), 2, 'initial render marks both directories once')
    assert_folder_icon(0, 0, 0, closed)
    assert_folder_icon(0, 1, 0, closed)
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectFolderIcon', link = true }),
      { default = true, link = 'Directory' }, 'icon group links to Directory by default')

    listing:expand(2)
    local expanded_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    H.assert_eq(expanded_lines, { 'empty/', 'sub/', '  nested/', '  inside.txt', 'file.txt' })
    H.assert_eq(#folder_icon_marks(0), 3, 'expanded view has one icon per directory row')
    assert_folder_icon(0, 1, 0, opened)
    assert_folder_icon(0, 2, 2, closed)
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), expanded_lines,
      'virt_text leaves expanded lines unchanged')
    H.assert_eq(listing:get_paths(3, 4), {
      ws .. '/sub/nested/', ws .. '/sub/inside.txt',
    }, 'path/yank selection remains based on unchanged row identities')

    listing:collapse(2)
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), plain_lines,
      'collapse removes rows without icon text entering the buffer')
    H.assert_eq(#folder_icon_marks(0), 2, 'collapse clears stale nested icons')
    assert_folder_icon(0, 1, 0, closed)
    listing:list()
    H.assert_eq(#folder_icon_marks(0), 2, 'repeated list does not duplicate icons')

    config.setup({ show_folder_icons = false })
    listing:list()
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), plain_lines,
      'disabling icons leaves line data unchanged')
    H.assert_eq(folder_icon_marks(0), {}, 'next disabled refresh clears existing icons')
    config.setup({ show_folder_icons = true })
    listing:list()
    H.assert_eq(#folder_icon_marks(0), 2, 're-enabling icons refreshes exactly once')
    config.setup({ show_folder_icons = 1 })
    listing:list()
    H.assert_eq(folder_icon_marks(0), {}, 'non-boolean truthy values do not enable icons')
    config.setup({ show_folder_icons = true })
    listing:list()
    local before_sync = H.fs_snapshot(ws)
    H.assert_true(listing:sync() == true, 'sync succeeds with virtual icons enabled')
    H.assert_eq(H.fs_snapshot(ws), before_sync, 'icons do not alter sync effects')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), plain_lines,
      'sync keeps the same line data when icons are enabled')
  end)

  H.it('marks an empty expanded directory open and leaves file-only buffers icon-free', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({ show_folder_icons = true })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'empty')
    H.mkfile(ws, 'file.txt', '')
    local listing = buffer.list(ws)
    local closed, opened = '\u{f024b}', '\u{f0770}'
    assert_folder_icon(0, 0, 0, closed)
    listing:expand(1)
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'empty/', 'file.txt' },
      'expanding empty directory does not materialize a fake child row')
    assert_folder_icon(0, 0, 0, opened)

    local files_only = H.mkdir(sb.root, 'files-only')
    H.mkfile(files_only, 'only.txt', '')
    buffer.list(files_only)
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'only.txt' })
    H.assert_eq(folder_icon_marks(0), {}, 'file-only buffer has no folder icons')
  end)


  H.it('default-links visible directories to Directory and hidden entries to Comment after ColorScheme', function()
    local expected = {
      DirectDirectory = 'Directory',
      DirectHiddenDirectory = 'Comment',
      DirectHiddenFile = 'Comment',
    }
    local function assert_defaults()
      for group, target in pairs(expected) do
        H.assert_eq(vim.api.nvim_get_hl(0, { name = group, link = true }), {
          link = target,
        }, group .. ' default link')
      end
    end

    assert_defaults()
    H.assert_eq(#vim.api.nvim_get_autocmds({
      group = 'direct_hidden_highlight_defaults', event = 'ColorScheme',
    }), 1, 'one ColorScheme autocmd owns default reapplication')

    vim.cmd('highlight clear DirectDirectory')
    vim.cmd('highlight clear DirectHiddenDirectory')
    vim.cmd('highlight clear DirectHiddenFile')
    vim.api.nvim_exec_autocmds('ColorScheme', {})
    assert_defaults()
  end)

  H.it('preserves user-defined highlights over defaults', function()
    vim.api.nvim_set_hl(0, 'DirectDirectory', { fg = 0x234567 })
    vim.api.nvim_set_hl(0, 'DirectHiddenDirectory', { fg = 0x123456 })
    vim.api.nvim_set_hl(0, 'DirectHiddenFile', { fg = 0x654321 })

    vim.api.nvim_exec_autocmds('ColorScheme', {})
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectDirectory', link = true }),
      { fg = 0x234567 }, 'default directory link does not overwrite a user highlight')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectHiddenDirectory', link = true }),
      { fg = 0x123456 }, 'default directory link does not overwrite a user highlight')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectHiddenFile', link = true }),
      { fg = 0x654321 }, 'default file link does not overwrite a user highlight')

    vim.api.nvim_set_hl(0, 'DirectDirectory', {})
    vim.api.nvim_set_hl(0, 'DirectHiddenDirectory', {})
    vim.api.nvim_set_hl(0, 'DirectHiddenFile', {})
    vim.cmd('highlight default link DirectDirectory Directory')
    vim.cmd('highlight default link DirectHiddenDirectory Comment')
    vim.cmd('highlight default link DirectHiddenFile Comment')
  end)

  H.it('does not add filename marks for ordinary, filetype-like, or exact special names', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local files = {
      'sample.js', 'sample.py', 'sample.ts', 'sample.sh', 'sample.lua', 'Dockerfile',
      'sample.java', 'sample.cpp', 'sample.c', 'Makefile', 'sample.bat',
      'sample.cs', 'sample.php', 'CMakeLists.txt', 'sample.ps1', 'sample.kt',
      'sample.rb', 'sample.go', 'sample.swift', 'sample.rs',
      'GNUmakefile', 'Rakefile', 'justfile', 'Containerfile', 'Jenkinsfile',
      'Vagrantfile', 'README.md', 'LICENSE', 'CODEOWNERS', 'Gemfile',
      '.hidden.js', 'unknown.extension',
    }
    for _, name in ipairs(files) do H.mkfile(ws, name, '') end
    H.mkdir(ws, 'directory.py')
    local listing = buffer.list(ws)
    local lines = H.buf_lines()
    local by_name = {}
    for row, line in ipairs(lines) do by_name[line] = row - 1 end

    local filename_cases = {
      'sample.js', 'sample.py', 'sample.ts', 'sample.sh', 'sample.lua',
      'sample.java', 'sample.cpp', 'sample.c', 'sample.bat', 'sample.cs',
      'sample.php', 'sample.ps1', 'sample.kt', 'sample.rb', 'sample.go',
      'sample.swift', 'sample.rs', 'unknown.extension',
      'Dockerfile', 'Makefile', 'CMakeLists.txt', 'GNUmakefile', 'Rakefile',
      'justfile', 'Containerfile', 'Jenkinsfile', 'Vagrantfile', 'README.md',
      'LICENSE', 'CODEOWNERS', 'Gemfile',
    }
    for _, name in ipairs(filename_cases) do
      H.assert_nil(row_mark(0, by_name[name]), name .. ' has no filename-derived highlight')
    end
    H.assert_nil(row_mark(0, by_name['.hidden.js']), 'dotfiles remain deferred to existing styling')
    H.assert_nil(row_mark(0, by_name['directory.py/']),
      'directories have no filename-derived extmark')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectSpecialFile', link = true }), {},
      'listing does not define a special-file highlight group')

    H.assert_not_nil(listing, 'listing rendered')
  end)

  H.it('recomputes marks after child insertion and full listing replacement', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'child.py', '')
    H.mkfile(ws, 'root.js', '')
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_get_namespaces()['direct-listing-highlights']
    H.assert_true(ns ~= vim.api.nvim_get_namespaces()['direct-listing-rows'],
      'highlight extmarks are separate from row identity extmarks')

    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '  child.py', 'root.js' })
    H.assert_nil(row_mark(bufnr, 1), 'expanded filetype name has no mark')
    H.assert_nil(row_mark(bufnr, 2), 'root filetype name has no mark')

    vim.uv.fs_unlink(ws .. '/root.js')
    H.mkfile(ws, 'new.unknown', '')
    listing:list()

    H.assert_buf_eq({ 'sub/', '  child.py', 'new.unknown' })
    H.assert_eq(#highlight_marks(bufnr), 0, 'no marks remain after listing replacement')
    local row_ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    H.assert_true(#vim.api.nvim_buf_get_extmarks(bufnr, row_ns, 0, -1, {}) > 0,
      'row identity namespace remains populated and unchanged')
  end)

end)
