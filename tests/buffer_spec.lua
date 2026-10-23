-- tests/buffer_spec.lua -- listing, path identity, cursor, and open behavior.
-- The symlink-prefix fixture avoids the harness realpath masking path spelling.

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

H.describe('buffer: listing', function()
  H.it('indexes root identities with linear stats and no pairwise same_path calls', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'large')
    local count = 2000
    for index = 1, count do
      H.mkfile(ws, string.format('file-%04d.txt', index), '')
    end

    vim.cmd('edit ' .. vim.fn.fnameescape(ws .. '/file-2000.txt'))
    local listing = buffer.Buffer(ws)
    local original_stat, original_same_path = vim.uv.fs_stat, fs.same_path
    local stat_calls, same_path_calls = 0, 0
    vim.uv.fs_stat = function(...)
      stat_calls = stat_calls + 1
      return original_stat(...)
    end
    fs.same_path = function(...)
      same_path_calls = same_path_calls + 1
      if same_path_calls > 0 then error('unexpected same_path call in Buffer:list') end
      return original_same_path(...)
    end
    local initial_ok, initial_result = pcall(listing.list, listing)
    local initial_stats = stat_calls
    vim.uv.fs_stat, fs.same_path = original_stat, original_same_path

    H.assert_true(initial_ok, tostring(initial_result))
    H.assert_true(initial_result == true, 'initial listing succeeds')
    H.assert_eq(same_path_calls, 0, 'initial listing avoids same_path comparisons')
    H.assert_true(initial_stats <= 2 * count + 10,
      'initial listing uses at most 2*N+10 stats, got ' .. initial_stats)
    H.assert_eq(vim.api.nvim_buf_line_count(0), count, 'all plain files are listed')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], count,
      'cursor restoration finds the selected file through the precomputed identity')
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before_marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    H.assert_eq(#before_marks, count, 'every row has a stable identity mark')

    stat_calls, same_path_calls = 0, 0
    vim.uv.fs_stat = function(...)
      stat_calls = stat_calls + 1
      return original_stat(...)
    end
    fs.same_path = function(...)
      same_path_calls = same_path_calls + 1
      if same_path_calls > 0 then error('unexpected same_path call in Buffer:list refresh') end
      return original_same_path(...)
    end
    local refresh_ok, refresh_result = pcall(listing.list, listing)
    local refresh_stats = stat_calls
    vim.uv.fs_stat, fs.same_path = original_stat, original_same_path

    H.assert_true(refresh_ok, tostring(refresh_result))
    H.assert_true(refresh_result == true, 'refresh succeeds')
    H.assert_eq(same_path_calls, 0, 'refresh avoids same_path comparisons')
    H.assert_true(refresh_stats <= 3 * count + 10,
      'refresh uses at most 3*N+10 stats, got ' .. refresh_stats)
    local after_marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    H.assert_eq(after_marks, before_marks, 'refresh preserves every row identity mark')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], count,
      'refresh restores the cursor without pairwise path comparisons')
  end)

  H.it('retains expanded child identities and paths during an indexed refresh', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'inside.txt', '')
    local listing = buffer.list(ws)
    listing:expand(1)
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    local before_paths = listing:get_paths(1, 2)

    H.assert_true(listing:list(), 'refresh succeeds')

    H.assert_buf_eq({ 'child/', '  inside.txt' }, 0, 'expanded child stays rendered')
    H.assert_eq(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}), before,
      'root and child marks retain their IDs')
    H.assert_eq(listing:get_paths(1, 2), before_paths, 'child paths remain associated')
  end)

  H.it('reuses identity when a filesystem entry is replaced at the same path', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local path = H.mkfile(ws, 'replace.txt', { 'old' })
    local listing = buffer.list(ws)
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})[1][1]
    local replacement = H.mkfile(ws, 'replacement.tmp', { 'new inode' })
    H.assert_false(fs.same_path(path, replacement), 'replacement has a distinct inode')
    H.assert_true(vim.uv.fs_rename(replacement, path) == true,
      'atomically replace the entry at the same path')

    H.assert_true(listing:list(), 'refresh succeeds after replacement')

    H.assert_eq(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})[1][1], before,
      'same path reuses its prior row identity')
  end)

  H.it('keeps M.Buffer identities isolated across many directory roots', function()
    clean_buffers()
    local sb = H.sandbox()
    local roots = {}
    local row_ids = {}
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']

    for index = 1, 24 do
      local root = H.mkdir(sb.root, string.format('root-%02d', index))
      H.mkfile(root, string.format('file-%02d.txt', index), '')
      buffer.list(root)
      roots[index] = { path = root, bufnr = vim.api.nvim_get_current_buf() }
      row_ids[index] = vim.api.nvim_buf_get_extmarks(roots[index].bufnr, ns, 0, -1, {})[1][1]
    end

    for index, root in ipairs(roots) do
      local listing = buffer.Buffer(root.path)
      H.assert_true(listing:list(), 're-listing root ' .. index .. ' succeeds')
      H.assert_eq(vim.api.nvim_get_current_buf(), root.bufnr,
        'M.Buffer reuses the matching directory buffer')
      H.assert_eq(vim.api.nvim_buf_get_extmarks(root.bufnr, ns, 0, -1, {})[1][1], row_ids[index],
        'root ' .. index .. ' retains its own row identity')
    end
  end)

  H.it('fails closed for duplicate hardlink identities when hardlinks are supported', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local source = H.mkfile(ws, 'source.txt', '')
    local alias = ws .. '/hardlink.txt'
    local linked = vim.uv.fs_link(source, alias)
    if not linked then return end

    local listing = buffer.list(ws)
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    H.assert_eq(#before, 2, 'both hardlink names are listed')

    H.assert_true(listing:list(), 'refresh succeeds')

    local after = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    H.assert_eq(#after, 2, 'both names remain visible')
    H.assert_true(after[1][1] ~= before[1][1] and after[1][1] ~= before[2][1],
      'first duplicate gets a fresh identity')
    H.assert_true(after[2][1] ~= before[1][1] and after[2][1] ~= before[2][1],
      'second duplicate gets a fresh identity')
  end)

  H.it('does not reuse a deleted row identity when no replacement exists', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local deleted = H.mkfile(ws, 'deleted.txt', '')
    H.mkfile(ws, 'kept.txt', '')
    local listing = buffer.list(ws)
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    local deleted_id = before[1][1]
    local kept_id = before[2][1]
    vim.uv.fs_unlink(deleted)

    H.assert_true(listing:list(), 'refresh succeeds after deletion')

    local after = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    H.assert_eq(#after, 1, 'only the surviving row remains')
    H.assert_eq(after[1][1], kept_id, 'the surviving row keeps its identity')
    H.assert_true(after[1][1] ~= deleted_id, 'the deleted identity is not reused')
  end)

  H.it('uses normalized path fallback when an entry stat fails', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local path = H.mkfile(ws, 'unstatable.txt', '')
    local listing = buffer.Buffer(ws)
    local original_stat = vim.uv.fs_stat
    vim.uv.fs_stat = function(candidate, ...)
      if candidate == path then return nil, 'EACCES' end
      return original_stat(candidate, ...)
    end
    local first_ok, first_result = pcall(listing.list, listing)
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local first_id = first_ok and vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})[1][1]
    local second_ok, second_result = pcall(listing.list, listing)
    vim.uv.fs_stat = original_stat

    H.assert_true(first_ok and first_result == true, tostring(first_result))
    H.assert_true(second_ok and second_result == true, tostring(second_result))
    H.assert_eq(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})[1][1], first_id,
      'normalized-name fallback reuses only the same path identity')
  end)

  H.it('keeps wildignored symlink aliases hidden with linear identity stat work', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    for index = 1, 40 do H.mkfile(ws, string.format('file-%02d.txt', index), '') end
    local target = H.mkfile(ws, 'hidden.log', '')
    local alias = ws .. '/alias.txt'
    H.assert_true(make_symlink(target, alias), 'symlink alias created')
    local listing = buffer.Buffer(ws)
    local original_stat, original_same_path = vim.uv.fs_stat, fs.same_path
    local stat_calls, same_path_calls = 0, 0
    vim.uv.fs_stat = function(...)
      stat_calls = stat_calls + 1
      return original_stat(...)
    end
    fs.same_path = function(...)
      same_path_calls = same_path_calls + 1
      if same_path_calls > 0 then error('unexpected same_path call in wildignore listing') end
      return original_same_path(...)
    end
    local ok, result
    H.with_option('wildignore', '*.log,*.tmp,absent-a,absent-b,absent-c', function()
      ok, result = pcall(listing.list, listing)
    end)
    local stat_count = stat_calls
    vim.uv.fs_stat, fs.same_path = original_stat, original_same_path

    H.assert_true(ok, tostring(result))
    H.assert_true(result == true, 'wildignore listing succeeds')
    H.assert_eq(vim.api.nvim_buf_line_count(0), 40, 'the ignored target and its symlink alias are hidden')
    H.assert_true(not vim.tbl_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), 'hidden.log'),
      'the matched ignored entry is absent')
    H.assert_true(not vim.tbl_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), 'alias.txt'),
      'the same-inode alias stays hidden')
    H.assert_eq(same_path_calls, 0, 'ignore matching avoids same_path comparisons')
    H.assert_true(stat_count <= 2 * 42 + 5 + 10,
      'stat work is linear in entries and patterns, got ' .. stat_count)
  end)

  H.it('dirs render first then files, each group sorted, hidden entries kept', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'b-dir')
    H.mkdir(ws, 'a-dir')
    H.mkfile(ws, 'z.txt', { 'z' })
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, '.hidden', { 'h' })

    buffer.list(ws)

    H.assert_buf_eq({ 'a-dir/', 'b-dir/', '.hidden', 'a.txt', 'z.txt' })
    -- options via vim.bo, never a global `set`.
    H.assert_eq(vim.bo.buftype, 'acwrite', 'buftype')
    H.assert_eq(vim.bo.buflisted, true, 'buflisted')
    H.assert_eq(vim.bo.swapfile, false, 'noswapfile')
    H.assert_eq(vim.bo.filetype, 'direct', 'filetype')
    H.assert_false(vim.bo.modified, 'nomodified only after a real refresh')
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
    H.assert_eq(vim.fn.maparg('<C-r>', 'n', false, true).rhs, '<Cmd>redo<CR>',
      'direct buffer maps redo to Neovim text redo')
    vim.api.nvim_feedkeys('u', 'mx', false)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0, 'undo restores exact child rows')
    H.assert_eq(vim.api.nvim_buf_get_extmarks(bufnr, row_ns, 0, -1, {}), before_marks,
      'undo restores the exact row identity marks')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-r>', true, false, true),
      'mx', false)
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

    vim.api.nvim_feedkeys('u', 'mx', false)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0, 'first undo restores collapsed rows')
    vim.api.nvim_feedkeys('u', 'mx', false)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/' }, 0, 'second undo removes the original expansion normally')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-r>', true, false, true),
      'mx', false)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0, 'redo restores expansion once')
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-r>', true, false, true),
      'mx', false)
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
    H.assert_eq(vim.api.nvim_buf_get_name(bufnr), real, 'buffer name is the resolved alias')
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

  H.it('DirectYank refresh does not transfer an edited root identity to matching text', function()
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
    H.assert_buf_eq({ 'a/', 'b/', 'unrelated.txt' }, 0,
      'stale a/ children are discarded instead of rendered under b/')
    H.assert_eq(H.fs_snapshot(ws), before,
      'the refresh performs no filesystem actions')
  end)

  H.it('DirectYank safely re-renders when an edited root creates hostile duplicate rows', function()
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
    H.assert_buf_eq({ 'a/', 'b/', 'unrelated.txt' }, 0,
      'ambiguous duplicate text triggers a safe filesystem re-render')
    H.assert_eq(H.fs_snapshot(ws), before,
      'the hostile refresh performs no filesystem actions')
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

  H.it('<CR> still opens a nested listing and replaces the previous direct buffer', function()
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
    H.assert_false(vim.api.nvim_buf_is_valid(previous),
      'the prior direct buffer is wiped as before')
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
    for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'direct' })) do
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
    for _, au in ipairs(vim.api.nvim_get_autocmds({ group = 'direct' })) do
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

