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

local function assert_row_highlight(bufnr, row, group, start_col, end_col)
  local mark = row_mark(bufnr, row)
  H.assert_not_nil(mark, 'row ' .. row .. ' has a filename highlight')
  H.assert_eq(mark[4].hl_group, group, 'highlight group')
  H.assert_eq(mark[3], start_col, 'highlight starts at filename')
  H.assert_eq(mark[4].end_col, end_col, 'highlight ends at filename')
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

local expected_languages = {
  { name = 'JavaScript', filetype = 'javascript', probe = 'sample.js', group = 'DirectLangJavaScript' },
  { name = 'Python', filetype = 'python', probe = 'sample.py', group = 'DirectLangPython' },
  { name = 'TypeScript', filetype = 'typescript', probe = 'sample.ts', group = 'DirectLangTypeScript' },
  { name = 'Shell', filetype = 'sh', probe = 'sample.sh', group = 'DirectLangShell' },
  { name = 'Dockerfile', filetype = 'dockerfile', probe = 'Dockerfile', group = 'DirectLangDockerfile' },
  { name = 'Java', filetype = 'java', probe = 'sample.java', group = 'DirectLangJava' },
  { name = 'C++', filetype = 'cpp', probe = 'sample.cpp', group = 'DirectLangCpp' },
  { name = 'C', filetype = 'c', probe = 'sample.c', group = 'DirectLangC' },
  { name = 'Makefile', filetype = 'make', probe = 'Makefile', group = 'DirectLangMakefile' },
  { name = 'Batchfile', filetype = 'dosbatch', probe = 'sample.bat', group = 'DirectLangBatchfile' },
  { name = 'C#', filetype = 'cs', probe = 'sample.cs', group = 'DirectLangCSharp' },
  { name = 'PHP', filetype = 'php', probe = 'sample.php', group = 'DirectLangPHP' },
  { name = 'CMake', filetype = 'cmake', probe = 'CMakeLists.txt', group = 'DirectLangCMake' },
  { name = 'PowerShell', filetype = 'ps1', probe = 'sample.ps1', group = 'DirectLangPowerShell' },
  { name = 'Kotlin', filetype = 'kotlin', probe = 'sample.kt', group = 'DirectLangKotlin' },
  { name = 'Ruby', filetype = 'ruby', probe = 'sample.rb', group = 'DirectLangRuby' },
  { name = 'Go', filetype = 'go', probe = 'sample.go', group = 'DirectLangGo' },
  { name = 'Swift', filetype = 'swift', probe = 'sample.swift', group = 'DirectLangSwift' },
  { name = 'Rust', filetype = 'rust', probe = 'sample.rs', group = 'DirectLangRust' },
}

