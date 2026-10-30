-- tests/register_spec.lua -- persistent yank/paste, clash prompts, and undo.
-- Unsafe names and destinations are rejected before copying; skipped entries
-- stay out of history so undo cannot remove data that was never pasted.

local H = require('tests.support.harness')
local reg = require('direct.register')
-- Loading the facade wires `register.relist` to the real buffer re-list.
-- Require it here so `reg` is the same table wired by the facade,
-- not a table a later `require` created.
require('direct')
local ui = require('direct.ui') -- chunk-time capture: the SAME table reg.M.ui uses
local paths = require('direct.paths')
local fs = require('direct.fs')
local history = require('direct.history')
-- The attempt cap lets this test fail instead of hanging if the prompt loops.
local action = require('direct.action')
local fixtures = require('tests.support.history_fixtures')

H.describe('register', function()
  local function register_dir(sb)
    return vim.fs.joinpath(sb.data_home, 'direct/register')
  end

  local function sorted_dst(sb, sources)
    local sorted = vim.deepcopy(sources)
    table.sort(sorted)
    return vim.fs.joinpath(register_dir(sb), paths.digest(sorted))
  end

  H.it('yank stores dir1 (never \'\') and the tree, points content at the absolute dst', function()
    local sb = H.sandbox()
    local src_file = sb.root .. '/f.txt'
    local src_dir = sb.root .. '/dir1/'
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.mkdir(sb.root, 'dir1')
    H.mkfile(sb.root, 'dir1/sub.txt', { 's' })

    H.capture_messages()
    H.assert_true(reg.yank({ src_file, src_dir }) == true, 'yank succeeds')

    -- Trailing-slash-safe basename: the directory is stored as `dir1`,
    -- and both entries land in the sorted-digest destination with a tree.
    local dst = sorted_dst(sb, { src_file, src_dir })
    H.assert_fs_eq(dst, { 'dir1/', 'dir1/sub.txt', 'f.txt' },
      'register entry holds the file and the dir1 tree')

    -- content pointer: the absolute register path, not a relative one.
    local content_path = vim.fs.joinpath(register_dir(sb), 'content')
    H.assert_eq(vim.fn.readfile(content_path), { dst }, 'content holds the absolute dst')
    H.assert_eq(reg.content(), dst, 'content() reads the pointer back')

    -- one `Yanked <raw source>` per source, in input order (the dir line
    -- keeps its raw trailing-slash spelling).
    local text = H.messages()
    local file_idx = text:find('Yanked ' .. src_file, 1, true)
    local dir_idx = text:find('Yanked ' .. src_dir, 1, true)
    H.assert_true(file_idx ~= nil and dir_idx ~= nil, 'both Yanked lines are present')
    H.assert_true(file_idx < dir_idx, 'yank lines are in input order')
    local _, count = text:gsub('Yanked ', '')
    H.assert_eq(count, 2, 'exactly one Yanked line per source')
  end)

  -- Yank destroys nothing, so an uncopyable entry should be skipped and reported
  -- rather than failing the yank or disappearing silently.
  H.it('a yank of a tree holding a symlink succeeds and reports the skipped entry', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'tree')
    H.mkfile(root, 'a.txt', { 'a' })
    H.mkdir(root, 'sub')
    H.mkfile(root, 'sub/b.txt', { 'b' })
    pcall(vim.uv.fs_symlink, root .. '/a.txt', root .. '/sub/link')
    H.assert_true(vim.uv.fs_lstat(root .. '/sub/link') ~= nil, 'nested symlink created')

    H.capture_messages()
    local ok, err = reg.yank({ root })
    H.assert_true(ok == true, 'the yank succeeds: ' .. tostring(err))
    H.assert_notified('Skipped 1', vim.log.levels.WARN)

    -- The register copy holds everything reproducible, with no stand-in for
    -- what could not be copied.
    local dst = sorted_dst(sb, { root })
    H.assert_fs_eq(dst, { 'tree/', 'tree/a.txt', 'tree/sub/', 'tree/sub/b.txt' },
      'the yank stored what it could copy')
    H.assert_fs_eq(root, { 'a.txt', 'sub/', 'sub/b.txt', 'sub/link@' },
      'the source is untouched, symlink included')
  end)

  H.it('digest is stable across orderings and a re-yank replaces the entry', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    H.mkdir(sb.root, 'dir1')
    H.mkfile(sb.root, 'dir1/a.txt', { '1' })

    H.assert_true(reg.yank({ sb.root .. '/a.txt', sb.root .. '/dir1' }) == true,
      'first yank')
    local first = reg.content()
    H.assert_true(first ~= nil, 'content pointer written')

    -- Same sources, reversed caller order: same sorted digest -> same dst.
    H.mkfile(sb.root, 'dir1/b.txt', { '2' })
    H.assert_true(reg.yank({ sb.root .. '/dir1', sb.root .. '/a.txt' }) == true,
      're-yank in the opposite caller order')
    H.assert_eq(reg.content(), first,
      'digest is stable across caller orderings')

    -- Replace semantics: the stale member from the first yank is gone.
    H.assert_fs_eq(first .. '/dir1', { 'a.txt', 'b.txt' },
      'the re-yank kept the original member (re-copy, no loss)')
    H.mkfile(sb.root, 'dir1/c.txt', { '3' })
    H.assert_true(reg.yank({ sb.root .. '/a.txt', sb.root .. '/dir1' }) == true,
      'third yank')
    H.assert_fs_eq(first .. '/dir1', { 'a.txt', 'b.txt', 'c.txt' },
      're-yank copies the whole tree; no member is lost')
  end)

  H.it('paste pastes into dst, returns the last entry, logs history, notifies the summary once', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local src = reg.content()
    local ws = H.mkdir(sb.root, 'ws')

    H.capture_messages()
    local last = reg.paste(ws)
    H.assert_eq(last, ws .. '/f.txt', 'the last pasted entry is returned')
    H.assert_fs_eq(ws, { 'f.txt' }, 'file pasted')

    local text = H.messages()
    H.assert_true(text:find('Pasted into ', 1, true) ~= nil,
      'the summary is notified on success')
    local _, count = text:gsub('Pasted into ', '')
    H.assert_eq(count, 1, 'the summary is emitted exactly once')

    -- History is logged only on success: the JSONL header plus one action record.
    local undo_path = vim.fs.joinpath(sb.data_home, 'direct/history/undo.log')
    local redo_path = vim.fs.joinpath(sb.data_home, 'direct/history/redo.log')
    H.assert_eq(vim.fn.readfile(undo_path),
      { fixtures.header, fixtures.paste('p', src, ws, { 'f.txt' }, { 'f.txt' }) },
      'the header plus canonical paste record is recorded')
    H.assert_eq(vim.fn.readfile(redo_path), { fixtures.header },
      'log() reset the redo log to its header')
  end)

  H.it('file paste refuses an occupant created after the clash check', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'REGISTER' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank source')
    local ws = H.mkdir(sb.root, 'ws')
    local dst = ws .. '/f.txt'
    local real = fs.copy_file_exclusive
    local injected = false
    local restore = H.stub(fs, 'copy_file_exclusive', function(src, target)
      if target == dst and not injected then
        injected = true
        H.mkfile(ws, 'f.txt', { 'FOREIGN' })
      end
      return real(src, target)
    end)

    H.capture_messages()
    local result = reg.paste(ws)
    restore()

    H.assert_true(injected, 'the destination raced in after the check')
    H.assert_nil(result, 'exclusive copy refuses the raced destination')
    H.assert_eq(vim.fn.readfile(dst), { 'FOREIGN' }, 'raced file is unchanged')
    H.assert_eq(vim.fn.readfile(reg.content() .. '/f.txt'), { 'REGISTER' },
      'register source remains unchanged')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), { history.HEADER },
      'a failed copy adds no action record')
  end)

  H.it('directory paste refuses an occupant that races in before final placement', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'tree')
    H.mkfile(sb.root, 'tree/source.txt', { 'REGISTER' })
    H.assert_true(reg.yank({ sb.root .. '/tree' }) == true, 'yank directory')
    local ws = H.mkdir(sb.root, 'ws')
    local dst = ws .. '/tree'
    local real = fs.rename_noreplace
    local injected = false
    local restore = H.stub(fs, 'rename_noreplace', function(src, target)
      if target == dst and src:find('/payload$', 1) and not injected then
        injected = true
        H.mkdir(ws, 'tree')
        H.mkfile(ws, 'tree/foreign.txt', { 'KEEP' })
      end
      return real(src, target)
    end)

    H.capture_messages()
    local result = reg.paste(ws)
    restore()

    H.assert_true(injected, 'the destination raced in before placement')
    H.assert_nil(result, 'no-replace placement refuses the raced directory')
    H.assert_eq(vim.fn.readfile(dst .. '/foreign.txt'), { 'KEEP' },
      'the raced directory and its contents remain untouched')
    H.assert_false(fs.exists(dst .. '/source.txt'), 'the source tree was not merged')
    H.assert_eq(vim.fn.glob(ws .. '/.direct-copy-tree-*'), '',
      'the failed private copy temp was cleaned')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), { history.HEADER },
      'failed directory placement adds no action record')
  end)

  H.it('a destination clash prompts and pastes under the answered name', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.mkdir(sb.root, 'dir1')
    H.mkfile(sb.root, 'dir1/sub.txt', { 's' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt', sb.root .. '/dir1' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'f.txt', { 'original' })

    H.capture_messages()
    local last = nil
    -- Stub the chunk-time ui table (the one reg.M.ui resolves to), not a
    -- fresh require: the harness forgets direct.* modules at the file
    -- boundary, so `require('direct.ui')` at test time would return a
    -- new table and the stub would miss. The real prompt would then reach
    -- vim.fn.input under `-l` instead of failing through this test seam.
    local restore = H.stub(ui, 'prompt', function() return 'other.txt' end)
    local ok, perr = xpcall(function()
      last = reg.paste(ws)
    end, debug.traceback)
    restore()
    if not ok then
      error(perr, 0)
    end

    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'original' },
      'the clashing entry is not overwritten')
    H.assert_fs_eq(ws, { 'dir1/', 'dir1/sub.txt', 'f.txt', 'other.txt' },
      'the clash was pasted under the answered name')
    H.assert_eq(last, ws .. '/other.txt', 'the renamed copy is the last pasted entry')
    H.assert_false(H.messages():find('Skipped', 1, true) ~= nil,
      'a non-empty answer is not a skip')
  end)

  -- A clash answer that still names an existing entry must be rejected; otherwise
  -- copy/undo could merge into or delete data that existed before the paste.
  -- Ask again until the name is free; an empty answer still skips the entry.
  H.it('a directory clash re-prompts instead of merging into the existing directory', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'tree')
    H.mkfile(sb.root, 'tree/sub.txt', { 'sub' })
    H.assert_true(reg.yank({ sb.root .. '/tree' }) == true, 'yank a directory')
    local ws = H.mkdir(sb.root, 'ws')
    -- The destination already holds a DIFFERENT directory of the same name.
    H.mkdir(ws, 'tree')
    H.mkfile(ws, 'tree/keep.txt', { 'KEEP' })

    H.capture_messages()
    local prompts, answers = 0, { 'tree', 'fresh' }
    local restore = H.stub(ui, 'prompt', function()
      prompts = prompts + 1
      return table.remove(answers, 1) or ''
    end)
    local res
    local ok, perr = xpcall(function() res = reg.paste(ws) end, debug.traceback)
    restore()
    if not ok then error(perr, 0) end

    H.assert_eq(prompts, 2, 'the still-colliding answer re-prompts')
    H.assert_fs_eq(ws .. '/tree', { 'keep.txt' },
      'the pre-existing directory was not merged into')
    H.assert_fs_eq(ws .. '/fresh', { 'sub.txt' },
      'the directory landed under the fresh name')
    H.assert_eq(res, ws .. '/fresh', 'the fresh entry is the last pasted one')
  end)

  H.it('undo after a clashing directory paste removes only what the paste created', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'tree')
    H.mkfile(sb.root, 'tree/sub.txt', { 'sub' })
    H.assert_true(reg.yank({ sb.root .. '/tree' }) == true, 'yank a directory')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'tree')
    H.mkfile(ws, 'tree/keep.txt', { 'KEEP' })

    local answers = { 'tree', 'fresh' }
    local restore = H.stub(ui, 'prompt', function()
      return table.remove(answers, 1) or ''
    end)
    local ok, perr = xpcall(function() reg.paste(ws) end, debug.traceback)
    restore()
    if not ok then error(perr, 0) end

    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_fs_eq(ws, { 'tree/', 'tree/keep.txt' },
      'undo removed exactly the pasted directory and spared the pre-existing one')
  end)

  H.it('cancelling the clash prompt changes nothing, even after a colliding answer', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'tree')
    H.mkfile(sb.root, 'tree/sub.txt', { 'sub' })
    H.assert_true(reg.yank({ sb.root .. '/tree' }) == true, 'yank a directory')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'tree')
    H.mkfile(ws, 'tree/keep.txt', { 'KEEP' })

    H.capture_messages()
    local answers = { 'tree', '' } -- collide once, then cancel
    local restore = H.stub(ui, 'prompt', function()
      return table.remove(answers, 1) or ''
    end)
    local ok, perr = xpcall(function() reg.paste(ws) end, debug.traceback)
    restore()
    if not ok then error(perr, 0) end

    H.assert_fs_eq(ws, { 'tree/', 'tree/keep.txt' },
      'a cancelled paste left the filesystem exactly as it was')
    H.assert_notified('Skipped tree')
  end)

  H.it('a file clash re-prompts too, so undo cannot delete a pre-existing file', function()
    -- Item-2 investigation, pinned: a FILE clash took the same branch, so the
    -- answer `f.txt` used to overwrite the pre-existing file and undo then
    -- deleted it. The re-prompt loop closes that path without any overwrite
    -- policy decision: the existing file is never written and never removed.
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'reg-f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'f.txt', { 'KEEP' })

    local answers = { 'f.txt', 'f-copy.txt' }
    local restore = H.stub(ui, 'prompt', function()
      return table.remove(answers, 1) or ''
    end)
    local ok, perr = xpcall(function() reg.paste(ws) end, debug.traceback)
    restore()
    if not ok then error(perr, 0) end

    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'KEEP' },
      'the pre-existing file was not overwritten')
    H.assert_eq(vim.fn.readfile(ws .. '/f-copy.txt'), { 'reg-f' },
      'the copy landed under the fresh name')

    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'KEEP' },
      'undo spared the pre-existing file')
    H.assert_false(fs.exists(ws .. '/f-copy.txt'),
      'undo removed only the pasted copy')
  end)

  -- The clash loop must be bounded. A prompt that keeps
  -- answering a name that still exists (stubbed or broken) would spin forever
  -- and freeze the editor, so the loop is capped; on exhaustion the entry is
  -- skipped and reported, exactly like a cancelled prompt. The stub aborts past
  -- a ceiling so the PRE-fix run fails an assertion instead of hanging.
  H.it('a stuck clash prompt is capped: the entry is skipped, not retried forever', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'reg-f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'f.txt', { 'KEEP' })

    H.capture_messages()
    local prompts = 0
    local restore = H.stub(ui, 'prompt', function()
      prompts = prompts + 1
      if prompts > 50 then
        error('paste clash prompt exceeded its ceiling: the loop is unbounded', 0)
      end
      return 'f.txt' -- always the name that already exists
    end)
    local ok, perr = xpcall(function() reg.paste(ws) end, debug.traceback)
    restore()
    if not ok then error(perr, 0) end

    H.assert_eq(prompts, action.PASTE_CLASH_ATTEMPTS,
      'the loop stops at the attempt cap instead of spinning')
    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'KEEP' },
      'the pre-existing file was never touched')
    H.assert_notified('Skipped f.txt')
  end)

  -- Use the same lstat-based occupancy check as copy: a dangling destination
  -- symlink is occupied, prompts for another name, and is never written through.
  H.it('the paste clash loop treats a dangling destination symlink as occupied', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'reg-f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')
    H.assert_true(vim.uv.fs_symlink(ws .. '/nowhere', ws .. '/f.txt') == true,
      'dangling symlink occupying the paste destination name')
    H.assert_false(fs.exists(ws .. '/f.txt'),
      'the following check reports the name free')

    local prompts = 0
    local restore = H.stub(ui, 'prompt', function()
      prompts = prompts + 1
      return 'f-copy.txt'
    end)
    local ok, perr = xpcall(function() reg.paste(ws) end, debug.traceback)
    restore()
    if not ok then error(perr, 0) end

    H.assert_eq(prompts, 1, 'the clash loop asks, because the name is taken')
    local st = vim.uv.fs_lstat(ws .. '/f.txt')
    H.assert_true(st ~= nil and st.type == 'link',
      'the dangling link is untouched, not replaced or written through')
    H.assert_false(fs.exists(ws .. '/nowhere'), 'nothing was created at the link target')
    H.assert_eq(vim.fn.readfile(ws .. '/f-copy.txt'), { 'reg-f' },
      'the copy landed under the fresh name the answer gave')
  end)

  H.it('an empty prompt answer skips the entry and reports it', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'f.txt', { 'original' })

    H.capture_messages()
    local res = nil
    local restore = H.stub(ui, 'prompt', function() return '' end)
    local ok, perr = xpcall(function()
      res = reg.paste(ws)
    end, debug.traceback)
    restore()
    if not ok then
      error(perr, 0)
    end

    -- A fully-skipped Paste returns true (last or true); nothing was copied.
    H.assert_eq(res, true, 'a fully-skipped paste still succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'original' },
      'nothing was pasted')
    H.assert_notified('Skipped f.txt')
  end)

  H.it('a partially-skipped paste logs only what it copied; undo spares the original', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'reg-a' })
    H.mkfile(sb.root, 'b.txt', { 'reg-b' })
    H.assert_true(reg.yank({ sb.root .. '/a.txt', sb.root .. '/b.txt' }) == true,
      'yank two entries')
    local ws = H.mkdir(sb.root, 'ws')
    -- a.txt clashes with a pre-existing file the paste must NOT overwrite;
    -- b.txt has no clash and is the entry that is actually copied.
    H.mkfile(ws, 'a.txt', { 'IRREPLACEABLE USER DATA' })

    H.capture_messages()
    local last = nil
    local restore = H.stub(ui, 'prompt', function() return '' end)
    local ok, perr = xpcall(function()
      last = reg.paste(ws)
    end, debug.traceback)
    restore()
    if not ok then
      error(perr, 0)
    end

    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'IRREPLACEABLE USER DATA' },
      'the skipped destination keeps its original content')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'reg-b' },
      'the non-clashing entry was pasted')
    H.assert_eq(last, ws .. '/b.txt', 'the copied entry is the last pasted one')

    -- Undo reverses only what was written: b.txt goes, a.txt stays. Before the
    -- prune the skipped a.txt was still in renames, so undo deleted the
    -- untouched original.
    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'IRREPLACEABLE USER DATA' },
      'undo leaves the pre-existing destination untouched')
    H.assert_false(fs.exists(ws .. '/b.txt'),
      'undo removes the entry that was actually pasted')
  end)

  H.it('a fully-skipped paste logs a reversal that changes nothing', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'reg-a' })
    H.mkfile(sb.root, 'b.txt', { 'reg-b' })
    H.assert_true(reg.yank({ sb.root .. '/a.txt', sb.root .. '/b.txt' }) == true,
      'yank two entries')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'orig-a' })
    H.mkfile(ws, 'b.txt', { 'orig-b' })

    H.capture_messages()
    local res = nil
    local restore = H.stub(ui, 'prompt', function() return '' end)
    local ok, perr = xpcall(function()
      res = reg.paste(ws)
    end, debug.traceback)
    restore()
    if not ok then
      error(perr, 0)
    end

    H.assert_eq(res, true, 'a fully-skipped paste still succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'orig-a' }, 'a.txt untouched')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'orig-b' }, 'b.txt untouched')

    -- Every entry was skipped, so the pruned renames list is empty and the
    -- logged reversal is a no-op (before it deleted both originals).
    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'orig-a' },
      'undo changes nothing when every entry was skipped')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'orig-b' },
      'undo changes nothing when every entry was skipped')
  end)

  H.it('space-named entries round-trip through JSONL without arming unrelated deletes', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'my file.txt', { 'spacey' })
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'file.txt', { 'UNRELATED' })

    H.assert_true(reg.yank({ sb.root .. '/my file.txt' }) == true,
      'space-named entry is accepted by the register')
    H.assert_eq(reg.paste(ws), ws .. '/my file.txt', 'the entry pasted under its original name')
    H.assert_eq(vim.fn.readfile(ws .. '/my file.txt'), { 'spacey' }, 'pasted bytes survive')
    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_false(fs.exists(ws .. '/my file.txt'), 'undo removes only the pasted entry')
    H.assert_eq(vim.fn.readfile(ws .. '/file.txt'), { 'UNRELATED' },
      'the unrelated file.txt survives')
  end)

  -- The register is persisted and untrusted, but JSON arrays preserve spaces in
  -- names without confusing distinct entries during undo.
  H.it('a space-named entry already present in the register pastes safely', function()
    local sb = H.sandbox()

    -- Simulate a persisted register entry plus its content pointer.
    local reg_dir = register_dir(sb)
    local digest = 'legacy-digest'
    local entry_dir = vim.fs.joinpath(reg_dir, digest)
    H.mkfile(reg_dir, digest .. '/my file.txt', { 'legacy' })
    H.mkfile(reg_dir, 'content', { entry_dir })
    H.assert_eq(reg.content(), entry_dir, 'the legacy pointer is read back')

    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'my', { 'UNRELATED-A' })
    H.mkfile(ws, 'file.txt', { 'UNRELATED-B' })

    H.capture_messages()
    local result = reg.paste(ws)
    H.assert_eq(result, ws .. '/my file.txt', 'the stored entry pastes successfully')
    H.assert_eq(vim.fn.readfile(ws .. '/my'), { 'UNRELATED-A' },
      'the unrelated my survives with its content')
    H.assert_eq(vim.fn.readfile(ws .. '/file.txt'), { 'UNRELATED-B' },
      'the unrelated file.txt survives with its content')
    H.assert_eq(vim.fn.readfile(ws .. '/my file.txt'), { 'legacy' },
      'the legacy space-named entry is preserved')
    H.assert_true(history.undo() ~= nil, 'the legacy register paste is undoable')
    H.assert_false(fs.exists(ws .. '/my file.txt'), 'undo removes the pasted copy')
    H.assert_eq(vim.fn.readfile(ws .. '/file.txt'), { 'UNRELATED-B' },
      'undo leaves unrelated names untouched')
  end)

  H.it('a space-carrying clash answer round-trips and undo preserves originals', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'reg-a' })
    H.mkfile(sb.root, 'b.txt', { 'reg-b' })
    H.assert_true(reg.yank({ sb.root .. '/a.txt', sb.root .. '/b.txt' }) == true,
      'yank two entries')
    local ws = H.mkdir(sb.root, 'ws')
    -- Both entries clash with pre-existing files the paste must never touch.
    H.mkfile(ws, 'a.txt', { 'PRECIOUS ORIGINAL' })
    H.mkfile(ws, 'b.txt', { 'orig-b' })

    H.capture_messages()
    local last = nil
    -- Consumed in ascending src order: both names are valid JSON array values.
    local answers = { 'a.txt copy', 'renamed.txt' }
    local restore = H.stub(ui, 'prompt', function()
      if #answers == 0 then return nil end
      return table.remove(answers, 1)
    end)
    local ok, perr = xpcall(function()
      last = reg.paste(ws)
    end, debug.traceback)
    restore()
    if not ok then
      error(perr, 0)
    end

    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'PRECIOUS ORIGINAL' },
      'the original clash is never overwritten')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'orig-b' },
      'the clashing b.txt is not overwritten either')
    H.assert_eq(vim.fn.readfile(ws .. '/renamed.txt'), { 'reg-b' },
      'the valid second answer was pasted')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt copy'), { 'reg-a' },
      'the space-carrying answer was pasted exactly')
    H.assert_eq(last, ws .. '/renamed.txt', 'the pasted fragment is the last entry')

    -- Undo reverses both pasted names without touching the existing clashes.
    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'PRECIOUS ORIGINAL' },
      'undo leaves the pre-existing destination untouched')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'orig-b' },
      'undo leaves the other untouched original alone')
    H.assert_false(fs.exists(ws .. '/renamed.txt'),
      'undo removes only the actually-pasted fragment')
    H.assert_false(fs.exists(ws .. '/a.txt copy'),
      'undo removes the space-named pasted fragment')

    H.assert_false(H.messages():find('Skipped a.txt', 1, true) ~= nil,
      'a valid space name is not reported as skipped')
  end)

  -- The FIELD_SEPARATOR ('\t') is as unserializable as the ENTRY_SEPARATOR
  -- (' '), and must be refused at the same boundary -- at the yank and for a
  -- clash answer. Before the fix a TAB-named entry yanked fine and undid as a
  -- silent no-op (no data loss, but inconsistent).
  H.it('a TAB-named entry is refused at the yank boundary with an error', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f\to.txt', { 'tabby' })

    H.capture_messages()
    local ok, err = reg.yank({ sb.root .. '/f\to.txt' })
    H.assert_nil(ok, 'the TAB-named entry is refused')
    H.assert_true(type(err) == 'string' and #err > 0, 'yank carries an err')
    H.assert_notified('contains a tab')
    H.assert_nil(reg.content(), 'a refused entry never arms a content pointer')
    H.assert_eq(H.ls(register_dir(sb)), {},
      'a refused yank leaves no digest dir entry behind')
  end)

  H.it('a TAB-carrying clash answer is refused like an empty answer', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'f.txt', { 'original' })

    H.capture_messages()
    local res = nil
    local restore = H.stub(ui, 'prompt', function() return 'f\tother.txt' end)
    local ok, perr = xpcall(function()
      res = reg.paste(ws)
    end, debug.traceback)
    restore()
    if not ok then
      error(perr, 0)
    end

    H.assert_eq(res, true, 'a fully-skipped paste still succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'original' },
      'the tab-answered clash is skipped, never overwritten')
    H.assert_false(fs.exists(ws .. '/f\tother.txt'),
      'no tab-named file is created')
    H.assert_notified('Skipped f.txt')

    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'original' },
      'undo changes nothing when the only entry was skipped')
  end)

  -- A destination containing a control byte is refused before copy or history.
  H.it('a control-char destination is refused before any copy and writes no corrupted undo line', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local dst = H.mkdir(sb.root, 'de\tst')

    H.capture_messages()
    local res, err = reg.paste(dst)

    H.assert_nil(res, 'the paste into an unrepresentable destination is refused')
    H.assert_true(type(err) == 'string' and #err > 0,
      'the refusal carries a reason')
    H.assert_notified('contains a tab')
    H.assert_false(H.messages():find('Pasted into ', 1, true) ~= nil,
      'no success summary was emitted for a refused paste')
    -- The refusal happens BEFORE the copy: the destination is still empty.
    H.assert_eq(H.ls(dst), {}, 'nothing was copied into the destination')
    -- Preflight ran before the path refusal, but no action record was written.
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), { fixtures.header }, 'the undo stack stays empty')
  end)

  H.it('a mixed yank with a space-named entry round-trips both names', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'good.txt', { 'g' })
    H.mkfile(sb.root, 'my file.txt', { 'spacey' })

    H.assert_true(reg.yank({ sb.root .. '/good.txt', sb.root .. '/my file.txt' }) == true,
      'the mixed yank is accepted')
    local ws = H.mkdir(sb.root, 'ws')
    reg.paste(ws)
    H.assert_eq(vim.fn.readfile(ws .. '/good.txt'), { 'g' }, 'ordinary entry pasted')
    H.assert_eq(vim.fn.readfile(ws .. '/my file.txt'), { 'spacey' }, 'space name pasted')
    H.assert_true(history.undo() ~= nil, 'both entries are undoable')
    H.assert_eq(H.fs_snapshot(ws), {}, 'undo removes exactly the two pasted entries')
  end)

  H.it('an empty register notifies and pastes nothing', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')

    H.capture_messages()
    local res, err = reg.paste(ws)
    H.assert_nil(res, 'paste on an empty register returns nil')
    H.assert_nil(err, 'no error is carried for an empty register')
    H.assert_notified('Register is empty')
    H.assert_false(H.messages():find('Pasted into ', 1, true) ~= nil,
      'no summary was emitted')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), { fixtures.header },
      'preflight initialized an empty stack without writing an action')
  end)

  H.it('paste copies a yanked directory tree', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'tree')
    H.mkfile(sb.root, 'tree/sub.txt', { 's' })
    H.mkfile(sb.root, 'tree/deep.txt', { 'd' })
    H.assert_true(reg.yank({ sb.root .. '/tree' }) == true, 'yank the tree')
    local ws = H.mkdir(sb.root, 'ws')

    local last = reg.paste(ws)
    H.assert_eq(last, ws .. '/tree', 'the directory entry is the last pasted one')
    H.assert_fs_eq(ws, { 'tree/', 'tree/deep.txt', 'tree/sub.txt' },
      'the whole tree pasted')
  end)

  -- The skip report is not yank-only. A paste destroys
  -- nothing either, and its source (the register dir) is persisted, untrusted
  -- data -- a legacy entry can hold an entry the copy cannot reproduce. It must
  -- warn with the count rather than pasting short in silence. The copy seam is
  -- stubbed so the report path is pinned without depending on how such an entry
  -- got into the register.
  H.it('a paste whose tree copy skipped an entry warns with the count', function()
    local sb = H.sandbox()
    H.mkdir(sb.root, 'tree')
    H.mkfile(sb.root, 'tree/a.txt', { 'a' })
    H.assert_true(reg.yank({ sb.root .. '/tree' }) == true, 'yank the tree')
    local ws = H.mkdir(sb.root, 'ws')

    local restore = H.stub(fs, 'copy_tree_exclusive', function()
      return true, { { path = '/register/tree/link', kind = 'symlink' } }
    end)
    H.capture_messages()
    local last, err = reg.paste(ws)
    restore()

    H.assert_true(last ~= nil, 'the paste succeeds: ' .. tostring(err))
    H.assert_notified('Skipped 1', vim.log.levels.WARN)
  end)

  H.it('the re-list hook fires only for the no-arg paste form and tolerates nil', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')

    -- The facade wires the real buffer re-list into register.relist; this test
    -- stubs that register-level seam directly.
    H.assert_true(type(reg.relist) == 'function',
      'M.relist is wired to the real buffer re-list')

    -- Stub the seam so the two command forms can be told apart without
    -- touching a real buffer.
    local called = 0
    local restore = H.stub(reg, 'relist', function()
      called = called + 1
    end)
    local ws2 = H.mkdir(sb.root, 'ws2')
    H.assert_true(reg.paste(ws2, true) ~= nil, 'no-arg form pastes')
    H.assert_eq(called, 1, 'no-arg form fires the re-list hook exactly once')
    local ws3 = H.mkdir(sb.root, 'ws3')
    H.assert_true(reg.paste(ws3, false) ~= nil, '{dir} form pastes')
    H.assert_eq(called, 1, '{dir} form never fires the re-list hook')
    restore()
  end)

  H.it('a failed paste notifies and logs no history', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')

    local restore = H.stub(fs, 'copy_file_exclusive', function()
      return nil, 'forced failure'
    end)
    H.capture_messages()
    local res, err = reg.paste(ws)
    restore()

    H.assert_nil(res, 'paste reports the failure')
    H.assert_nil(err, 'the failure is reported through the notification')
    H.assert_notified('Failed to paste')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), { fixtures.header },
      'a failed paste leaves preflight history header-only')
  end)

  H.it('yank and paste report an unavailable data dir instead of raising', function()
    local sb = H.sandbox()
    H.mkfile(sb.data_home, 'direct', { 'occupied' }) -- <home>/direct is a file
    H.mkfile(sb.root, 'f.txt', { 'valid source' })

    H.capture_messages()
    local ok, yerr = reg.yank({ sb.root .. '/f.txt' })
    H.assert_nil(ok, 'yank reports the failure')
    H.assert_true(type(yerr) == 'string' and #yerr > 0, 'yank carries an err')
    H.assert_notified('history was preserved')

    H.capture_messages()
    local res, perr = reg.paste(sb.root .. '/ws')
    H.assert_nil(res, 'paste reports the failure')
    H.assert_true(type(perr) == 'string' and #perr > 0, 'paste carries an err')
    H.assert_notified('history was preserved')
    H.assert_false(H.messages():find('Register is empty', 1, true) ~= nil,
      'a data-dir failure is not reported as an empty register')
  end)
end)
