-- tests/fs_spec.lua -- the filesystem seam contract (T-007, spec section 8).
--
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

  H.it('non-string inputs return nil, err instead of raising (B2)', function()
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

  H.it('same_path is ino+dev for two spellings of a symlinked prefix (B9/D2)', function()
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

  H.it('a non-EXDEV rename error propagates and leaves the source intact (D5)', function()
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

  -- P1 (Greptile, PR #1): copy_tree used to copy only 'file'/'directory' stats
  -- and silently skip everything else while still returning true, and
  -- rename()'s EXDEV fallback then removed the source tree -- so a cross-device
  -- move destroyed symlinks/FIFOs/sockets with no warning.
  --
  -- P1 follow-up (review): the refusal is the DESTRUCTIVE caller's contract, so
  -- it is REQUESTED (`{ require_complete = true }`) by the caller that removes
  -- the source after a successful copy -- rename's EXDEV fallback, which the
  -- tests below pin end to end. The WALK is the single authority (there is no
  -- up-front-only scan to outrun), and a refusal discards whatever the copy had
  -- already created, so the source is intact and no destination is left behind.
  H.it('copy_tree with require_complete refuses a symlink tree, leaving no destination (P1)', function()
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

  -- P1 follow-up (review, Greptile P1): the same tree copied by a caller that
  -- destroys NOTHING (a yank, a paste) must not fail -- failing it broke an
  -- ordinary yank of any tree that merely CONTAINS a symlink. Everything
  -- reproducible is copied, the symlink is left out, and the omission is
  -- REPORTED as the second return value instead of being dropped silently.
  H.it('copy_tree without require_complete copies what it can and reports the symlink it skipped (P1)', function()
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

  H.it('an EXDEV move of a tree holding a symlink fails loudly and keeps the source (P1)', function()
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

  H.it('copy_tree with require_complete refuses a FIFO, leaving no destination (P1)', function()
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

  -- P1 follow-up (review): `list_dir` returns nil only for a non-directory; a
  -- directory whose entries cannot be read (EACCES) goes through `iter_dir`,
  -- which swallows the scandir failure and yields nothing -- so `list_dir`
  -- returned an EMPTY listing and the copy saw "nothing uncopyable". It then
  -- returned TRUE with the locked subtree silently missing (probe at 51bb146),
  -- and on the EXDEV move path the source is removed afterwards: a silent
  -- destroy that the refusal exists to prevent.
  --
  -- This test REPLACES the pre-scan-era test of the same guarantee. The walk is
  -- now the single authority, so the guarantee is kept by copy_dir probing each
  -- directory with fs_scandir as it descends; the locked subtree is placed after
  -- a copyable one so the destination the refusal discards is genuinely non-empty.
  -- Skipped under root, which ignores permission bits.
  H.it('copy_tree with require_complete refuses an unreadable directory, leaving no destination (P1)', function()
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

  -- P1 follow-up (review): a caller that destroys nothing gets a best-effort
  -- copy. The locked subtree is REPORTED, never silently short: an empty
  -- `locked/` standing in for contents that could not be read would hide the
  -- omission instead of surfacing it.
  H.it('copy_tree without require_complete reports an unreadable directory it skipped (P1)', function()
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

  -- P1 regression (Greptile on 7d5ce12, "Moves can lose new entries"): the
  -- round that narrowed the refusal replaced the per-subtree re-check with one
  -- up-front scan, so an entry that appeared AFTER that scan was neither refused
  -- nor reported -- copy_dir simply left it out -- and rename's EXDEV fallback
  -- then removed the source, destroying it silently. The walk is now the single
  -- authority and re-lists every directory as it descends, so each entry is
  -- classified after the copy has started.
  --
  -- The injection is deterministic: M.mkdirp is a module-table seam (section 8),
  -- and the stub creates the entry at the copy's first mkdirp, i.e. inside the
  -- walk. No sleeping and no reliance on scheduling, so this cannot flake.
  H.it('an entry that appears after the copy started still refuses the copy (P1)', function()
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

  -- The other half of the same regression: on a path that destroys nothing, the
  -- late entry must still be REPORTED. At 7d5ce12 it was followed as a copy of
  -- its target and copy_tree returned true with no skip report at all.
  H.it('an entry that appears after the copy started is still reported, not dropped (P1)', function()
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

  -- End to end on the path the invariant is about: a source-removing move must
  -- never delete a source it could not copy completely, whenever the entry shows
  -- up. At 7d5ce12 this probe returned true and the source tree was gone.
  H.it('a cross-device move never removes a source it could not copy completely (P1)', function()
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

  -- The cleanup a refusal now performs must undo only what THAT copy created: a
  -- destination that already existed belongs to its owner and is left alone.
  H.it('a refused copy removes only what it created (P1)', function()
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

  H.it('copy_tree honours a stub on M.copy_file (module-table seam, O1)', function()
    -- The seam rule (section 8: functions call each other through the module
    -- table) is pinned here: a test stub on M.copy_file must be seen by
    -- M.copy_tree. A previous pass captured copy_file locally, the suite
    -- stayed green, and nothing pinned the seam (P1 gate review, O1).
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

  H.it('mkdirp/touch/basename/abspath reject non-string input without touching disk (O3)', function()
    -- O3 sweep: without the guards, fs.mkdirp(42) creates a directory named
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
