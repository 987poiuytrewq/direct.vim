-- sync_tree_edit_spec.lua -- sync: editable expanded subtrees.
-- Exercises the sync facade and filesystem effects.

local sync = require('tests.support.sync_helpers').new()
local H = sync.H
local buffer = sync.buffer
local fs = sync.fs
local paths = sync.paths
local history = sync.history
local register = sync.register
local fixtures = sync.fixtures
local HEADER = sync.HEADER
local decode_record = sync.decode_record
local clean_buffers = sync.clean_buffers
local route_write_to_test_buffer = sync.route_write_to_test_buffer
local history_lines = sync.history_lines
local list_edit_and_sync = sync.list_edit_and_sync

H.describe('sync: editable expanded subtrees', function()
  H.it('syncs mixed create, rename, and delete edits within one expanded directory', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'keep.txt', { 'keep' })
    H.mkfile(sub, 'remove.txt', { 'remove' })
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)
    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '  keep.txt', '  remove.txt', 'root.txt' }, 0,
      'expanded directory children are materialized')

    vim.api.nvim_buf_set_text(0, 1, 2, 1, 2 + #'keep.txt', { 'renamed.txt' })
    vim.api.nvim_buf_set_lines(0, 2, 3, false, {})
    vim.api.nvim_buf_set_lines(0, 2, 2, false, { '  new.txt' })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, {
      'root.txt', 'sub/', 'sub/new.txt', 'sub/renamed.txt',
    }, 'the subtree edit applies without touching root entries')
    H.assert_eq(vim.fn.readfile(sub .. '/renamed.txt'), { 'keep' },
      'renaming a child preserves its contents')
    H.assert_eq(listing:get_paths(2, 3), {
      sub .. '/new.txt', sub .. '/renamed.txt',
    }, 'the refreshed subtree resolves child paths')
    H.assert_false(vim.bo.modified, 'successful subtree sync clears modified state')
  end)

  H.it('saves an expanded child rename after unrelated sibling changes on disk', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'rename.txt', { 'keep' })
    H.mkfile(sub, 'remove.txt', { 'external delete' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local rename_row
    for row, line in ipairs(H.buf_lines()) do
      if line == '  rename.txt' then rename_row = row; break end
    end
    H.assert_not_nil(rename_row, 'rename source is visible in the expanded listing')
    vim.api.nvim_buf_set_text(0, rename_row - 1, 2, rename_row - 1,
      2 + #'rename.txt', { 'renamed.txt' })
    H.mkfile(sub, 'external.txt', { 'external create' })
    vim.fn.delete(vim.fs.joinpath(sub, 'remove.txt'))

    local ok, err = listing:sync()

    H.assert_true(ok, 'unrelated expanded-folder changes do not block sync: ' .. tostring(err))
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sub, 'renamed.txt')), { 'keep' },
      'the requested rename is saved')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sub, 'external.txt')), { 'external create' },
      'the external addition is preserved')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(sub, 'remove.txt')),
      'the unrelated external deletion is reconciled')
    H.assert_false(vim.bo.modified, 'the listing refreshes after sync')
  end)

  H.it('refuses an expanded rename when its source changes on disk', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'rename.txt', { 'original' })
    local replacement = H.mkdir(sb.root, 'external-replacement')
    H.mkfile(replacement, 'replacement.txt', { 'replacement' })
    local listing = buffer.list(ws)
    listing:expand(1)
    vim.api.nvim_buf_set_text(0, 1, 2, 1, 2 + #'rename.txt', { 'renamed.txt' })
    vim.fn.delete(vim.fs.joinpath(sub, 'rename.txt'))
    H.assert_true(vim.uv.fs_rename(replacement, vim.fs.joinpath(sub, 'rename.txt')),
      'move a separately allocated directory into the old path')

    local ok, err = listing:sync()

    H.assert_nil(ok, 'a replaced expanded source remains a conflict')
    H.assert_true(tostring(err):find('rename.txt', 1, true) ~= nil, tostring(err))
    H.assert_true(tostring(err):find(':DirectList!', 1, true) ~= nil,
      'the refusal explains that the edit must be discarded before a fresh listing')
    H.assert_true(H.exists(vim.fs.joinpath(sub, 'rename.txt', 'replacement.txt')),
      'the external replacement is untouched')
    H.assert_false(H.exists(vim.fs.joinpath(sub, 'renamed.txt')),
      'the requested rename is not applied')
    H.assert_true(vim.bo.modified, 'the requested edit remains in the listing')
  end)

  H.it('renders and syncs tree edits with a custom indentation width', function()
    clean_buffers()
    local config = require('direct.config')
    config.setup({ indent_size = 4, collapse_single_entry_directories = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    H.mkfile(ws, 'from-root.txt', { 'preserve me' })
    local listing = buffer.list(ws)
    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '    inside.txt', 'from-root.txt' }, 0,
      'expanded child rows use the configured indentation width')

    vim.api.nvim_buf_set_text(0, 2, 0, 2, 0, { '    ' })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, {
      'sub/', 'sub/from-root.txt', 'sub/inside.txt',
    }, 'sync parses the configured width and moves the root file into the subtree')
    H.assert_eq(vim.fn.readfile(sub .. '/from-root.txt'), { 'preserve me' },
      'the moved file contents are preserved')
    config.setup({ collapse_single_entry_directories = false })
  end)

  H.it('moves a file between expanded sibling directories with its contents intact', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local top = H.mkdir(ws, 'top')
    local a = H.mkdir(top, 'a')
    local b = H.mkdir(top, 'b')
    H.mkfile(a, 'from.txt', { 'preserve me' })
    H.mkfile(b, 'stay.txt', { 'stay' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    listing:expand(4)
    H.assert_buf_eq({
      'top/', '  a/', '    from.txt', '  b/', '    stay.txt',
    }, 0, 'both sibling directories are expanded')

    -- Move the existing line, rather than replacing it, so its extmark identity
    -- follows it to the new parent and the sync can distinguish a move from a
    -- delete/create pair.
    vim.cmd('3move 5')
    H.assert_buf_eq({
      'top/', '  a/', '  b/', '    stay.txt', '    from.txt',
    }, 0, 'the row now belongs to b/')

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, {
      'top/', 'top/a/', 'top/b/', 'top/b/from.txt', 'top/b/stay.txt',
    }, 'the filesystem move is applied across the two subtree scopes')
    H.assert_eq(vim.fn.readfile(b .. '/from.txt'), { 'preserve me' },
      'the moved file keeps its contents')
    H.assert_false(fs.exists(a .. '/from.txt'), 'the source is no longer present')
    H.assert_eq(listing:get_paths(4, 5), {
      b .. '/from.txt', b .. '/stay.txt',
    }, 'the refreshed destination subtree resolves its files')

    require('direct').undo()
    H.wait_for_direct()
    H.assert_true(fs.exists(a .. '/from.txt'), 'filesystem undo restores the source path')
    H.assert_false(fs.exists(b .. '/from.txt'), 'filesystem undo clears the destination')
    require('direct').redo()
    H.wait_for_direct()
    H.assert_true(fs.exists(b .. '/from.txt'), 'filesystem redo reapplies the subtree move')
  end)

  H.it('moves an expanded directory with its whole subtree to another parent', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local top = H.mkdir(ws, 'top')
    local a = H.mkdir(top, 'a')
    local b = H.mkdir(top, 'b')
    local branch = H.mkdir(a, 'branch')
    H.mkfile(branch, 'deep.txt', { 'deep' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    listing:expand(3)
    listing:expand(5)
    H.assert_buf_eq({
      'top/', '  a/', '    branch/', '      deep.txt', '  b/',
    }, 0, 'the source tree and destination are expanded')

    vim.cmd('3,4move 5')

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, {
      'top/', 'top/a/', 'top/b/', 'top/b/branch/', 'top/b/branch/deep.txt',
    }, 'the directory move carries its full tree')
    H.assert_eq(listing:get_paths(5, 5), { b .. '/branch/deep.txt' },
      'the moved expansion is restored at its new parent')
  end)

  H.it('moves a root file into an expanded subtree without a create/delete pair', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local top = H.mkdir(ws, 'top')
    local sub = H.mkdir(top, 'sub')
    H.mkfile(sub, 'stay.txt', { 'stay' })
    H.mkfile(ws, 'from-root.txt', { 'preserve me' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    H.assert_buf_eq({ 'top/', '  sub/', '    stay.txt', 'from-root.txt' }, 0,
      'nested destination is materialized')

    vim.api.nvim_buf_set_text(0, 3, 0, 3, 0, { '    ' })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, {
      'top/', 'top/sub/', 'top/sub/from-root.txt', 'top/sub/stay.txt',
    }, 'the existing root file is moved into the subtree')
    H.assert_eq(vim.fn.readfile(sub .. '/from-root.txt'), { 'preserve me' },
      'the root file contents are preserved')
    H.assert_eq(listing:get_paths(3, 4), {
      sub .. '/from-root.txt', sub .. '/stay.txt',
    }, 'the refreshed expanded directory shows the moved file')
  end)

  H.it('moves a child file back to the root listing by reducing its indentation', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'from-child.txt', { 'preserve me' })
    H.mkfile(ws, 'stay.txt', { 'stay' })
    local listing = buffer.list(ws)
    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '  from-child.txt', 'stay.txt' }, 0,
      'the source child is materialized')

    vim.api.nvim_buf_set_text(0, 1, 0, 1, 2, { '' })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, { 'from-child.txt', 'stay.txt', 'sub/' },
      'the child is moved into the root listing')
    H.assert_eq(vim.fn.readfile(ws .. '/from-child.txt'), { 'preserve me' },
      'the moved file contents are preserved')
  end)

  H.it('renames an expanded child directory and restores its nested expansion', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    local nested = H.mkdir(sub, 'nested')
    H.mkfile(nested, 'deep.txt', { 'deep' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    H.assert_buf_eq({ 'sub/', '  nested/', '    deep.txt' }, 0,
      'the nested directory is expanded')

    vim.api.nvim_buf_set_text(0, 1, 2, 1, #'  nested/', { 'renamed/' })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, {
      'sub/', 'sub/renamed/', 'sub/renamed/deep.txt',
    }, 'the directory and its contents move together')
    H.assert_eq(listing:get_paths(3, 3), { sub .. '/renamed/deep.txt' },
      'the nested expansion is restored at the renamed path')
  end)

  H.it('uses a same-slot whole-line replacement as a child rename', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'anchor.txt', { 'anchor' })
    H.mkfile(sub, 'old.txt', { 'preserve me' })
    local listing = buffer.list(ws)
    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '  anchor.txt', '  old.txt' }, 0,
      'both original identities are materialized')

    vim.api.nvim_buf_set_lines(0, 2, 3, false, { '  renamed.txt' })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, { 'sub/', 'sub/anchor.txt', 'sub/renamed.txt' },
      'the replacement is interpreted as a rename, not delete/create')
    H.assert_eq(vim.fn.readfile(sub .. '/renamed.txt'), { 'preserve me' },
      'whole-line rename preserves the original contents')
  end)

  H.it('accepts sibling row reordering as presentation-only', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'a.txt', { 'a' })
    H.mkfile(sub, 'b.txt', { 'b' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local before = H.fs_snapshot(ws)

    vim.cmd('2move 3')

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'row order does not move filesystem entries')
    H.assert_buf_eq({ 'sub/', '  a.txt', '  b.txt' }, 0,
      'the refreshed directory returns to its sorted order')
    H.assert_eq(history_lines('undo.log'), {}, 'a presentation-only reorder writes no history')
  end)

  H.it('saves an expanded rename after an unrelated sibling appears on disk', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'old.txt', { 'old' })
    local listing = buffer.list(ws)
    listing:expand(1)
    H.mkfile(sub, 'external.txt', { 'external' })
    vim.api.nvim_buf_set_text(0, 1, 2, 1, 2 + #'old.txt', { 'renamed.txt' })
    local yanked, classified = 0, 0
    local classify, yank = buffer.classify, register.yank
    buffer.classify = function(...) classified = classified + 1; return classify(...) end
    register.yank = function(...) yanked = yanked + 1; return yank(...) end

    H.capture_messages()
    local ok, reason = listing:sync()

    buffer.classify, register.yank = classify, yank
    H.assert_true(ok, 'unrelated external additions do not block an expanded rename: '
      .. tostring(reason) .. '\n' .. H.messages())
    H.assert_eq(classified, 1, 'root identity classification still runs')
    H.assert_eq(yanked, 0, 'a rename does not auto-yank the unchanged source')
    H.assert_eq(H.fs_snapshot(ws), { 'sub/', 'sub/external.txt', 'sub/renamed.txt' },
      'both the external addition and requested rename remain on disk')
    H.assert_false(vim.bo.modified, 'successful sync refreshes the listing')
  end)

  H.it('creates a nested subtree beneath a directory added in the same edit', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      'new/', '  nested/', '    file.txt',
    })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, { 'new/', 'new/nested/', 'new/nested/file.txt' },
      'parent directories are created before nested entries')
  end)
end)
