-- tests/buffer_spec.lua -- buffer attach/create, listing, current entry, open
-- (T-018, T-019, and the `open` half of T-022; spec B1-B3, B8, B9, B13, D2,
-- D8b, D11, D14).
--
-- The P4 command surface does not exist yet, so this file drives `buffer`
-- directly and thereby pins the P3 module API the commands will wrap. The B3/B9
-- attach case is asserted with a symlinked prefix the spec builds itself, because
-- the harness realpaths its temp root (11.1 step 3) and would otherwise mask a
-- spelling-sensitive buffer-reuse comparison.

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

H.describe('buffer: listing (B1/B13)', function()
  H.it('dirs render first then files, each group sorted, hidden entries kept (B1)', function()
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
    -- D11: options via vim.bo, never a global `set`.
    H.assert_eq(vim.bo.buftype, 'acwrite', 'buftype')
    H.assert_eq(vim.bo.buflisted, true, 'buflisted')
    H.assert_eq(vim.bo.swapfile, false, 'noswapfile')
    H.assert_eq(vim.bo.filetype, 'direct', 'filetype')
    H.assert_false(vim.bo.modified, 'nomodified only after a real refresh (D11)')
  end)

  H.it('resolves symlinks: dir link renders as name/, file link as name, broken link omitted (B1/R3)', function()
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

  H.it('wildignore removes matching entries and tolerates spaces around commas (B13)', function()
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

  H.it('glob uses nosuf, so a suffix option cannot fabricate an ignore match (B13)', function()
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

    -- only the exact pattern match is ignored (nosuf).
    H.assert_buf_eq({ 'note.md' })
  end)

  -- P3-NB1: an entry whose name carries a newline can never be a buffer line
  -- (`nvim_buf_set_lines` raises on it), so listing its directory used to abort.
  -- The line is dropped with a notification; a representable space-named entry
  -- must still list.
  H.it('a newline-named entry is dropped with a notice, a space-named one survives (NB1)', function()
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

H.describe('buffer: current entry and cursor (B2)', function()
  H.it('cursor lands on the current FILE entry (B2)', function()
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

  H.it('cursor lands on the current DIRECTORY entry (B2)', function()
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

  H.it('a current entry that is missing on disk yields nil and leaves the cursor put (B2)', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    H.mkfile(ws, 'b.txt', { 'b' })

    vim.cmd('enew')
    vim.api.nvim_buf_set_name(0, ws .. '/gone.txt') -- never created on disk

    local buf = buffer.Buffer(ws)
    H.assert_nil(buf.current_entry, 'a missing current entry is nil (B2)')
    buf:list()

    H.assert_buf_eq({ 'a.txt', 'b.txt' })
    H.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'cursor was left where it was')
  end)

  H.it('entry_path keeps a directory trailing slash and special-cases the root (B1/B5)', function()
    H.assert_eq(buffer.entry_path('/a/b', 'dir/'), '/a/b/dir/', 'dir line keeps /')
    H.assert_eq(buffer.entry_path('/a/b', 'f.txt'), '/a/b/f.txt', 'file line')
    H.assert_eq(buffer.entry_path('/', 'f.txt'), '/f.txt', 'root is special-cased')
  end)
end)

H.describe('buffer: attach by path identity (B3/B9)', function()
  H.it('reuses the buffer for the same directory, repeated attaches included (B3)', function()
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

  H.it('does not reuse a buffer for a nested entry of the root (B3, reviewer B2)', function()
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

  H.it('reuses the buffer for a root reached through an unresolved symlinked prefix (B9)', function()
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

    -- B9 premise: nvim_buf_set_name resolved the symlinked prefix, so the stored
    -- spelling differs from the unresolved root. Without this the case would be
    -- vacuous rather than wrong, which is why it is asserted, not skipped.
    H.assert_true(stored ~= unresolved,
      'nvim resolved the symlinked prefix (B9 premise): ' .. stored)
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

H.describe('buffer: open and ranged paths (B8/D8b/D14)', function()
  H.it('open() on a file edits it and wipes the previous direct buffer (B8/D8b)', function()
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

  H.it('open() on a directory line opens a new direct listing (B8)', function()
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

  H.it('open() edits a file whose name contains a space (D14)', function()
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

  H.it('get_paths() returns absolute paths for the range, directories keep the slash (B8)', function()
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
