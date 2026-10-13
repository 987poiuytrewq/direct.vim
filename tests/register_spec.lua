-- tests/register_spec.lua -- yank/paste register (T-016, B7, N6).
--
-- Proves: yank stores a directory entry as `dir1` (never '', R4) and a tree;
-- `register/content` holds the absolute destination; each yank emits one
-- `Yanked <raw path>` line in input order (B15); the digest is stable across
-- caller orderings and a re-yank replaces the entry with no stale members
-- (R7/D15); paste pastes into dst, returns the last pasted entry, logs
-- history only on success and notifies the B15 summary once; the clash prompt
-- (T-013/D9/D8a) renames via a scripted answer and skips+reports on an empty
-- answer; a skipped entry is pruned from the logged renames so history.undo()
-- reverses only what was actually copied and never deletes an untouched
-- original (B1); a fully-skipped paste logs a reversal that changes nothing.
-- A source whose basename contains a space cannot be yanked (B2): the
-- ' '-joined name lists could not round-trip it and Unpaste would delete an
-- unrelated file. The same boundary also refuses a TAB-named entry and a
-- separator-carrying clash answer (N2), a refused yank leaves no stray
-- register digest dir (N1), and a space-carrying clash answer is treated like
-- an empty one -- undo then spares the untouched original and removes only
-- the actually-pasted fragment (B3). An empty register notifies; and the
-- `:DirectPaste` re-list asymmetry (B7/N6) is pinned through the swappable
-- `M.relist` seam -- the no-arg form (relist_flag) fires it, the `{dir}` form
-- never does, and P4/NB6 has wired the real buffer re-list into it.
--
-- A destination the history framing cannot represent (a control character, the
-- '\t' FIELD_SEPARATOR included) is REFUSED before any copy: register.paste
-- asks the same action.serialize guard the persisted undo line will pass, so
-- the second ingress into the `NAME\tfield...` framing (B2/P2-NB2) cannot emit a
-- corrupted line that would desync on undo.
--
-- Data-dir failures (B9/O2) are reported, not raised, for yank and paste.

local H = require('tests.support.harness')
local reg = require('direct.register')
-- NB6: loading the facade wires `register.relist` to the real buffer re-list
-- (`init.lua`). Required here so this file's `reg` table is the table P4 wires,
-- not a table a later `require` created.
require('direct')
local ui = require('direct.ui') -- chunk-time capture: the SAME table reg.M.ui uses
local paths = require('direct.paths')
local fs = require('direct.fs')
local history = require('direct.history')