H.describe('listing filename highlights', function()
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

  H.it('keeps exactly the mapped programming languages and validates runtime detection', function()
    local actual = highlight._languages_for_test()
    H.assert_eq(actual, expected_languages,
      'the static snapshot has the supported mapped members, with PLpgSQL omitted')
    for _, language in ipairs(actual) do
      H.assert_eq(vim.filetype.match({ filename = language.probe }), language.filetype,
        language.name .. ' runtime filename detection')
    end
    H.assert_nil(vim.filetype.match({ filename = 'sample.plpgsql' }),
      'PLpgSQL has no dedicated runtime filetype')
  end)

  H.it('highlights programming filenames and exact special names on the filename only', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local files = {
      'sample.js', 'sample.py', 'sample.ts', 'sample.sh', 'Dockerfile',
      'sample.java', 'sample.cpp', 'sample.c', 'Makefile', 'sample.bat',
      'sample.cs', 'sample.php', 'CMakeLists.txt', 'sample.ps1', 'sample.kt',
      'sample.rb', 'sample.go', 'sample.swift', 'sample.rs', 'sample.plpgsql',
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

    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectSpecialFile', link = true }),
      { default = true, link = 'Special' }, 'special group links to Special by default')
    for _, language in ipairs(expected_languages) do
      H.assert_eq(vim.api.nvim_get_hl(0, { name = language.group, link = true }), {
        default = true,
        link = 'Type',
      }, language.name .. ' standard default link')
    end
    local shell_target = vim.api.nvim_get_hl(0, { name = 'Type' })
    H.assert_true(next(shell_target) ~= nil, 'standard Type group resolves to usable highlight attributes')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectLangShell', link = false }), shell_target,
      'shell filename group resolves to the standard Type attributes')

    assert_row_highlight(0, by_name['sample.js'], 'DirectLangJavaScript', 0, #'sample.js')
    assert_row_highlight(0, by_name['sample.py'], 'DirectLangPython', 0, #'sample.py')
    assert_row_highlight(0, by_name['sample.ts'], 'DirectLangTypeScript', 0, #'sample.ts')
    assert_row_highlight(0, by_name['sample.sh'], 'DirectLangShell', 0, #'sample.sh')
    assert_row_highlight(0, by_name['sample.cpp'], 'DirectLangCpp', 0, #'sample.cpp')
    assert_row_highlight(0, by_name['sample.bat'], 'DirectLangBatchfile', 0, #'sample.bat')
    assert_row_highlight(0, by_name['sample.cs'], 'DirectLangCSharp', 0, #'sample.cs')
    assert_row_highlight(0, by_name['sample.ps1'], 'DirectLangPowerShell', 0, #'sample.ps1')
    assert_row_highlight(0, by_name['sample.kt'], 'DirectLangKotlin', 0, #'sample.kt')
    assert_row_highlight(0, by_name['sample.rb'], 'DirectLangRuby', 0, #'sample.rb')
    assert_row_highlight(0, by_name['sample.go'], 'DirectLangGo', 0, #'sample.go')
    assert_row_highlight(0, by_name['sample.swift'], 'DirectLangSwift', 0, #'sample.swift')
    assert_row_highlight(0, by_name['sample.rs'], 'DirectLangRust', 0, #'sample.rs')

    local special = {
      'Dockerfile', 'Makefile', 'CMakeLists.txt', 'GNUmakefile', 'Rakefile',
      'justfile', 'Containerfile', 'Jenkinsfile', 'Vagrantfile', 'README.md',
      'LICENSE', 'CODEOWNERS', 'Gemfile',
    }
    for _, name in ipairs(special) do
      assert_row_highlight(0, by_name[name], 'DirectSpecialFile', 0, #name)
    end
    H.assert_nil(row_mark(0, by_name['sample.plpgsql']), 'unsupported PLpgSQL has no mark')
    H.assert_nil(row_mark(0, by_name['.hidden.js']), 'dotfiles remain deferred to existing styling')
    H.assert_nil(row_mark(0, by_name['unknown.extension']), 'unknown filetypes have no mark')
    H.assert_nil(row_mark(0, by_name['directory.py/']), 'directories are not highlighted')

    -- Special names win over their language filetype and generate one mark only.
    for _, name in ipairs({ 'Dockerfile', 'Makefile', 'CMakeLists.txt' }) do
      local marks = 0
      for _, mark in ipairs(highlight_marks(0)) do
        if mark[2] == by_name[name] then marks = marks + 1 end
      end
      H.assert_eq(marks, 1, name .. ' has exactly one special-file mark')
    end
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
    assert_row_highlight(bufnr, 1, 'DirectLangPython', 2, 10)
    assert_row_highlight(bufnr, 2, 'DirectLangJavaScript', 0, 7)

    vim.uv.fs_unlink(ws .. '/root.js')
    H.mkfile(ws, 'new.unknown', '')
    listing:list()

    H.assert_buf_eq({ 'sub/', '  child.py', 'new.unknown' })
    H.assert_eq(#highlight_marks(bufnr), 1, 'stale marks from replaced rows are removed')
    assert_row_highlight(bufnr, 1, 'DirectLangPython', 2, 10)
    local row_ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    H.assert_true(#vim.api.nvim_buf_get_extmarks(bufnr, row_ns, 0, -1, {}) > 0,
      'row identity namespace remains populated and unchanged')
  end)

  H.it('preserves user-defined defaults and applies one mark to an exact special match', function()
    clean_buffers()
    local original = vim.api.nvim_get_hl(0, { name = 'DirectLangJavaScript', link = true })
    local original_shell = vim.api.nvim_get_hl(0, { name = 'DirectLangShell', link = true })
    vim.api.nvim_set_hl(0, 'DirectLangJavaScript', { fg = 0x123456 })
    vim.api.nvim_set_hl(0, 'DirectLangShell', { fg = 0x654321 })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'app.js', '')
    H.mkfile(ws, 'install.sh', '')
    H.mkfile(ws, 'readme.md', '')
    buffer.list(ws)

    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectLangJavaScript', link = true }),
      { fg = 0x123456 }, 'default link does not overwrite an existing user highlight')
    H.assert_eq(vim.api.nvim_get_hl(0, { name = 'DirectLangShell', link = true }),
      { fg = 0x654321 }, 'default link does not overwrite a user shell highlight')
    local lines = H.buf_lines()
    local row = {}
    for index, line in ipairs(lines) do row[line] = index - 1 end
    assert_row_highlight(0, row['app.js'], 'DirectLangJavaScript', 0, #'app.js')
    assert_row_highlight(0, row['install.sh'], 'DirectLangShell', 0, #'install.sh')
    H.assert_nil(row_mark(0, row['readme.md']), 'README matching is exact and case-sensitive')

    if next(original) then
      vim.api.nvim_set_hl(0, 'DirectLangJavaScript', original)
    else
      vim.api.nvim_set_hl(0, 'DirectLangJavaScript', {})
    end
    if next(original_shell) then
      vim.api.nvim_set_hl(0, 'DirectLangShell', original_shell)
    else
      vim.api.nvim_set_hl(0, 'DirectLangShell', {})
    end
  end)
end)
