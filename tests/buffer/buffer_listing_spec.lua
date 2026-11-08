-- buffer_listing_spec.lua -- listing, path identity, and wildignore filtering.
local H = require('tests.support.harness')
local buffer = require('direct.buffer.buffer')
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


H.describe('buffer: listing and path identity', function()
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
    local original_scandir, original_get_extmarks =
      vim.uv.fs_scandir, vim.api.nvim_buf_get_extmarks
    local stat_calls, same_path_calls, root_scans, extmark_calls = 0, 0, 0, 0
    vim.uv.fs_stat = function(...)
      stat_calls = stat_calls + 1
      return original_stat(...)
    end
    vim.uv.fs_scandir = function(path, ...)
      if vim.fs.normalize(path) == vim.fs.normalize(ws) then
        root_scans = root_scans + 1
      end
      return original_scandir(path, ...)
    end
    vim.api.nvim_buf_get_extmarks = function(...)
      extmark_calls = extmark_calls + 1
      return original_get_extmarks(...)
    end
    fs.same_path = function(...)
      same_path_calls = same_path_calls + 1
      if same_path_calls > 0 then error('unexpected same_path call in Buffer:list') end
      return original_same_path(...)
    end
    local initial_ok, initial_result = pcall(listing.list, listing)
    local initial_stats = stat_calls
    vim.uv.fs_stat, vim.uv.fs_scandir = original_stat, original_scandir
    vim.api.nvim_buf_get_extmarks, fs.same_path = original_get_extmarks, original_same_path

    H.assert_true(initial_ok, tostring(initial_result))
    H.assert_true(initial_result == true, 'initial listing succeeds')
    H.assert_eq(same_path_calls, 0, 'initial listing avoids same_path comparisons')
    H.assert_eq(root_scans, 1, 'initial listing scans the root only once')
    H.assert_true(extmark_calls <= 4,
      'initial rendering reads extmarks in batches, got ' .. extmark_calls .. ' calls')
    H.assert_true(initial_stats <= 2 * count + 10,
      'initial listing uses at most 2*N+10 stats, got ' .. initial_stats)
    H.assert_eq(vim.api.nvim_buf_line_count(0), count, 'all plain files are listed')
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], count,
      'cursor restoration finds the selected file through the precomputed identity')
    local ns = vim.api.nvim_get_namespaces()['direct-listing-rows']
    local before_marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
    H.assert_eq(#before_marks, count, 'every row has a stable identity mark')

    stat_calls, same_path_calls, root_scans, extmark_calls = 0, 0, 0, 0
    vim.uv.fs_stat = function(...)
      stat_calls = stat_calls + 1
      return original_stat(...)
    end
    vim.uv.fs_scandir = function(path, ...)
      if vim.fs.normalize(path) == vim.fs.normalize(ws) then
        root_scans = root_scans + 1
      end
      return original_scandir(path, ...)
    end
    vim.api.nvim_buf_get_extmarks = function(...)
      extmark_calls = extmark_calls + 1
      return original_get_extmarks(...)
    end
    fs.same_path = function(...)
      same_path_calls = same_path_calls + 1
      if same_path_calls > 0 then error('unexpected same_path call in Buffer:list refresh') end
      return original_same_path(...)
    end
    local refresh_ok, refresh_result = pcall(listing.list, listing)
    local refresh_stats = stat_calls
    vim.uv.fs_stat, vim.uv.fs_scandir = original_stat, original_scandir
    vim.api.nvim_buf_get_extmarks, fs.same_path = original_get_extmarks, original_same_path

    H.assert_true(refresh_ok, tostring(refresh_result))
    H.assert_true(refresh_result == true, 'refresh succeeds')
    H.assert_eq(same_path_calls, 0, 'refresh avoids same_path comparisons')
    H.assert_eq(root_scans, 1, 'refresh scans the root only once')
    H.assert_true(extmark_calls <= 4,
      'refresh rendering reads extmarks in batches, got ' .. extmark_calls .. ' calls')
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

  H.it(':e reloads the current directory contents in a direct buffer', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local old_path = H.mkfile(ws, 'old.txt', { 'old' })
    local listing = buffer.list(ws)
    H.assert_buf_eq({ 'old.txt' }, 0, 'initial listing reflects the directory')

    H.assert_true(vim.uv.fs_unlink(old_path), 'remove the old entry outside the buffer')
    H.mkfile(ws, 'new.txt', { 'new' })

    vim.cmd('edit')

    H.assert_buf_eq({ 'new.txt' }, 0, ':e replaces stale rows with current directory entries')
    H.assert_eq(vim.bo.filetype, 'direct', ':e keeps the direct buffer filetype')
    H.assert_false(vim.bo.modified, ':e leaves the refreshed listing unmodified')
    H.assert_eq(listing:get_paths(1, 1), { ws .. '/new.txt' },
      'row paths match the reloaded directory contents')
  end)

  H.it('refuses to re-list a modified directory buffer without changing it', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', '')
    local listing = require('direct').list(ws)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved rename.txt' })
    vim.bo[buf].modified = true
    H.mkfile(ws, 'new.txt', '')
    H.capture_messages()

    local result = require('direct').list(ws)

    H.assert_nil(result, 're-listing a modified buffer is refused')
    H.assert_eq(vim.api.nvim_get_current_buf(), buf, 'the current buffer is unchanged')
    H.assert_buf_eq({ 'unsaved rename.txt' }, buf, 'unsaved text is preserved')
    H.assert_true(vim.bo[buf].modified, 'the buffer stays modified')
    H.assert_notified('unsaved edits', vim.log.levels.ERROR)
  end)

  H.it('refuses Buffer:list on a modified listing', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'old.txt', '')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved rename.txt' })
    vim.bo.modified = true
    H.capture_messages()

    local result = listing:list()

    H.assert_nil(result, 'direct refresh is refused')
    H.assert_buf_eq({ 'unsaved rename.txt' }, 0, 'unsaved text is preserved')
    H.assert_true(vim.bo.modified, 'the buffer stays modified')
    H.assert_notified('unsaved edits', vim.log.levels.ERROR)
  end)

  H.it('refuses to open a file from a modified listing', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'file.txt', { 'on disk' })
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited row', 'file.txt' })
    vim.bo.modified = true
    local buf = vim.api.nvim_get_current_buf()
    H.capture_messages()

    local result = listing:open('file.txt')

    H.assert_nil(result, 'opening a file from a modified listing is refused')
    H.assert_eq(vim.api.nvim_get_current_buf(), buf, 'the listing remains current')
    H.assert_buf_eq({ 'edited row', 'file.txt' }, buf, 'unsaved text is preserved')
    H.assert_true(vim.bo[buf].modified, 'the buffer stays modified')
    H.assert_eq(vim.fn.readfile(ws .. '/file.txt'), { 'on disk' },
      'the file is not opened or changed')
    H.assert_notified('unsaved edits', vim.log.levels.ERROR)
  end)

  H.it('does not switch back to a modified listing when navigating up', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkfile(sub, 'child.txt', '')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved root edit' })
    vim.bo.modified = true
    local root_buf = vim.api.nvim_get_current_buf()
    H.assert_true(listing:open('sub/'), 'a directory can be opened safely')
    local child_buf = vim.api.nvim_get_current_buf()
    H.assert_true(child_buf ~= root_buf, 'the child listing is current')
    H.capture_messages()

    local result = require('direct').list(ws)

    H.assert_nil(result, 'returning to the modified listing is refused')
    H.assert_eq(vim.api.nvim_get_current_buf(), child_buf,
      'the current child listing is unchanged')
    H.assert_buf_eq({ 'unsaved root edit' }, root_buf, 'the parent edit is preserved')
    H.assert_true(vim.bo[root_buf].modified, 'the parent stays modified')
    H.assert_notified('unsaved edits', vim.log.levels.ERROR)
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
    if not linked then H.skip('hard links are unavailable on this filesystem') end

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

  H.it('snapshot filtering indexes a large ignored set instead of comparing every pair', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    for index = 1, 40 do
      H.mkfile(ws, string.format('visible-%02d.txt', index), '')
      H.mkfile(ws, string.format('ignored-%02d.log', index), '')
    end
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    -- Adding an entry runs apply_snapshot over the visible listing. Any
    -- pairwise same_path comparison there scales as visible x ignored.
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'new.txt' })
    local original_same_path, comparisons = fs.same_path, 0
    fs.same_path = function(...)
      comparisons = comparisons + 1
      return original_same_path(...)
    end
    local ok, result = pcall(listing.sync, listing)
    fs.same_path = original_same_path

    H.assert_true(ok, tostring(result))
    H.assert_true(result == true, 'filtered save succeeds')
    H.assert_eq(comparisons, 0,
      'apply_snapshot performs indexed lookups, not visible-by-ignored same_path comparisons')
    H.assert_true(H.exists(ws, 'ignored-40.log'), 'ignored files remain untouched')
    H.assert_true(H.exists(ws, 'new.txt'), 'the visible addition is saved')
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
end)
