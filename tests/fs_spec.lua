-- tests/fs_spec.lua -- filesystem operations, copy safety, and error handling.

-- Proves: operations return true or nil, err and never raise; predicates
-- return booleans; symlinks are resolved for listing while broken links are
-- omitted; same_path is ino+dev regardless of spelling; rename falls back to
-- copy+remove only on EXDEV and propagates every other error; a directory's
-- inode survives a rename.

local H = require('tests.support.harness')
local fs = require('direct.fs')

H.describe('fs', function()
  H.it('operations return true or nil, err and never raise; predicates are booleans', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'hello' })

    H.assert_true(fs.mkdirp(sb.root .. '/sub') == true, 'mkdirp')
    H.assert_true(fs.touch(sb.root .. '/sub/new.txt') == true, 'touch')
    H.assert_true(fs.copy_file(sb.root .. '/a.txt', sb.root .. '/b.txt') == true, 'copy_file')
    H.assert_true(fs.rename(sb.root .. '/b.txt', sb.root .. '/c.txt') == true, 'rename')
    H.assert_true(fs.rm_file(sb.root .. '/c.txt') == true, 'rm_file')
    H.assert_true(fs.copy_tree(sb.root .. '/sub', sb.root .. '/sub2') == true, 'copy_tree')
    H.assert_true(fs.rm_tree(sb.root .. '/sub2') == true, 'rm_tree')

    -- Failures come back as nil, err -- never a raised Lua error.
    local r, e = fs.copy_file(sb.root .. '/missing.txt', sb.root .. '/x.txt')
    H.assert_nil(r, 'copy_file failure returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'copy_file failure carries an err string')
    r = fs.rm_file(sb.root .. '/missing.txt')
    H.assert_nil(r, 'rm_file failure returns nil')
    r = fs.copy_tree(sb.root .. '/missing', sb.root .. '/y')
    H.assert_nil(r, 'copy_tree failure returns nil')
    r = fs.mkdirp(sb.root .. '/a.txt') -- a file occupies the path
    H.assert_nil(r, 'mkdirp over a file returns nil')
    r = fs.touch(sb.root .. '/missing-dir/x.txt')
    H.assert_nil(r, 'touch into a missing directory returns nil')

    -- Predicates.
    H.assert_true(fs.is_dir(sb.root) == true, 'is_dir true')
    H.assert_true(fs.is_file(sb.root .. '/a.txt') == true, 'is_file true')
    H.assert_false(fs.is_dir(sb.root .. '/a.txt'), 'is_dir false for a file')
    H.assert_false(fs.is_file(sb.root .. '/missing.txt'), 'is_file false for missing')
    H.assert_false(fs.exists(sb.root .. '/missing.txt'), 'exists false for missing')
    H.assert_true(fs.exists(sb.root .. '/a.txt'), 'exists true for present')
    H.assert_true(fs.same_path(sb.root, sb.root) == true, 'same_path reflexive')
    H.assert_false(fs.same_path(sb.root, sb.root .. '/a.txt'), 'same_path false across entries')
  end)

  H.it('non-string inputs return nil, err instead of raising', function()
    local sb = H.sandbox()
    local r, e = fs.rename(nil, sb.root .. '/x')
    H.assert_nil(r, 'rename(nil, dst) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'rename(nil, dst) carries an err')
    r, e = fs.same_path(42, sb.root)
    H.assert_nil(r, 'same_path(42, base) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'same_path(42, base) carries an err')
    r, e = fs.copy_file(nil, sb.root .. '/d')
    H.assert_nil(r, 'copy_file(nil, dst) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'copy_file(nil, dst) carries an err')
    r, e = fs.rm_file(nil)
    H.assert_nil(r, 'rm_file(nil) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'rm_file(nil) carries an err')
  end)

  H.it('same_path is ino+dev for two spellings of a symlinked prefix', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'outer/sub')
    H.mkfile(sb.root, 'outer/sub/x.txt', { 'x' })
    local link = sb.root .. '/alias'
    H.assert_true(vim.uv.fs_symlink(sb.root .. '/outer', link) == true, 'created prefix symlink')

    local through_link = link .. '/sub/x.txt'
    local direct = sb.root .. '/outer/sub/x.txt'
    H.assert_true(through_link ~= direct, 'the two spellings differ as strings')
    H.assert_true(fs.same_path(through_link, direct),
      'same_path is true despite the different spelling')
    H.assert_true(fs.same_path(link .. '/sub', sb.root .. '/outer/sub'),
      'same_path works for directories too')
  end)

  H.it('read_dir_lines resolves links, orders dirs first, omits broken links', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'listing')
    H.mkfile(root, 'b.txt', { 'b' })
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkdir(root, 'zdir')
    H.mkdir(root, 'adir')
    vim.uv.fs_symlink(root .. '/zdir', root .. '/linkdir')
    vim.uv.fs_symlink(root .. '/a.txt', root .. '/linkfile')
    vim.uv.fs_symlink(root .. '/missing', root .. '/broken')

    H.assert_eq(fs.read_dir_lines(root),
      { 'adir/', 'linkdir/', 'zdir/', 'a.txt', 'b.txt', 'linkfile' },
      'dirs first (trailing /), then files; links resolved; broken omitted')

    -- wildignore ignore_set: an entry is dropped when same_path matches.
    H.assert_eq(fs.read_dir_lines(root, { root .. '/b.txt' }),
      { 'adir/', 'linkdir/', 'zdir/', 'a.txt', 'linkfile' },
      'ignore_set entries are dropped')
  end)

  H.it('rename falls back to copy+remove on EXDEV and removes the source', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'src.txt', { 'payload' })
    local restore = H.stub(vim.uv, 'fs_rename', function()
      return nil, 'EXDEV: cross-device link not permitted', 'EXDEV'
    end)
    local ok, err = fs.rename(sb.root .. '/src.txt', sb.root .. '/dst.txt')
    restore()

    H.assert_true(ok == true, 'EXDEV rename succeeds: ' .. tostring(err))
    H.assert_false(fs.exists(sb.root .. '/src.txt'), 'source removed by the fallback')
    H.assert_true(fs.exists(sb.root .. '/dst.txt'), 'destination created')
    H.assert_eq(vim.fn.readfile(sb.root .. '/dst.txt'), { 'payload' }, 'content copied')
  end)

  H.it('a non-EXDEV rename error propagates and leaves the source intact', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'src.txt', { 'payload' })
    local restore = H.stub(vim.uv, 'fs_rename', function()
      return nil, 'EACCES: permission denied', 'EACCES'
    end)
    local ok, err = fs.rename(sb.root .. '/src.txt', sb.root .. '/dst.txt')
    restore()

    H.assert_nil(ok, 'rename reports failure')
    H.assert_eq(err, 'EACCES: permission denied', 'the original error is returned')
    H.assert_true(fs.exists(sb.root .. '/src.txt'), 'source intact')
    H.assert_false(fs.exists(sb.root .. '/dst.txt'), 'destination not created')
  end)

  H.it('rename preserves a directory inode', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'd1')
    local before = H.inode_of(sb.root .. '/d1')
    H.assert_true(fs.rename(sb.root .. '/d1', sb.root .. '/d2') == true, 'rename dir')
    H.assert_eq(H.inode_of(sb.root .. '/d2'), before, 'directory ino preserved')
    H.assert_false(fs.exists(sb.root .. '/d1'), 'old name gone')
  end)

  H.it('copy_tree is recursive with mkdir -p semantics', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'tree/sub/deep.txt', { 'deep' })
    H.mkfile(sb.root, 'tree/top.txt', { 'top' })
    H.assert_true(fs.copy_tree(sb.root .. '/tree', sb.root .. '/nested/copy') == true, 'copy_tree')
    H.assert_fs_eq(sb.root .. '/nested/copy',
      { 'sub/', 'sub/deep.txt', 'top.txt' }, 'tree copied recursively')
  end)

  -- A cross-device move removes its source after copying, so it requires a
  -- complete copy and must refuse unsupported entries. Yank and paste destroy
  -- nothing; they may skip such entries, but must report each omission.
  H.it('copy_tree with require_complete refuses a symlink tree, leaving no destination', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkdir(root, 'sub')
    H.mkfile(root, 'sub/b.txt', { 'b' })
    -- Nested, and reached only AFTER a.txt and sub/b.txt have been copied, so
    -- the no-partial-destination assertion also pins the cleanup.
    pcall(vim.uv.fs_symlink, root .. '/a.txt', root .. '/sub/link')
    H.assert_true(vim.uv.fs_lstat(root .. '/sub/link') ~= nil, 'nested symlink created')

    local ok, err = fs.copy_tree(root, sb.root .. '/dst', { require_complete = true })
    H.assert_nil(ok, 'copy_tree refuses a tree holding a symlink')
    H.assert_true(type(err) == 'string' and err:find('sub/link', 1, true) ~= nil,
      'the error names the offending entry: ' .. tostring(err))
    H.assert_false(fs.exists(sb.root .. '/dst'), 'no partial destination left behind')
    H.assert_fs_eq(root, { 'a.txt', 'sub/', 'sub/b.txt', 'sub/link@' },
      'the source tree is untouched')
  end)

  -- Non-destructive copies still copy reproducible entries, skip unsupported
  -- ones, and report omissions instead of failing the entire yank or paste.
  H.it('copy_tree without require_complete copies what it can and reports the symlink it skipped', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkdir(root, 'sub')
    H.mkfile(root, 'sub/b.txt', { 'b' })
    pcall(vim.uv.fs_symlink, root .. '/a.txt', root .. '/sub/link')
    H.assert_true(vim.uv.fs_lstat(root .. '/sub/link') ~= nil, 'nested symlink created')

    local dst = sb.root .. '/dst'
    local ok, skipped = fs.copy_tree(root, dst)
    H.assert_true(ok == true, 'a copy that destroys nothing succeeds: ' .. tostring(skipped))
    H.assert_true(type(skipped) == 'table' and #skipped == 1,
      'exactly one skipped entry is reported: ' .. vim.inspect(skipped))
    H.assert_eq(skipped[1].path, root .. '/sub/link', 'the report names the symlink')
    H.assert_eq(skipped[1].kind, 'symlink', 'the report names what the entry is')
    -- Everything reproducible is copied; the symlink is the only omission.
    H.assert_fs_eq(dst, { 'a.txt', 'sub/', 'sub/b.txt' }, 'the copyable entries are copied')
    H.assert_fs_eq(root, { 'a.txt', 'sub/', 'sub/b.txt', 'sub/link@' },
      'the source tree is untouched')
  end)

  H.it('an EXDEV move of a tree holding a symlink fails loudly and keeps the source', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    pcall(vim.uv.fs_symlink, root .. '/a.txt', root .. '/link')
    H.assert_true(vim.uv.fs_lstat(root .. '/link') ~= nil, 'symlink created')

    local restore = H.stub(vim.uv, 'fs_rename', function()
      return nil, 'EXDEV: cross-device link not permitted', 'EXDEV'
    end)
    local ok, err = fs.rename(root, sb.root .. '/moved')
    restore()

    H.assert_nil(ok, 'the move fails instead of losing the symlink')
    H.assert_true(type(err) == 'string' and err:find('link', 1, true) ~= nil,
      'the error names the entry: ' .. tostring(err))
    H.assert_true(fs.exists(sb.root .. '/tree'), 'the source tree is intact')
    H.assert_false(fs.exists(sb.root .. '/moved'), 'no destination left behind')
    H.assert_fs_eq(root, { 'a.txt', 'link@' }, 'nothing was destroyed')
  end)

  H.it('copy_tree with require_complete refuses a FIFO, leaving no destination', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    local fifo = root .. '/pipe'
    -- mkfifo is an external tool; the harness has no skip primitive, so a
    -- platform without it returns early (the symlink cases pin the walk).
    -- Guarded by lstat, never by the exit status alone.
    vim.fn.system({ 'mkfifo', fifo })
    local st = vim.uv.fs_lstat(fifo)
    if st == nil or st.type ~= 'fifo' then
      return
    end
    local ok, err = fs.copy_tree(root, sb.root .. '/dst', { require_complete = true })
    H.assert_nil(ok, 'copy_tree refuses a FIFO')
    H.assert_true(type(err) == 'string' and err:find('pipe', 1, true) ~= nil,
      'the error names the FIFO: ' .. tostring(err))
    H.assert_false(fs.exists(sb.root .. '/dst'), 'no partial destination left behind')
  end)

  -- vim.fs.dir can make an unreadable directory look empty, hiding data before
  -- an EXDEV move removes the source. The copy walk probes with fs_scandir; this
  -- fixture puts the locked subtree last to verify partial-copy cleanup. Root
  -- bypasses permission bits, so the test returns early there.
  H.it('copy_tree with require_complete refuses an unreadable directory, leaving no destination', function()
    if vim.uv.getuid ~= nil and vim.uv.getuid() == 0 then
      return
    end
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    local keep = H.mkdir(root, 'keep')
    H.mkfile(keep, 'inner.txt', { 'i' })
    -- Sorted last, so 'a.txt' and 'keep/inner.txt' are already copied when the
    -- walk reaches it.
    local locked = H.mkdir(root, 'locked')
    H.mkfile(locked, 'inner.txt', { 'i' })
    H.assert_true(vim.uv.fs_chmod(locked, 0) == true, 'locked the directory')

    local ok, err = fs.copy_tree(root, sb.root .. '/dst', { require_complete = true })
    -- Restore 0700 before asserting so a failed assertion still leaves the
    -- sandbox removable by the harness teardown.
    vim.uv.fs_chmod(locked, 448)

    H.assert_nil(ok, 'copy_tree refuses an unreadable directory')
    H.assert_true(type(err) == 'string' and err:find('locked', 1, true) ~= nil,
      'the error names the offending entry: ' .. tostring(err))
    H.assert_false(fs.exists(sb.root .. '/dst'), 'no partial destination left behind')
    H.assert_fs_eq(root, { 'a.txt', 'keep/', 'keep/inner.txt', 'locked/',
      'locked/inner.txt' }, 'the source is untouched')
  end)

  -- Best-effort copies may skip unreadable subtrees, but must report them rather
  -- than silently creating an empty stand-in.
  H.it('copy_tree without require_complete reports an unreadable directory it skipped', function()
    if vim.uv.getuid ~= nil and vim.uv.getuid() == 0 then
      return
    end
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    local locked = H.mkdir(root, 'locked')
    H.mkfile(locked, 'inner.txt', { 'i' })
    H.assert_true(vim.uv.fs_chmod(locked, 0) == true, 'locked the directory')

    local dst = sb.root .. '/dst'
    local ok, skipped = fs.copy_tree(root, dst)
    vim.uv.fs_chmod(locked, 448)

    H.assert_true(ok == true, 'a copy that destroys nothing succeeds: ' .. tostring(skipped))
    H.assert_true(type(skipped) == 'table' and #skipped == 1,
      'exactly one skipped entry is reported: ' .. vim.inspect(skipped))
    H.assert_eq(skipped[1].path, root .. '/locked', 'the report names the locked directory')
    H.assert_fs_eq(dst, { 'a.txt' },
      'the readable entries are copied and no stand-in for the locked tree is created')
    H.assert_fs_eq(root, { 'a.txt', 'locked/', 'locked/inner.txt' },
      'the source is untouched')
  end)

  -- An up-front scan can miss entries created during copying. The walk must
  -- re-list each directory as it descends so late entries are refused or reported
  -- before an EXDEV fallback can remove the source.
  --
  -- The injection is deterministic: M.mkdirp is a module-table seam,
  -- and the stub creates the entry at the copy's first mkdirp, i.e. inside the
  -- walk. No sleeping and no reliance on scheduling, so this cannot flake.
  H.it('an entry that appears after the copy started still refuses the copy', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkfile(root, 'sub/b.txt', { 'b' })

    local injected = false
    local real_mkdirp = fs.mkdirp
    local restore = H.stub(fs, 'mkdirp', function(path)
      if not injected then
        injected = true
        -- A symlink because it is portable; a FIFO/socket/device is refused by
        -- the same branch (and is pinned by the FIFO test above).
        vim.uv.fs_symlink(root .. '/a.txt', root .. '/late')
      end
      return real_mkdirp(path)
    end)
    local ok, err = fs.copy_tree(root, sb.root .. '/dst', { require_complete = true })
    restore()

    H.assert_true(injected, 'the entry was created during the copy')
    H.assert_nil(ok, 'the late entry refuses the copy: ' .. tostring(err))
    H.assert_true(type(err) == 'string' and err:find('late', 1, true) ~= nil,
      'the error names the entry that appeared late: ' .. tostring(err))
    H.assert_false(fs.exists(sb.root .. '/dst'), 'no partial destination left behind')
    H.assert_fs_eq(root, { 'a.txt', 'late@', 'sub/', 'sub/b.txt' },
      'the source is untouched, the late entry included')
  end)

  -- Best-effort copies must also report late entries instead of silently omitting them.
  H.it('an entry that appears after the copy started is still reported, not dropped', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkfile(root, 'sub/b.txt', { 'b' })

    local injected = false
    local real_mkdirp = fs.mkdirp
    local restore = H.stub(fs, 'mkdirp', function(path)
      if not injected then
        injected = true
        vim.uv.fs_symlink(root .. '/a.txt', root .. '/late')
      end
      return real_mkdirp(path)
    end)
    local dst = sb.root .. '/dst'
    local ok, skipped = fs.copy_tree(root, dst)
    restore()

    H.assert_true(injected, 'the entry was created during the copy')
    H.assert_true(ok == true, 'a copy that destroys nothing succeeds')
    H.assert_true(type(skipped) == 'table' and #skipped == 1,
      'the late entry is reported, not dropped: ' .. vim.inspect(skipped))
    H.assert_eq(skipped[1].path, root .. '/late', 'the report names it')
    H.assert_fs_eq(dst, { 'a.txt', 'sub/', 'sub/b.txt' },
      'the copyable entries are copied and the late symlink is not followed')
    H.assert_fs_eq(root, { 'a.txt', 'late@', 'sub/', 'sub/b.txt' },
      'the source is untouched')
  end)

  -- Verify the destructive EXDEV path too: a move must never remove a source it
  -- could not copy completely.
  H.it('a cross-device move never removes a source it could not copy completely', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkfile(root, 'sub/b.txt', { 'b' })

    local injected = false
    local real_mkdirp = fs.mkdirp
    local mrestore = H.stub(fs, 'mkdirp', function(path)
      if not injected then
        injected = true
        vim.uv.fs_symlink(root .. '/a.txt', root .. '/late')
      end
      return real_mkdirp(path)
    end)
    local rrestore = H.stub(vim.uv, 'fs_rename', function()
      return nil, 'EXDEV: cross-device link not permitted', 'EXDEV'
    end)
    local ok, err = fs.rename(root, sb.root .. '/moved')
    rrestore()
    mrestore()

    H.assert_true(injected, 'the entry was created during the cross-device copy')
    H.assert_nil(ok, 'the move fails instead of losing the entry: ' .. tostring(err))
    H.assert_true(type(err) == 'string' and err:find('late', 1, true) ~= nil,
      'the error names the entry: ' .. tostring(err))
    H.assert_true(fs.exists(sb.root .. '/tree'), 'the source tree is intact')
    H.assert_false(fs.exists(sb.root .. '/moved'), 'no destination left behind')
    H.assert_fs_eq(root, { 'a.txt', 'late@', 'sub/', 'sub/b.txt' },
      'nothing was destroyed')
  end)

  -- A refused copy may remove only paths it created; existing destinations
  -- belong to their owner and must remain untouched.
  H.it('a refused copy removes only what it created', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    pcall(vim.uv.fs_symlink, root .. '/a.txt', root .. '/link')
    H.assert_true(vim.uv.fs_lstat(root .. '/link') ~= nil, 'symlink created')
    local dst = H.mkdir(sb.root, 'dst')
    H.mkfile(dst, 'keep.txt', { 'KEEP' })

    local ok, err = fs.copy_tree(root, dst, { require_complete = true })

    H.assert_nil(ok, 'the copy is refused: ' .. tostring(err))
    H.assert_fs_eq(dst, { 'keep.txt' },
      'only the entries the copy created are undone, never the pre-existing destination')
  end)

  -- A failed copy once recorded a destination file without checking
  -- whether something was already there. A source file whose name clashes with
  -- an existing destination DIRECTORY makes copy_file fail (EISDIR), and the
  -- cleanup then deleted that directory -- and everything inside it -- although
  -- the copy never created it. Only paths this copy created may be undone.
  H.it('a failed copy never deletes a pre-existing destination directory', function()
    local sb = H.sandbox()
    local src = H.mkdir(sb.root, 'src')
    H.mkfile(src, 'a.txt', { 'a' })
    H.mkfile(src, 'clash', { 'SOURCE FILE' })
    local dst = H.mkdir(sb.root, 'dst')
    H.mkfile(dst, 'clash/keep.txt', { 'PRE-EXISTING DATA' })

    local ok, err = fs.copy_tree(src, dst, { require_complete = true })

    H.assert_nil(ok, 'the copy fails: ' .. tostring(err))
    H.assert_true(fs.is_dir(dst .. '/clash'), 'the pre-existing directory survives')
    H.assert_fs_eq(dst, { 'clash/', 'clash/keep.txt' },
      'the pre-existing entry and its contents survive; only this copy remains undone')
    H.assert_fs_eq(src, { 'a.txt', 'clash' }, 'the source is untouched')
  end)

  -- The same guarantee on the best-effort path: a hard failure there also cleans
  -- up, and it must undo only what this copy created.
  H.it('a failed best-effort copy never deletes a pre-existing destination directory', function()
    local sb = H.sandbox()
    local src = H.mkdir(sb.root, 'src')
    H.mkfile(src, 'a.txt', { 'a' })
    H.mkfile(src, 'clash', { 'SOURCE FILE' })
    local dst = H.mkdir(sb.root, 'dst')
    H.mkfile(dst, 'clash/keep.txt', { 'PRE-EXISTING DATA' })

    local ok, err = fs.copy_tree(src, dst)

    H.assert_nil(ok, 'the copy fails: ' .. tostring(err))
    H.assert_fs_eq(dst, { 'clash/', 'clash/keep.txt' },
      'the pre-existing entry and its contents survive')
    H.assert_fs_eq(src, { 'a.txt', 'clash' }, 'the source is untouched')
  end)

  -- Recursive cleanup could delete a foreign file added after the copy created
  -- its parent directory. Cleanup now unlinks only recorded files and removes
  -- recorded directories only while empty. This fixture verifies that foreign
  -- data survives while the copy's own partial files are removed.
  --
  -- The injection is deterministic: M.mkdirp is a module-table seam,
  -- and the stub runs at the copy's first mkdirp -- inside the walk, after the
  -- destination directory exists and before its listing -- so the foreign file
  -- and the late source entry are both created mid-copy. No sleeping.
  H.it('a refused copy preserves foreign entries inside its destination', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkfile(root, 'sub/b.txt', { 'b' })
    local dst = sb.root .. '/dst'

    local injected = false
    local real_mkdirp = fs.mkdirp
    local restore = H.stub(fs, 'mkdirp', function(path)
      local ok, err = real_mkdirp(path)
      if ok and not injected and path == dst then
        injected = true
        -- FOREIGN: placed inside the destination directory by someone who is
        -- not the copy, after the copy created it.
        vim.fn.writefile({ 'FOREIGN' }, dst .. '/foreign.txt')
        -- The refusal trigger, sorted last so the copy's own partials exist:
        -- 'a.txt' and 'sub/b.txt' are already copied when the walk reaches it.
        vim.uv.fs_symlink(root .. '/a.txt', root .. '/zz-late')
      end
      return ok, err
    end)
    local ok, err = fs.copy_tree(root, dst, { require_complete = true })
    restore()

    H.assert_true(injected, 'the foreign entry and the late entry were created during the copy')
    H.assert_nil(ok, 'the late entry refuses the copy: ' .. tostring(err))
    H.assert_true(type(err) == 'string' and err:find('zz-late', 1, true) ~= nil,
      'the error names the entry that appeared late: ' .. tostring(err))
    H.assert_true(fs.exists(dst .. '/foreign.txt'),
      'the foreign file the copy did not create survives the cleanup')
    H.assert_eq(vim.fn.readfile(dst .. '/foreign.txt'), { 'FOREIGN' },
      'the foreign file keeps its contents')
    H.assert_false(fs.exists(dst .. '/a.txt'),
      'the copy\'s own partial file is removed')
    H.assert_false(fs.exists(dst .. '/sub'),
      'the created directory that the cleanup emptied is removed')
    H.assert_true(fs.is_dir(dst),
      'the created directory that is no longer empty is left behind, not force-deleted')
    H.assert_fs_eq(dst, { 'foreign.txt' },
      'the destination holds exactly the foreign entry and nothing this copy created')
    H.assert_fs_eq(root, { 'a.txt', 'sub/', 'sub/b.txt', 'zz-late@' },
      'the source is untouched, the late entry included')
  end)

  -- Complete mode pre-scans unsupported trees so common refusals happen before
  -- any write. Stubbing the write primitives verifies that guarantee directly.
  H.it('a destructive refusal in the common case performs zero writes', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkfile(root, 'sub/b.txt', { 'b' })
    pcall(vim.uv.fs_symlink, root .. '/a.txt', root .. '/zz-link')
    H.assert_true(vim.uv.fs_lstat(root .. '/zz-link') ~= nil, 'symlink created')

    local primitives = { 'mkdirp', 'copy_file', 'rm_file', 'rm_tree' }
    local calls = { mkdirp = 0, copy_file = 0, rm_file = 0, rm_tree = 0 }
    local restores = {}
    for _, name in ipairs(primitives) do
      local real = fs[name]
      restores[#restores + 1] = H.stub(fs, name, function(...)
        calls[name] = calls[name] + 1
        return real(...)
      end)
    end
    local dst = sb.root .. '/dst'
    local ok, err = fs.copy_tree(root, dst, { require_complete = true })
    for _, restore in ipairs(restores) do
      restore()
    end

    H.assert_nil(ok, 'the copy is refused: ' .. tostring(err))
    H.assert_true(type(err) == 'string' and err:find('zz-link', 1, true) ~= nil,
      'the refusal names the offending entry: ' .. tostring(err))
    H.assert_eq(calls, { mkdirp = 0, copy_file = 0, rm_file = 0, rm_tree = 0 },
      'the common-case refusal writes nothing: not even a directory')
    H.assert_false(fs.exists(dst), 'no destination was created')
    H.assert_fs_eq(root, { 'a.txt', 'sub/', 'sub/b.txt', 'zz-link@' },
      'the source is untouched')
  end)

  -- fs.taken uses lstat so a dangling destination symlink is treated as
  -- occupied, matching the copy and paste clash checks and preventing writes
  -- through a path the user already owns.
  H.it('a dangling destination symlink counts as an occupied name', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    local dst = sb.root .. '/dst'
    H.assert_true(vim.uv.fs_symlink(sb.root .. '/nowhere', dst) == true,
      'dangling symlink occupying the destination name')
    H.assert_true(fs.taken(dst) == true,
      'the shared helper counts a dangling symlink as taken')
    H.assert_false(fs.exists(dst),
      'the following check reports the name free')

    local ok, err = fs.copy_tree(root, dst, { require_complete = true })

    H.assert_nil(ok, 'the copy refuses the taken destination: ' .. tostring(err))
    H.assert_true(type(err) == 'string' and err:find('destination exists', 1, true) ~= nil,
      'the refusal names the destination clash: ' .. tostring(err))
    local st = vim.uv.fs_lstat(dst)
    H.assert_true(st ~= nil and st.type == 'link',
      'the dangling link is itself untouched, not replaced or written through')
    H.assert_false(fs.exists(sb.root .. '/nowhere'),
      'nothing was created at the link target')
    H.assert_fs_eq(root, { 'a.txt' }, 'the source is untouched')
  end)

  -- Complete mode refuses taken destinations because copy_file overwrites them.
  -- Best-effort mode retains overwrite behavior for yank and paste.
  H.it('complete mode refuses an already-taken destination instead of overwriting', function()
    local sb = H.sandbox()
    local src = H.mkdir(sb.root, 'src')
    H.mkfile(src, 'a.txt', { 'NEW' })
    local dst = H.mkdir(sb.root, 'dst')
    H.mkfile(dst, 'a.txt', { 'OLD' })

    local ok, err = fs.copy_tree(src, dst, { require_complete = true })

    H.assert_nil(ok, 'complete mode refuses the taken destination: ' .. tostring(err))
    H.assert_true(type(err) == 'string' and err:find('destination exists', 1, true) ~= nil,
      'the refusal names the destination clash: ' .. tostring(err))
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'OLD' },
      'the existing destination file is not overwritten')
    H.assert_fs_eq(dst, { 'a.txt' }, 'the destination is exactly as it was')
    H.assert_fs_eq(src, { 'a.txt' }, 'the source is untouched')

    -- The same tree on the path that destroys nothing: the overwrite stays.
    local bok = fs.copy_tree(src, dst)
    H.assert_true(bok == true, 'best-effort mode still succeeds on the same tree')
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'NEW' },
      'best-effort mode keeps its overwrite semantics (yank/paste)')
  end)

  -- A pre-scan cannot see destinations created during copying, so the walk
  -- checks each path immediately before use and leaves foreign entries intact.
  H.it('complete mode refuses a destination entry created mid-copy', function()
    local sb = H.sandbox()
    local src = H.mkdir(sb.root, 'src')
    H.mkfile(src, 'a.txt', { 'a' })
    H.mkfile(src, 'zz-clash', { 'SOURCE FILE' })
    local dst = sb.root .. '/dst'

    local injected = false
    local real_mkdirp = fs.mkdirp
    local restore = H.stub(fs, 'mkdirp', function(path)
      local ok, err = real_mkdirp(path)
      if ok and not injected and path == dst then
        injected = true
        -- FOREIGN: a destination entry created by someone else, mid-copy.
        H.mkfile(dst, 'zz-clash/keep.txt', { 'PRE-EXISTING DATA' })
      end
      return ok, err
    end)
    local ok, err = fs.copy_tree(src, dst, { require_complete = true })
    restore()

    H.assert_true(injected, 'the foreign destination entry was created during the copy')
    H.assert_true(fs.exists(dst .. '/zz-clash/keep.txt'),
      'the foreign entry the copy did not create survives the cleanup')
    H.assert_eq(vim.fn.readfile(dst .. '/zz-clash/keep.txt'), { 'PRE-EXISTING DATA' },
      'the foreign entry keeps its contents')
    H.assert_nil(ok, 'the copy refuses instead of writing to it: ' .. tostring(err))
    H.assert_true(type(err) == 'string' and err:find('destination exists', 1, true) ~= nil,
      'the refusal names the destination clash: ' .. tostring(err))
    H.assert_false(fs.exists(dst .. '/a.txt'), 'the copy\'s own partial file is removed')
    H.assert_fs_eq(dst, { 'zz-clash/', 'zz-clash/keep.txt' },
      'the destination holds exactly the foreign entry and nothing this copy created')
    H.assert_fs_eq(src, { 'a.txt', 'zz-clash' }, 'the source is untouched')
  end)

  H.it('list_dir is sorted and the thin wrappers behave', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'c.txt', { 'c' })
    H.mkfile(sb.root, 'a.txt', { 'a' })
    H.mkfile(sb.root, 'b.txt', { 'b' })
    H.mkdir(sb.root, 'sub')
    H.assert_eq(fs.list_dir(sb.root), { 'a.txt', 'b.txt', 'c.txt', 'data', 'sub' },
      'list_dir sorted ascending')

    H.assert_eq(fs.basename('/a/b/'), 'b', 'basename strips trailing slash')
    H.assert_eq(fs.basename('/a/b'), 'b', 'basename without trailing slash')
    H.assert_eq(fs.dirname('/a/b/c'), '/a/b', 'dirname')
    H.assert_eq(fs.join('/a', 'b', 'c'), '/a/b/c', 'join')
    H.assert_true(fs.abspath('x'):sub(1, 1) == '/', 'abspath is absolute')
    H.assert_eq(fs.realpath(sb.root .. '/a.txt'), vim.uv.fs_realpath(sb.root .. '/a.txt'),
      'realpath resolves')
    H.assert_eq(fs.realpath(sb.root .. '/missing'), sb.root .. '/missing',
      'realpath falls back to the input')

    local st = fs.stat(sb.root .. '/a.txt')
    H.assert_true(st ~= nil and st.type == 'file', 'stat returns a stat table')
    local missing, stat_err = fs.stat(sb.root .. '/missing')
    H.assert_nil(missing, 'stat missing returns nil')
    H.assert_true(type(stat_err) == 'string', 'stat missing carries an err')

    local seen = {}
    for name, typ in fs.iter_dir(sb.root) do
      seen[name] = typ
    end
    H.assert_eq(seen['a.txt'], 'file', 'iter_dir yields files')
    H.assert_eq(seen['data'], 'directory', 'iter_dir yields directories')
    local count = 0
    for _ in fs.iter_dir(sb.root .. '/missing') do
      count = count + 1
    end
    H.assert_eq(count, 0, 'iter_dir on a bad path yields nothing')
  end)

  H.it('copy_tree honours a stub on M.copy_file (module-table seam)', function()
    -- Calls go through the module table so a stub on M.copy_file reaches
    -- M.copy_tree; this test protects that injection seam.
    local sb = H.sandbox()
    H.mkfile(sb.root, 'tree/a.txt', { 'a' })
    local restore = H.stub(fs, 'copy_file', function()
      return nil, 'forced'
    end)
    local ok, err = fs.copy_tree(sb.root .. '/tree', sb.root .. '/copy')
    restore()

    H.assert_nil(ok, 'copy_tree propagates the stubbed failure')
    H.assert_eq(err, 'forced', 'the stub error propagates untouched')
    H.assert_false(fs.exists(sb.root .. '/copy/a.txt'), 'no file was copied')
  end)

  H.it('mkdirp/touch/basename/abspath reject non-string input without touching disk', function()
    -- Without the guards, fs.mkdirp(42) creates a directory named
    -- `42` in the cwd and fs.mkdirp(nil) creates a literal `v:null`
    -- directory (a stray `v:null/` from that class of bug already sat in the
    -- repo root before this phase). Each call must return nil, err and create
    -- nothing anywhere.
    local sb = H.sandbox()
    local cwd = vim.fn.getcwd()

    local r, e = fs.mkdirp(42)
    H.assert_nil(r, 'mkdirp(42) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'mkdirp(42) carries an err')
    H.assert_eq(vim.fn.isdirectory(vim.fs.joinpath(cwd, '42')), 0,
      'mkdirp(42) created nothing in the cwd')

    r, e = fs.mkdirp(nil)
    H.assert_nil(r, 'mkdirp(nil) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'mkdirp(nil) carries an err')
    H.assert_eq(vim.fn.isdirectory(vim.fs.joinpath(cwd, 'v:null')), 0,
      'mkdirp(nil) created no literal v:null directory in the cwd')

    r, e = fs.touch(nil)
    H.assert_nil(r, 'touch(nil) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'touch(nil) carries an err')
    r, e = fs.touch(42)
    H.assert_nil(r, 'touch(42) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'touch(42) carries an err')

    r, e = fs.basename(42)
    H.assert_nil(r, 'basename(42) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'basename(42) carries an err')

    r, e = fs.abspath(nil)
    H.assert_nil(r, 'abspath(nil) returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'abspath(nil) carries an err')

    -- The sandbox (and only the sandbox) is untouched: still just the data
    -- home the harness points into it.
    H.assert_fs_eq(sb.root, { 'data/' }, 'sandbox untouched by the rejected calls')
  end)
end)
