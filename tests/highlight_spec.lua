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

    listing:unfold(1)
    H.assert_buf_eq({ 'sub/', '  child.py', 'root.js' })
    H.assert_nil(row_mark(bufnr, 1), 'unfolded filetype name has no mark')
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
