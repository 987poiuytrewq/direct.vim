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
