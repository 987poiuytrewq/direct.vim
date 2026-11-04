-- buffer_expansion_spec.lua -- expansion, collapse, and undo behavior.
local H = require('tests.support.harness')
local buffer = require('direct.buffer')
local fs = require('direct.fs')
local paths = require('direct.paths')

-- Within-file isolation: the harness wipes buffers only at FILE boundaries, so a
-- modified buffer left by one spec would make the next `enew` raise E37.
local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

-- Symlink helper: luv returns true|nil, err from fs_symlink, so existence is
-- checked through lstat instead of the return value.
local function make_symlink(target, link)
  pcall(vim.uv.fs_symlink, target, link)
  return vim.uv.fs_lstat(link) ~= nil
end


H.describe('buffer: expansion and collapse lifecycle', function()
  H.it('[d and ]d jump between visible directory rows without changing expansion', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local alpha = H.mkdir(ws, 'alpha')
    local inner = H.mkdir(alpha, 'inner')
    H.mkfile(inner, 'deep.txt', { 'deep' })
    H.mkfile(alpha, 'alpha.txt', { 'alpha' })
    H.mkdir(ws, 'beta/hidden-child')
    H.mkdir(ws, 'gamma')
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    H.assert_buf_eq({
      'alpha/', '  inner/', '    deep.txt', '  alpha.txt', 'beta/', 'gamma/',
    }, 0)

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_feedkeys('[d', 'mx', false)
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2,
      '[d skips preceding files and reaches a nested directory')

    vim.api.nvim_feedkeys(']d', 'mx', false)
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5,
      ']d skips files and collapsed descendants to reach the next visible directory')
    vim.api.nvim_feedkeys(']d', 'mx', false)
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 6,
      ']d continues across visible root directories')
    vim.api.nvim_feedkeys(']d', 'mx', false)
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 6,
      ']d stays put when there is no later visible directory')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys('[d', 'mx', false)
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1,
      '[d stays put when there is no earlier visible directory')

    H.assert_buf_eq({
      'alpha/', '  inner/', '    deep.txt', '  alpha.txt', 'beta/', 'gamma/',
    }, 0, 'directory jumps do not expand, collapse, or edit the listing')
  end)

  H.it('keeps the root flat and expands one directory level lazily', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(sub, 'nested')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })

    local foldmethod, foldexpr = vim.wo.foldmethod, vim.wo.foldexpr
    local listing = buffer.list(ws)
    H.assert_buf_eq({ 'sub/', 'root.txt' }, 0)
    H.assert_eq(vim.wo.foldmethod, foldmethod, 'listing leaves foldmethod untouched')
    H.assert_eq(vim.wo.foldexpr, foldexpr, 'listing leaves foldexpr untouched')
    H.assert_false(vim.bo.modified, 'flat initial listing stays clean')

    local before = vim.fn.undotree()
    local calls = 0
    local read = buffer.read
    buffer.read = function(path)
      calls = calls + 1
      return read(path)
    end
    local ok, err = pcall(function()
      listing:expand(1)
      H.assert_buf_eq({ 'sub/', '  nested/', '  inside.txt', 'root.txt' }, 0)
      H.assert_eq(calls, 1, 'one immediate-child read')
      H.assert_false(vim.bo.modified, 'display-only expansion remains clean')
      listing:expand(1)
      H.assert_eq(calls, 1, 'repeat expansion does not re-read')
      H.assert_eq(vim.api.nvim_buf_line_count(0), 4, 'repeat expansion does not duplicate')
      H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'cursor stays on the directory')
      H.assert_eq(vim.fn.undotree().seq_cur, before.seq_cur + 1,
        'expansion starts its own undo block after the prior change')
    end)
    buffer.read = read
    if not ok then error(err) end
  end)

  H.it('zo, za, and zc expand and collapse by adding and removing rows', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    buffer.list(ws)

    vim.api.nvim_feedkeys('zo', 'mx', false)
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0)
    vim.api.nvim_feedkeys('za', 'mx', false)
    H.assert_buf_eq({ 'sub/' }, 0, 'za removes the expanded child rows')
    vim.api.nvim_feedkeys('za', 'mx', false)
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0, 'za expands a collapsed directory')
    vim.api.nvim_feedkeys('zc', 'mx', false)
    H.assert_buf_eq({ 'sub/' }, 0, 'zc collapses an expanded directory')
  end)

  H.it('zO, zA, zC, zR, and zM handle recursive and all-directory expansion', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({ max_recursive_expand_depth = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local nested = H.mkdir(ws, 'a/b/c')
    H.mkfile(nested, 'deep.txt', { 'deep' })
    local other = H.mkdir(ws, 'other/child')
    H.mkfile(other, 'file.txt', { 'other' })
    buffer.list(ws)

    vim.api.nvim_feedkeys('zO', 'mx', false)
    H.assert_buf_eq({ 'a/', '  b/', '    c/', '      deep.txt', 'other/' }, 0,
      'zO recursively expands the directory under the cursor')

    vim.api.nvim_feedkeys('zA', 'mx', false)
    H.assert_buf_eq({ 'a/', 'other/' }, 0, 'zA recursively collapses an open directory')
    vim.api.nvim_feedkeys('zA', 'mx', false)
    H.assert_buf_eq({ 'a/', '  b/', '    c/', '      deep.txt', 'other/' }, 0,
      'zA recursively expands a closed directory')
    vim.api.nvim_feedkeys('zC', 'mx', false)
    H.assert_buf_eq({ 'a/', 'other/' }, 0, 'zC recursively collapses the directory')

    vim.api.nvim_feedkeys('zR', 'mx', false)
    H.assert_buf_eq({
      'a/', '  b/', '    c/', '      deep.txt',
      'other/', '  child/', '    file.txt',
    }, 0, 'zR recursively expands every root directory')
    vim.api.nvim_feedkeys('zM', 'mx', false)
    H.assert_buf_eq({ 'a/', 'other/' }, 0, 'zM collapses every root directory')
    config.setup({ max_recursive_expand_depth = false })
  end)

  H.it('recursive all-expansion respects the configured depth limit', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({ max_recursive_expand_depth = 2 })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local deepest = H.mkdir(ws, 'a/b/c')
    H.mkfile(deepest, 'deep.txt', { 'deep' })
    buffer.list(ws)

    vim.api.nvim_feedkeys('zR', 'mx', false)

    H.assert_buf_eq({ 'a/', '  b/', '    c/' }, 0,
      'depth two opens a and b but leaves c closed')
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_feedkeys('zo', 'mx', false)
    H.assert_buf_eq({ 'a/', '  b/', '    c/', '      deep.txt' }, 0,
      'the recursive limit does not restrict ordinary one-level browsing')
    config.setup({ max_recursive_expand_depth = false })
  end)

  H.it('unlimited recursive expansion stops at a symlink cycle', function()
    clean_buffers()
    require('direct.config').setup({ max_recursive_expand_depth = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.assert_true(make_symlink(ws, sub .. '/loop'), 'create a symlink to an ancestor')
    buffer.list(ws)

    vim.api.nvim_feedkeys('zO', 'mx', false)

    H.assert_buf_eq({ 'sub/', '  loop/', '    sub/' }, 0,
      'the repeated directory identity is shown but not expanded again')
  end)

  H.it('collapsing a parent removes its complete expanded nested subtree', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    local nested = H.mkdir(sub, 'nested')
    H.mkfile(nested, 'deep.txt', { 'deep' })
    H.mkfile(sub, 'sibling.txt', { 'sibling' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    H.assert_buf_eq({ 'sub/', '  nested/', '    deep.txt', '  sibling.txt' }, 0)

    listing:collapse(1)

    H.assert_buf_eq({ 'sub/' }, 0, 'all descendants disappear with the parent collapse')
    local state = buffer._state_for_test(vim.api.nvim_get_current_buf())
    H.assert_nil(state.expanded[state.root_ids[1]], 'parent expansion record is cleared')
    H.assert_eq(#vim.api.nvim_buf_get_extmarks(0,
      vim.api.nvim_get_namespaces()['direct-listing-rows'], 0, -1, {}), 1,
      'only the parent row identity remains')
  end)

  H.it('collapse on a row hidden by a collapsed parent is a safe no-op', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(sub, 'nested')
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:collapse(1)
    local before = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    local ok = listing:collapse(2)

    H.assert_nil(ok, 'a hidden child row has no current identity')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), before,
      'the hidden child cannot affect the collapsed parent')
  end)

  H.it('preserves expansion state when a direct buffer is re-entered', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_feedkeys('zo', 'mx', false)
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0)

    vim.cmd('enew')
    vim.cmd('buffer ' .. bufnr)

    H.assert_buf_eq({ 'sub/', '  inside.txt' }, bufnr,
      're-entry preserves the materialized child rows')
  end)

  H.it('collapse undo restores child rows and identities once; redo collapses again', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local bufnr = vim.api.nvim_get_current_buf()
    local row_ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before_marks = vim.api.nvim_buf_get_extmarks(bufnr, row_ns, 0, -1, {})
    H.assert_eq(#before_marks, 2, 'parent and child identities exist before collapse')

    listing:collapse(1)
    H.assert_buf_eq({ 'sub/' }, 0, 'collapse removes child rows')
    H.assert_eq(vim.fn.maparg('<C-r>', 'n', false, true).rhs, '<Cmd>DirectRedo<CR>',
      'direct buffer maps <C-r> to filesystem redo')
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0, 'undo restores exact child rows')
    H.assert_eq(vim.api.nvim_buf_get_extmarks(bufnr, row_ns, 0, -1, {}), before_marks,
      'undo restores the exact row identity marks')
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/' }, 0, 'redo re-collapses without duplicate rows')
    H.assert_eq(vim.api.nvim_buf_line_count(bufnr), 1, 'redo leaves one directory row')
  end)

  H.it('a second undo still reverses expansion and redo restores it before recollapse', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    listing:expand(1)
    listing:collapse(1)

    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0, 'first undo restores collapsed rows')
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/' }, 0, 'second undo removes the original expansion normally')
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0, 'redo restores expansion once')
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/' }, 0, 'redo then reapplies the collapse')
  end)

  H.it('re-list preserves collapsed state and expansion rereads external changes', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'old.txt', { 'old' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:collapse(1)
    listing:list()
    H.assert_buf_eq({ 'sub/' }, 0, 're-list keeps a previously collapsed directory closed')

    H.mkfile(sub, 'new.txt', { 'new' })
    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '  new.txt', '  old.txt' }, 0,
      'expansion rereads current contents after an external change')
  end)

  H.it('collapse undo after re-list restores child identities and remains syncable', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']

    listing:expand(1)
    local before_marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    listing:collapse(1)
    listing:list()
    H.assert_buf_eq({ 'sub/' }, bufnr, 're-list preserves the collapsed rows')
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    H.assert_buf_eq({ 'sub/', '  inside.txt' }, bufnr,
      'undo restores the exact rows after the row namespace was rebuilt')
    local state = buffer._state_for_test(bufnr)
    local parent_id = state.root_ids[1]
    H.assert_not_nil(state.expanded[parent_id], 'undo restores the expansion record')
    H.assert_eq(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {}), before_marks,
      'undo restores the saved parent and child identities')
    H.assert_eq(listing:get_paths(2, 2), { ws .. '/sub/inside.txt' },
      'the restored child identity resolves to its filesystem path')
    local ok, reason = listing:sync()
    H.assert_true(ok == true, 'sync accepts the restored child state: ' .. tostring(reason))
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, bufnr,
      'successful sync retains the expanded materialization')
  end)

  H.it('collapse undo after re-list restores identities across expanded sibling subtrees', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    for _, root_name in ipairs({ 'a', 'b' }) do
      local root = H.mkdir(ws, root_name)
      local sub = H.mkdir(root, 'sub')
      H.mkfile(sub, 'inside.txt', { root_name })
    end
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    listing:expand(4)
    listing:expand(5)
    local expanded = {
      'a/', '  sub/', '    inside.txt',
      'b/', '  sub/', '    inside.txt',
    }
    H.assert_buf_eq(expanded, 0, 'both similarly-shaped sibling subtrees are expanded')
    listing:collapse(1)
    listing:list()
    H.assert_buf_eq({ 'a/', 'b/', '  sub/', '    inside.txt' }, 0,
      're-list keeps a collapsed and b expanded')
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = vim.api.nvim_get_current_buf() })

    H.assert_buf_eq(expanded, 0, 'undo restores rows for both sibling subtrees')
    local state = buffer._state_for_test(vim.api.nvim_get_current_buf())
    H.assert_not_nil(state.expanded[state.root_ids[1]], 'a expansion is restored')
    H.assert_not_nil(state.expanded[state.root_ids[2]], 'b expansion remains restored')
    H.assert_eq(listing:get_paths(1, 6), {
      ws .. '/a/', ws .. '/a/sub/', ws .. '/a/sub/inside.txt',
      ws .. '/b/', ws .. '/b/sub/', ws .. '/b/sub/inside.txt',
    }, 'every row retains its own sibling-specific path identity')
    local ok, reason = listing:sync()
    H.assert_true(ok == true, 'sync accepts every restored sibling row: ' .. tostring(reason))
  end)

  H.it('collapse undo after re-list preserves a pending root rename outside the subtree', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local row_namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    listing:expand(1)
    vim.api.nvim_buf_set_text(bufnr, 2, 0, 2, #'root.txt', { 'renamed.txt' })
    local root_mark = vim.api.nvim_buf_get_extmarks(bufnr, row_namespace,
      { 2, 0 }, { 2, -1 }, { details = true })[1]
    H.assert_not_nil(root_mark, 'pending rename retains its root row identity')
    H.assert_false(root_mark[4] and root_mark[4].invalid or false,
      'pending root rename keeps a valid identity mark')

    listing:collapse(1)
    listing:list()
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    H.assert_buf_eq({ 'sub/', '  inside.txt', 'renamed.txt' }, bufnr,
      'undo restores children while retaining the pending root rename')
    local state = buffer._state_for_test(bufnr)
    H.assert_not_nil(state.expanded[state.root_ids[1]], 'collapsed subtree expansion is restored')
    local paths, path_err = listing:get_paths(1, 3)
    H.assert_eq(paths, {
      ws .. '/sub/', ws .. '/sub/inside.txt', ws .. '/renamed.txt',
    }, 'all restored rows have usable paths: ' .. tostring(path_err))

    local ok, reason = listing:sync()
    H.assert_true(ok == true, 'sync applies the pending root rename: ' .. tostring(reason))
    H.assert_fs_eq(ws, { 'renamed.txt', 'sub/', 'sub/inside.txt' },
      'sync applies the root rename without disturbing the expanded subtree')
  end)

  H.it('edited child rows still block collapse after an expand undo/redo cycle', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { '  edited.txt' })
    H.capture_messages()

    local ok = listing:collapse(1)

    H.assert_false(ok, 'restored but edited child rows still refuse collapse')
    H.assert_buf_eq({ 'sub/', '  edited.txt' }, bufnr,
      'refusal after redo keeps the edited row visible')
    H.assert_notified('unsaved edits', vim.log.levels.ERROR)
  end)

  H.it('collapse and expand do not add file history or yank side effects', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    local history = require('direct.history')
    local register = require('direct.register')
    local history_calls, yank_calls = 0, 0
    local original_log, original_yank = history.log, register.yank
    history.log = function(...) history_calls = history_calls + 1; return original_log(...) end
    register.yank = function(...) yank_calls = yank_calls + 1; return original_yank(...) end
    local ok, err = pcall(function()
      listing:expand(1)
      listing:collapse(1)
      listing:expand(1)
    end)
    history.log, register.yank = original_log, original_yank
    H.assert_true(ok, tostring(err))
    H.assert_eq(history_calls, 0, 'view transitions do not log filesystem history')
    H.assert_eq(yank_calls, 0, 'view transitions do not touch the yank register')
  end)

  H.it('refuses collapse atomically when a child row has unsaved text', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(sub, 'nested')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { '  edited.txt' })
    local before_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before_marks = vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {})
    local state = buffer._state_for_test(vim.api.nvim_get_current_buf())
    local before_expanded = vim.deepcopy(state.expanded)
    H.capture_messages()

    local ok, reason = listing:collapse(1)

    H.assert_false(ok, 'collapse is refused')
    H.assert_true(tostring(reason):find('unsaved', 1, true) ~= nil,
      'reason identifies the unsaved child row')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), before_lines,
      'refusal leaves every buffer row unchanged')
    H.assert_eq(vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}), before_marks,
      'refusal leaves every row identity unchanged')
    H.assert_eq(state.expanded, before_expanded, 'refusal leaves expansion state unchanged')
    H.assert_notified('collapse', vim.log.levels.ERROR)
  end)

  H.it('refuses collapse when a child row identity mark is missing', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local child_id = vim.api.nvim_buf_get_extmarks(0, ns, { 1, 0 }, { 1, -1 }, {})[1][1]
    vim.api.nvim_buf_del_extmark(0, ns, child_id)
    H.capture_messages()

    local ok = listing:collapse(1)

    H.assert_false(ok, 'missing child identity refuses collapse')
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0,
      'refusal keeps child rows present')
    H.assert_notified('identity', vim.log.levels.ERROR)
  end)
end)
