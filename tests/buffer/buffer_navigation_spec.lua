-- buffer_navigation_spec.lua -- current entry, attach, open, and ranged paths.

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
    local separator = package.config:sub(1, 1)
    local native_root = separator == '\\'
      and ((vim.env.SystemDrive or 'C:') .. separator) or separator
    local workspace = vim.fs.joinpath(vim.uv.cwd(), 'a', 'b')
    H.assert_eq(buffer.entry_path(workspace, 'dir' .. separator),
      vim.fs.joinpath(workspace, 'dir') .. separator,
      'dir line keeps the native separator')
    H.assert_true(buffer.entry_path(workspace, 'dir' .. separator):match('[/\\]$') ~= nil,
      'directory identity retains a trailing separator')
    H.assert_eq(buffer.entry_path(workspace, 'f.txt'),
      vim.fs.joinpath(workspace, 'f.txt'), 'file line')
    H.assert_eq(buffer.entry_path(native_root, 'f.txt'),
      vim.fs.joinpath(native_root, 'f.txt'), 'root is special-cased')
  end)

  H.it('renders configured markers but builds native filesystem paths', function()
    clean_buffers()
    local marker = package.config:sub(1, 1) == '/' and '\\' or '/'
    require('direct.config').setup({ directory_separator = marker, git = { enabled = false } })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'existing')
    if package.config:sub(1, 1) == '/' and marker == '\\' then
      H.mkfile(ws, 'hidden\\marker.txt', 'not representable with this marker')
    end

    local listing = buffer.list(ws)

    H.assert_buf_eq({ 'existing' .. marker })
    local expected = vim.fs.joinpath(ws, 'existing') .. package.config:sub(1, 1)
    H.assert_eq(buffer.entry_path(ws, 'existing' .. marker), expected,
      'display override does not leak into filesystem paths')
    vim.api.nvim_buf_set_lines(0, -1, -1, false, {
      'created' .. marker,
      'nested' .. marker,
      'nested' .. marker .. 'child.txt',
    })
    H.assert_true(listing:sync() == true, 'a directory can be created with the configured marker')
    H.assert_true(fs.is_dir(vim.fs.joinpath(ws, 'created')), 'the native path was created')
    H.assert_true(fs.is_file(vim.fs.joinpath(ws, 'nested', 'child.txt')),
      'nested paths use the platform separator for filesystem operations')
    H.assert_true(buffer._component_reason('bad' .. marker .. 'name') ~= nil,
      'the configured marker is reserved inside entry names')
  end)

  H.it('renders the native separator by default', function()
    clean_buffers()
    local native = package.config:sub(1, 1)
    require('direct.config').setup({ directory_separator = native, git = { enabled = false } })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'native')

    buffer.list(ws)

    H.assert_buf_eq({ 'native' .. native })
    H.assert_eq(buffer.entry_path(ws, 'native' .. native),
      vim.fs.joinpath(ws, 'native') .. native,
      'the default display marker still maps to a native filesystem path')
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
    if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
      H.assert_true(fs.same_path(stored, real), 'stored name resolves to the target')
    else
      H.assert_true(stored ~= unresolved,
        'nvim resolved the symlinked prefix: ' .. stored)
      H.assert_eq(stored, real, 'the stored name is the resolved spelling')
    end
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

  H.it('navigation back to a parent directory reuses its existing buffer', function()
    clean_buffers()
    local sb = H.sandbox()
    local parent = H.mkdir(sb.root, 'parent')
    local child = H.mkdir(parent, 'child')
    H.mkfile(child, 'inside.txt', { 'i' })

    local parent_listing = buffer.list(parent)
    local parent_bufnr = vim.api.nvim_get_current_buf()
    parent_listing:open('child/')
    local child_bufnr = vim.api.nvim_get_current_buf()

    H.assert_true(vim.api.nvim_buf_is_valid(parent_bufnr),
      'opening a directory keeps the previous direct buffer available')
    H.assert_true(require('direct').open_parent_expanded(),
      'navigation to the parent succeeds')
    H.assert_eq(vim.api.nvim_get_current_buf(), parent_bufnr,
      'the existing parent buffer is reused')
    H.assert_true(vim.api.nvim_buf_is_valid(child_bufnr),
      'the child listing remains available')
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