H.describe('register', function()
  local function register_dir(sb)
    return vim.fs.joinpath(sb.data_home, 'direct/register')
  end

  local function sorted_dst(sb, sources)
    local sorted = vim.deepcopy(sources)
    table.sort(sorted)
    return vim.fs.joinpath(register_dir(sb), paths.digest(sorted))
  end

  H.it('yank stores dir1 (never \'\') and the tree, points content at the absolute dst (T-016)', function()
    local sb = H.sandbox()
    local src_file = sb.root .. '/f.txt'
    local src_dir = sb.root .. '/dir1/'
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.mkdir(sb.root, 'dir1')
    H.mkfile(sb.root, 'dir1/sub.txt', { 's' })

    H.capture_messages()
    H.assert_true(reg.yank({ src_file, src_dir }) == true, 'yank succeeds')

    -- Trailing-slash-safe basename (R4): the directory is stored as `dir1`,
    -- and both entries land in the sorted-digest destination with a tree.
    local dst = sorted_dst(sb, { src_file, src_dir })
    H.assert_fs_eq(dst, { 'dir1/', 'dir1/sub.txt', 'f.txt' },
      'register entry holds the file and the dir1 tree')

    -- B15 content pointer: the absolute register path, not a relative one.
    local content_path = vim.fs.joinpath(register_dir(sb), 'content')
    H.assert_eq(vim.fn.readfile(content_path), { dst }, 'content holds the absolute dst')
    H.assert_eq(reg.content(), dst, 'content() reads the pointer back')

    -- B15: one `Yanked <raw source>` per source, in input order (the dir line
    -- keeps its raw trailing-slash spelling).
    local text = H.messages()
    local file_idx = text:find('Yanked ' .. src_file, 1, true)
    local dir_idx = text:find('Yanked ' .. src_dir, 1, true)
    H.assert_true(file_idx ~= nil and dir_idx ~= nil, 'both Yanked lines are present')
    H.assert_true(file_idx < dir_idx, 'yank lines are in input order')
    local _, count = text:gsub('Yanked ', '')
    H.assert_eq(count, 2, 'exactly one Yanked line per source')
  end)

  H.it('digest is stable across orderings and a re-yank replaces the entry (T-016/R7/D15)', function()
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

  H.it('paste pastes into dst, returns the last entry, logs history, notifies the summary once (T-016)', function()
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
      'the B15 summary is notified on success')
    local _, count = text:gsub('Pasted into ', '')
    H.assert_eq(count, 1, 'the summary is emitted exactly once')

    -- History is logged only on success (B6): the marker plus one undo line.
    local undo_path = vim.fs.joinpath(sb.data_home, 'direct/history/undo.log')
    local redo_path = vim.fs.joinpath(sb.data_home, 'direct/history/redo.log')
    H.assert_eq(vim.fn.readfile(undo_path),
      { '#direct-history-v2', 'p\t' .. src .. '\t' .. ws .. '\tf.txt\tf.txt' },
      'the marker plus the serialized paste line is recorded')
    H.assert_eq(vim.fn.readfile(redo_path), { '#direct-history-v2' },
      'log() reset the redo log to its marker')
  end)

  H.it('a destination clash prompts and pastes under the answered name (T-013/D9)', function()
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
    -- boundary (B7), so `require('direct.ui')` at test time would return a
    -- NEW table and the stub would miss -- the real prompt would then call
    -- vim.fn.input, which aborts silently under `-l`. This mirrors the D13
    -- fs-stub convention in history_spec.
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

  -- P1 (Greptile, PR #1): a clash answer that still named an existing entry was
  -- accepted verbatim, so a directory was MERGED into (copy_tree) / a file was
  -- overwritten and the paste was still recorded as newly created -- undo then
  -- deleted the whole destination, including data that predated the paste.
  -- The prompt must re-ask until the name is free; cancel still skips (D8a).
  H.it('a directory clash re-prompts instead of merging into the existing directory (P1)', function()
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

  H.it('undo after a clashing directory paste removes only what the paste created (P1)', function()
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

  H.it('cancelling the clash prompt changes nothing, even after a colliding answer (P1)', function()
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

  H.it('a file clash re-prompts too, so undo cannot delete a pre-existing file (P1)', function()
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

  H.it('an empty prompt answer skips the entry and reports it (T-013/D8a)', function()
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

  H.it('a partially-skipped paste logs only what it copied; undo spares the original (B1)', function()
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
    -- B1 prune the skipped a.txt was still in renames, so undo deleted the
    -- untouched original.
    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'IRREPLACEABLE USER DATA' },
      'undo leaves the pre-existing destination untouched (B1)')
    H.assert_false(fs.exists(ws .. '/b.txt'),
      'undo removes the entry that was actually pasted')
  end)

  H.it('a fully-skipped paste logs a reversal that changes nothing (B1)', function()
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
    -- logged reversal is a no-op (before B1 it deleted both originals).
    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'orig-a' },
      'undo changes nothing when every entry was skipped (B1)')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'orig-b' },
      'undo changes nothing when every entry was skipped (B1)')
  end)

  H.it('a space-named entry can never arm an unrelated delete (B2)', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'my file.txt', { 'spacey' })
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'file.txt', { 'UNRELATED' })

    H.capture_messages()
    local yanked = reg.yank({ sb.root .. '/my file.txt' })
    if yanked == true then
      -- Guard reverted (negative-control shape): the space name must still not
      -- be able to arm an unrelated delete. Replay the paste+undo and require
      -- the unrelated file to survive the desynced renames lists.
      local last = reg.paste(ws)
      H.assert_eq(last, ws .. '/my file.txt', 'the space-named entry pasted')
      H.assert_true(history.undo() ~= nil, 'undo succeeds')
    else
      -- Chosen scheme (B2): the yank boundary refuses a space-named basename.
      H.assert_notified('contains a space')
      H.assert_nil(reg.content(),
        'a refused entry never arms a register content pointer')
    end
    H.assert_eq(vim.fn.readfile(ws .. '/file.txt'), { 'UNRELATED' },
      'the unrelated file.txt survives (B2)')
  end)

  -- R1: the register DIR is persisted, untrusted data. The Python predecessor
  -- wrote entry names there with no validation into the SAME dir (plugin/
  -- direct/register.py / data.py), so a legacy space-named entry exists on
  -- disk even though Lua refuses to WRITE one (B2). The name guard drops it
  -- before Paste is built; NB3 then stops the paste entirely (nothing survived
  -- filtering), so no no-op history line is written and no unrelated delete is
  -- ever armed.
  H.it('a legacy space-named register entry cannot arm an unrelated delete (R1/B2)', function()
    local sb = H.sandbox()

    -- Simulate the legacy on-disk state: a digest dir holding `my file.txt`
    -- plus the content pointer to it. Written directly -- NOT through yank,
    -- which refuses the name by design (B2/N1).
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
    local res = reg.paste(ws)

    -- The deleted-file oracle: with the R1 guard reverted these two readfile
    -- calls raise E484, because Unpaste desynced the names and removed both.
    H.assert_eq(vim.fn.readfile(ws .. '/my'), { 'UNRELATED-A' },
      'the unrelated my survives with its content (R1/B2)')
    H.assert_eq(vim.fn.readfile(ws .. '/file.txt'), { 'UNRELATED-B' },
      'the unrelated file.txt survives with its content (R1/B2)')
    H.assert_false(fs.exists(ws .. '/my file.txt'),
      'the legacy space-named entry was never pasted')
    H.assert_notified('skipping register entry')

    -- With the guard in place the only entry is dropped, so NB3 stops before
    -- building a Paste: nothing is logged and nothing is claimed.
    H.assert_nil(res, 'a register with no pasteable entry pastes nothing (NB3)')
    H.assert_notified('Nothing to paste')
    H.assert_false(H.messages():find('Pasted into ', 1, true) ~= nil,
      'no paste summary was emitted')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), nil,
      'no no-op history line was written (NB3)')
  end)

  -- B3: the SAME refusal must hold for a clash-prompt answer. Taking the raw
  -- answer verbatim (the pre-fix behaviour) let a space-carrying answer arm an
  -- unrelated delete: 'a.txt copy' serialized into the ' '-joined dst list,
  -- deserialized back as two names, and undo deleted the untouched ws/a.txt.
  H.it('a space-carrying clash answer is refused; undo spares the original and removes only the pasted fragment (B3)', function()
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
    -- Consumed in ascending src order: a.txt is answered with a
    -- separator-carrying name (must be refused like an empty answer), b.txt
    -- with a valid rename that is actually pasted.
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
      'the separator-answered clash is skipped, never overwritten (B3)')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'orig-b' },
      'the clashing b.txt is not overwritten either')
    H.assert_eq(vim.fn.readfile(ws .. '/renamed.txt'), { 'reg-b' },
      'the valid second answer was pasted')
    H.assert_eq(last, ws .. '/renamed.txt', 'the pasted fragment is the last entry')

    -- Undo must reverse only what was written: renamed.txt goes, and the
    -- untouched pre-existing a.txt survives -- before B3 the space answer was
    -- serialized verbatim, so the desynced names deleted ws/a.txt on undo
    -- (readfile then raises E484: the data-loss class this spec guards). This
    -- check is deliberately first among the post-conditions.
    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'PRECIOUS ORIGINAL' },
      'undo leaves the pre-existing destination untouched (B3)')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'orig-b' },
      'undo leaves the other untouched original alone')
    H.assert_false(fs.exists(ws .. '/renamed.txt'),
      'undo removes only the actually-pasted fragment')

    -- The refused answer is reported like an empty one, and it never creates a
    -- separator-named file in the first place.
    H.assert_notified('Skipped a.txt')
    H.assert_false(fs.exists(ws .. '/a.txt copy'),
      'no separator-named file is created (B3)')
  end)

  -- N2: the FIELD_SEPARATOR ('\t') is as unserializable as the ENTRY_SEPARATOR
  -- (' '), and must be refused at the same boundary -- at the yank and for a
  -- clash answer. Before the fix a TAB-named entry yanked fine and undid as a
  -- silent no-op (no data loss, but inconsistent).
  H.it('a TAB-named entry is refused at the yank boundary with an error (N2)', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f\to.txt', { 'tabby' })

    H.capture_messages()
    local ok, err = reg.yank({ sb.root .. '/f\to.txt' })
    H.assert_nil(ok, 'the TAB-named entry is refused')
    H.assert_true(type(err) == 'string' and #err > 0, 'yank carries an err')
    H.assert_notified('contains a tab')
    H.assert_nil(reg.content(), 'a refused entry never arms a content pointer')
    H.assert_eq(H.ls(register_dir(sb)), {},
      'a refused yank leaves no digest dir entry behind (N1)')
  end)

  H.it('a TAB-carrying clash answer is refused like an empty answer (N2)', function()
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
      'the tab-answered clash is skipped, never overwritten (N2)')
    H.assert_false(fs.exists(ws .. '/f\tother.txt'),
      'no tab-named file is created')
    H.assert_notified('Skipped f.txt')

    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/f.txt'), { 'original' },
      'undo changes nothing when the only entry was skipped (N2)')
  end)

  -- P2-NB2/B2: the register PASTE is the second ingress into the
  -- `NAME\tfield...` framing. The entry names are validated above, but the
  -- DESTINATION was not: a dst carrying the '\t' FIELD_SEPARATOR serialized into
  -- a corrupted line, `deserialize` split it into extra fields, and the reversal
  -- targeted a nonexistent path -- a silent no-op whose message still claimed
  -- success, with a differently-desynced undo on a second undo. The refusal is
  -- routed through the SAME action.serialize guard the persisted line will pass,
  -- BEFORE any copy, so nothing is written and no corrupted line can exist.
  H.it('a control-char destination is refused before any copy and writes no corrupted undo line (P2-NB2/B2)', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local dst = H.mkdir(sb.root, 'de\tst')

    H.capture_messages()
    local res, err = reg.paste(dst)

    H.assert_nil(res, 'the paste into an unrepresentable destination is refused')
    H.assert_true(type(err) == 'string' and #err > 0,
      'the refusal carries a reason')
    H.assert_notified('unrepresentable')
    H.assert_false(H.messages():find('Pasted into ', 1, true) ~= nil,
      'no success summary was emitted for a refused paste')
    -- The refusal happens BEFORE the copy: the destination is still empty.
    H.assert_eq(H.ls(dst), {}, 'nothing was copied into the destination')
    -- And no (corrupted) undo line was written at all.
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), nil, 'no undo line was written')
  end)

  -- N1: the space refusal must run BEFORE the digest dir is created, or a
  -- mixed yank leaves an unreferenced register dir containing the good entry.
  H.it('a refused mixed yank (good name + space name) creates no new register dir entry (N1)', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'good.txt', { 'g' })
    H.mkfile(sb.root, 'my file.txt', { 'spacey' })

    H.capture_messages()
    local ok, err = reg.yank({ sb.root .. '/good.txt', sb.root .. '/my file.txt' })
    H.assert_nil(ok, 'the mixed yank is refused')
    H.assert_true(type(err) == 'string' and #err > 0, 'yank carries an err')
    H.assert_notified('contains a space')
    H.assert_nil(reg.content(), 'a refused yank never arms a content pointer')
    H.assert_eq(H.ls(register_dir(sb)), {},
      'no digest dir or content entry exists after the refused yank')
  end)

  H.it('an empty register notifies and pastes nothing (T-016)', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')

    H.capture_messages()
    local res, err = reg.paste(ws)
    H.assert_nil(res, 'paste on an empty register returns nil')
    H.assert_nil(err, 'no error is carried for an empty register')
    H.assert_notified('Register is empty')
    H.assert_false(H.messages():find('Pasted into ', 1, true) ~= nil,
      'no summary was emitted')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct/history/undo.log')),
      nil, 'nothing was logged')
  end)

  H.it('paste copies a yanked directory tree (T-016)', function()
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

  H.it('the re-list hook fires only for the no-arg paste form and tolerates nil (B7/N6)', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')

    -- P4/NB6 wires the real buffer re-list into register.relist (init.lua);
    -- the register-level seam is what T-016 pins here.
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

  H.it('a failed paste notifies and logs no history (T-016/B6)', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'f.txt', { 'f' })
    H.assert_true(reg.yank({ sb.root .. '/f.txt' }) == true, 'yank')
    local ws = H.mkdir(sb.root, 'ws')

    local restore = H.stub(fs, 'copy_file', function()
      return nil, 'forced failure'
    end)
    H.capture_messages()
    local res, err = reg.paste(ws)
    restore()

    H.assert_nil(res, 'paste reports the failure')
    H.assert_nil(err, 'the failure is reported through the notification')
    H.assert_notified('Failed to paste')
    H.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct/history/undo.log')),
      nil, 'a failed paste is never logged')
  end)

  H.it('yank and paste report an unavailable data dir instead of raising (B9/O2)', function()
    local sb = H.sandbox()
    H.mkfile(sb.data_home, 'direct', { 'occupied' }) -- <home>/direct is a file

    H.capture_messages()
    local ok, yerr = reg.yank({ sb.root .. '/f.txt' })
    H.assert_nil(ok, 'yank reports the failure')
    H.assert_true(type(yerr) == 'string' and #yerr > 0, 'yank carries an err')
    H.assert_notified('register unavailable')

    H.capture_messages()
    local res, perr = reg.paste(sb.root .. '/ws')
    H.assert_nil(res, 'paste reports the failure')
    H.assert_true(type(perr) == 'string' and #perr > 0, 'paste carries an err')
    H.assert_notified('register unavailable')
    H.assert_false(H.messages():find('Register is empty', 1, true) ~= nil,
      'a data-dir failure is not reported as an empty register')
  end)
end)