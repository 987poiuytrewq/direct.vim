-- tests/entry_spec.lua -- public commands, guards, interception, and mappings.

-- Modules are required INSIDE the `it` bodies: the harness forgets every
-- `direct.*` module and re-sources `plugin/direct.lua` at each file boundary
-- so chunk-time tables would be stale after the reload.
--
-- The opt-out assertions cover only mappings owned by `ftplugin/direct.lua`.

local H = require('tests.support.harness')

-- Build the retired Vimscript prefix at runtime so this file does not embed it;
-- the check below scans mapping values, not repository source files.
local RETIRED = 'direct' .. '#'

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

-- buf_maps(bufnr, mode) -> { [lhs] = rhs } for the buffer-local mappings.
local function buf_maps(bufnr, mode)
  local by_lhs = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    by_lhs[m.lhs] = m.rhs
  end
  return by_lhs
end

local function buf_map_records(bufnr, mode)
  local by_lhs = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    by_lhs[map.lhs] = map
  end
  return by_lhs
end

-- global_map(lhs) -> the normal-mode GLOBAL mapping for lhs, or nil. Uses
-- `nvim_get_keymap` (global set only) so a buffer-local mapping of the same lhs
-- can never masquerade as the global one.
local function global_map(lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap('n')) do
    if m.lhs == lhs then
      return m
    end
  end
  return nil
end

local function enter_buffer_named(path)
  vim.cmd('enew')
  vim.api.nvim_buf_set_name(0, path)
end

local EXPECTED_N = {
  ['<CR>'] = '<Cmd>lua require("direct").open()<CR>',
  ['<C-S>'] = '<Cmd>lua require("direct").open({ split = "horizontal" })<CR>',
  ['<C-V>'] = '<Cmd>lua require("direct").open({ split = "vertical" })<CR>',
  ['<C-T>'] = '<Cmd>lua require("direct").open({ split = "tab" })<CR>',
  ['-'] = '<Cmd>lua require("direct").list(vim.fn.fnamemodify(vim.b.direct_root or vim.api.nvim_buf_get_name(0), ":h"))<CR>',
  ['z-'] = '<Cmd>lua require("direct").open_parent_expanded()<CR>',
  ['u'] = '<Cmd>DirectUndo<CR>',
  ['<C-R>'] = '<Cmd>DirectRedo<CR>',
  ['yy'] = '<Cmd>DirectYank<CR>',
  ['Y'] = '<Cmd>DirectYank<CR>',
  ['p'] = '<Cmd>DirectPaste<CR>',
  ['P'] = '<Cmd>DirectPaste<CR>',
  ['gh'] = '<Cmd>DirectToggleHidden<CR>',
  ['gC'] = '<Cmd>DirectToggleDirectoryCollapse<CR>',
  ['ga'] = '<Cmd>DirectGit git add -- {}<CR>',
  ['\\gu'] = '<Cmd>DirectGit git reset -- {}<CR>',
  ['\\gr'] = '<Cmd>DirectGitRestore<CR>',
  ['gs'] = '<Cmd>DirectToggleGitStatus<CR>',
  ['gd'] = '<Cmd>lua require("direct").git_diff()<CR>',
  [']c'] = '<Cmd>DirectNextChange<CR>',
  ['[c'] = '<Cmd>DirectPreviousChange<CR>',
  [']f'] = '<Cmd>DirectNextFile<CR>',
  ['[f'] = '<Cmd>DirectPreviousFile<CR>',
}

local EXPECTED_V = {
  ['y'] = '<Cmd>lua require("direct").yank(vim.fn.line("v"), vim.fn.line("."))<CR>',
}

