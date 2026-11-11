-- sync_undo_spec.lua -- sync with expanded children.
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

H.describe('sync with expanded children', function()
  H.it('writing after collapse leaves the filesystem unchanged', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local before = H.fs_snapshot(ws)

    listing:expand(1)
    listing:collapse(1)
    H.assert_buf_eq({ 'sub/' }, 0, 'collapse leaves only the root directory row')
    vim.cmd('write')
    H.wait_for_direct()

    H.assert_eq(H.fs_snapshot(ws), before, 'write after collapse does not delete children')
    H.assert_buf_eq({ 'sub/' }, 0, 'sync preserves the collapsed view')
  end)

  H.it('deletes a collapsed non-empty directory as one tree action', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    H.mkfile(ws, 'keep.txt', { 'keep' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:collapse(1)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_fs_eq(ws, { 'keep.txt' }, 'the directory tree is removed')
    local content = register.content()
    H.assert_not_nil(content, 'the removed tree is auto-yanked')
    H.assert_eq(vim.fn.readfile(content .. '/sub/inside.txt'), { 'inside' },
      'the auto-yank contains the collapsed directory contents')
  end)

  H.it('allows deleting an empty collapsed directory', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'empty')
    H.mkfile(ws, 'keep.txt', { 'keep' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:collapse(1)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})

    local ok = listing:sync()

    H.assert_true(ok == true, 'empty collapsed directory follows normal delete semantics')
    H.assert_fs_eq(ws, { 'keep.txt' }, 'empty directory was removed')
  end)

  H.it('writes a root creation after undoing an expand without classifying children', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new.txt' })

    local classified, classify = nil, buffer.classify
    buffer.classify = function(actual, expected)
      classified = { vim.deepcopy(actual), vim.deepcopy(expected) }
      return classify(actual, expected)
    end
    local called, err = pcall(vim.cmd, 'write')
    buffer.classify = classify
    H.wait_for_direct()

    H.assert_true(called, tostring(err))
    H.assert_eq(classified, { { 'sub/', 'new.txt' }, { 'sub/' } },
      'the root classifier sees only root rows')
    H.assert_eq(H.fs_snapshot(ws), { 'new.txt', 'sub/', 'sub/inside.txt' },
      'only the new root file is created')
    H.assert_eq(listing:get_paths(1, 2), { ws .. '/sub/', ws .. '/new.txt' },
      'the saved listing contains roots only')
  end)

  H.it('applies root deletion after undoing an expand only after child preflight', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_buf_set_lines(0, 1, 2, false, {})

    local classified, classify = nil, buffer.classify
    buffer.classify = function(actual, expected)
      classified = { vim.deepcopy(actual), vim.deepcopy(expected) }
      return classify(actual, expected)
    end
    local called, err = pcall(vim.cmd, 'write')
    buffer.classify = classify
    H.wait_for_direct()

    H.assert_true(called, tostring(err))
    H.assert_eq(classified, { { 'sub/' }, { 'sub/', 'root.txt' } },
      'the root classifier sees only root rows')
    H.assert_eq(H.fs_snapshot(ws), { 'sub/', 'sub/inside.txt' },
      'only the deleted root file is removed')
    local content = register.content()
    H.assert_not_nil(content, 'legacy root deletion auto-yanks after preflight')
    H.assert_eq(vim.fn.readfile(content .. '/root.txt'), { 'root' },
      'the root file is the only auto-yanked entry')
    local undo = history_lines('undo.log')
    H.assert_eq(#undo, 2, 'only one root deletion is recorded in history')
    H.assert_eq(decode_record(undo, 2).src, ws .. '/root.txt',
      'the history record is the root deletion')
  end)

  H.it('syncs visible subtree edits without deleting rows hidden by undo', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkdir(ws, 'b')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'a/inside-a.txt', { 'a' })
    H.mkfile(ws, 'b/inside-b.txt', { 'b' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(3)
    vim.cmd('undo')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new.txt' })
    vim.api.nvim_buf_set_text(0, 1, 2, 1, 2 + #'inside-a.txt', { 'tampered-a.txt' })
    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), {
      'a/', 'a/tampered-a.txt', 'b/', 'b/inside-b.txt', 'new.txt', 'root.txt',
    }, 'only the visible a-subtree edit and root creation are applied')
    H.assert_true(fs.exists(ws .. '/b/inside-b.txt'),
      'undoing b expansion is not interpreted as deleting its child')
  end)

  H.it('refuses a lost surviving child identity on an undo branch before side effects', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkdir(ws, 'b')
    H.mkfile(ws, 'a/inside-a.txt', { 'a' })
    H.mkfile(ws, 'b/inside-b.txt', { 'b' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(3)
    vim.cmd('undo')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new.txt' })
    local bufnr = vim.api.nvim_get_current_buf()
    local state = buffer._state_for_test(bufnr)
    local child_id = state.expanded[state.root_ids[1]].children[1].id
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    H.assert_true(vim.api.nvim_buf_del_extmark(bufnr, namespace, child_id),
      'the surviving child identity is removed')
    local before_fs = H.fs_snapshot(ws)
    local before_register = register.content()
    local before_undo = history_lines('undo.log')
    local before_redo = history_lines('redo.log')
    local classified, yanked = 0, 0
    local classify, yank = buffer.classify, register.yank
    buffer.classify = function(...) classified = classified + 1; return classify(...) end
    register.yank = function(...) yanked = yanked + 1; return yank(...) end

    local ok, reason = listing:sync()

    buffer.classify, register.yank = classify, yank
    H.assert_nil(ok, 'missing surviving child identity is refused')
    H.assert_true(tostring(reason):find('child', 1, true) ~= nil
      or tostring(reason):find('identity', 1, true) ~= nil, tostring(reason))
    H.assert_eq(classified, 0, 'lost child identity stops before root classification')
    H.assert_eq(yanked, 0, 'lost child identity stops before auto-yank')
    H.assert_eq(H.fs_snapshot(ws), before_fs, 'the filesystem is unchanged')
    H.assert_eq(register.content(), before_register, 'the register is unchanged')
    H.assert_eq(history_lines('undo.log'), before_undo, 'undo history is unchanged')
    H.assert_eq(history_lines('redo.log'), before_redo, 'redo history is unchanged')
  end)

  H.it('refuses an indented child-shaped row after undo before root classification', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { '  child-like.txt' })
    local before_fs = H.fs_snapshot(ws)
    local classified, classify = 0, buffer.classify
    buffer.classify = function(...) classified = classified + 1; return classify(...) end

    local ok, reason = listing:sync()

    buffer.classify = classify
    H.assert_nil(ok, 'an indented unmarked row is not accepted as a root')
    H.assert_true(tostring(reason):find('child', 1, true) ~= nil,
      'refusal reports child contamination')
    H.assert_eq(classified, 0, 'child-shaped contamination stops before classification')
    H.assert_eq(H.fs_snapshot(ws), before_fs, 'the filesystem is unchanged')
  end)

  H.it('writes a root rename after undoing an expand', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    listing:expand(1)
    vim.cmd('undo')
    H.assert_buf_eq({ 'sub/', 'root.txt' }, 0,
      'undo removes the materialized child while retaining root rows')
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys('ccrenamed.txt\27', 'xt', false)

    local called, err = pcall(vim.cmd, 'write')
    H.wait_for_direct()

    H.assert_true(called, tostring(err))
    H.assert_buf_eq({ 'sub/', 'renamed.txt' }, 0,
      'successful write keeps only the root rows')
    H.assert_false(vim.bo.modified, 'successful write clears modified state')
    H.assert_eq(H.fs_snapshot(ws), { 'renamed.txt', 'sub/', 'sub/inside.txt' },
      'write applies the root rename and no child filesystem action')
    H.assert_eq(listing:get_paths(1, 2), { ws .. '/sub/', ws .. '/renamed.txt' },
      'the saved rows resolve as roots, not stale child rows')
  end)

  H.it('restores child identities after undo reconciliation and redo', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local a = H.mkdir(ws, 'a')
    H.mkdir(a, 'nested')
    H.mkfile(a, 'nested/deep.txt', { 'deep' })
    H.mkfile(ws, 'root.txt', { 'root' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']

    listing:expand(1)
    listing:expand(2)
    local state = buffer._state_for_test(bufnr)
    local root_id = state.root_ids[1]
    local child_id = state.expanded[root_id].children[1].id
    local nested_id = child_id
    local deep_id = state.expanded[nested_id].children[1].id

    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_nil(state.expanded[nested_id], 'undo reconciliation removes the nested expansion')
    H.assert_eq(state.rows[deep_id], nil, 'the live nested child record is discarded on undo')

    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    H.assert_buf_eq({ 'a/', '  nested/', '    deep.txt', 'root.txt' }, 0,
      'redo restores the exact nested child snapshot')
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    H.assert_eq(marks[2][1], child_id, 'redo restores the original child extmark identity')
    H.assert_eq(marks[3][1], deep_id, 'redo restores the nested child extmark identity')
    H.assert_eq(state.expanded[nested_id].children[1].id, deep_id,
      'the nested expansion state is restored with the original child record')
    H.assert_eq(state.rows[deep_id].parent, nested_id,
      'the restored child retains its original parent relationship')
    H.assert_eq(listing:get_paths(2, 3), {
      ws .. '/a/nested/', ws .. '/a/nested/deep.txt',
    }, 'restored rows resolve to their original nested filesystem paths')

    -- Exercise both repeated replay of the nested insertion and a full
    -- multi-materialization rewind/replay (parent, then nested child).
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_eq(listing:get_paths(3, 3), { ws .. '/a/nested/deep.txt' },
      'a second nested redo cycle restores the same path identity')

    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'a/', 'root.txt' }, 0,
      'undoing both materializations removes only their view rows')
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'a/', '  nested/', 'root.txt' }, 0,
      'the first redo restores the parent materialization only')
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'a/', '  nested/', '    deep.txt', 'root.txt' }, 0,
      'the next redo restores the nested materialization')
    H.assert_eq(listing:get_paths(2, 3), {
      ws .. '/a/nested/', ws .. '/a/nested/deep.txt',
    }, 'multi-materialization replay preserves both original paths')

    local no_op_ok, no_op_err = pcall(vim.cmd, 'write')
    H.assert_true(no_op_ok, tostring(no_op_err))
    H.wait_for_direct()
    H.assert_eq(H.fs_snapshot(ws), {
      'a/', 'a/nested/', 'a/nested/deep.txt', 'root.txt',
    }, 'a no-op write accepts redone children without filesystem changes')

    vim.api.nvim_buf_set_text(bufnr, 3, 0, 3, #'root.txt', { 'renamed.txt' })
    local write_ok, write_err = pcall(vim.cmd, 'write')
    H.assert_true(write_ok, tostring(write_err))
    H.wait_for_direct()
    H.assert_eq(H.fs_snapshot(ws), {
      'a/', 'a/nested/', 'a/nested/deep.txt', 'renamed.txt',
    }, 'a root-only edit never treats redone children as root actions')

    local register = require('direct.register')
    local original_yank, yanked = register.yank, nil
    register.yank = function(sources) yanked = vim.deepcopy(sources); return true end
    local yank_ok, yank_err = pcall(require('direct').yank, 3, 3)
    register.yank = original_yank
    H.assert_true(yank_ok, tostring(yank_err))
    H.assert_eq(yanked, { ws .. '/a/nested/deep.txt' },
      'yank on the restored deep child uses its exact filesystem path')

    listing:open('    deep.txt')
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/a/nested/deep.txt'),
      'open on the restored deep child resolves the exact filesystem path')
  end)

  H.it('expand and undo-redo preserve child paths for open', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.txt', { 'child contents' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()

    H.assert_true(listing:expand(1) == true, 'normal nonempty expand succeeds')
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    local child_path = ws .. '/child/inside.txt'
    H.assert_eq(listing:get_paths(2, 2), { child_path },
      'redo restores the child path identity')
    H.assert_true(listing:open('  inside.txt') == true, 'open accepts the intact redone row')
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), child_path),
      'open consumes the restored child path')
  end)

  H.it('restores an expansion with its captured empty wildignore after the option changes', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.txt', { 'child contents' })
    route_write_to_test_buffer()
    local listing
    H.with_option('wildignore', '', function()
      listing = buffer.list(ws)
      listing:expand(1)
    end)
    local bufnr = vim.api.nvim_get_current_buf()
    local state = buffer._state_for_test(bufnr)
    local child_id = state.expanded[state.root_ids[1]].children[1].id
    local fs_before = H.fs_snapshot(ws)
    local register = require('direct.register')
    local register_before = register.content()

    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'child/' }, 0, 'undo removes the materialized child')

    H.with_option('wildignore', '*.txt', function()
      vim.cmd('redo')
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

      H.assert_buf_eq({ 'child/', '  inside.txt' }, 0,
        'redo uses the captured empty filter rather than the current filter')
      local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
      H.assert_true(marks[2] and marks[2][1] == child_id,
        'redo restores the original child identity')
      H.assert_eq(listing:get_paths(2, 2), { child .. '/inside.txt' },
        'the restored child keeps its original path')

      local write_ok, write_err = pcall(vim.cmd, 'write')
      H.assert_true(write_ok, tostring(write_err))
      H.wait_for_direct()
      H.assert_eq(H.fs_snapshot(ws), fs_before, 'a no-op write changes no filesystem entries')
      H.assert_eq(register.content(), register_before, 'a no-op write does not change the register')

      local original_yank, yanked = register.yank, nil
      register.yank = function(sources) yanked = vim.deepcopy(sources); return true end
      local yank_ok, yank_err = pcall(require('direct').yank, 2, 2)
      register.yank = original_yank
      H.assert_true(yank_ok, tostring(yank_err))
      H.assert_eq(yanked, { child .. '/inside.txt' },
        'yank accepts the restored child and uses its original path')
      H.assert_eq(register.content(), register_before, 'the path spy causes no register mutation')

      H.assert_true(listing:open('  inside.txt') == true,
        'open accepts the restored child under the changed filter')
      H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), child .. '/inside.txt'),
        'open uses the restored child path')
    end)

    H.assert_eq(H.fs_snapshot(ws), fs_before, 'redo/open/yank/write do not alter the directory')
    H.assert_eq(register.content(), register_before, 'redo/open/yank/write leave register contents intact')
  end)

  H.it('uses the captured non-empty wildignore when the current filter changes to empty', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.log', { 'hidden by the captured filter' })
    H.mkfile(child, 'visible.txt', { 'child contents' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
      listing:expand(1)
    end)
    local bufnr = vim.api.nvim_get_current_buf()
    local state = buffer._state_for_test(bufnr)
    local child_id = state.expanded[state.root_ids[1]].children[1].id
    H.assert_eq(state.rows[child_id].name, 'visible.txt',
      'the original non-empty filter hides inside.log')

    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'child/' }, 0, 'undo removes the materialized child')

    H.with_option('wildignore', '', function()
      vim.cmd('redo')
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

      H.assert_buf_eq({ 'child/', '  visible.txt' }, 0,
        'redo uses the captured non-empty filter after current filtering is disabled')
      local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
      H.assert_eq(marks[2][1], child_id, 'redo restores the original child identity')
      H.assert_eq(listing:get_paths(2, 2), { child .. '/visible.txt' },
        'the restored child keeps its original path')
    end)
  end)

  H.it('fails closed when the redo filter snapshot is missing', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.txt', { 'child contents' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local bufnr = vim.api.nvim_get_current_buf()

    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    local state = buffer._state_for_test(bufnr)
    H.assert_true(state.materialization_recoveries[1] ~= nil,
      'undo retains the redo recovery record')
    state.materialization_recoveries[1].wildignore = nil

    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    local paths, reason = listing:get_paths(2, 2)
    H.assert_nil(paths, 'a missing filter snapshot does not restore child identity')
    H.assert_true(type(reason) == 'string' and #reason > 0,
      'the unsafe redone row is refused with a reason')
  end)

  H.it('yank after undo-redo consumes the restored child path', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.txt', { 'child contents' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    local register = require('direct.register')
    local original_yank, yanked = register.yank, nil
    register.yank = function(sources) yanked = vim.deepcopy(sources); return true end
    require('direct').yank(2, 2)
    register.yank = original_yank
    H.assert_eq(yanked, { ws .. '/child/inside.txt' },
      'yank consumes the restored child path')
  end)

  H.it('tampered redone child rows refuse open before switching buffers', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.txt', { 'child contents' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    local child_path = ws .. '/child/inside.txt'
    vim.api.nvim_buf_set_text(bufnr, 1, 2, 1, #'  inside.txt', { 'changed.txt' })
    local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local fs_before = H.fs_snapshot(ws)
    local opened, open_err = listing:open('  changed.txt')
    H.assert_nil(opened, 'open refuses the stale child path')
    H.assert_true(type(open_err) == 'string' and open_err ~= '', 'open explains the refusal')
    H.assert_eq(vim.api.nvim_get_current_buf(), bufnr, 'refused open does not switch buffers')
    H.assert_eq(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines_before,
      'refused operations do not rewrite the listing')
    H.assert_eq(H.fs_snapshot(ws), fs_before, 'refused operations do not change the filesystem')
    H.assert_true(fs.stat(child_path) ~= nil, 'the original child remains available')
  end)

  H.it('tampered redone child rows refuse get_paths and yank before register effects', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.txt', { 'child contents' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    vim.api.nvim_buf_set_text(bufnr, 1, 2, 1, #'  inside.txt', { 'changed.txt' })
    local fs_before = H.fs_snapshot(ws)
    local register = require('direct.register')
    local register_before = register.content()
    local original_yank, yank_calls = register.yank, 0
    register.yank = function(...)
      yank_calls = yank_calls + 1
      return original_yank(...)
    end

    local paths, path_err = listing:get_paths(2, 2)
    local yank_ok, yank_result = pcall(require('direct').yank, 2, 2)
    register.yank = original_yank

    H.assert_nil(paths, 'get_paths refuses text that no longer matches its child record')
    H.assert_true(type(path_err) == 'string' and path_err ~= '', 'get_paths explains the refusal')
    H.assert_true(yank_ok, tostring(yank_result))
    H.assert_nil(yank_result, 'yank refuses the stale child path')
    H.assert_eq(yank_calls, 0, 'refused child rows never reach register.yank')
    H.assert_eq(vim.api.nvim_get_current_buf(), bufnr, 'refused yank keeps the direct buffer')
    H.assert_eq(H.fs_snapshot(ws), fs_before, 'refused yank does not change the filesystem')
    H.assert_eq(register.content(), register_before,
      'refused operations do not change register state')
  end)

  H.it('fails closed when redone child text is tampered before any sync effects', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkfile(ws, 'a/inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'tampered.txt' })

    local register = require('direct.register')
    local original_yank, yank_calls = register.yank, 0
    register.yank = function(...) yank_calls = yank_calls + 1; return original_yank(...) end
    local yank_call_ok, yank_result = pcall(require('direct').yank, 2, 2)
    local open_result = listing:open('  tampered.txt')
    register.yank = original_yank
    H.assert_true(yank_call_ok, tostring(yank_result))
    H.assert_nil(yank_result, 'yank rejects text that no longer matches the child identity')
    H.assert_eq(yank_calls, 0, 'tampered child text does not reach the register')
    H.assert_nil(open_result, 'open rejects text that no longer matches the child identity')

    local before_fs = H.fs_snapshot(ws)
    local before_register = register.content()
    local before_undo, before_redo = history_lines('undo.log'), history_lines('redo.log')
    local classified, yanked = 0, 0
    local classify, yank = buffer.classify, register.yank
    buffer.classify = function(...) classified = classified + 1; return classify(...) end
    register.yank = function(...) yanked = yanked + 1; return yank(...) end

    local ok, reason = listing:sync()

    buffer.classify, register.yank = classify, yank
    H.assert_nil(ok, 'tampered redone child text is refused')
    H.assert_true(type(reason) == 'string' and reason ~= '',
      'refusal explains why the redone row is unsafe')
    H.assert_eq(classified, 0, 'tampering stops before root classification')
    H.assert_eq(yanked, 0, 'tampering stops before register effects')
    H.assert_eq(H.fs_snapshot(ws), before_fs, 'tampering has no filesystem effects')
    H.assert_eq(register.content(), before_register, 'tampering leaves register state unchanged')
    H.assert_eq(history_lines('undo.log'), before_undo, 'tampering writes no undo history')
    H.assert_eq(history_lines('redo.log'), before_redo, 'tampering writes no redo history')
  end)

  H.it('does not recover a redo against a changed directory tree snapshot', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local a = H.mkdir(ws, 'a')
    H.mkfile(a, 'inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    listing:expand(1)
    vim.cmd('undo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.mkfile(a, 'added-while-undone.txt', { 'new tree state' })
    vim.cmd('redo')
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

    local before_fs = H.fs_snapshot(ws)
    local before_register = register.content()
    local before_undo, before_redo = history_lines('undo.log'), history_lines('redo.log')
    local classified, yanked = 0, 0
    local classify, yank = buffer.classify, register.yank
    buffer.classify = function(...) classified = classified + 1; return classify(...) end
    register.yank = function(...) yanked = yanked + 1; return yank(...) end

    local yank_call_ok, yank_result = pcall(require('direct').yank, 2, 2)
    local open_result = listing:open('  inside.txt')
    H.assert_true(yank_call_ok, tostring(yank_result))
    H.assert_nil(yank_result, 'ambiguous redo blocks child yanking')
    H.assert_nil(open_result, 'ambiguous redo blocks child opening')
    H.assert_eq(yanked, 0, 'ambiguous redo has no register effect')

    local ok, reason = listing:sync()

    buffer.classify, register.yank = classify, yank
    H.assert_nil(ok, 'redo with a changed directory snapshot is ambiguous and refused')
    H.assert_true(type(reason) == 'string' and reason ~= '',
      'the refusal explains why recovery was unsafe')
    H.assert_eq(classified, 0, 'ambiguous recovery stops before root classification')
    H.assert_eq(yanked, 0, 'ambiguous recovery stops before register effects')
    H.assert_eq(H.fs_snapshot(ws), before_fs, 'ambiguous recovery has no filesystem effects')
    H.assert_eq(register.content(), before_register, 'ambiguous recovery leaves register state unchanged')
    H.assert_eq(history_lines('undo.log'), before_undo, 'ambiguous recovery writes no undo history')
    H.assert_eq(history_lines('redo.log'), before_redo, 'ambiguous recovery writes no redo history')
  end)

  H.it('keeps an un-undone child identity and syncs its later edit', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkdir(ws, 'b')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'a/inside-a.txt', { 'a' })
    H.mkfile(ws, 'b/inside-b.txt', { 'b' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local state = buffer._state_for_test(bufnr)

    listing:expand(1)
    local a_id = state.expanded[state.root_ids[1]].children[1].id
    listing:expand(3)
    vim.cmd('undo')
    H.assert_buf_eq({ 'a/', '  inside-a.txt', 'b/', 'root.txt' }, 0,
      'undo removes only the latest b materialization')

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_feedkeys('ccrenamed.txt\27', 'xt', false)
    vim.api.nvim_buf_set_text(bufnr, 1, 2, 1, 2 + #'inside-a.txt', { 'tampered.txt' })
    local synced, reason = listing:sync()

    H.assert_true(synced == true, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), {
      'a/', 'a/tampered.txt', 'b/', 'b/inside-b.txt', 'renamed.txt',
    }, 'the visible subtree edit and root rename both apply')
    H.assert_true(fs.exists(ws .. '/a/tampered.txt'),
      'the changed child is present at its new path')
    H.assert_true(fs.exists(ws .. '/b/inside-b.txt'),
      'the hidden b subtree remains untouched')
  end)

  H.it('writes only root changes when undo removes one of multiple materializations', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkdir(ws, 'b')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'a/inside-a.txt', { 'a' })
    H.mkfile(ws, 'b/inside-b.txt', { 'b' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local state = buffer._state_for_test(vim.api.nvim_get_current_buf())

    listing:expand(1)
    local a_id = state.expanded[state.root_ids[1]].children[1].id
    listing:expand(3)
    vim.cmd('undo')
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    vim.api.nvim_feedkeys('ccrenamed.txt\27', 'xt', false)
    H.assert_eq(state.expanded[state.root_ids[1]].children[1].id, a_id,
      'the materialization not undone retains its child identity before save')

    local called, err = pcall(vim.cmd, 'write')
    H.wait_for_direct()

    H.assert_true(called, tostring(err))
    H.assert_eq(H.fs_snapshot(ws), {
      'a/', 'a/inside-a.txt', 'b/', 'b/inside-b.txt', 'renamed.txt',
    }, 'write applies only the root rename and no child row as a root action')
  end)

  H.it('undo after expanding keeps a prior root rename and write reconciles the view', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local state = buffer._state_for_test(bufnr)
    local root_id = state.root_ids[1]
    local before = H.fs_snapshot(ws)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys('ccrenamed.txt\27', 'xt', false)
    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '  inside.txt', 'renamed.txt' }, 0,
      'the unrelated directory is expanded after the root rename')
    H.assert_eq(H.fs_snapshot(ws), before, 'editing and expanding are view/buffer only')

    vim.cmd('undo')

    H.assert_buf_eq({ 'sub/', 'renamed.txt' }, 0,
      'undo removes only the materialized child rows, not the earlier rename')
    H.assert_eq(H.fs_snapshot(ws), before, 'undo has no filesystem effects')
    local called, err = pcall(vim.cmd, 'write')
    H.wait_for_direct()

    H.assert_true(called, tostring(err))
    H.assert_buf_eq({ 'sub/', 'renamed.txt' }, 0,
      'write keeps the coherent root-only view after materialization undo')
    H.assert_false(vim.bo.modified, 'successful write clears modified state')
    H.assert_eq(H.fs_snapshot(ws), { 'renamed.txt', 'sub/', 'sub/inside.txt' },
      "write applies only the user's root rename")
    state = buffer._state_for_test(vim.api.nvim_get_current_buf())
    H.assert_eq(listing:get_paths(1, 2), { ws .. '/sub/', ws .. '/renamed.txt' },
      'the surviving rows resolve as roots, not stale children')
    H.assert_nil(state.expanded[root_id], 'undone materialization is removed from saved state')
    H.assert_eq(#state.display_ids, #state.root_ids,
      'saved display identities contain roots only after reconciliation')
  end)

  H.it('undo without expanding still reverses a root filename edit', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys('ccrenamed.txt\27', 'xt', false)
    vim.cmd('undo')

    H.assert_buf_eq({ 'root.txt' }, 0, 'ordinary undo restores the root filename')
    H.assert_true(listing:sync() == true, 'write/sync remains valid after ordinary undo')
    H.assert_fs_eq(ws, { 'root.txt' }, 'ordinary undo causes no filesystem action')
  end)

  H.it('repeated expand and undo keeps child rows and identities coherent on write', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local state = buffer._state_for_test(bufnr)
    local root_id = state.root_ids[1]
    local first_child_id

    for iteration = 1, 2 do
      listing:expand(1)
      H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0,
        'each expand materializes exactly one child row')
      local child_id = state.expanded[root_id].children[1].id
      if iteration == 1 then
        first_child_id = child_id
      else
        H.assert_true(child_id ~= first_child_id,
          'repeated expansion creates a fresh child identity after undo')
      end
      vim.cmd('undo')
      H.assert_buf_eq({ 'sub/' }, 0, 'undo removes that expand independently')
      H.assert_fs_eq(ws, { 'sub/', 'sub/inside.txt' },
        'view undo and write do not change filesystem entries')
    end

    local ok, err = pcall(vim.cmd, 'write')
    H.wait_for_direct()
    H.assert_true(ok, tostring(err))
    H.assert_buf_eq({ 'sub/' }, 0, 'write keeps the root-only view coherent')
    state = buffer._state_for_test(vim.api.nvim_get_current_buf())
    H.assert_eq(#state.display_ids, #state.root_ids,
      'saved identities contain roots only after undo reconciliation')
    H.assert_fs_eq(ws, { 'sub/', 'sub/inside.txt' },
      'writing after repeated view undo does not change filesystem entries')
    H.assert_eq(listing:get_paths(1, 1), { ws .. '/sub/' },
      'the remaining row retains its root path identity')
    H.assert_nil(state.expanded[root_id], 'no abandoned expansion remains')
  end)

  H.it('undoes multiple independent materializations in order without stale child state', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkdir(ws, 'b')
    H.mkfile(ws, 'a/inside-a.txt', { 'a' })
    H.mkfile(ws, 'b/inside-b.txt', { 'b' })
    route_write_to_test_buffer()
    local listing = buffer.list(ws)

    listing:expand(1)
    listing:expand(3)
    H.assert_buf_eq({ 'a/', '  inside-a.txt', 'b/', '  inside-b.txt' }, 0,
      'each directory has an independent materialization')
    vim.cmd('undo')
    H.assert_buf_eq({ 'a/', '  inside-a.txt', 'b/' }, 0,
      'the first undo removes only the most recent directory children')
    vim.cmd('undo')
    H.assert_buf_eq({ 'a/', 'b/' }, 0,
      'the next undo removes the earlier materialization')
    H.assert_fs_eq(ws, { 'a/', 'a/inside-a.txt', 'b/', 'b/inside-b.txt' },
      'view undo has no filesystem effects')

    local called, err = pcall(vim.cmd, 'write')
    H.wait_for_direct()
    H.assert_true(called, tostring(err))
    H.assert_buf_eq({ 'a/', 'b/' }, 0, 'write retains the coherent root listing')
    local state = buffer._state_for_test(vim.api.nvim_get_current_buf())
    H.assert_eq(#state.display_ids, #state.root_ids,
      'all undone child identities are removed from saved display state')
    H.assert_eq(H.fs_snapshot(ws), { 'a/', 'a/inside-a.txt', 'b/', 'b/inside-b.txt' },
      'write does not interpret view rows as filesystem edits')
  end)

  H.it('syncs a root file rename while clean child baselines are loaded', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local classified
    local classify = buffer.classify
    buffer.classify = function(actual, expected)
      classified = { vim.deepcopy(actual), vim.deepcopy(expected) }
      return classify(actual, expected)
    end
    vim.api.nvim_buf_set_text(0, 2, 0, 2, #('root.txt'), { 'renamed.txt' })

    local ok, err = listing:sync()
    buffer.classify = classify

    H.assert_true(ok == true, tostring(err))
    H.assert_eq(classified[1], { 'sub/', 'renamed.txt' },
      'only depth-zero rows are classifier input')
    H.assert_eq(classified[2], { 'sub/', 'root.txt' }, 'expected is root-only')
    H.assert_fs_eq(ws, { 'renamed.txt', 'sub/', 'sub/inside.txt' })
    H.assert_buf_eq({ 'sub/', '  inside.txt', 'renamed.txt' }, 0)
    H.assert_eq(listing:get_paths(2, 2), { ws .. '/sub/inside.txt' },
      'child identity survives full refresh')

    vim.api.nvim_buf_set_lines(0, 2, 3, false, {})
    H.assert_true(listing:sync() == true, 'a root-file delete remains supported')
    H.assert_false(fs.exists(ws .. '/renamed.txt'), 'root file was deleted')
    local content = register.content()
    H.assert_not_nil(content, 'normal unblocked root deletes still auto-yank')
    H.assert_eq(vim.fn.readfile(content .. '/renamed.txt'), { 'root' },
      'root file contents were auto-yanked')
  end)

  H.it('root rename undo then :write preserves unchanged child identities', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'root.txt', { 'root' })
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    local listing = require('direct').list(ws)
    listing:expand(1)
    local materialization_seq = vim.fn.undotree().seq_cur

    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_feedkeys('ccrenamed.txt\27', 'xt', false)
    H.assert_buf_eq({ 'sub/', '  inside.txt', 'renamed.txt' }, 0,
      'normal-mode editing renames the root entry')
    vim.cmd('undo')
    H.assert_buf_eq({ 'sub/', '  inside.txt', 'root.txt' }, 0,
      'undo restores the root filename before writing')
    H.assert_eq(vim.fn.undotree().seq_cur, materialization_seq,
      'undo returns to the child materialization history baseline')

    local ok, err = pcall(vim.cmd, 'write')
    H.wait_for_direct()

    H.assert_true(ok, tostring(err))
    H.assert_buf_eq({ 'sub/', '  inside.txt', 'root.txt' }, 0,
      'the root-only save keeps the materialized display')
    H.assert_false(vim.bo.modified, 'successful :write marks the listing clean')
    H.assert_fs_eq(ws, { 'root.txt', 'sub/', 'sub/inside.txt' },
      'undo recovery does not change filesystem entries')
    H.assert_eq(listing:get_paths(2, 2), { ws .. '/sub/inside.txt' },
      'recovered row identity still resolves its child path')
  end)

  H.it('root rename undo with a duplicate or mismatched child fails closed', function()
    for _, hostile in ipairs({ 'duplicate', 'mismatch' }) do
      clean_buffers()
      local sb = H.sandbox()
      local ws = H.mkdir(sb.root, 'ws')
      H.mkdir(ws, 'sub')
      H.mkfile(ws, 'root.txt', { 'root' })
      H.mkfile(ws, 'sub/inside.txt', { 'inside' })
      local listing = buffer.list(ws)
      listing:expand(1)
      vim.cmd('let &undolevels = &undolevels')
      vim.api.nvim_buf_set_text(0, 2, 0, 2, #('root.txt'), { 'renamed.txt' })
      vim.cmd('undo')
      if hostile == 'duplicate' then
        vim.api.nvim_buf_set_lines(0, 2, 2, false, { '  inside.txt' })
      else
        vim.api.nvim_buf_set_text(0, 1, 2, 1, #('  inside.txt'), { '  changed.txt' })
      end

      local classified = 0
      local classify = buffer.classify
      buffer.classify = function(...) classified = classified + 1; return classify(...) end
      local ok, reason = listing:sync()
      buffer.classify = classify

      H.assert_nil(ok, hostile .. ' child baseline is refused')
      H.assert_true(tostring(reason):find('child', 1, true) ~= nil
        or tostring(reason):find('identity', 1, true) ~= nil, tostring(reason))
      H.assert_eq(classified, 0, hostile .. ' damage stops before classification')
      H.assert_true(vim.bo.modified, hostile .. ' refusal keeps the buffer modified')
      H.assert_fs_eq(ws, { 'root.txt', 'sub/', 'sub/inside.txt' },
        hostile .. ' damage has no filesystem effects')
    end
  end)

  H.it('recovers a reported-invalid direct child mark before root-only sync', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(sub, 'nested')
    H.mkfile(sub, 'sibling.txt', { 'sibling' })
    H.mkfile(sub .. '/nested', 'deep.txt', { 'deep' })
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)
    listing:expand(1)
    listing:expand(2)
    H.assert_buf_eq({
      'sub/', '  nested/', '    deep.txt', '  sibling.txt', 'root.txt',
    }, 0, 'the full ordered child subtree is materialized')

    local bufnr = vim.api.nvim_get_current_buf()
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local child_mark = vim.api.nvim_buf_get_extmarks(bufnr, namespace,
      { 1, 0 }, { 1, -1 }, {})[1]
    H.assert_not_nil(child_mark, 'the direct child has a real row identity')
    local invalid_id = child_mark[1]
    local state = buffer._state_for_test(bufnr)
    local root_id = state.root_ids[1]
    local direct_child = state.expanded[root_id].children[1]
    local sibling = state.expanded[root_id].children[2]
    local grandchild = state.expanded[direct_child.id].children[1]
    H.assert_eq(direct_child.id, invalid_id, 'the simulated invalid identity is the first child')
    H.assert_eq(direct_child.parent, root_id, 'direct child retains its root parent')
    H.assert_eq(direct_child.order, 1, 'first child order is materialized')
    H.assert_eq(sibling.parent, root_id, 'sibling retains the same root parent')
    H.assert_eq(sibling.order, 2, 'sibling order is materialized')
    H.assert_eq(grandchild.parent, direct_child.id, 'nested child retains its direct parent')
    H.assert_eq(grandchild.text, '    deep.txt', 'nested child text is unchanged')
    local original_get_extmarks = vim.api.nvim_buf_get_extmarks
    local original_set_extmark = vim.api.nvim_buf_set_extmark
    local original_classify = buffer.classify
    local restored = false
    local classified_actual, classified_expected
    vim.api.nvim_buf_get_extmarks = function(mark_buf, ns, first, last, opts)
      local marks = original_get_extmarks(mark_buf, ns, first, last, opts)
      if mark_buf == bufnr and ns == namespace then
        for _, mark in ipairs(marks) do
          if mark[1] == invalid_id then
            mark[4] = vim.tbl_extend('force', mark[4] or {}, { invalid = true })
          end
        end
      end
      return marks
    end
    vim.api.nvim_buf_set_extmark = function(mark_buf, ns, row, col, opts)
      if mark_buf == bufnr and ns == namespace and opts.id == invalid_id
        and row == 1 then
        restored = true
      end
      return original_set_extmark(mark_buf, ns, row, col, opts)
    end

    -- Keep this valid root rename in the materialization undo block. The
    -- reported-invalid mark is injected below, independently of Neovim's
    -- version-specific natural invalidation behavior.
    local materialization_seq = vim.fn.undotree().seq_cur
    vim.cmd('undojoin')
    vim.api.nvim_buf_set_text(bufnr, 4, 0, 4, #('root.txt'), { 'renamed.txt' })
    H.assert_eq(vim.fn.undotree().seq_cur, materialization_seq,
      'the root-only operation remains at the materialization undo baseline')

    buffer.classify = function(actual, expected)
      classified_actual, classified_expected = vim.deepcopy(actual), vim.deepcopy(expected)
      local mark = original_get_extmarks(bufnr, namespace, 0, -1, { details = true })
      local recovered_mark
      for _, entry in ipairs(mark) do
        if entry[1] == invalid_id then recovered_mark = entry; break end
      end
      H.assert_not_nil(recovered_mark, 'child identity exists before classification')
      H.assert_true(not (recovered_mark[4] and recovered_mark[4].invalid),
        'recovered identity is valid before classification')
      H.assert_eq(recovered_mark[2], 1, 'identity is restored to its baseline row')
      return original_classify(actual, expected)
    end
    local ok, sync_result, sync_err = pcall(function() return listing:sync() end)
    vim.api.nvim_buf_get_extmarks = original_get_extmarks
    vim.api.nvim_buf_set_extmark = original_set_extmark
    buffer.classify = original_classify
    H.assert_true(ok, tostring(sync_result))
    H.assert_true(sync_result == true, tostring(sync_err))

    H.assert_true(restored, 'sync restored the actual direct-namespace child mark')
    H.assert_eq(classified_actual, { 'sub/', 'renamed.txt' },
      'only root rows reach the classifier')
    H.assert_eq(classified_expected, { 'sub/', 'root.txt' },
      'disk comparison contains root rows only')
    H.assert_fs_eq(ws, { 'renamed.txt', 'sub/', 'sub/nested/',
      'sub/nested/deep.txt', 'sub/sibling.txt' }, 'the root rename applied')
    H.assert_buf_eq({
      'sub/', '  nested/', '    deep.txt', '  sibling.txt', 'renamed.txt',
    }, 0, 'unchanged child rows remain expanded and intact')
    H.assert_eq(listing:get_paths(3, 3), { ws .. '/sub/nested/deep.txt' },
      'nested child identity still resolves to its parent path')
  end)

  H.it('duplicate reported-invalid child marks fail closed before classification', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local bufnr = vim.api.nvim_get_current_buf()
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local child_mark = vim.api.nvim_buf_get_extmarks(bufnr, namespace,
      { 1, 0 }, { 1, -1 }, {})[1]
    local original_get_extmarks = vim.api.nvim_buf_get_extmarks
    vim.api.nvim_buf_get_extmarks = function(mark_buf, ns, first, last, opts)
      local marks = original_get_extmarks(mark_buf, ns, first, last, opts)
      if mark_buf == bufnr and ns == namespace then
        for _ = 1, 2 do
          marks[#marks + 1] = {
            child_mark[1], child_mark[2], child_mark[3], { invalid = true },
          }
        end
      end
      return marks
    end
    local classified, yanked = 0, 0
    local original_classify, original_yank = buffer.classify, register.yank
    local register_before = register.content()
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    buffer.classify = function(...) classified = classified + 1; return original_classify(...) end
    register.yank = function(...) yanked = yanked + 1; return original_yank(...) end
    local called, sync_result, reason = pcall(function() return listing:sync() end)
    vim.api.nvim_buf_get_extmarks = original_get_extmarks
    buffer.classify, register.yank = original_classify, original_yank

    H.assert_true(called, tostring(sync_result))
    H.assert_nil(sync_result, 'duplicate invalid identities are refused')
    H.assert_true(tostring(reason):find('identity', 1, true) ~= nil, tostring(reason))
    H.assert_eq(classified, 0, 'malformed identity report stops before classification')
    H.assert_eq(yanked, 0, 'malformed identity report stops before auto-yank')
    H.assert_true(vim.bo[bufnr].modified, 'refusal keeps the buffer modified')
    H.assert_fs_eq(ws, { 'root.txt', 'sub/', 'sub/inside.txt' },
      'malformed identity report has no filesystem effects')
    H.assert_eq(register.content(), register_before, 'malformed identity leaves register unchanged')
    H.assert_eq(history_lines('undo.log'), undo_before, 'malformed identity writes no undo history')
    H.assert_eq(history_lines('redo.log'), redo_before, 'malformed identity leaves redo history unchanged')
  end)

  H.it('Windows path components reject device names and trailing dot/space aliases', function()
    local invalid = {
      'CON', 'con.txt', 'PRN.log', 'AUX', 'NUL.txt', 'COM1', 'LPT9.ext',
      'CON ', 'nul.txt ', 'CON.', 'normal.txt.',
    }
    for _, name in ipairs(invalid) do
      H.assert_not_nil(buffer._component_reason(name, 'win32'), name .. ' is unsafe on Windows')
    end
    for _, name in ipairs({ 'normal.txt', 'console.txt', 'COM10.txt', 'NULish' }) do
      H.assert_nil(buffer._component_reason(name, 'win32'), name .. ' is a valid non-device name')
    end
    H.assert_nil(buffer._component_reason('literal\\name', 'posix'),
      'POSIX backslashes remain literal')
    for _, name in ipairs({ 'nested/CON.txt', 'nested/trailing.', 'nested/trailing ' }) do
      H.assert_not_nil(buffer._nested_path_reason(name, 'win32'),
        name .. ' has an unsafe nested Windows component')
    end
    H.assert_nil(buffer._nested_path_reason('nested/normal.txt', 'win32'),
      'a normal nested Windows path is valid')
  end)

  H.it('renames and deletes a root directory while descendants are expanded', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local register_calls, fs_mutations, classified = 0, 0, {}
    local yank, classify = register.yank, buffer.classify
    local mutation_names = { 'rename', 'rename_noreplace', 'copy_file',
      'copy_tree', 'rm_tree', 'mkdirp' }
    local original_fs = {}
    for _, name in ipairs(mutation_names) do
      local method_name = name
      original_fs[method_name] = fs[method_name]
      fs[method_name] = function(...)
        fs_mutations = fs_mutations + 1
        return original_fs[method_name](...)
      end
    end
    register.yank = function() register_calls = register_calls + 1; return true end
    local register_before = register.content()
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    fs_mutations = 0
    buffer.classify = function(actual, expected)
      local plan = classify(actual, expected)
      classified[#classified + 1] = {
        actual = vim.deepcopy(actual), expected = vim.deepcopy(expected), plan = plan,
      }
      return plan
    end
    vim.api.nvim_buf_set_text(0, 0, 0, 0, #('sub/'), { 'other/' })
    local renamed, rename_err = listing:sync()
    H.assert_true(renamed == true, tostring(rename_err))
    H.assert_true(fs.exists(ws .. '/other'), 'the directory rename is applied')
    H.assert_buf_eq({ 'other/', '  inside.txt', 'root.txt' }, 0,
      'the renamed directory remains expanded after sync')
    H.assert_eq(listing:get_paths(2, 2), { ws .. '/other/inside.txt' },
      'the retained child identity resolves through the renamed directory')

    -- Restore the spelling, then delete the marked root row while retaining its
    -- materialized child. Its row identity still protects the subtree from root
    -- classification, while deleting the directory owns the entire tree.
    vim.api.nvim_buf_set_text(0, 0, 0, 0, #('other/'), { 'sub/' })
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    local deleted, delete_err = listing:sync()
    buffer.classify, register.yank = classify, yank
    for _, name in ipairs(mutation_names) do fs[name] = original_fs[name] end
    H.assert_eq(classified[1].actual, { 'other/', 'root.txt' },
      'rename classification receives root rows only')
    H.assert_eq(classified[1].expected, { 'sub/', 'root.txt' },
      'expected entries are root rows only')
    H.assert_eq(classified[1].plan.kind, 'RENAME', 'classifier proposes the rename')
    H.assert_eq(classified[1].plan.moves,
      { { src = 'sub/', dst = 'other/' } }, 'classified root rename')
    H.assert_false(fs.exists(ws .. '/other'), 'the selected directory was removed')
    H.assert_true(deleted == true, tostring(delete_err))
    H.assert_eq(classified[2].actual, { 'root.txt' },
      'deletion classification excludes loaded children and deleted root')
    H.assert_eq(classified[2].expected, { 'other/', 'root.txt' },
      'delete classification compares the root listing')
    H.assert_eq(classified[2].plan.kind, 'DELETE', 'classifier proposes the delete')
    H.assert_eq(classified[2].plan.removed, { 'other/' }, 'classified root deletion')
    H.assert_eq(register_calls, 1, 'the tree deletion is auto-yanked once')
    H.assert_true(fs_mutations > 0, 'the directory rename and delete mutate the filesystem')
    H.assert_eq(register.content(), register_before, 'blocked batches preserve register state')
    H.assert_fs_eq(ws, { 'root.txt' }, 'the expanded tree is deleted')
    H.assert_false(vim.bo.modified, 'successful sync clears modified state')
    H.assert_true(#history_lines('undo.log') > #undo_before,
      'the rename and directory removal are recorded in history')
    H.assert_true(#history_lines('redo.log') >= #redo_before,
      'history redo state remains well-formed')
  end)

  H.it('malformed child structure and damaged identities refuse before classification', function()
    local cases = {
      { name = 'duplicate child', edit = function()
        vim.api.nvim_buf_set_lines(0, 2, 2, false, { '  inside.txt' })
      end },
      { name = 'odd indentation', edit = function()
        vim.api.nvim_buf_set_lines(0, 2, 2, false, { '   malformed.txt' })
      end },
      { name = 'lost identity', edit = function()
        local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
        vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
      end },
      { name = 'duplicate identity position', edit = function()
        local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
        vim.api.nvim_buf_set_extmark(0, ns, 1, 0, { id = 1000 })
      end },
    }
    for _, case in ipairs(cases) do
      clean_buffers()
      local sb = H.sandbox()
      local ws = H.mkdir(sb.root, 'ws')
      H.mkdir(ws, 'sub')
      H.mkfile(ws, 'sub/inside.txt', { 'inside' })
      H.mkfile(ws, 'root.txt', { 'root' })
      local listing = buffer.list(ws)
      listing:expand(1)
      case.edit()
      local classified, yanked = 0, 0
      local classify, yank = buffer.classify, register.yank
      buffer.classify = function(...) classified = classified + 1; return classify(...) end
      register.yank = function() yanked = yanked + 1; return true end
      local ok, reason = listing:sync()
      buffer.classify, register.yank = classify, yank
      H.assert_nil(ok, case.name .. ' was refused')
      H.assert_true(tostring(reason):find('child', 1, true) ~= nil
        or tostring(reason):find('identity', 1, true) ~= nil,
        case.name .. ': ' .. tostring(reason))
      H.assert_eq(classified, 0, case.name .. ' stops before classifier')
      H.assert_eq(yanked, 0, case.name .. ' stops before auto-yank')
      H.assert_true(vim.bo.modified, case.name .. ' remains modified')
      H.assert_fs_eq(ws, { 'root.txt', 'sub/', 'sub/inside.txt' },
        case.name .. ' has no filesystem effects')
      H.assert_eq(history_lines('undo.log'), {}, case.name .. ' writes no history')
    end
  end)

  H.it('deleting an expanded root directory removes and auto-yanks its whole tree', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)
    listing:expand(1)
    -- Removing only the directory row means the directory action owns its
    -- materialized descendants; no child rows are classified as root entries.
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    local yanked, classified = 0, 0
    local classified_actual, classified_expected, plan
    local classify, yank = buffer.classify, register.yank
    buffer.classify = function(actual, expected)
      classified = classified + 1
      classified_actual, classified_expected = vim.deepcopy(actual), vim.deepcopy(expected)
      plan = classify(actual, expected)
      return plan
    end
    register.yank = function() yanked = yanked + 1; return true end
    local ok = listing:sync()
    buffer.classify, register.yank = classify, yank

    H.assert_true(ok == true, 'expanded directory deletion succeeds')
    H.assert_eq(classified, 1, 'root deletion is classified after root identity loss')
    H.assert_eq(classified_actual, { 'root.txt' }, 'only root rows reach classifier')
    H.assert_eq(classified_expected, { 'sub/', 'root.txt' }, 'expected root rows only')
    H.assert_eq(plan.kind, 'DELETE', 'classifier proposes deleting loaded directory')
    H.assert_eq(plan.removed, { 'sub/' }, 'classifier identifies deleted root directory')
    H.assert_eq(yanked, 1, 'directory deletion is auto-yanked once')
    H.assert_fs_eq(ws, { 'root.txt' }, 'only the selected directory tree is removed')
    H.assert_nil(register.content(), 'the stub yank leaves the register pointer untouched')
    H.assert_true(#history_lines('undo.log') > 0, 'the directory removal is undoable')
    H.assert_true(#history_lines('redo.log') > 0, 'redo history remains initialized')
    H.assert_false(vim.bo.modified, 'successful sync clears modified state')
  end)

  H.it('deleting all materialized rows of a directory emits one tree removal', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    local listing = buffer.list(ws)
    listing:expand(1)
    vim.api.nvim_buf_set_lines(0, 0, 2, false, {})
    local yank_calls, yanked = 0, nil
    local yank = register.yank
    register.yank = function(paths)
      yank_calls = yank_calls + 1
      yanked = vim.deepcopy(paths)
      return true
    end

    local ok, reason = listing:sync()

    register.yank = yank
    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(yank_calls, 1, 'the whole tree is yanked once')
    H.assert_eq(yanked, { ws .. '/sub/' }, 'only the directory root is auto-yanked')
    H.assert_fs_eq(ws, { 'root.txt' }, 'one directory removal covers its children')
    local undo = history_lines('undo.log')
    H.assert_eq(#undo, 2, 'one rmdir action is recorded, not duplicate child removals')
    H.assert_eq(decode_record(undo, 2).src, ws .. '/sub/',
      'history contains the directory-tree removal')
  end)

  H.it('root deletion followed by same-text reinsertion does not revive its identity', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    listing:expand(1)

    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'sub/' })
    local classified, actual, expected = 0, nil, nil
    local classify = buffer.classify
    buffer.classify = function(root_actual, root_expected)
      classified = classified + 1
      actual, expected = vim.deepcopy(root_actual), vim.deepcopy(root_expected)
      return classify(root_actual, root_expected)
    end
    local ok, err = listing:sync()
    buffer.classify = classify

    H.assert_true(ok == true, tostring(err))
    H.assert_eq(classified, 1, 'same-text reinserted root is classified normally')
    H.assert_eq(actual, { 'sub/' }, 'only the reinserted root row reaches classification')
    H.assert_eq(expected, { 'sub/' }, 'disk comparison remains root-only')
    H.assert_buf_eq({ 'sub/' }, 0,
      'reinserted text gets a fresh identity instead of inheriting stale children')
    H.assert_fs_eq(ws, { 'sub/', 'sub/inside.txt' }, 'no filesystem action was needed')
  end)

  H.it('refuses an unidentifiable root row after text undo/redo', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'original' })
    local listing = buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    vim.b[bufnr].direct_text_undo_mode = true
    vim.bo[bufnr].modified = true

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'missing identity is not guessed from row position or spelling')
    H.assert_true(tostring(reason):find('identity', 1, true) ~= nil, tostring(reason))
    H.assert_true(tostring(reason):find(':DirectList!', 1, true) ~= nil
      and tostring(reason):find('redo the change', 1, true) ~= nil,
      'the refusal gives a clear recovery path')
    H.assert_false(tostring(reason):find('re-list this directory', 1, true) ~= nil,
      'the refusal does not suggest a refresh that would discard the edits')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(ws, 'a.txt')), { 'original' },
      'the filesystem is unchanged')
    H.assert_eq(history_lines('undo.log'), {}, 'no history is written')
    H.assert_true(vim.bo[bufnr].modified, 'the row remains available for review')
  end)

  H.it('root containment guard rejects traversal paths before classification', function()
    for _, malicious in ipairs({ '../escaped' }) do
      clean_buffers()
      local sb = H.sandbox()
      local ws = H.mkdir(sb.root, 'ws')
      local listing = buffer.list(ws)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { malicious })
      local classified = 0
      local classify = buffer.classify
      buffer.classify = function(...) classified = classified + 1; return classify(...) end
      local ok, reason = listing:sync()
      buffer.classify = classify
      H.assert_nil(ok, malicious .. ' is rejected')
      H.assert_true(tostring(reason):find('component', 1, true) ~= nil,
        malicious .. ': ' .. tostring(reason))
      H.assert_eq(classified, 0, 'path guard precedes classification')
      H.assert_false(fs.exists(sb.root .. '/escaped'), 'parent traversal did not escape')
      H.assert_false(fs.exists(ws .. '/x'), 'nested component was not created')
      H.assert_eq(history_lines('undo.log'), {}, 'unsafe input writes no history')
    end
  end)

  H.it('root containment guard still rejects nested rename destinations', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', { 'old' })
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_text(0, 0, 1, 0, #('old.txt'), { '/new.txt' })
    local classified = 0
    local classify = buffer.classify
    buffer.classify = function(...) classified = classified + 1; return classify(...) end
    local ok, reason = listing:sync()
    buffer.classify = classify
    H.assert_nil(ok, 'a rename cannot use a nested destination')
    H.assert_true(tostring(reason):find('component', 1, true) ~= nil, tostring(reason))
    H.assert_eq(classified, 0, 'path guard precedes rename classification')
    H.assert_true(fs.exists(ws .. '/old.txt'), 'rename source remains intact')
    H.assert_false(fs.exists(ws .. '/o'), 'nested rename did not create a directory')
    H.assert_eq(history_lines('undo.log'), {}, 'unsafe rename writes no history')
  end)

  H.it('refuses root-level names beginning with whitespace', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { ' spaced.txt' })
    local ok, reason = listing:sync()
    H.assert_nil(ok, 'leading whitespace cannot be confused with child indentation')
    H.assert_true(tostring(reason):find('whitespace', 1, true) ~= nil, tostring(reason))
    H.assert_false(fs.exists(ws .. '/ spaced.txt'), 'no leading-space path is created')
  end)

  H.it('accepts the single directory marker', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'dir/' })
    H.assert_true(listing:sync() == true, 'dir/ is a valid directory component')
    H.assert_true(fs.is_dir(ws .. '/dir'), 'directory created')
  end)

  H.it('accepts POSIX literal backslashes in filename components', function()
    if H.is_windows() then
      H.skip('a backslash is a path separator on Windows, not a literal filename byte')
    end
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'literal\\name' })
    H.assert_true(listing:sync() == true, 'POSIX backslash is a legal literal')
    H.assert_true(fs.is_file(ws .. '/literal\\name'), 'literal backslash file created')
  end)
end)
