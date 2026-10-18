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

  H.it('keeps the root flat and unfolds one directory level lazily (Phase 1)', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(sub, 'nested')
    H.mkfile(sub, 'inside.txt', { 'inside' })
    H.mkfile(ws, 'root.txt', { 'root' })

    local global_foldmethod = vim.go.foldmethod
    local listing = buffer.list(ws)
    H.assert_buf_eq({ 'sub/', 'root.txt' }, 0)
    H.assert_eq(vim.wo.foldmethod, 'expr', 'folding is configured locally for this window')
    H.assert_eq(vim.go.foldmethod, global_foldmethod, 'global fold options are untouched')
    H.assert_false(vim.bo.modified, 'flat initial listing stays clean')

    local before = vim.fn.undotree()
    local calls = 0
    local read = buffer.read
    buffer.read = function(path)
      calls = calls + 1
      return read(path)
    end
    local ok, err = pcall(function()
      listing:unfold(1)
      H.assert_buf_eq({ 'sub/', '  nested/', '  inside.txt', 'root.txt' }, 0)
      H.assert_eq(calls, 1, 'one immediate-child read')
      H.assert_false(vim.bo.modified, 'display-only expansion remains clean')
      listing:unfold(1)
      H.assert_eq(calls, 1, 'repeat expansion does not re-read')
      H.assert_eq(vim.api.nvim_buf_line_count(0), 4, 'repeat expansion does not duplicate')
      H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'cursor stays on the directory')
      H.assert_eq(vim.fn.undotree().seq_cur, before.seq_cur,
        'expansion does not add an undo entry')
    end)
    buffer.read = read
    if not ok then error(err) end
  end)

  H.it('zo and za unfold and visually collapse without unloading children', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    buffer.list(ws)

    vim.api.nvim_feedkeys('zo', 'mx', false)
    H.assert_buf_eq({ 'sub/', '  inside.txt' }, 0)
    H.assert_eq(vim.fn.foldclosed(1), -1, 'zo leaves the directory unfolded')
    vim.api.nvim_feedkeys('za', 'mx', false)
    H.assert_eq(vim.fn.foldclosed(1), 1, 'za visually closes the directory fold')
    H.assert_eq(vim.api.nvim_buf_line_count(0), 2,
      'collapse does not unload materialized child rows')
    vim.api.nvim_feedkeys('za', 'mx', false)
    H.assert_eq(vim.fn.foldclosed(1), -1, 'za opens a loaded fold')
  end)

  H.it('preserves a manually collapsed fold when the buffer is re-entered', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'sub')
    H.mkfile(ws, 'sub/inside.txt', { 'inside' })
    buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_feedkeys('zo', 'mx', false)
    vim.api.nvim_feedkeys('za', 'mx', false)
    H.assert_eq(vim.fn.foldclosed(1), 1, 'directory fold is collapsed before switching')

    vim.cmd('enew')
    vim.cmd('buffer ' .. bufnr)

    H.assert_eq(vim.fn.foldclosed(1), 1,
      'BufWinEnter preserves the user-collapsed fold')
    H.assert_eq(vim.api.nvim_buf_line_count(bufnr), 2,
      're-entry does not unload materialized children')
  end)

  H.it('nested directories reveal only their immediate children when unfolded', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local sub = H.mkdir(ws, 'sub')
    H.mkdir(sub, 'nested')
    H.mkfile(sub, 'sibling.txt', { 'sibling' })
    H.mkfile(sub, 'nested/deep.txt', { 'deep' })
    local listing = buffer.list(ws)

    listing:unfold(1)
    H.assert_buf_eq({ 'sub/', '  nested/', '  sibling.txt' }, 0,
      'the root unfold is exactly one level')
    listing:unfold(2)
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
    listing:unfold(1)

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
    listing:unfold(1)
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