local EXPECTED_CMDS = {
  DirectList = { nargs = '1', complete = 'dir', bang = true },
  DirectListBuffer = { nargs = '0', bang = true },
  DirectListCwd = { nargs = '0', bang = true },
  DirectSync = { nargs = '0' },
  DirectFoldAll = { nargs = '0' },
  DirectUnfoldAll = { nargs = '0' },
  DirectToggleHidden = { nargs = '0' },
  DirectToggleDirectoryCollapse = { nargs = '0' },
  DirectToggleGitStatus = { nargs = '0' },
  DirectGitStatus = { nargs = '*', complete = 'custom' },
  DirectGitDiff = { nargs = '*', complete = 'custom' },
  DirectNextChange = { nargs = '0' },
  DirectPreviousChange = { nargs = '0' },
  DirectNextFile = { nargs = '0' },
  DirectPreviousFile = { nargs = '0' },
  DirectToggleGitIgnore = { nargs = '0' },
  DirectUndo = { nargs = '0' },
  DirectRedo = { nargs = '0' },
  DirectHistory = { nargs = '*', complete = 'custom' },
  DirectHistoryReset = { nargs = '0' },
  DirectTrash = { nargs = '*', bang = true, complete = 'custom' },
  DirectYank = { nargs = '0', range = '.' },
  DirectPaste = { nargs = '?', complete = 'dir' },
  DirectPasteAs = { nargs = '1', complete = 'file' },
  DirectRun = { nargs = '+' },
  DirectGit = { nargs = '+' },
  DirectGitRestore = { nargs = '0' },
  DirectGitRestore = { nargs = '0' },
}