H.describe('buffer: current entry and cursor', function()
  H.it('cursor lands on the current FILE entry', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b.txt', { 'b' })

    vim.cmd('enew')
    vim.api.nvim_buf_set_name(0, ws .. '/b.txt')

    buffer.list(ws)

    H.assert_buf_eq({ 'a.txt', 'b.txt' })
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'cursor is on b.txt')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[2], 0, 'column reset to 0')
  end)

  H.it('cursor lands on the current DIRECTORY entry', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'asub')
    H.mkdir(ws, 'zsub')
    H.mkfile(ws, 'a.txt', { 'a' })

    vim.cmd('enew')
    vim.api.nvim_buf_set_name(0, ws .. '/zsub')

    buffer.list(ws)

    H.assert_buf_eq({ 'asub/', 'zsub/', 'a.txt' })
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2, 'cursor is on zsub/')
  end)

  H.it('a current entry that is missing on disk yields nil and leaves the cursor put', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b.txt', { 'b' })

    vim.cmd('enew')
    vim.api.nvim_buf_set_name(0, ws .. '/gone.txt') -- never created on disk

    local buf = buffer.Buffer(ws)
    H.assert_nil(buf.current_entry, 'a missing current entry is nil')
    buf:list()

    H.assert_buf_eq({ 'a.txt', 'b.txt' })
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'cursor was left where it was')
  end)

  H.it('entry_path keeps a directory trailing slash and special-cases the root', function()
    H.assert_eq(buffer.entry_path('/a/b', 'dir/'), '/a/b/dir/', 'dir line keeps /')
    H.assert_eq(buffer.entry_path('/a/b', 'f.txt'), '/a/b/f.txt', 'file line')
    H.assert_eq(buffer.entry_path('/', 'f.txt'), '/f.txt', 'root is special-cased')
  end)
