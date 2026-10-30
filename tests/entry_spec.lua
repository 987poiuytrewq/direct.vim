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
  ['-'] = '<Cmd>lua require("direct").open("../")<CR>',
  ['u'] = '<Cmd>undo<CR>',
  ['<C-R>'] = '<Cmd>redo<CR>',
  ['yy'] = '<Cmd>DirectYank<CR>',
  ['Y'] = '<Cmd>DirectYank<CR>',
  ['p'] = '<Cmd>DirectPaste<CR>',
  ['P'] = '<Cmd>DirectPaste<CR>',
}

local EXPECTED_V = {
  ['y'] = '<Cmd>lua require("direct").yank(vim.fn.line("v"), vim.fn.line("."))<CR>',
}

local EXPECTED_CMDS = {
  DirectList = { nargs = '1', complete = 'dir' },
  DirectListBuffer = { nargs = '0' },
  DirectListCwd = { nargs = '0' },
  DirectSync = { nargs = '0' },
  DirectUndo = { nargs = '0' },
  DirectRedo = { nargs = '0' },
  DirectYank = { nargs = '0', range = '.' },
  DirectPaste = { nargs = '?', complete = 'dir' },
  DirectPasteAs = { nargs = '1', complete = 'file' },
}

H.describe('entry: command surface', function()
  H.it('the nine commands exist with their exact nargs/range/complete', function()
    local cmds = vim.api.nvim_get_commands({ builtin = false })
    for name, want in pairs(EXPECTED_CMDS) do
      local got = cmds[name]
      H.assert_true(got ~= nil, name .. ' is registered')
      if got then
        H.assert_eq(got.nargs, want.nargs, name .. '.nargs')
        H.assert_eq(got.complete, want.complete, name .. '.complete')
        H.assert_eq(got.range, want.range, name .. '.range')
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

    H.assert_true(vim.uv.fs_stat(vim.fs.joinpath(ws, 'new.txt')) ~= nil,
      'the write routed to the sync and created new.txt')
    H.assert_false(vim.bo[buf].modified, 'the write cleared modified')
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
    local expected = { 'setup', 'list', 'list_buffer', 'list_cwd', 'open',
      'sync', 'undo', 'redo', 'yank', 'paste', 'paste_as' }
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

  H.it('guarded commands notify and change nothing outside a direct buffer', function()
    local cases = {
      { name = 'DirectUndo', call = function(api) return api.undo() end },
      { name = 'DirectRedo', call = function(api) return api.redo() end },
      { name = 'DirectYank', call = function(api) return api.yank(1, 1) end },
      { name = 'DirectPaste', call = function(api) return api.paste() end },
      { name = 'DirectPasteAs', call = function(api) return api.paste_as('x.txt') end },
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

  H.it('all nine buffer-local mappings resolve to their commands and none call the retired Vimscript', function()
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
    for lhs, rhs in pairs(EXPECTED_N) do
      H.assert_eq(normal[lhs], rhs, 'normal-mode ' .. lhs)
    end
    for lhs, rhs in pairs(EXPECTED_V) do
      H.assert_eq(visual[lhs], rhs, 'visual-mode ' .. lhs)
    end

    for _, maps in ipairs({ normal, visual }) do
      for lhs, rhs in pairs(maps) do
        H.assert_false(rhs:find(RETIRED, 1, true) ~= nil,
          'the rhs of ' .. lhs .. ' must not call the retired Vimscript function')
      end
    end
  end)

  H.it('map_default_keys=false installs no global - and no Lua buffer-local mappings', function()
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
    local visual = buf_maps(buf, 'v')
    for lhs in pairs(EXPECTED_N) do
      local rhs = normal[lhs]
      if rhs ~= nil then
        H.assert_false(rhs:find('<Cmd>', 1, true) ~= nil,
          'the opt-out must not install the Lua mapping for normal ' .. lhs)
      end
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