H.describe('entry: command surface', function()
  H.it('the commands exist with their exact nargs/range/complete', function()
    local cmds = vim.api.nvim_get_commands({ builtin = false })
    for name, want in pairs(EXPECTED_CMDS) do
      local got = cmds[name]
      H.assert_true(got ~= nil, name .. ' is registered')
      if got then
        H.assert_eq(got.nargs, want.nargs, name .. '.nargs')
        if want.complete == 'custom' then
          H.assert_true(got.complete ~= nil, name .. '.complete is registered')
        else
          H.assert_eq(got.complete, want.complete, name .. '.complete')
        end
        H.assert_eq(got.range, want.range, name .. '.range')
        H.assert_eq(got.bang, want.bang or false, name .. '.bang')
      end
    end
  end)

  H.it(':DirectList {dir} opens a direct buffer with the correct listing', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'a.txt', { 'a' })

    vim.cmd('DirectList ' .. vim.fn.fnameescape(ws))

    H.assert_eq(vim.bo.filetype, 'direct', ':DirectList sets filetype=direct')
    H.assert_eq(vim.bo.buftype, 'acwrite', 'and buftype=acwrite')
    H.assert_buf_eq({ 'sub/', 'a.txt' })
  end)

  H.it(':DirectList! deliberately discards unsaved listing edits', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', '')
    require('direct').list(ws)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved edit' })
    vim.bo[buf].modified = true
    H.mkfile(ws, 'new.txt', '')

    vim.cmd('DirectList! ' .. vim.fn.fnameescape(ws))

    H.assert_eq(vim.api.nvim_get_current_buf(), buf, 'the existing directory buffer is reused')
    H.assert_buf_eq({ 'new.txt', 'old.txt' }, buf, 'the listing reflects the directory')
    H.assert_false(vim.bo[buf].modified, 'the explicit discard leaves a clean listing')
  end)

  H.it(':write in a direct buffer runs the sync and clears modified', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    require('direct').list(ws)
    local buf = vim.api.nvim_get_current_buf()

    -- Add an entry the filesystem does not have yet, then write.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    lines[#lines + 1] = 'new.txt'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    H.assert_true(vim.bo[buf].modified, 'the buffer is dirty before the write')

    vim.cmd('write')
    H.wait_for_direct()

    H.assert_true(vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) ~= nil,
      'the write routed to the sync and created new.txt')
    H.assert_false(vim.bo[buf].modified, 'the write cleared modified')
  end)

  H.it('open({ split = ... }) preserves the listing while opening files and directories', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local directory = H.mkdir(ws, 'directory')
    local file = H.mkfile(ws, 'file.txt', { 'file' })
    H.mkfile(directory, 'inside.txt', { 'inside' })
    local api = require('direct')
    api.list(ws)
    local source_buf = vim.api.nvim_get_current_buf()
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(source_buf, -1, -1, false, { 'unsaved listing edit' })
    local preserved_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
    H.assert_true(vim.bo[source_buf].modified, 'the source listing is dirty')

    local function row_for(text)
      for row, line in ipairs(preserved_lines) do
        if line == text then return row end
      end
    end

    vim.api.nvim_win_set_cursor(source_win, { row_for('directory/'), 0 })
    H.assert_true(api.open({ split = 'horizontal' }), 'horizontal split opens the directory')
    H.assert_true(vim.api.nvim_get_current_win() ~= source_win, 'a new horizontal window is current')
    H.assert_eq(vim.bo.filetype, 'direct', 'the split shows a direct listing')
    H.assert_true(require('direct.fs').same_path(vim.api.nvim_buf_get_name(0), directory),
      'the child directory is listed in the split')
    H.assert_true(vim.api.nvim_buf_is_valid(source_buf), 'the original listing buffer survives')
    H.assert_eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), preserved_lines,
      'the original listing text is unchanged')
    H.assert_true(vim.bo[source_buf].modified, 'the original listing remains modified')
    vim.cmd('close')
    vim.api.nvim_set_current_win(source_win)

    vim.api.nvim_win_set_cursor(source_win, { row_for('file.txt'), 0 })
    H.assert_true(api.open({ split = 'vertical' }), 'vertical split opens a file')
    H.assert_true(require('direct.fs').same_path(vim.api.nvim_buf_get_name(0), file),
      'the requested file opens in the vertical split')
    H.assert_true(vim.api.nvim_buf_is_valid(source_buf), 'opening the file keeps the source buffer')
    H.assert_eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), preserved_lines,
      'the dirty source listing is untouched by the file open')
    vim.cmd('close')
    vim.api.nvim_set_current_win(source_win)

    local tab_count = #vim.api.nvim_list_tabpages()
    vim.api.nvim_win_set_cursor(source_win, { row_for('directory/'), 0 })
    H.assert_true(api.open({ split = 'tab' }), 'tab open opens the directory')
    H.assert_eq(#vim.api.nvim_list_tabpages(), tab_count + 1, 'a new tab is created')
    H.assert_eq(vim.bo.filetype, 'direct', 'the new tab lists the selected directory')
    H.assert_true(vim.api.nvim_buf_is_valid(source_buf), 'the original buffer survives the tab open')
    vim.cmd('tabclose')
    H.assert_eq(vim.api.nvim_get_current_buf(), source_buf, 'closing the new tab returns to the listing')
    H.assert_eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), preserved_lines,
      'the original listing still contains its unsaved edit')
    H.assert_true(vim.bo[source_buf].modified, 'the original modified flag is preserved')

    local before_tabs = #vim.api.nvim_list_tabpages()
    local rejected, split_err = api.open({ split = 'diagonal' })
    H.assert_nil(rejected, 'unsupported split names are refused')
    H.assert_true(tostring(split_err):find('horizontal', 1, true) ~= nil,
      'the returned error lists supported layouts')
    H.assert_eq(#vim.api.nvim_list_tabpages(), before_tabs, 'invalid options open no windows')
  end)

  H.it('the BufEnter intercept is registered and converts a directory buffer', function()
    clean_buffers()
    local sb = H.sandbox()
    local dir = H.mkdir(sb.root, 'dir')
    H.mkfile(dir, 'b.txt', { 'b' })

    local registered = false
    for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'direct', event = 'BufEnter' })) do
      if au.pattern == '*' then
        registered = true
      end
    end
    H.assert_true(registered, 'the BufEnter intercept is registered in the direct augroup')

    enter_buffer_named(dir)
    H.assert_true(vim.bo.filetype ~= 'direct', 'sanity: the directory buffer is not direct yet')
    vim.api.nvim_exec_autocmds('BufEnter', {})
    H.assert_eq(vim.bo.filetype, 'direct', 'the intercept converted the buffer')
    H.assert_buf_eq({ 'b.txt' })
  end)

  H.it('the intercept leaves an unnamed buffer and a regular file buffer alone', function()
    clean_buffers()
    local sb = H.sandbox()
    local file = H.mkfile(sb.root, 'plain.txt', { 'p' })

    -- Unnamed: the intercept must not list anything.
    vim.cmd('enew')
    vim.api.nvim_exec_autocmds('BufEnter', {})
    H.assert_true(vim.bo.filetype ~= 'direct', 'an unnamed buffer is not converted')

    -- A regular file: the predicate's is_dir clause must stop the intercept
    -- before it tries to list a non-directory (which would notify).
    clean_buffers()
    enter_buffer_named(file)
    H.capture_messages()
    vim.api.nvim_exec_autocmds('BufEnter', {})
    H.assert_true(vim.bo.filetype ~= 'direct', 'a file buffer is not converted')
    H.assert_false(H.messages():find('cannot list', 1, true) ~= nil,
      'the intercept attempted no listing for a regular file')
  end)
