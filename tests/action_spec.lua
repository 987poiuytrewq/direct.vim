-- tests/action_spec.lua -- filesystem actions and history serialization.
-- Covers reversals, pathname identity, trash handling, and paste behavior.

local H = require('tests.support.harness')
local M = require('direct.action')
local paths = require('direct.paths')

H.describe('action', function()
  H.it('Move preserves the inode for files and directories', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    H.mkdir(sb.root, 'dir1')
    H.mkfile(sb.root, 'dir1/sub.txt', { 's' })

    local file_ino = H.inode_of(sb.root .. '/a.txt')
    H.assert_true(M.Move(sb.root .. '/a.txt', sb.root .. '/b.txt')['do']() ~= nil,
      'file move succeeds')
    H.assert_eq(H.inode_of(sb.root .. '/b.txt'), file_ino,
      'file inode preserved across a move')
    H.assert_false(H.exists(sb.root, 'a.txt'), 'file source gone')

    local dir_ino = H.inode_of(sb.root .. '/dir1')
    local sub_ino = H.inode_of(sb.root .. '/dir1/sub.txt')
    H.assert_true(M.Move(sb.root .. '/dir1', sb.root .. '/dir2')['do']() ~= nil,
      'directory move succeeds')
    H.assert_eq(H.inode_of(sb.root .. '/dir2'), dir_ino,
      'directory inode preserved across a move')
    H.assert_eq(H.inode_of(sb.root .. '/dir2/sub.txt'), sub_ino,
      'nested entry inode preserved')
    H.assert_false(H.exists(sb.root, 'dir1'), 'directory source gone')
  end)

  H.it('Move permits a case-only rename when both spellings are the same entry', function()
    local sb = H.sandbox()
    local source = H.mkfile(sb.root, 'foo.txt', { 'case-only content' })
    local alternate = sb.root .. '/Foo.txt'
    if vim.uv.fs_lstat(alternate) == nil then
      -- Case-sensitive filesystems have two distinct names here; this specific
      -- action contract applies only when the alternate spelling aliases src.
      return
    end

    local ok, err = M.Move(source, alternate)['do']()

    H.assert_true(ok == true, 'same-entry destination is not an occupied collision: ' .. tostring(err))
    H.assert_eq(vim.fn.readfile(alternate), { 'case-only content' }, 'content survives')
    local names = {}
    for name in vim.fs.dir(sb.root) do names[#names + 1] = name end
    table.sort(names)
    H.assert_eq(names, { 'Foo.txt', 'data' }, 'the directory entry uses the requested spelling')
  end)

  H.it('Move refuses a hardlink destination even when it shares the source inode', function()
    local sb = H.sandbox()
    local source = H.mkfile(sb.root, 'foo.txt', { 'preserve both names' })
    local destination = sb.root .. '/Foo.txt'
    if vim.uv.fs_link(source, destination) ~= true then return end

    local ok, err = M.Move(source, destination)['do']()

    H.assert_nil(ok, 'a hardlink is a distinct occupied pathname')
    H.assert_true(tostring(err):find('destination exists', 1, true) ~= nil, tostring(err))
    H.assert_eq(vim.fn.readfile(source), { 'preserve both names' }, 'source remains')
    H.assert_eq(vim.fn.readfile(destination), { 'preserve both names' }, 'hardlink remains')
  end)

  -- Match the resolved pathname, not inode identity: hard links are distinct
  -- names, while symlink prefixes, `..`, and trailing slashes resolve alike.
  H.describe('action: close_src_buffer pathname identity', function()
    H.it('a buffer on one hardlink survives close_src_buffer of another', function()
      local sb = H.sandbox()
      H.mkfile(sb.root, 'a.txt', { 'a' })
      H.assert_true(vim.uv.fs_link(sb.root .. '/a.txt', sb.root .. '/b.txt') == true,
        'hardlink created')

      -- Neovim refuses a second buffer for the other hard link (E95), so an
      -- inode-based close could discard the only buffer's unsaved edits when
      -- an action targets the other pathname.
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, sb.root .. '/a.txt')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved edit' })
      H.assert_true(vim.bo[buf].modified, 'the buffer is modified')

      -- Renaming/deleting b.txt must not close the buffer for a.txt.
      H.assert_true(M.close_src_buffer(sb.root .. '/b.txt') == true,
        'close_src_buffer succeeded')

      H.assert_true(vim.api.nvim_buf_is_valid(buf),
        'the other hardlink buffer is still open')
      H.assert_eq(H.buf_lines(buf), { 'unsaved edit' }, 'its unsaved edits are intact')
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    H.it('still closes a buffer whose name is the resolved target (symlinked prefix)', function()
      -- The trap the naive fix falls into: nvim resolves a symlinked prefix in
      -- the stored buffer name (the macOS /tmp -> /private/tmp case), so a
      -- plain vim.fs.normalize(a) == normalize(b) comparison would MISS the
      -- buffer. realpath resolves both sides, so the unresolved spelling must
      -- still close it.
      local sb = H.sandbox()
      H.mkdir(sb.root, 'realdir')
      H.mkfile(sb.root, 'realdir/file.txt', { 'x' })
      pcall(vim.uv.fs_symlink, sb.root .. '/realdir', sb.root .. '/linkdir')
      H.assert_true(vim.uv.fs_lstat(sb.root .. '/linkdir') ~= nil, 'prefix symlink created')

      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, sb.root .. '/linkdir/file.txt')
      H.assert_eq(vim.api.nvim_buf_get_name(buf), sb.root .. '/realdir/file.txt',
        'premise: nvim stored the resolved spelling')

      H.assert_true(M.close_src_buffer(sb.root .. '/linkdir/file.txt') == true,
        'close_src_buffer succeeded for the unresolved spelling')
      H.assert_false(vim.api.nvim_buf_is_valid(buf), 'the buffer was closed')
    end)

    H.it('matches the same file reached through a .. or a trailing-slash spelling', function()
      local sb = H.sandbox()
      H.mkdir(sb.root, 'sub')
      H.mkfile(sb.root, 'real.txt', { 'x' })
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, sb.root .. '/real.txt')

      H.assert_true(M.close_src_buffer(sb.root .. '/sub/../real.txt') == true,
        'close_src_buffer succeeded for a .. spelling')
      H.assert_false(vim.api.nvim_buf_is_valid(buf), 'the buffer was closed')

      H.mkdir(sb.root, 'adir')
      local d = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(d, sb.root .. '/adir')
      H.assert_true(M.close_src_buffer(sb.root .. '/adir/') == true,
        'close_src_buffer succeeded for a directory named with a trailing slash')
      H.assert_false(vim.api.nvim_buf_is_valid(d), 'the directory buffer was closed')
    end)
  end)

  H.it('Remove and RemoveDirectory send entries to the trash', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.mkdir(sb.root, 'dir1')
    H.mkfile(sb.root, 'dir1/sub.txt', { 's' })

    local file_ino = H.inode_of(sb.root .. '/f.txt')
    local remove = M.Remove(sb.root .. '/f.txt')
    H.assert_true(remove['do']() ~= nil, 'remove succeeds')
    H.assert_false(H.exists(sb.root, 'f.txt'), 'file gone from the workspace')
    H.assert_true(remove.dst ~= nil, 'trash destination was resolved')
    H.assert_true(vim.fn.isdirectory(sb.data_home .. '/direct/trash') == 1,
      'trash dir lives under the data home')
    H.assert_eq(remove.dst:sub(1, #(sb.data_home .. '/direct/trash')),
      sb.data_home .. '/direct/trash', 'trash entry is under <data_home>/direct/trash')
    H.assert_eq(H.inode_of(remove.dst), file_ino, 'trashed file keeps its inode')

    local sub_ino = H.inode_of(sb.root .. '/dir1/sub.txt')
    local rmdir = M.RemoveDirectory(sb.root .. '/dir1')
    H.assert_true(rmdir['do']() ~= nil, 'remove directory succeeds')
    H.assert_false(H.exists(sb.root, 'dir1'), 'directory gone from the workspace')
    H.assert_eq(H.inode_of(rmdir.dst .. '/sub.txt'), sub_ino,
      'trashed directory tree keeps its inodes')
  end)

  -- Use the same lstat-based occupancy check as copy and paste: a dangling
  -- symlink occupies the trash name even though fs.exists follows it.
  H.it('first_free_trash skips a dangling symlink at the candidate name', function()
    local sb = H.sandbox()
    local trash = M.paths.join(sb.data_home, 'direct/trash')
    H.mkdir(trash, '')
    H.mkfile(sb.root, 'f.txt', { 'f' })
    local src = sb.root .. '/f.txt'
    local base = M.paths.digest(src)
    H.assert_true(vim.uv.fs_symlink(trash .. '/nowhere', trash .. '/' .. base) == true,
      'dangling symlink occupying the base trash name')
    H.assert_false(vim.uv.fs_stat(trash .. '/' .. base) ~= nil,
      'the following check reports the name free')

    H.assert_eq(M.first_free_trash(trash, src), trash .. '/' .. base .. '-1',
      'the picker skips the occupied name instead of naming a taken destination')
  end)

  H.it('Restore brings a file and RestoreDirectory a tree back', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.mkdir(sb.root, 'dir1')
    H.mkfile(sb.root, 'dir1/sub.txt', { 's' })

    local remove = M.Remove(sb.root .. '/f.txt')
    remove['do']()
    local rmdir = M.RemoveDirectory(sb.root .. '/dir1')
    rmdir['do']()

    H.assert_true(M.Restore(remove.dst, remove.src)['do']() ~= nil, 'restore succeeds')
    H.assert_eq(vim.fn.readfile(sb.root .. '/f.txt'), { 'f' },
      'file restored with content')
    H.assert_true(M.RestoreDirectory(rmdir.dst, rmdir.src)['do']() ~= nil,
      'restore directory succeeds')
    -- Restore moves the content out and leaves an EMPTY MARKER at the
    -- trash slot, so the trash dir holds two marker entries alongside the
    -- restored workspace (an empty file and an empty directory).
    H.assert_fs_eq(sb.root, {
      'data/',
      'data/direct/',
      'data/direct/trash/',
      'data/direct/trash/' .. paths.digest(sb.root .. '/f.txt'),
      'data/direct/trash/' .. paths.digest(sb.root .. '/dir1') .. '/',
      'dir1/',
      'dir1/sub.txt',
      'f.txt',
    }, 'workspace back to the original shape, trash holds only the markers')
    H.assert_eq(vim.fn.readfile(remove.dst), {}, 'the marker file is empty')
    H.assert_eq(#vim.fn.readdir(rmdir.dst), 0, 'the marker directory is empty')
  end)

  H.it('remove/restore/remove yields two distinct trash entries with no nesting', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })

    local r1 = M.Remove(sb.root .. '/f.txt')
    H.assert_true(r1['do']() ~= nil, 'first remove')
    H.assert_true(r1.dst ~= nil, 'first trash path resolved')
    local t1 = r1.dst
    H.assert_eq(vim.fs.basename(t1), paths.digest(sb.root .. '/f.txt'),
      'first entry is the bare digest')

    H.assert_true(M.Restore(t1, sb.root .. '/f.txt')['do']() ~= nil, 'restore')
    H.assert_true(H.exists(sb.root, 'f.txt'), 'file is back')

    local r2 = M.Remove(sb.root .. '/f.txt')
    H.assert_true(r2['do']() ~= nil, 'second remove')
    H.assert_true(r2.dst ~= nil, 'second trash path resolved')
    local t2 = r2.dst

    H.assert_true(t1 ~= t2, 'two distinct trash entries')
    H.assert_eq(vim.fs.basename(t2), vim.fs.basename(t1) .. '-1',
      'the second entry is the first free -<n> sibling')

    -- No nesting: the trash dir holds exactly two sibling entries, and the
    -- second is a file like the first (not a directory inside the first).
    local trash_dir = vim.fs.dirname(t1)
    local names = {}
    for name in vim.fs.dir(trash_dir) do
      names[#names + 1] = name
    end
    table.sort(names)
    H.assert_eq(names, { vim.fs.basename(t1), vim.fs.basename(t2) },
      'trash holds exactly the two sibling entries')
    H.assert_eq(vim.fn.isdirectory(t2), 0, 'no nested directory was created')
  end)

  H.it('Touch and MakeDirectory create entries', function()
    local sb = H.sandbox()
    H.assert_true(M.Touch(sb.root .. '/new.txt')['do']() ~= nil, 'touch succeeds')
    H.assert_true(H.exists(sb.root, 'new.txt'), 'file created')
    H.assert_eq(vim.fn.readfile(sb.root .. '/new.txt'), {}, 'file is empty')
    H.assert_true(M.MakeDirectory(sb.root .. '/newdir')['do']() ~= nil, 'mkdir succeeds')
    H.assert_eq(vim.fn.isdirectory(sb.root .. '/newdir'), 1, 'directory created')
  end)

  H.it('execute dispatches by action kind and the legacy do method delegates to it', function()
    local sb = H.sandbox()
    local dispatched = M.Touch(sb.root .. '/via-execute.txt')
    H.assert_true(M.execute(dispatched) == true, 'the kind executor creates the file')
    H.assert_true(H.exists(sb.root, 'via-execute.txt'), 'the dispatched action ran')

    local legacy = M.Touch(sb.root .. '/via-do.txt')
    H.assert_true(legacy['do']() == true, 'the compatibility method uses execute dispatch')
    H.assert_true(H.exists(sb.root, 'via-do.txt'), 'the compatibility action ran')

    local ok, err = M.execute({ name = 'unknown' })
    H.assert_nil(ok, 'an unknown action has no executor')
    H.assert_true(tostring(err):find('no executor', 1, true) ~= nil, tostring(err))

    local mismatch = M.Touch(sb.root .. '/must-not-run.txt')
    mismatch.name = 'mkdir'
    ok, err = M.execute(mismatch)
    H.assert_nil(ok, 'an action cannot dispatch through another kind')
    H.assert_true(tostring(err):find('kind mismatch', 1, true) ~= nil, tostring(err))
    H.assert_false(H.exists(sb.root, 'must-not-run.txt'),
      'a mismatched action did not run its original executor')
  end)

  H.it('creation and move actions refuse occupied destinations without overwriting', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'source.txt', { 'source' })
    H.mkfile(sb.root, 'occupied.txt', { 'do not replace' })
    local occupied_before = vim.fn.readfile(sb.root .. '/occupied.txt', 'b')
    local source_before = vim.fn.readfile(sb.root .. '/source.txt', 'b')

    local touched, touch_err = M.Touch(sb.root .. '/occupied.txt')['do']()
    local made, mkdir_err = M.MakeDirectory(sb.root .. '/occupied.txt')['do']()
    local moved, move_err = M.Move(sb.root .. '/source.txt', sb.root .. '/occupied.txt')['do']()

    H.assert_nil(touched, 'touch refuses an existing destination')
    H.assert_true(tostring(touch_err):find('destination exists', 1, true) ~= nil,
      tostring(touch_err))
    H.assert_nil(made, 'mkdir refuses an existing destination')
    H.assert_true(tostring(mkdir_err):find('destination exists', 1, true) ~= nil,
      tostring(mkdir_err))
    H.assert_nil(moved, 'move refuses an existing destination')
    H.assert_true(tostring(move_err):find('destination exists', 1, true) ~= nil,
      tostring(move_err))
    H.assert_eq(vim.fn.readfile(sb.root .. '/occupied.txt', 'b'), occupied_before,
      'the occupied destination is unchanged')
    H.assert_eq(vim.fn.readfile(sb.root .. '/source.txt', 'b'), source_before,
      'the move source is unchanged')
  end)

  H.it('move never overwrites a target that appears after the action check', function()
    local sb = H.sandbox()
    local src, dst = H.mkfile(sb.root, 'source.txt', { 'SOURCE' }), sb.root .. '/target.txt'
    local real = M.fs.rename_noreplace
    local injected = false
    local restore = H.stub(M.fs, 'rename_noreplace', function(from, to)
      if from == src and to == dst and not injected then
        injected = true
        H.mkfile(sb.root, 'target.txt', { 'FOREIGN' })
      end
      return real(from, to)
    end)

    local ok, err = M.Move(src, dst)['do']()
    restore()

    H.assert_true(injected, 'the destination raced in after the action check')
    H.assert_nil(ok, 'atomic no-replace rejects the raced destination')
    H.assert_true(tostring(err):find('destination exists', 1, true) ~= nil, tostring(err))
    H.assert_eq(vim.fn.readfile(src), { 'SOURCE' }, 'source remains unchanged')
    H.assert_eq(vim.fn.readfile(dst), { 'FOREIGN' }, 'the raced occupant remains unchanged')
  end)

  H.it('touch and mkdir remain exclusive when a destination races in', function()
    local sb = H.sandbox()
    local file = sb.root .. '/new.txt'
    local real_touch = M.fs.touch
    local touch_injected = false
    local restore_touch = H.stub(M.fs, 'touch', function(path)
      if not touch_injected then
        touch_injected = true
        H.mkfile(sb.root, 'new.txt', { 'FOREIGN' })
      end
      return real_touch(path)
    end)
    local touched, touch_err = M.Touch(file)['do']()
    restore_touch()
    H.assert_true(touch_injected, 'file appeared after the action check')
    H.assert_nil(touched, 'wx refuses the raced file')
    H.assert_true(tostring(touch_err):find('destination exists', 1, true) ~= nil,
      tostring(touch_err))
    H.assert_eq(vim.fn.readfile(file), { 'FOREIGN' }, 'raced file was not truncated')

    local dir = sb.root .. '/newdir'
    local real_mkdir = M.fs.mkdir_exclusive
    local mkdir_injected = false
    local restore_mkdir = H.stub(M.fs, 'mkdir_exclusive', function(path)
      if not mkdir_injected then
        mkdir_injected = true
        H.mkdir(sb.root, 'newdir')
        H.mkfile(sb.root, 'newdir/foreign.txt', { 'KEEP' })
      end
      return real_mkdir(path)
    end)
    local made, mkdir_err = M.MakeDirectory(dir)['do']()
    restore_mkdir()
    H.assert_true(mkdir_injected, 'directory appeared after the action check')
    H.assert_nil(made, 'exclusive mkdir refuses the raced directory')
    H.assert_true(tostring(mkdir_err):find('destination exists', 1, true) ~= nil,
      tostring(mkdir_err))
    H.assert_eq(vim.fn.readfile(dir .. '/foreign.txt'), { 'KEEP' },
      'raced directory contents remain untouched')
  end)

  H.it('trash and restore use atomic no-replace placement', function()
    local sb = H.sandbox()
    M.paths.ensure_data_dir('trash')
    local src = H.mkfile(sb.root, 'source.txt', { 'SOURCE' })
    local remove = M.Remove(src)
    local trash = remove.dst
    local real = M.fs.rename_noreplace
    local injected = false
    local restore = H.stub(M.fs, 'rename_noreplace', function(from, to)
      if from == src and to == trash and not injected then
        injected = true
        H.mkfile(vim.fs.dirname(trash), vim.fs.basename(trash), { 'FOREIGN' })
      end
      return real(from, to)
    end)
    local removed, remove_err = remove['do']()
    restore()
    H.assert_true(injected, 'the trash slot raced in')
    H.assert_nil(removed, 'trash move refuses the occupied slot')
    H.assert_true(tostring(remove_err):find('destination exists', 1, true) ~= nil,
      tostring(remove_err))
    H.assert_eq(vim.fn.readfile(src), { 'SOURCE' }, 'source remains')
    H.assert_eq(vim.fn.readfile(trash), { 'FOREIGN' }, 'foreign trash occupant remains')

    local restore_src = H.mkfile(sb.root, 'trash-entry', { 'TRASH' })
    local restore_dst = sb.root .. '/restored.txt'
    local real_restore = M.fs.rename_noreplace
    local restore_injected = false
    local restore_stub = H.stub(M.fs, 'rename_noreplace', function(from, to)
      if from == restore_src and to == restore_dst and not restore_injected then
        restore_injected = true
        H.mkfile(sb.root, 'restored.txt', { 'KEEP' })
      end
      return real_restore(from, to)
    end)
    local restored, restore_err = M.Restore(restore_src, restore_dst)['do']()
    restore_stub()
    H.assert_true(restore_injected, 'restore destination raced in')
    H.assert_nil(restored, 'restore refuses to overwrite the raced destination')
    H.assert_true(tostring(restore_err):find('destination exists', 1, true) ~= nil,
      tostring(restore_err))
    H.assert_eq(vim.fn.readfile(restore_src), { 'TRASH' }, 'trash source remains')
    H.assert_eq(vim.fn.readfile(restore_dst), { 'KEEP' }, 'raced destination remains')
  end)

  H.it('stage_moves preserves a temp occupant that races in after selection', function()
    local sb = H.sandbox()
    local src_a = H.mkfile(sb.root, 'a.txt', { 'A' })
    local src_b = H.mkfile(sb.root, 'b.txt', { 'B' })
    local temp = M.first_free_temp(sb.root)
    local real = M.fs.rename_noreplace
    local injected = false
    local restore = H.stub(M.fs, 'rename_noreplace', function(from, to)
      if from == src_a and to == temp and not injected then
        injected = true
        H.mkfile(sb.root, vim.fs.basename(temp), { 'FOREIGN' })
      end
      return real(from, to)
    end)

    local staging, err, temps = M.stage_moves({
      M.Move(src_a, src_b), M.Move(src_b, src_a),
    })
    restore()

    H.assert_true(injected, 'temp path was occupied after selection')
    H.assert_nil(staging, 'staging fails rather than replacing the occupant')
    H.assert_true(tostring(err):find('destination exists', 1, true) ~= nil, tostring(err))
    H.assert_eq(temps, {}, 'no source was displaced')
    H.assert_eq(vim.fn.readfile(src_a), { 'A' }, 'first source remains')
    H.assert_eq(vim.fn.readfile(src_b), { 'B' }, 'second source remains')
    H.assert_eq(vim.fn.readfile(temp), { 'FOREIGN' }, 'raced temp occupant is untouched')
  end)

  H.it('action guards treat trailing-slash dangling symlink destinations as occupied', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'source.txt', { 'source' })
    local occupied = sb.root .. '/target.log'
    H.assert_true(vim.uv.fs_symlink(sb.root .. '/missing', occupied) == true,
      'dangling symlink created')
    H.assert_true(M.fs.taken(occupied .. '/'),
      'occupancy checks preserve the directory marker while finding the link')
    H.assert_true(M.fs.taken('/'), 'the filesystem root remains occupied')

    local made, make_err = M.MakeDirectory(occupied .. '/')['do']()
    local moved, move_err = M.Move(sb.root .. '/source.txt', occupied .. '/')['do']()

    H.assert_nil(made, 'mkdir refuses the dangling symlink destination')
    H.assert_true(tostring(make_err):find('destination exists', 1, true) ~= nil,
      tostring(make_err))
    H.assert_nil(moved, 'move refuses the dangling symlink destination')
    H.assert_true(tostring(move_err):find('destination exists', 1, true) ~= nil,
      tostring(move_err))
    H.assert_true(vim.uv.fs_lstat(occupied) ~= nil, 'the symlink remains in place')
    H.assert_eq(vim.fn.readfile(sb.root .. '/source.txt'), { 'source' },
      'the move source remains unchanged')
  end)

  H.it('describe() is CWD-relative and human', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    H.mkdir(sb.root, 'tree')
    H.with_cwd(sb.root, function()
      H.assert_eq(M.Move(sb.root .. '/a.txt', sb.root .. '/b.txt').describe(),
        'Moved a.txt to b.txt', 'move')
      H.assert_eq(M.Remove(sb.root .. '/a.txt').describe(),
        'Removed a.txt', 'remove')
      H.assert_eq(M.RemoveDirectory(sb.root .. '/tree').describe(),
        'Removed tree', 'remove directory')
      H.assert_eq(M.Restore(sb.root .. '/x', sb.root .. '/a.txt').describe(),
        'Restored a.txt', 'restore')
      H.assert_eq(M.RestoreDirectory(sb.root .. '/x', sb.root .. '/tree').describe(),
        'Restored tree', 'restore directory')
      H.assert_eq(M.Touch(sb.root .. '/c.txt').describe(),
        'Created c.txt', 'touch')
      H.assert_eq(M.MakeDirectory(sb.root .. '/d').describe(),
        'Created d', 'make directory')
      H.assert_eq(M.Paste(sb.root .. '/reg', sb.root, { 'e' }, { 'e' }).describe(),
        'Pasted into ./', 'paste carries the trailing separator')
      H.assert_eq(M.Unpaste(sb.root, sb.root .. '/reg', { 'e' }, { 'e' }).describe(),
        'Reversed paste into ./', 'unpaste')
    end)
  end)

  H.it('serialize() emits canonical JSON records with fixed key order', function()
    local sb = H.sandbox()
    H.assert_eq(M.serialize(M.Move('/r/a', '/r/b')),
      '{"op":"mv","src":"/r/a","dst":"/r/b"}', 'mv')
    H.assert_eq(M.serialize(M.Touch('/r/t')), '{"op":"touch","dst":"/r/t"}', 'touch')
    H.assert_eq(M.serialize(M.MakeDirectory('/r/d')),
      '{"op":"mkdir","dst":"/r/d"}', 'mkdir')
    H.assert_eq(M.serialize(M.Restore('/r/trash', '/r/a')),
      '{"op":"rs","src":"/r/trash","dst":"/r/a"}', 'rs')

    local remove = M.Remove('/r/f')
    H.assert_eq(M.serialize(remove),
      '{"op":"rm","src":"/r/f","dst":' .. vim.json.encode(remove.dst) .. '}',
      'rm stores the resolved trash dst')

    H.assert_eq(
      M.serialize(M.Paste('/r/reg', '/r/dst', { 'a', 'b' }, { 'a', 'b' })),
      '{"op":"p","src":"/r/reg","dst":"/r/dst",'
        .. '"src_names":["a","b"],"dst_names":["a","b"]}', 'p name arrays')
    H.assert_eq(
      M.serialize(M.Unpaste('/r/dst', '/r/reg', { 'a', 'b' }, { 'a', 'b' })),
      '{"op":"up","src":"/r/dst","dst":"/r/reg",'
        .. '"src_names":["a","b"],"dst_names":["a","b"]}', 'up name arrays')
  end)

  H.it('path_reason and serialize refuse only unrepresentable path fields', function()
    -- path_reason is the universal guard serialize runs over every
    -- field. A normal path and a SPACE path are representable; a tab (the
    -- FIELD_SEPARATOR) and any other control character (a newline included) are
    -- not.
    H.assert_nil(M.path_reason('/r/a.txt'), 'a normal path is representable')
    H.assert_nil(M.path_reason('/r/my file.txt'), 'a space path is representable')
    H.assert_eq(M.path_reason('/r/f\to'), 'contains a tab', 'a tab is refused')
    H.assert_eq(M.path_reason('/r/f\nx'), 'contains a control character',
      'a newline is refused')

    -- serialize returns nil, err rather than emitting a corrupted line.
    local line, err = M.serialize(M.Touch('/r/a\tb'))
    H.assert_nil(line, 'a tab-carrying field emits no line')
    H.assert_true(type(err) == 'string' and #err > 0, 'serialize carries a reason')

    H.assert_eq(M.serialize(M.Touch('/r/a b')), '{"op":"touch","dst":"/r/a b"}',
      'a space path serializes verbatim')
  end)

  H.it('entry_name_reason accepts spaces but rejects invalid basename components', function()
    H.assert_nil(M.entry_name_reason('notes.txt'),
      'a normal name can round-trip')
    H.assert_eq(M.entry_name_reason(''), 'empty', 'an empty name is refused')
    H.assert_eq(M.entry_name_reason(nil), 'empty', 'a non-string name is refused')
    H.assert_nil(M.entry_name_reason('my file.txt'), 'spaces are valid JSON array values')
    H.assert_eq(M.entry_name_reason('../escape'), 'not a basename component',
      'a slash is refused')
    H.assert_eq(M.entry_name_reason('..'), 'not a basename component',
      'dot-dot is refused')
    H.assert_eq(M.entry_name_reason('a\tb'), 'contains a tab',
      'the FIELD_SEPARATOR is refused')
    H.assert_eq(M.entry_name_reason('a\nb'), 'contains a control character',
      'an embedded NL is refused')
    H.assert_eq(M.entry_name_reason('a\255'), 'invalid UTF-8', 'invalid UTF-8 is refused')
  end)

  H.it('reverse(serialize(a)) round-trips all 9 action types', function()
    local sb = H.sandbox()
    local root = sb.root
    local reg = H.mkdir(sb.root, 'reg')
    -- The reversal mapping follows the documented action contract (the Python
    -- REVERSALS): mv/rm/rmdir/rs/rsdir swap src/dst; rs/rsdir/touch/mkdir
    -- reverse into a freshly-trashed rm/rmdir of the destination; p/up swap
    -- src/dst and invert the renames lists.
    local cases = {
      { label = 'mv', a = M.Move(root .. '/a.txt', root .. '/b.txt'),
        check = function(rev, a)
          return rev.name == 'mv' and rev.src == a.dst and rev.dst == a.src
        end },
      { label = 'rm', a = M.Remove(root .. '/a.txt'),
        check = function(rev, a)
          return rev.name == 'rs' and rev.src == a.dst and rev.dst == a.src
        end },
      { label = 'rmdir', a = M.RemoveDirectory(root .. '/dir'),
        check = function(rev, a)
          return rev.name == 'rsdir' and rev.src == a.dst and rev.dst == a.src
        end },
      { label = 'rs', a = M.Restore(root .. '/trash1', root .. '/a.txt'),
        check = function(rev, a)
          return rev.name == 'rm' and rev.src == a.dst
        end },
      { label = 'rsdir', a = M.RestoreDirectory(root .. '/trash2', root .. '/dir'),
        check = function(rev, a)
          return rev.name == 'rmdir' and rev.src == a.dst
        end },
      { label = 'touch', a = M.Touch(root .. '/c.txt'),
        check = function(rev, a)
          return rev.name == 'rm' and rev.src == a.dst
        end },
      { label = 'mkdir', a = M.MakeDirectory(root .. '/d'),
        check = function(rev, a)
          return rev.name == 'rmdir' and rev.src == a.dst
        end },
      { label = 'p', a = M.Paste(reg, root, { 'x', 'y' }, { 'm', 'n' }),
        check = function(rev, a)
          return rev.name == 'up' and rev.src == a.dst and rev.dst == a.src
            and rev.renames[1].src == 'm' and rev.renames[1].dst == 'x'
            and rev.renames[2].src == 'n' and rev.renames[2].dst == 'y'
        end },
      { label = 'up', a = M.Unpaste(root, reg, { 'p', 'q' }, { 'p', 'q' }),
        check = function(rev, a)
          return rev.name == 'p' and rev.src == a.dst and rev.dst == a.src
            and rev.renames[1].src == 'p' and rev.renames[1].dst == 'p'
            and rev.renames[2].src == 'q' and rev.renames[2].dst == 'q'
        end },
    }
    for _, c in ipairs(cases) do
      local rev = M.reverse(M.serialize(c.a))
      H.assert_true(rev ~= nil, c.label .. ': reverse(serialize(a)) resolves')
      H.assert_true(c.check(rev, c.a),
        c.label .. ': the reversal mapping holds')
    end

    -- Pin the p/up serialization swapping verbatim (the renames inversion in
    -- the serialized form, which history will replay).
    local pa = M.Paste(reg, root, { 'x', 'y' }, { 'm', 'n' })
    H.assert_eq(M.serialize(pa), '{"op":"p","src":' .. vim.json.encode(reg)
      .. ',"dst":' .. vim.json.encode(root)
      .. ',"src_names":["x","y"],"dst_names":["m","n"]}',
      'p serialized with both name arrays')
    local upa = M.reverse(M.serialize(pa))
    H.assert_eq(M.serialize(upa), '{"op":"up","src":' .. vim.json.encode(root)
      .. ',"dst":' .. vim.json.encode(reg)
      .. ',"src_names":["m","n"],"dst_names":["x","y"]}',
      'the reversal swaps src/dst and inverts the name arrays')
    local back = M.reverse(M.serialize(upa))
    H.assert_eq(M.serialize(back), M.serialize(pa),
      'double reversal returns the original paste')
  end)

  H.it('deserialize and reverse return nil, err for malformed lines', function()
    local r, e = M.deserialize('bogus\ta\tb')
    H.assert_nil(r, 'deserialize of an unknown name returns nil')
    H.assert_true(type(e) == 'string' and #e > 0, 'deserialize carries an err')
    r, e = M.deserialize(nil)
    H.assert_nil(r, 'deserialize(nil) returns nil')
    r, e = M.reverse('bogus\ta\tb')
    H.assert_nil(r, 'reverse of an unknown line returns nil')
    r, e = M.reverse('')
    H.assert_nil(r, 'reverse of an empty line returns nil')
  end)

  H.it('JSON records use canonical escaping and reject duplicate or extra keys', function()
    local src = '/r/quote"\\slash/café'
    local expected = '{"op":"mv","src":"/r/quote\\"\\\\slash/café","dst":"/r/b"}'
    H.assert_eq(M.serialize(M.Move(src, '/r/b')), expected,
      'quotes and backslashes are escaped; slash and UTF-8 stay literal')
    H.assert_eq(M.serialize(M.deserialize(expected)), expected,
      'decode and re-encode preserve canonical bytes')

    for _, record in ipairs({
      '{"op":"mv","op":"mv","src":"/r/a","dst":"/r/b"}',
      '{"op":"mv","src":"/r/a","dst":"/r/b","extra":1}',
      '{"op":"mv","src":"/r/a"}',
      '{"op":"mv","src":1,"dst":"/r/b"}',
      '{"op":"future","dst":"/r/b"}',
      '{ "op":"touch","dst":"/r/t"}',
      '{"op":"g","moves":[{"src":"/r/a","dst":"/r/b"}]}',
      '{"op":"g","moves":[{"src":"/r/a","dst":"/r/b"},'
        .. '{"src":"/r/c","dst":"/r/d"}]}',
    }) do
      local parsed, err = M.deserialize(record)
      H.assert_nil(parsed, 'invalid or non-canonical JSON is rejected')
      H.assert_true(type(err) == 'string' and #err > 0, 'decoder reports a reason')
    end
  end)

  H.it('Paste copies files and trees; Unpaste removes them without trashing', function()
    local sb = H.sandbox()
    local reg = H.mkdir(sb.root, 'reg')
    local register_home = paths.data_dir('register')
    vim.fn.writefile({ reg }, paths.join(register_home, 'content'))
    H.mkfile(reg, 'f.txt', { 'f' })
    H.mkdir(reg, 'tree')
    H.mkfile(reg, 'tree/sub.txt', { 's' })
    local dst = H.mkdir(sb.root, 'dst')

    local paste = M.Paste(reg, dst, { 'f.txt', 'tree' }, { 'f.txt', 'tree' })
    local last = paste['do']()
    H.assert_eq(last, dst .. '/tree', 'last pasted entry returned (sorted order)')
    H.assert_fs_eq(dst, { 'f.txt', 'tree/', 'tree/sub.txt' }, 'entries pasted')

    H.assert_true(
      M.Unpaste(dst, reg, { 'f.txt', 'tree' }, { 'f.txt', 'tree' })['do']() ~= nil,
      'unpaste succeeds')
    H.assert_fs_eq(dst, {}, 'pasted entries removed')
    H.assert_fs_eq(reg, { 'f.txt', 'tree/', 'tree/sub.txt' },
      'the register itself is untouched')
  end)

  H.it('summarize() joins descriptions with a single leading capital', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    H.mkfile(sb.root, 'c.txt', { 'c' })
    H.with_cwd(sb.root, function()
      local summary = M.summarize({
        M.Move(sb.root .. '/a.txt', sb.root .. '/b.txt'),
        M.Remove(sb.root .. '/c.txt'),
      })
      H.assert_eq(summary, 'Moved a.txt to b.txt, Removed c.txt',
        'joined, first letter already capital, rest untouched')
      H.assert_eq(M.summarize({ M.Touch(sb.root .. '/t.txt') }),
        'Created t.txt', 'single lowercase description is capitalised')
    end)
  end)
end)
