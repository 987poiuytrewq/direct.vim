-- buffer_rows_spec.lua -- row identity, rendering, and stale-state safety.
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
  pcall(H.symlink, target, link)
  return vim.uv.fs_lstat(link) ~= nil
end


H.describe('buffer: row identity and filtered rendering', function()
  H.it('avoids full decoration redraws for in-place normal-mode edits', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'entry.txt', '')
    buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()

    local original = vim.api.nvim_buf_get_extmarks
    local calls = 0
    vim.api.nvim_buf_get_extmarks = function(...)
      calls = calls + 1
      return original(...)
    end
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'prefix-' })
    vim.api.nvim_buf_get_extmarks = original

    H.assert_eq(calls, 1,
      'in-place edits inspect only the changed row instead of redrawing every row')
  end)

  H.it('skips insert-mode decoration refreshes when row count is unchanged', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'entry.txt', '')
    buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { 'renamed-' })

    local original = vim.api.nvim_buf_get_extmarks
    local calls = 0
    vim.api.nvim_buf_get_extmarks = function(...)
      calls = calls + 1
      return original(...)
    end
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
    vim.api.nvim_buf_get_extmarks = original

    H.assert_eq(calls, 0,
      'same-line insert edits do not rebuild row highlights and icons')
  end)

  H.it('nested directories reveal only their immediate children when expanded', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(sub, 'nested')
    H.mkfile(sub, 'sibling.txt', { 'sibling' })
    H.mkfile(sub, 'nested/deep.txt', { 'deep' })
    local listing = buffer.list(ws)

    listing:expand(1)
    H.assert_buf_eq({ 'sub/', '  nested/', '  sibling.txt' }, 0,
      'the root expand is exactly one level')
    listing:expand(2)
    H.assert_buf_eq({ 'sub/', '  nested/', '    deep.txt', '  sibling.txt' }, 0,
      'nested contents are materialized only on the nested directory')
    H.assert_eq(listing:get_paths(3, 3), { ws .. '/sub/nested/deep.txt' })
  end)

  H.it('child paths resolve through row identity for open and yank (Phase 1)', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    local direct = require('direct')
    local listing = direct.list(ws)
    listing:expand(1)

    H.assert_eq(listing:get_paths(2, 2), { ws .. '/sub/inside.txt' },
      'child path comes from its baseline, not root plus indentation')
    local register = require('direct.register')
    local original_yank = register.yank
    local yanked
    register.yank = function(sources) yanked = vim.deepcopy(sources); return true end
    local ok, err = pcall(direct.yank, 2, 2)
    register.yank = original_yank
    if not ok then error(err) end
    H.assert_eq(yanked, { ws .. '/sub/inside.txt' }, 'DirectYank uses child identity')

    direct.open('  inside.txt')
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/sub/inside.txt'),
      'open uses the child baseline path')
    H.assert_buf_eq({ 'inside' }, 0)
  end)

  H.it('preserves expanded root identity when refresh uses a resolved symlink alias', function()
    clean_buffers()
    local sb = H.sandbox()
    local real_parent = H.mkdir(sb.root, 'real-parent')
    local real = H.mkdir(real_parent, 'workdir')
    H.mkdir(real, 'a')
    H.mkfile(real, 'a/inside.txt', { 'child' })
    local link = sb.root .. '/link'
    H.assert_true(make_symlink(real_parent, link), 'created the symlinked prefix')
    local unresolved = link .. '/workdir'

    local listing = buffer.list(unresolved)
    listing:expand(1)
    H.assert_buf_eq({ 'a/', '  inside.txt' }, 0, 'initial listing is expanded')
    local bufnr = vim.api.nvim_get_current_buf()
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before_marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    local root_id, child_id = before_marks[1][1], before_marks[2][1]
    H.assert_true(listing.root ~= real, 'the initial listing retains unresolved root spelling')

    -- nvim stores the buffer's canonical spelling. Restore through that alias
    -- so list() compares the equivalent path against the unresolved saved path.
    local stored = vim.api.nvim_buf_get_name(bufnr)
    if H.is_windows() then
      H.assert_true(fs.same_path(stored, real), 'buffer name resolves to the alias target')
    else
      H.assert_eq(stored, real, 'buffer name is the resolved alias')
    end
    local refreshed = buffer.restore()
    refreshed:list()

    H.assert_buf_eq({ 'a/', '  inside.txt' }, 0,
      'the expanded child remains visible after refresh through the alias')
    local after_marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    H.assert_eq(after_marks[1][1], root_id, 'same root identity is reused')
    H.assert_eq(after_marks[2][1], child_id, 'same child identity is reused')
    H.assert_true(fs.same_path(refreshed:get_paths(2, 2)[1], real .. '/a/inside.txt'),
      'the retained child identity denotes the real directory entry')
  end)

  H.it('DirectYank preserves edits to a root row that matches another entry', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkdir(ws, 'b')
    H.mkfile(ws, 'a/inside.txt', { 'a child' })
    H.mkfile(ws, 'unrelated.txt', { 'unrelated' })
    local direct = require('direct')
    local listing = direct.list(ws)
    listing:expand(1)
    local before = H.fs_snapshot(ws)

    -- Keep the extmark identity for a/ while changing its visible spelling to
    -- b/. The real b/ row remains later in the buffer, making duplicate text.
    vim.api.nvim_buf_set_text(0, 0, 0, 0, 1, { 'b' })
    local register = require('direct.register')
    local original_yank = register.yank
    local yanked
    register.yank = function(sources) yanked = vim.deepcopy(sources); return true end
    local ok, err = pcall(vim.cmd, '4DirectYank')
    register.yank = original_yank
    if not ok then error(err) end

    H.assert_eq(yanked, { ws .. '/unrelated.txt' },
      ':DirectYank uses only the selected unrelated root file')
    H.assert_buf_eq({ 'b/', '  inside.txt', 'b/', 'unrelated.txt' }, 0,
      'yanking does not refresh and discard the modified listing')
    H.assert_true(vim.bo.modified, 'the user edit remains pending')
    H.assert_eq(H.fs_snapshot(ws), before,
      'yanking performs no filesystem actions')
  end)

  H.it('DirectYank preserves hostile duplicate rows in a modified listing', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'a')
    H.mkdir(ws, 'b')
    H.mkfile(ws, 'a/inside.txt', { 'a child' })
    H.mkfile(ws, 'unrelated.txt', { 'unrelated' })
    local direct = require('direct')
    local listing = direct.list(ws)
    listing:expand(1)
    local before = H.fs_snapshot(ws)

    vim.api.nvim_buf_set_text(0, 0, 0, 0, 1, { 'b' })
    -- Add another indistinguishable root row. Its lack of identity must not
    -- make the first edited row eligible to inherit a/'s loaded expansion.
    vim.api.nvim_buf_set_lines(0, 2, 2, false, { 'b/' })
    local register = require('direct.register')
    local original_yank = register.yank
    local yanked
    register.yank = function(sources) yanked = vim.deepcopy(sources); return true end
    local ok, err = pcall(vim.cmd, '5DirectYank')
    register.yank = original_yank
    if not ok then error(err) end

    H.assert_eq(yanked, { ws .. '/unrelated.txt' },
      ':DirectYank still resolves the unrelated file in an ambiguous listing')
    H.assert_buf_eq({ 'b/', '  inside.txt', 'b/', 'b/', 'unrelated.txt' }, 0,
      'yanking does not refresh and discard the modified listing')
    H.assert_true(vim.bo.modified, 'the user edits remain pending')
    H.assert_eq(H.fs_snapshot(ws), before,
      'yanking performs no filesystem actions')
  end)

  H.it('DirectYank discards expansions when distinct root names share a filesystem identity', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local target = H.mkdir(sb.root, 'shared-target')
    H.mkfile(target, 'child.txt', { 'shared child' })
    H.mkfile(ws, 'unrelated.txt', { 'unrelated' })
    local alias_a, alias_b = ws .. '/alias-a', ws .. '/alias-b'

    -- Prefer two real symlink spellings. Some platforms deny symlink creation
    -- to unprivileged test processes; there the fallback creates two directories
    -- and stubs only their identity fingerprints. Stat-failure fallback is tested
    -- independently through fs.same_path in fs_spec.
    local native_aliases = make_symlink(target, alias_a)
      and make_symlink(target, alias_b)
    local original_path_identity = fs.path_identity
    if not native_aliases then
      for _, alias in ipairs({ alias_a, alias_b }) do
        if vim.uv.fs_lstat(alias) then pcall(vim.uv.fs_unlink, alias) end
        vim.fn.mkdir(alias, 'p')
        H.mkfile(alias, 'child.txt', { 'shared child' })
      end
      local normalized_a = alias_a:gsub('/+$', '')
      local normalized_b = alias_b:gsub('/+$', '')
      fs.path_identity = function(path, st)
        local identity = original_path_identity(path, st)
        path = type(path) == 'string' and path:gsub('/+$', '') or path
        if path == normalized_a or path == normalized_b then
          identity.inode = 'test-shared-inode'
        end
        return identity
      end
    end

    local direct = require('direct')
    local listing = direct.list(ws)
    H.assert_buf_eq({ 'alias-a/', 'alias-b/', 'unrelated.txt' }, 0,
      'filesystem listing includes both distinct root spellings')
    H.assert_true(fs.same_path(alias_a, alias_b),
      'both root spellings have the same filesystem identity')
    if native_aliases then
      H.assert_eq(vim.uv.fs_readlink(alias_a), target, 'alias-a is a native symlink')
      H.assert_eq(vim.uv.fs_readlink(alias_b), target, 'alias-b is a native symlink')
    end

    listing:expand(1)
    H.assert_buf_eq({ 'alias-a/', '  child.txt', 'alias-b/', 'unrelated.txt' }, 0,
      'one alias has a materialized child before refresh')
    local bufnr = vim.api.nvim_get_current_buf()
    local namespace = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before_marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    local old_root_a, old_child, old_root_b =
      before_marks[1][1], before_marks[2][1], before_marks[3][1]
    H.assert_true(old_root_a ~= old_root_b and old_child ~= old_root_a
      and old_child ~= old_root_b, 'the two filesystem roots and child start with distinct identities')
    local before = H.fs_snapshot(ws)

    local register = require('direct.register')
    local original_yank = register.yank
    local yanked
    register.yank = function(sources) yanked = vim.deepcopy(sources); return true end
    local ok, err = pcall(vim.cmd, '4DirectYank')
    register.yank = original_yank
    fs.path_identity = original_path_identity
    if not ok then error(err) end

    H.assert_eq(yanked, { ws .. '/unrelated.txt' },
      ':DirectYank sends only the selected unrelated file to the register')
    H.assert_buf_eq({ 'alias-a/', 'alias-b/', 'unrelated.txt' }, 0,
      'refresh discards the ambiguous stale expansion')
    local after_marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {})
    H.assert_true(after_marks[1][1] ~= old_root_a and after_marks[1][1] ~= old_root_b,
      'alias-a receives a fresh root identity instead of either ambiguous old identity')
    H.assert_true(after_marks[2][1] ~= old_root_a and after_marks[2][1] ~= old_root_b,
      'alias-b receives a fresh root identity instead of either ambiguous old identity')
    H.assert_true(after_marks[1][1] ~= after_marks[2][1],
      'the distinct spellings retain distinct row identities')
    H.assert_eq(#after_marks, 3, 'the stale child identity is discarded from the refreshed rows')
    for _, mark in ipairs(after_marks) do
      H.assert_true(mark[1] ~= old_child,
        'the old child identity is not attached to another alias or row')
    end
    H.assert_eq(listing:get_paths(1, 2), { alias_a .. '/', alias_b .. '/' },
      'the refreshed root paths preserve their own spellings')
    H.assert_eq(H.fs_snapshot(ws), before,
      'refresh and yank do not modify filesystem entries')
  end)

  H.it('<CR> opens a nested listing and keeps the previous direct buffer', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    local direct = require('direct')
    direct.list(ws)
    local previous = vim.api.nvim_get_current_buf()

    vim.api.nvim_feedkeys('\r', 'mx', false)

    H.assert_buf_eq({ 'inside.txt' }, 0)
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/sub'),
      '<CR> opens the directory listing')
    H.assert_true(vim.api.nvim_buf_is_valid(previous),
      'the prior direct buffer remains available for parent navigation')
  end)

  H.it('double-click opens the directory or file under the mouse', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })
    buffer.list(ws)

    local function double_click(row, column)
      local callback = vim.fn.maparg('<2-LeftMouse>', 'n', false, true).callback
      H.assert_true(type(callback) == 'function',
        'direct buffers install the double-click handler')
      local mouse = {
        winid = vim.api.nvim_get_current_win(),
        line = row,
        column = column or 1,
      }
      local restore = H.stub(vim.fn, 'getmousepos', function() return mouse end)
      local ok, err = pcall(callback)
      restore()
      if not ok then error(err, 0) end
    end

    local old_buf = vim.api.nvim_get_current_buf()
    double_click(1)
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/sub'),
      'double-clicking a directory opens its listing')
    H.assert_buf_eq({ 'inside.txt' }, 0)
    H.assert_true(vim.api.nvim_buf_is_valid(old_buf),
      'opening the directory keeps the old listing for parent navigation')

    old_buf = vim.api.nvim_get_current_buf()
    double_click(1)
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/sub/inside.txt'),
      'double-clicking a file opens the file')
    H.assert_buf_eq({ 'inside' }, 0)
    H.assert_false(vim.api.nvim_buf_is_valid(old_buf),
      'opening the file replaces the old listing')
  end)

  H.it('full list replacement reattaches child identities without re-reading', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    local listing = buffer.list(ws)
    listing:expand(1)
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local child_mark = vim.api.nvim_buf_get_extmarks(0, ns, { 1, 0 }, { 1, -1 }, {})[1]
    H.assert_not_nil(child_mark, 'child row has an identity mark')

    listing:list()

    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0)
    local mark = vim.api.nvim_buf_get_extmark_by_id(0, ns, child_mark[1], { details = true })
    H.assert_true(#mark > 0 and mark[1] == 1, 'child identity was reattached after replacement')
    H.assert_eq(listing:get_paths(2, 2), { ws .. '/sub/inside.txt' })
  end)

  H.it('extmark invalidation and undo_restore preserve identity lifecycle', function()
    clean_buffers()
    local bufnr = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_create_namespace('direct-test-extmark-lifecycle')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'before', 'target' })
    -- Move the initial setup out of the active undo block so deletion and its
    -- recovery are tested as a distinct undo transaction.
    vim.cmd('undo')
    vim.cmd('redo')
    local id = vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, {
      invalidate = true, undo_restore = true,
    })
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})
    local invalid = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
    H.assert_true(#invalid > 0 and invalid[3].invalid == true,
      'deleted identity is visible as invalid, not silently absent')
    vim.cmd('undo')
    local restored = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
    H.assert_true(#restored > 0 and not restored[3].invalid,
      'undo_restore reattaches the identity at its exact position')
    H.assert_eq(restored[1], 1, 'identity returns to its original line')
  end)

  H.it('wiping one direct buffer releases its state and scoped autocmds only', function()
    clean_buffers()
    local sb = H.sandbox()
    local first_root = H.mkdir(sb.root, 'first')
    local second_root = H.mkdir(sb.root, 'second')
    H.mkfile(first_root, 'first.txt', { 'first' })
    H.mkfile(second_root, 'second.txt', { 'second' })

    buffer.list(first_root)
    local first_buf = vim.api.nvim_get_current_buf()
    local first_win = vim.api.nvim_get_current_win()
    vim.cmd('vsplit')
    buffer.list(second_root)
    local second_buf = vim.api.nvim_get_current_buf()
    local second_win = vim.api.nvim_get_current_win()
    H.assert_true(first_buf ~= second_buf, 'the two roots have separate buffers')
    H.assert_not_nil(buffer._state_for_test(first_buf), 'first direct buffer owns row state')
    H.assert_not_nil(buffer._state_for_test(second_buf), 'second direct buffer owns row state')

    local scoped_before = 0
    for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'direct-buffer' })) do
      if au.buffer == first_buf then scoped_before = scoped_before + 1 end
    end
    H.assert_true(scoped_before > 0, 'first direct buffer has scoped autocmds')

    -- Keep both windows on the surviving buffer so deleting the now-hidden
    -- direct buffer cannot invoke Neovim's normal displayed-buffer replacement.
    vim.api.nvim_win_set_buf(first_win, second_buf)
    vim.api.nvim_buf_delete(first_buf, { force = true })

    H.assert_nil(buffer._state_for_test(first_buf), 'BufWipeout releases its row state')
    H.assert_true(buffer._state_for_test(second_buf) ~= nil,
      'wiping the first buffer preserves the second state')
    H.assert_false(vim.api.nvim_buf_is_valid(first_buf), 'first direct buffer is wiped')
    H.assert_true(vim.api.nvim_buf_is_valid(second_buf), 'surviving buffer remains valid')
    H.assert_true(vim.api.nvim_win_is_valid(first_win), 'the other window survives the wipe')
    H.assert_true(vim.api.nvim_win_is_valid(second_win), 'the survivor window remains valid')
    H.assert_eq(vim.api.nvim_win_get_buf(first_win), second_buf,
      'the other window remains on the surviving buffer')
    H.assert_eq(vim.api.nvim_win_get_buf(second_win), second_buf,
      'the surviving window stays on its direct buffer')
    H.assert_eq(buffer.restore():get_paths(1, 1), { second_root .. '/second.txt' },
      'the surviving buffer still resolves its paths')
    local scoped_after = 0
    for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'direct-buffer' })) do
      if au.buffer == first_buf then scoped_after = scoped_after + 1 end
    end
    H.assert_eq(scoped_after, 0, 'wiping removes first-buffer autocmds')
  end)

  H.it('resolves symlinks: dir link renders as name/, file link as name, broken link omitted', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'realdir')
    H.mkfile(ws, 'realfile.txt', { 'f' })

    H.assert_true(make_symlink(ws .. '/realdir', ws .. '/dirlink'), 'dir symlink created')
    H.assert_true(make_symlink(ws .. '/realfile.txt', ws .. '/filelink'), 'file symlink created')
    H.assert_true(make_symlink(ws .. '/does-not-exist', ws .. '/brokenlink'), 'broken symlink created')

    buffer.list(ws)

    -- symlinks resolved (dir -> name/, file -> name), broken link omitted.
    H.assert_buf_eq({ 'dirlink/', 'realdir/', 'filelink', 'realfile.txt' })
  end)

  H.it('wildignore removes matching entries and tolerates spaces around commas', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'junk')
    H.mkdir(ws, 'keep')
    H.mkfile(ws, 'a.log', { 'a' })
    H.mkfile(ws, 'b.txt', { 'b' })

    H.with_option('wildignore', ' *.log , junk ', function()
      buffer.list(ws)
    end)

    -- the *.log file and the junk/ dir are ignored.
    H.assert_buf_eq({ 'keep/', 'b.txt' })
    H.assert_true(H.exists(ws, 'a.log') and H.exists(ws, 'junk'),
      'wildignore filters the listing only, it does not delete')
  end)

  H.it('glob uses nosuf, so a suffix option cannot fabricate an ignore match', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'note', { 'n' })
    H.mkfile(ws, 'note.md', { 'm' })

    -- The ignore pattern is the exact name `note`; 'suffixes' would make a
    -- glob WITHOUT nosuf match `note.md` too and wrongly ignore it.
    H.with_option('suffixes', '.md', function()
      H.with_option('wildignore', 'note', function()
        buffer.list(ws)
      end)
    end)

    -- `nosuf` makes the exact glob match the only ignored entry.
    H.assert_buf_eq({ 'note.md' })
  end)

  -- A newline cannot be represented in a buffer line, so skip it with a notice
  -- rather than aborting the listing; space-named entries remain representable.
  H.it('a newline-named entry is dropped with a notice, a space-named one survives', function()
    if H.is_windows() then
      H.skip('Windows filenames cannot contain newline characters')
    end
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b\nc.txt', { 'x' })    -- newline in the name: unlistable
    H.mkfile(ws, 'my file.txt', { 's' }) -- space in the name: listable

    H.capture_messages()
    buffer.list(ws)

    H.assert_buf_eq({ 'a.txt', 'my file.txt' })
    H.assert_notified('skipping unlistable entry')
  end)
end)