end)

H.describe('entry: direct-buffer guard', function()
  H.it('the public API exposes every facade function', function()
    local api = require('direct')
    local expected = { 'setup', 'list', 'list_buffer', 'list_cwd', 'open', 'open_parent_expanded',
      'expand', 'collapse', 'toggle', 'expand_recursive', 'collapse_recursive',
      'toggle_recursive', 'next_directory', 'previous_directory',
      'toggle_hidden',
      'toggle_collapse_single_entry_directories',
      'toggle_gitignore',
      'toggle_git_status',
      'show_git_status',
      'git_diff',
      'next_change', 'previous_change', 'next_file', 'previous_file',
      'sync', 'fold_all', 'unfold_all', 'undo', 'redo', 'reset_history', 'yank', 'paste',
      'paste_as', 'run', 'git', 'restore_git', 'trash_list', 'trash_restore', 'trash_empty' }
    local actual = {}
    for name, value in pairs(api) do
      actual[#actual + 1] = name
      H.assert_eq(type(value), 'function', 'direct.' .. name .. ' is a function')
    end
    table.sort(expected)
    table.sort(actual)
    H.assert_eq(actual, expected, 'the documented facade exports exactly this API')
    for _, name in ipairs(expected) do
      H.assert_eq(type(api[name]), 'function', 'direct.' .. name .. ' is a function')
    end
  end)

  H.it('the public folder API expands, collapses, toggles, and navigates', function()
    clean_buffers()
    require('direct.config').setup({ collapse_single_entry_directories = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub/nested')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    H.mkdir(ws, 'other')
    local api = require('direct')
    api.list(ws)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    H.assert_true(api.expand(), 'expand opens one level')
    H.assert_buf_eq({ 'other/', 'sub/', '  nested/' }, 0,
      'expand materializes immediate children')
    H.assert_true(api.collapse(), 'collapse removes the selected subtree')
    H.assert_buf_eq({ 'other/', 'sub/' }, 0)
    H.assert_true(api.toggle(), 'toggle expands a collapsed directory')
    H.assert_true(api.expand_recursive(), 'recursive expand opens descendants')
    H.assert_buf_eq({ 'other/', 'sub/', '  nested/', '    inside.txt' }, 0)
    H.assert_true(api.collapse_recursive(), 'recursive collapse removes descendants')
    H.assert_buf_eq({ 'other/', 'sub/' }, 0)
    H.assert_true(api.toggle_recursive(), 'recursive toggle expands the full subtree')
    H.assert_buf_eq({ 'other/', 'sub/', '  nested/', '    inside.txt' }, 0)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.assert_true(api.next_directory(), 'next_directory finds the next visible directory')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2)
    H.assert_true(api.previous_directory(), 'previous_directory returns to the prior directory')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1)
    require('direct.config').setup({})
  end)

  H.it('gC and :DirectToggleDirectoryCollapse toggle collapsed directory chains', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({})
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local nested = H.mkdir(ws, 'foo/bar')
    H.mkfile(nested, 'baz.txt', { 'baz' })
    require('direct').list(ws)
    H.assert_buf_eq({ 'foo/bar/' }, 0, 'the default view collapses directory chains')

    vim.cmd('DirectToggleDirectoryCollapse')
    H.assert_buf_eq({ 'foo/' }, 0, 'the command switches collapsing off for this listing')
    vim.api.nvim_feedkeys('gC', 'mx', false)
    H.assert_buf_eq({ 'foo/bar/' }, 0, 'gC switches collapsing back on')
    config.setup({})
  end)

  H.it('guarded commands notify and change nothing outside a direct buffer', function()
    local cases = {
      { name = 'DirectUndo', call = function(api) return api.undo() end },
      { name = 'DirectRedo', call = function(api) return api.redo() end },
      { name = 'DirectGitRestore', call = function(api) return api.restore_git() end },
      { name = 'DirectFoldAll', call = function(api) return api.fold_all() end },
      { name = 'DirectUnfoldAll', call = function(api) return api.unfold_all() end },
      { name = 'DirectYank', call = function(api) return api.yank(1, 1) end },
      { name = 'DirectToggleHidden', call = function(api) return api.toggle_hidden() end },
      { name = 'DirectToggleDirectoryCollapse',
        call = function(api) return api.toggle_collapse_single_entry_directories() end },
      { name = 'DirectToggleGitStatus',
        call = function(api) return api.toggle_git_status() end },
      { name = 'DirectToggleGitIgnore',
        call = function(api) return api.toggle_gitignore() end },
      { name = 'DirectGitStatus',
        call = function(api) return api.show_git_status() end },
      { name = 'DirectNextChange',
        call = function(api) return api.next_change() end },
      { name = 'DirectPreviousChange',
        call = function(api) return api.previous_change() end },
      { name = 'DirectNextFile',
        call = function(api) return api.next_file() end },
      { name = 'DirectPreviousFile',
        call = function(api) return api.previous_file() end },
      { name = 'DirectPaste', call = function(api) return api.paste() end },
      { name = 'DirectPasteAs', call = function(api) return api.paste_as('x.txt') end },
      { name = 'DirectRun', call = function(api) return api.run('echo {}') end },
      { name = 'DirectGit', call = function(api) return api.git('git status -- {}') end },
    }
    for _, case in ipairs(cases) do
      clean_buffers()
      local sb = H.sandbox()
      local file = H.mkfile(sb.root, 'plain.txt', { 'keep' })
      enter_buffer_named(file)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep' })
      H.assert_eq(vim.bo.filetype, '', 'sanity: the buffer is not a direct buffer')

      H.capture_messages()
      local result = case.call(require('direct'))

      H.assert_nil(result, case.name .. ' returns nil when guarded')
      H.assert_notified(case.name .. ' can only be used in a direct buffer')
      H.assert_buf_eq({ 'keep' })
    end
  end)

  H.it(':DirectUnfoldAll and :DirectFoldAll expand and collapse the full tree', function()
    clean_buffers()
    require('direct.config').setup({ collapse_single_entry_directories = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local deepest = H.mkdir(ws, 'a/b')
    H.mkfile(deepest, 'leaf.txt', { 'leaf' })
    require('direct').list(ws)

    vim.cmd('DirectUnfoldAll')
    H.assert_buf_eq({ 'a/', '  b/', '    leaf.txt' })

    vim.cmd('DirectFoldAll')
    H.assert_buf_eq({ 'a/' })
    require('direct.config').setup({})
  end)

  H.it(':DirectSync is rejected in a named normal buffer without changing it', function()
    clean_buffers()
    local sb = H.sandbox()
    local file = H.mkfile(sb.root, 'plain.txt', { 'on disk' })
    enter_buffer_named(file)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved contents' })
    vim.bo[buf].modified = true
    H.assert_eq(vim.bo[buf].filetype, '', 'sanity: the buffer is not direct')

    H.capture_messages()
    -- The guard uses an ERROR-level notification, which Neovim also surfaces
    -- as an Ex-command error; contain that expected rejection here.
    pcall(vim.cmd, 'DirectSync')

    H.assert_notified('DirectSync can only be used in a direct buffer')
    H.assert_true(vim.api.nvim_buf_is_valid(buf), 'the normal buffer remains valid')
    H.assert_eq(vim.api.nvim_get_current_buf(), buf, 'the current buffer is unchanged')
    H.assert_eq(vim.api.nvim_buf_get_name(buf), file, 'the buffer name is unchanged')
    H.assert_buf_eq({ 'unsaved contents' })
    H.assert_true(vim.bo[buf].modified, 'the modified state is unchanged')
    H.assert_eq(vim.fn.readfile(file), { 'on disk' }, 'the file on disk is unchanged')
  end)

  H.it(':DirectSync is rejected in an unnamed normal buffer at the cwd root', function()
    clean_buffers()
    local sb = H.sandbox()
    H.with_cwd(sb.root, function()
      vim.cmd('enew')
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'scratch contents' })
      vim.bo[buf].modified = true
      H.assert_eq(vim.api.nvim_buf_get_name(buf), '', 'sanity: the buffer is unnamed')
      H.assert_eq(vim.bo[buf].filetype, '', 'sanity: the buffer is not direct')

      H.capture_messages()
      -- The guard uses an ERROR-level notification, which Neovim also surfaces
      -- as an Ex-command error; contain that expected rejection here.
      pcall(vim.cmd, 'DirectSync')

      H.assert_notified('DirectSync can only be used in a direct buffer')
      H.assert_true(vim.api.nvim_buf_is_valid(buf), 'the unnamed buffer remains valid')
      H.assert_eq(vim.api.nvim_get_current_buf(), buf, 'the current buffer is unchanged')
      H.assert_eq(vim.api.nvim_buf_get_name(buf), '', 'the buffer remains unnamed')
      H.assert_buf_eq({ 'scratch contents' })
      H.assert_true(vim.bo[buf].modified, 'the modified state is unchanged')
    end)
  end)

  H.it('open() is rejected in a modified normal buffer without changing it', function()
    clean_buffers()
    local sb = H.sandbox()
    local file = H.mkfile(sb.root, 'plain.txt', { 'on disk' })
    enter_buffer_named(file)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved contents' })
    vim.bo[buf].modified = true
    H.assert_eq(vim.bo[buf].filetype, '', 'sanity: the buffer is not direct')

    H.capture_messages()
    local ok, result = pcall(function() return require('direct').open() end)

    H.assert_true(ok, 'open() returns without raising')
    H.assert_nil(result, 'open() returns nil when guarded')
    H.assert_notified('open can only be used in a direct buffer')
    H.assert_true(vim.api.nvim_buf_is_valid(buf), 'the normal buffer remains valid')
    H.assert_eq(vim.api.nvim_get_current_buf(), buf, 'the current buffer is unchanged')
    H.assert_eq(vim.api.nvim_buf_get_name(buf), file, 'the buffer name is unchanged')
    H.assert_buf_eq({ 'unsaved contents' })
    H.assert_true(vim.bo[buf].modified, 'the modified state is unchanged')
    H.assert_eq(vim.fn.readfile(file), { 'on disk' }, 'the file on disk is unchanged')
  end)

  H.it(':DirectPaste {dir} is exempt: it pastes outside a direct buffer and leaves it untouched', function()
    clean_buffers()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'src.txt', { 's' })
    H.assert_true(require('direct.register').yank({ vim.fs.joinpath(sb.root, 'src.txt') }) == true,
      'the register holds src.txt')
    local dst = H.mkdir(sb.root, 'dst')
    local file = H.mkfile(sb.root, 'plain.txt', { 'keep' })
    enter_buffer_named(file)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep' })
    H.assert_eq(vim.bo.filetype, '', 'sanity: the buffer is not a direct buffer')

    H.capture_messages()
    local result = require('direct').paste(dst)

    H.assert_true(result ~= nil, 'the {dir} form pastes without the direct-buffer guard')
    H.assert_true(vim.uv.fs_stat(vim.fs.joinpath(dst, 'src.txt')) ~= nil,
      'src.txt was pasted into {dir}')
    H.assert_buf_eq({ 'keep' })
    H.assert_false(H.messages():find('can only be used in a direct buffer', 1, true) ~= nil,
      'the {dir} form never raised the guard notice')
  end)

  H.it(':DirectPaste targets the selected directory and refreshes its open folds', function()
    clean_buffers()
    require('direct.config').setup({ collapse_single_entry_directories = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local target = H.mkdir(parent, 'target')
    local nested = H.mkdir(target, 'nested')
    H.mkfile(target, 'old.txt', { 'old' })
    H.mkfile(nested, 'leaf.txt', { 'leaf' })
    local source = H.mkfile(sb.root, 'source.txt', { 'source' })
    H.assert_true(require('direct.register').yank({ source }) == true,
      'the register holds source.txt')

    local listing = require('direct').list(ws)
    listing:expand(1) -- parent/
    listing:expand(2) -- target/
    listing:expand(3) -- nested/
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- target/

    vim.cmd('DirectPaste')

    H.assert_true(H.exists(target, 'source.txt'),
      'paste lands in the selected nested directory')
    H.assert_false(H.exists(ws, 'source.txt'),
      'paste does not use the listing root')
    H.assert_buf_eq({
      'parent/',
      '  target/',
      '    nested/',
      '      leaf.txt',
      '    old.txt',
      '    source.txt',
    }, 0, 'the refreshed listing retains both open directory folds')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 6, 4 },
      'the cursor lands on the pasted entry name')
    require('direct.config').setup({})
  end)

  H.it(':DirectPaste opens the selected collapsed directory and selects the pasted entry', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local target = H.mkdir(ws, 'target')
    local source = H.mkfile(sb.root, 'source.txt', { 'source' })
    H.assert_true(require('direct.register').yank({ source }) == true,
      'the register holds source.txt')

    require('direct').list(ws)
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- target/, still collapsed
    vim.cmd('DirectPaste')

    H.assert_true(H.exists(target, 'source.txt'), 'paste lands in target/')
    H.assert_buf_eq({ 'target/', '  source.txt' },
      0, 'the destination unfolds to show the pasted entry')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 2, 2 },
      'the cursor lands on the first character of the pasted name')
  end)

  H.it(':DirectPaste unfolds a pasted directory and leaves the cursor on it', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local source = H.mkdir(sb.root, 'tree')
    H.mkfile(source, 'leaf.txt', { 'leaf' })
    H.assert_true(require('direct.register').yank({ source }) == true,
      'the register holds tree/')

    require('direct').list(ws)
    vim.cmd('DirectPaste')

    H.assert_buf_eq({ 'tree/', '  leaf.txt' },
      0, 'the pasted directory is unfolded')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 1, 0 },
      'the cursor stays on the first character of the pasted directory')
  end)

  H.it(':DirectPasteAs on a file targets that file\'s parent, including under an open fold', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local target = H.mkfile(parent, 'target.txt', { 'target' })
    local source = H.mkfile(sb.root, 'source.txt', { 'source' })
    H.assert_true(require('direct.register').yank({ source }) == true,
      'the register holds source.txt')

    local listing = require('direct').list(ws)
    listing:expand(1)
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- parent/target.txt

    vim.cmd('DirectPasteAs copied.txt')

    H.assert_true(H.exists(parent, 'copied.txt'),
      'paste-as lands beside the selected file')
    H.assert_false(H.exists(ws, 'copied.txt'),
      'paste-as does not use the listing root')
    H.assert_eq(vim.fn.readfile(parent .. '/copied.txt'), { 'source' },
      'the copied content is intact')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
      'parent/', '  copied.txt', '  target.txt',
    }, 'the open parent fold is refreshed')
    H.assert_eq(vim.api.nvim_win_get_cursor(0), { 2, 2 },
      'the cursor lands on the first character of the pasted-as entry')
    H.assert_true(H.exists(target), 'the original selected file remains untouched')
  end)