end)

H.describe('buffer: attach by path identity', function()
  H.it('reuses the buffer for the same directory, repeated attaches included', function()
    clean_buffers()
    local sb = H.sandbox()
    local root = paths.root(sb.root)

    local first = buffer.Buffer(root)
    local first_nr = vim.api.nvim_get_current_buf()
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(first_nr), root),
      'the created buffer denotes the root')

    local second = buffer.Buffer(root)
    H.assert_eq(vim.api.nvim_get_current_buf(), first_nr, 'the same buffer is reused')
    H.assert_eq(second.root, first.root, 'same root')
  end)

  H.it('does not reuse a buffer for a nested entry of the root', function()
    clean_buffers()
    local sb = H.sandbox()
    local root = paths.root(sb.root)
    H.mkdir(sb.root, 'nested')
    H.mkfile(sb.root, 'a.txt', { 'a' })

    local nested_nr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(nested_nr, root .. '/nested')
    local file_nr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(file_nr, root .. '/a.txt')

    buffer.Buffer(root)
    local current = vim.api.nvim_get_current_buf()

    H.assert_true(current ~= nested_nr, 'the <root>/nested buffer is not reused')
    H.assert_true(current ~= file_nr, 'the <root>/a.txt buffer is not reused')
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(current), root),
      'the current buffer is the one for exactly <root>')
  end)

  H.it('reuses the buffer for a root reached through an unresolved symlinked prefix', function()
    clean_buffers()
    local sb = H.sandbox()
    local real_parent = H.mkdir(sb.root, 'real-parent')
    local real = H.mkdir(real_parent, 'workdir')
    local link = sb.root .. '/link'
    H.assert_true(make_symlink(real_parent, link), 'created the symlinked prefix')

    -- The UNRESOLVED spelling (what paths.root() keeps) vs the RESOLVED one
    -- (what nvim_buf_set_name stores). String equality would miss and create a
    -- duplicate buffer; fs.same_path (ino+dev) must reuse.
    local unresolved = link .. '/workdir'
    local before = #vim.api.nvim_list_bufs()

    buffer.Buffer(unresolved)
    local created_nr = vim.api.nvim_get_current_buf()
    local stored = vim.api.nvim_buf_get_name(created_nr)

    -- nvim_buf_set_name resolves the symlinked prefix, so the stored
    -- spelling differs from the unresolved root. Without this the case would be
    -- vacuous rather than wrong, which is why it is asserted, not skipped.
    H.assert_true(stored ~= unresolved,
      'nvim resolved the symlinked prefix: ' .. stored)
    H.assert_eq(stored, real, 'the stored name is the resolved spelling')
    H.assert_true(fs.same_path(stored, unresolved),
      'the resolved and unresolved spellings denote the same directory')

    buffer.Buffer(unresolved)

    H.assert_eq(vim.api.nvim_get_current_buf(), created_nr, 'the buffer is reused, not duplicated')

    -- Exactly one buffer denotes the resolved directory: a spelling-sensitive
    -- `==` reuse test would have created a second one here.
    local matches = 0
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if fs.same_path(vim.api.nvim_buf_get_name(bufnr), real) then
        matches = matches + 1
      end
    end
    H.assert_eq(matches, 1, 'exactly one buffer for the directory (no duplicate)')
    H.assert_true(#vim.api.nvim_list_bufs() >= before, 'no buffer was destroyed')
  end)
end)

