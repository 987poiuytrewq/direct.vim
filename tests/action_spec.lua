-- tests/action_spec.lua -- filesystem actions, serialization, reversal.
--
-- Covers T-012 (single-entry actions: Move, Remove, RemoveDirectory, Restore,
-- RestoreDirectory, Touch, MakeDirectory -- ino preservation, B10 trash naming
-- with the -<n> suffix, no nesting) and T-014 (the exact
-- action<->serialization<->reversal mapping for all 9 action types, following
-- the spec's table verbatim: src/dst swapped and renames inverted for p/up).
-- The Paste/Unpaste prompt-seam acceptance (T-013) lives in register_spec.lua
-- per the spec.

local H = require('tests.support.harness')
local M = require('direct.action')
local paths = require('direct.paths')

H.describe('action', function()
  H.it('Move preserves the inode for files and directories (T-012)', function()
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

  -- P1 (Greptile, PR #1): close_src_buffer matched with fs.same_path, which is
  -- ino+dev identity -- so EVERY hard link to a file matched, and renaming one
  -- link force-closed the buffers of all the others, discarding unsaved edits.
  -- The match must be the resolved PATHNAME (fs.realpath), not inode identity:
  -- distinct hard links are distinct names; the same file reached through a
  -- symlinked prefix, `..` or a trailing slash still matches (B9).
  H.describe('action: close_src_buffer pathname identity (P1)', function()
    H.it('a buffer on one hardlink survives close_src_buffer of another (P1)', function()
      local sb = H.sandbox()
      H.mkfile(sb.root, 'a.txt', { 'a' })
      H.assert_true(vim.uv.fs_link(sb.root .. '/a.txt', sb.root .. '/b.txt') == true,
        'hardlink created')

      -- nvim itself refuses a SECOND buffer for the other hardlink (E95 -- its
      -- own ino+dev name unification), which is exactly what makes the P1 bug
      -- destructive: the single buffer for a.txt is at risk whenever a
      -- destructive action targets the OTHER hardlink name, because the old
      -- fs.same_path(b.txt, a.txt) matched by inode.
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

    H.it('still closes a buffer whose name is the resolved target (symlinked prefix, B9)', function()
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

    H.it('matches the same file reached through a .. or a trailing-slash spelling (P1)', function()
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

  H.it('Remove and RemoveDirectory send entries to the trash (T-012, B10)', function()
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

  H.it('Restore brings a file and RestoreDirectory a tree back (T-012)', function()
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
    -- D16: a restore moves the content out and leaves an EMPTY MARKER at the
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
    }, 'workspace back to the original shape, trash holds only the D16 markers')
    H.assert_eq(vim.fn.readfile(remove.dst), {}, 'the marker file is empty')
    H.assert_eq(#vim.fn.readdir(rmdir.dst), 0, 'the marker directory is empty')
  end)

  H.it('remove/restore/remove yields two distinct trash entries with no nesting (D16)', function()
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
      'the second entry is the first free -<n> sibling (B10)')

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

  H.it('Touch and MakeDirectory create entries (T-012)', function()
    local sb = H.sandbox()
    H.assert_true(M.Touch(sb.root .. '/new.txt')['do']() ~= nil, 'touch succeeds')
    H.assert_true(H.exists(sb.root, 'new.txt'), 'file created')
    H.assert_eq(vim.fn.readfile(sb.root .. '/new.txt'), {}, 'file is empty')
    H.assert_true(M.MakeDirectory(sb.root .. '/newdir')['do']() ~= nil, 'mkdir succeeds')
    H.assert_eq(vim.fn.isdirectory(sb.root .. '/newdir'), 1, 'directory created')
  end)

  H.it('describe() is CWD-relative and human (B15/N8)', function()
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

  H.it('serialize() emits NAME\\tfield... lines (T-014)', function()
    local sb = H.sandbox()
    H.assert_eq(M.serialize(M.Move('/r/a', '/r/b')), 'mv\t/r/a\t/r/b', 'mv')
    H.assert_eq(M.serialize(M.Touch('/r/t')), 'touch\t/r/t', 'touch')
    H.assert_eq(M.serialize(M.MakeDirectory('/r/d')), 'mkdir\t/r/d', 'mkdir')
    H.assert_eq(M.serialize(M.Restore('/r/trash', '/r/a')),
      'rs\t/r/trash\t/r/a', 'rs')

    local remove = M.Remove('/r/f')
    H.assert_eq(M.serialize(remove), 'rm\t/r/f\t' .. remove.dst,
      'rm stores the resolved trash dst (B10)')

    H.assert_eq(
      M.serialize(M.Paste('/r/reg', '/r/dst', { 'a', 'b' }, { 'a', 'b' })),
      'p\t/r/reg\t/r/dst\ta b\ta b', 'p appends the two name lists')
    H.assert_eq(
      M.serialize(M.Unpaste('/r/dst', '/r/reg', { 'a', 'b' }, { 'a', 'b' })),
      'up\t/r/dst\t/r/reg\ta b\ta b', 'up appends the two name lists')
  end)

  H.it('path_reason and serialize refuse only unrepresentable path fields (B2/P2-NB2)', function()
    -- P3-NB2: path_reason is the universal guard serialize runs over every
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

    H.assert_eq(M.serialize(M.Touch('/r/a b')), 'touch\t/r/a b',
      'a space path serializes verbatim')
  end)

  H.it('entry_name_reason rejects empty, separator and control-char names (B2/B3/N2/O2)', function()
    H.assert_nil(M.entry_name_reason('notes.txt'),
      'a normal name can round-trip')
    H.assert_eq(M.entry_name_reason(''), 'empty', 'an empty name is refused')
    H.assert_eq(M.entry_name_reason(nil), 'empty', 'a non-string name is refused')
    H.assert_eq(M.entry_name_reason('a b'), 'contains a space',
      'the ENTRY_SEPARATOR is refused')
    H.assert_eq(M.entry_name_reason('a\tb'), 'contains a tab',
      'the FIELD_SEPARATOR is refused')
    H.assert_eq(M.entry_name_reason('a\nb'), 'contains a control character',
      'an embedded NL is refused (the round trip no longer leans on the NUL encoding)')
  end)

  H.it('reverse(serialize(a)) round-trips all 9 action types (T-014)', function()
    local sb = H.sandbox()
    local root = sb.root
    local reg = H.mkdir(sb.root, 'reg')
    -- The reversal mapping follows the spec table verbatim (the Python
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
    H.assert_eq(M.serialize(pa), 'p\t' .. reg .. '\t' .. root .. '\tx y\tm n',
      'p serialized with both name lists')
    local upa = M.reverse(M.serialize(pa))
    H.assert_eq(M.serialize(upa),
      'up\t' .. root .. '\t' .. reg .. '\tm n\tx y',
      'the reversal swaps src/dst and inverts the name lists')
    local back = M.reverse(M.serialize(upa))
    H.assert_eq(M.serialize(back), M.serialize(pa),
      'double reversal returns the original paste')
  end)

  H.it('deserialize and reverse return nil, err for malformed lines (T-014)', function()
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

  H.it('Paste copies files and trees; Unpaste removes them without trashing (T-013)', function()
    local sb = H.sandbox()
    local reg = H.mkdir(sb.root, 'reg')
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

  H.it('summarize() joins descriptions with a single leading capital (B15)', function()
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