end)

H.describe('entry: default mappings', function()
  H.it('the global - is installed by default and resolves to DirectListBuffer', function()
    clean_buffers()
    require('direct.config').setup({ map_default_keys = true })
    local m = global_map('-')
    H.assert_true(m ~= nil, 'the global - mapping exists')
    if m then
      H.assert_eq(m.rhs, ':<C-U>DirectListBuffer<CR>', 'the global - lists the buffer directory')
    end
  end)

  H.it('all default buffer-local mappings resolve to their commands and none call the retired Vimscript', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    require('direct.config').setup({ map_default_keys = true })
    require('direct').list(ws)
    local buf = vim.api.nvim_get_current_buf()
    H.assert_eq(vim.bo[buf].filetype, 'direct')

    local normal = buf_maps(buf, 'n')
    local visual = buf_maps(buf, 'v')
    local normal_records = buf_map_records(buf, 'n')
    for lhs, rhs in pairs(EXPECTED_N) do
      H.assert_eq(normal[lhs], rhs, 'normal-mode ' .. lhs)
    end
    for lhs, rhs in pairs(EXPECTED_V) do
      H.assert_eq(visual[lhs], rhs, 'visual-mode ' .. lhs)
    end
    local fold_descriptions = {
      zo = 'direct: Expand one direct directory level',
      za = 'direct: Toggle direct directory expansion',
      zc = 'direct: Collapse direct directory rows',
      zO = 'direct: Recursively expand direct directories',
      zA = 'direct: Recursively toggle direct directories',
      zC = 'direct: Recursively collapse direct directories',
      zR = 'direct: Expand all direct directories',
      zM = 'direct: Collapse all direct directories',
      ['[d'] = 'direct: Jump to the previous visible direct directory',
      [']d'] = 'direct: Jump to the next visible direct directory',
      ['<LeftMouse>'] = 'direct: Toggle a direct directory from its folder icon',
      ['<2-LeftMouse>'] = 'direct: Open the direct entry under the double-click',
    }
    for lhs, desc in pairs(fold_descriptions) do
      local record = normal_records[lhs]
      H.assert_true(record and record.callback ~= nil,
        'direct mapping ' .. lhs .. ' uses a Lua callback')
      H.assert_eq(record and record.desc, desc,
        'fold mapping description ' .. lhs)
    end

    for _, maps in ipairs({ normal, visual }) do
      for lhs, rhs in pairs(maps) do
        H.assert_false(rhs:find(RETIRED, 1, true) ~= nil,
          'the rhs of ' .. lhs .. ' must not call the retired Vimscript function')
      end
    end
  end)

  H.it('z- opens the parent listing and expands the directory just left', function()
    clean_buffers()
    local sb = H.sandbox()
    local parent = H.mkdir(sb.root, 'parent')
    local child = H.mkdir(parent, 'child')
    H.mkfile(child, 'inside.txt', { 'inside' })
    H.mkfile(parent, 'sibling.txt', { 'sibling' })

    require('direct.config').setup({ map_default_keys = true })
    require('direct').list(child)
    local buf = vim.api.nvim_get_current_buf()
    local maps = buf_maps(buf, 'n')
    H.assert_eq(maps['z-'], EXPECTED_N['z-'], 'z- is installed buffer-locally')

    H.assert_true(require('direct').open_parent_expanded(), 'z- navigation succeeds')

    H.assert_true(require('direct.fs').same_path(vim.api.nvim_buf_get_name(0), parent),
      'the parent directory listing is current')
    H.assert_buf_eq({ 'child/', '  inside.txt', 'sibling.txt' })
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1,
      'the cursor remains on the directory that was just left')
  end)

  H.it('map_default_keys=false installs no global, standard, or fold mappings', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    require('direct.config').setup({ map_default_keys = false })
    H.assert_true(global_map('-') == nil, 'the opt-out removes the global - mapping')

    require('direct').list(ws)
    local buf = vim.api.nvim_get_current_buf()
    H.assert_eq(vim.bo[buf].filetype, 'direct', 'listing still works without mappings')

    -- Scoped to OUR ftplugin's `<Cmd>`-based mappings: the retired Vimscript
    -- ftplugin is gone, so a key absent here is simply not mapped.
    local normal = buf_maps(buf, 'n')
    local normal_records = buf_map_records(buf, 'n')
    local visual = buf_maps(buf, 'v')
    for lhs in pairs(EXPECTED_N) do
      local rhs = normal[lhs]
      if rhs ~= nil then
        H.assert_false(rhs:find('<Cmd>', 1, true) ~= nil,
          'the opt-out must not install the Lua mapping for normal ' .. lhs)
      end
    end
    H.assert_nil(normal.gh, 'the opt-out does not install the hidden toggle mapping')
    for _, lhs in ipairs({ 'zo', 'za', 'zc', 'zO', 'zA', 'zC', 'zR', 'zM', '[d', ']d',
      '<LeftMouse>', '<2-LeftMouse>' }) do
      H.assert_nil(normal_records[lhs], 'the opt-out leaves fold key ' .. lhs .. ' unmapped')
    end
    for lhs in pairs(EXPECTED_V) do
      local rhs = visual[lhs]
      if rhs ~= nil then
        H.assert_false(rhs:find('require("direct")', 1, true) ~= nil,
          'the opt-out must not install the Lua mapping for visual ' .. lhs)
      end
    end
  end)
end)