H.describe('buffer: open and ranged paths', function()
  H.it('open() on a file edits it and wipes the previous direct buffer', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'hello' })

    local buf = buffer.list(ws)
    local direct_nr = vim.api.nvim_get_current_buf()

    buf:open('a.txt')

    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/a.txt'),
      'the file buffer is current')
    H.assert_buf_eq({ 'hello' }, 0)
    H.assert_false(vim.api.nvim_buf_is_valid(direct_nr),
      'the previous direct buffer is gone')
  end)

  H.it('open() on a directory line opens a new direct listing', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inner.txt', { 'i' })

    local buf = buffer.list(ws)
    buf:open('sub/')

    H.assert_buf_eq({ 'inner.txt' })
    H.assert_eq(vim.bo.filetype, 'direct', 'the new buffer is a direct buffer')
    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/sub'),
      'the new buffer denotes the sub directory')
  end)

  H.it('open() edits a file whose name contains a space', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'my file.txt', { 'x' })

    local buf = buffer.list(ws)
    buf:open('my file.txt')

    H.assert_true(fs.same_path(vim.api.nvim_buf_get_name(0), ws .. '/my file.txt'),
      'the space-named file is current')
    H.assert_buf_eq({ 'x' }, 0)
  end)

  H.it('get_paths() returns absolute paths for the range, directories keep the slash', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'a.txt', { 'a' })

    local buf = buffer.list(ws)

    H.assert_eq(buf:get_paths(1, 2), { ws .. '/sub/', ws .. '/a.txt' })
    H.assert_eq(buf:get_paths(2, 2), { ws .. '/a.txt' }, 'single-line range')
  end)
end)
