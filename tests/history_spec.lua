-- tests/history_spec.lua -- undo/redo, versioned logs, and failure recovery.
-- The marker prevents unsafe legacy replay; failed reversals remain retryable.

local H = require('tests.support.harness')
local history = require('direct.history')
local action = require('direct.action')
local fs = require('direct.fs')
local log = require('direct.log')
local paths = require('direct.paths')

local MARKER = history.HEADER

H.describe('history', function()
  local function history_dir(sb)
    return vim.fs.joinpath(sb.data_home, 'direct/history')
  end

  -- with_fresh_process(fn): run fn against a fresh `direct.*` module graph, so a
  -- spec can model a SECOND nvim process that shares only the on-disk state.
  -- The module cache is restored afterwards, so this file's captured module
  -- tables (and the stubs that patch them) stay authoritative for later specs.
  local function with_fresh_process(fn)
    local saved = {}
    for k, value in pairs(package.loaded) do
      if k == 'direct' or k:match('^direct%.') then
        saved[k] = value
        package.loaded[k] = nil
      end
    end
    local ok, err = xpcall(fn, debug.traceback)
    for k in pairs(package.loaded) do
      if k == 'direct' or k:match('^direct%.') then
        package.loaded[k] = nil
      end
    end
    for k, value in pairs(saved) do
      package.loaded[k] = value
    end
    if not ok then
      error(err, 0)
    end
  end

  H.it('undo/redo round-trips per action type', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local reg = H.mkdir(sb.data_home, 'reg')
    H.mkfile(reg, 'f.txt', { 'f' })
    H.mkdir(reg, 'tree')
    H.mkfile(reg, 'tree/sub.txt', { 's' })
    H.mkfile(reg, 'u.txt', { 'u' })

    local function roundtrip(label, build, expect_after, expect_undo, cleanup)
      local a = build()
      H.assert_true(a['do']() ~= nil, label .. ': do() succeeds')
      H.assert_fs_eq(ws, expect_after, label .. ': state after do()')
      H.assert_true(history.log(a) == true, label .. ': log() succeeds')
      H.assert_true(history.undo() ~= nil, label .. ': undo() succeeds')
      H.assert_fs_eq(ws, expect_undo, label .. ': state after undo()')
      H.assert_true(history.redo() ~= nil, label .. ': redo() succeeds')
      H.assert_fs_eq(ws, expect_after, label .. ': state after redo()')
      if cleanup then
        cleanup()
        H.assert_fs_eq(ws, {}, label .. ': workspace clean for the next roundtrip')
      end
    end

    -- t.txt: touch roundtrip re-creates the file; remove it so the next
    -- roundtrip starts from an empty workspace.
    roundtrip('touch',
      function() return action.Touch(ws .. '/t.txt') end,
      { 't.txt' }, {},
      function() vim.fn.delete(ws .. '/t.txt') end)

    -- b.txt: the mv roundtrip ends with a.txt renamed to b.txt.
    H.mkfile(ws, 'a.txt', { 'a' })
    roundtrip('mv',
      function() return action.Move(ws .. '/a.txt', ws .. '/b.txt') end,
      { 'b.txt' }, { 'a.txt' },
      function() vim.fn.delete(ws .. '/b.txt') end)

    -- rm / rmdir roundtrips end with an empty workspace (the entry sits in the
    -- trash), so no cleanup is needed between them.
    H.mkfile(ws, 'f.txt', { 'f' })
    roundtrip('rm',
      function() return action.Remove(ws .. '/f.txt') end,
      {}, { 'f.txt' })

    H.mkdir(ws, 'd')
    H.mkfile(ws, 'd/sub.txt', { 's' })
    roundtrip('rmdir',
      function() return action.RemoveDirectory(ws .. '/d') end,
      {}, { 'd/', 'd/sub.txt' })

    -- rs: a restore from trash, using a throwaway (unlogged) removal to put a
    -- file into the trash first. The file must exist before the removal.
    H.mkfile(ws, 'f2.txt', { 'f2' })
    local rm_f = action.Remove(ws .. '/f2.txt')
    H.assert_true(rm_f['do']() ~= nil, 'setup: throwaway removal for rs')
    roundtrip('rs',
      function() return action.Restore(rm_f.dst, ws .. '/f2.txt') end,
      { 'f2.txt' }, {},
      function() vim.fn.delete(ws .. '/f2.txt') end)

    -- rsdir: same pattern for a directory tree, restored and then cleaned up.
    local rm_d = action.RemoveDirectory(ws .. '/d2')
    H.mkdir(ws, 'd2')
    H.mkfile(ws, 'd2/sub.txt', { 's' })
    H.assert_true(rm_d['do']() ~= nil, 'setup: throwaway removal for rsdir')
    roundtrip('rsdir',
      function() return action.RestoreDirectory(rm_d.dst, ws .. '/d2') end,
      { 'd2/', 'd2/sub.txt' }, {},
      function() vim.fs.rm(ws .. '/d2', { recursive = true, force = true }) end)

    -- mkdir / p / up roundtrips leave their entries behind after redo.
    roundtrip('mkdir',
      function() return action.MakeDirectory(ws .. '/d3') end,
      { 'd3/' }, {},
      function() vim.fs.rm(ws .. '/d3', { recursive = true, force = true }) end)

    roundtrip('p',
      function() return action.Paste(reg, ws, { 'f.txt', 'tree' }, { 'f.txt', 'tree' }) end,
      { 'f.txt', 'tree/', 'tree/sub.txt' }, {},
      function()
        vim.fn.delete(ws .. '/f.txt')
        vim.fs.rm(ws .. '/tree', { recursive = true, force = true })
      end)

    -- up: a manual (unlogged) paste first, then an unpaste that is undone
    -- and redone. The roundtrip ends with an empty workspace again.
    H.assert_true(
      action.Paste(reg, ws, { 'u.txt' }, { 'u.txt' })['do']() ~= nil,
      'setup: manual paste for up')
    roundtrip('up',
      function() return action.Unpaste(ws, reg, { 'u.txt' }, { 'u.txt' }) end,
      {}, { 'u.txt' })
  end)

  -- Ten stacked mutations verify strict LIFO undo followed by ordered redo.
  -- The sequence covers repeated trash naming and a directory restore whose
  -- ordering matters: the tree must be rebuilt before undoing its inner file.
  H.it('ten stacked mutations undo one LIFO step at a time, then redo in order', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')

    -- states[i] is the workspace snapshot after step i-1; states[1] is the
    -- original (empty) workspace. Each `step` applies a logged mutation and
    -- records the state it produced, so every undo/redo can name the exact state
    -- it must reach.
    local states = { H.fs_snapshot(ws) }
    local function step(build)
      local a = build()
      H.assert_true(a['do']() ~= nil, 'step ' .. (#states) .. ': do() succeeds')
      H.assert_true(history.log(a) == true, 'step ' .. (#states) .. ': log() succeeds')
      states[#states + 1] = H.fs_snapshot(ws)
    end

    step(function() return action.MakeDirectory(ws .. '/tree') end)          -- 1 mkdir
    step(function() return action.Touch(ws .. '/tree/inner.txt') end)        -- 2 create file
    step(function() return action.RemoveDirectory(ws .. '/tree') end)        -- 3 delete dir
    step(function() return action.Touch(ws .. '/same.txt') end)              -- 4 create file
    step(function() return action.Remove(ws .. '/same.txt') end)             -- 5 delete file
    step(function() return action.Touch(ws .. '/same.txt') end)              -- 6 recreate it
    step(function() return action.Remove(ws .. '/same.txt') end)             -- 7 delete it again
    step(function() return action.Touch(ws .. '/a.txt') end)                 -- 8 create file
    step(function() return action.Move(ws .. '/a.txt', ws .. '/b.txt') end)  -- 9 rename/move
    step(function() return action.Touch(ws .. '/c.txt') end)                 -- 10 create file

    -- The repeated removal really did take the collision slot: after step 7 the
    -- trash holds BOTH `<digest(same.txt)>` (step 5) and its `-1` sibling
    -- (step 7). Without this, the LIFO/trash-numbering claim could pass while the
    -- collision path was never reached.
    local trash = paths.data_dir('trash')
    local digest = paths.digest(ws .. '/same.txt')
    H.assert_true(fs.exists(paths.join(trash, digest)),
      'the first rm of same.txt occupies <digest>')
    H.assert_true(fs.exists(paths.join(trash, digest .. '-1')),
      'the repeated rm of same.txt took the <digest>-1 collision slot')

    -- Undo: step 10 first, ..., step 1 last; after each undo the workspace must
    -- equal the state that step originally produced only AFTER its predecessor.
    local n = #states - 1 -- number of steps (10)
    for j = n, 1, -1 do
      H.assert_true(history.undo() ~= nil, 'undo of step ' .. j .. ' succeeds')
      H.assert_eq(H.fs_snapshot(ws), states[j],
        'state after undoing step ' .. j .. ' (LIFO)')
    end
    -- Exactly ten steps were drained: an eleventh undo is the original state.
    H.assert_eq(H.fs_snapshot(ws), states[1], 'all ten steps undone to the original state')
    H.capture_messages()
    H.assert_nil(history.undo(), 'a further undo has nothing to undo')
    H.assert_notified('Nothing to undo')
    H.assert_eq(H.fs_snapshot(ws), states[1], 'the extra undo changed nothing')

    -- Redo: step 1 first, ..., step 10 last; after each redo the workspace must
    -- equal the state that step produced.
    for j = 1, n do
      H.assert_true(history.redo() ~= nil, 'redo of step ' .. j .. ' succeeds')
      H.assert_eq(H.fs_snapshot(ws), states[j + 1],
        'state after redoing step ' .. j)
    end
    H.assert_eq(H.fs_snapshot(ws), states[n + 1],
      'redo re-applied all ten steps to the final state')
  end)

  H.it('undo/redo on empty logs notify Nothing to undo / Nothing to redo', function()
    local sb = H.sandbox()
    H.capture_messages()
    H.assert_nil(history.undo(), 'undo on an empty log returns nil')
    H.assert_notified('Nothing to undo')
    H.capture_messages()
    H.assert_nil(history.redo(), 'redo on an empty log returns nil')
    H.assert_notified('Nothing to redo')
  end)

  H.it('a failing reversal keeps the undo entry on the source log and notifies', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    local move = action.Move(sb.root .. '/a.txt', sb.root .. '/b.txt')
    H.assert_true(move['do']() ~= nil, 'move applied')
    H.assert_true(history.log(move) == true, 'logged')

    local undo_path = vim.fs.joinpath(history_dir(sb), 'undo.log')
    local redo_path = vim.fs.joinpath(history_dir(sb), 'redo.log')
    local record = action.serialize(move)
    H.assert_eq(vim.fn.readfile(undo_path), { MARKER, record },
      'the JSONL header plus one canonical record is recorded')

    -- The reversal of the move is Move(b -> a); make fs.rename fail so the
    -- undo cannot execute. cwd is the workspace so the failure message is
    -- Descriptions are relative to the current working directory.
    local restore = H.stub(fs, 'rename', function()
      return nil, 'forced failure'
    end)
    H.capture_messages()
    H.with_cwd(sb.root, function()
      local res = history.undo()
      H.assert_nil(res, 'undo reports the failure')
    end)
    restore()

    H.assert_notified('Failed to undo action - Moved b.txt to a.txt')
    H.assert_eq(vim.fn.readfile(undo_path), { MARKER, record },
      'the original JSON record was restored to undo.log')
    H.assert_eq(vim.fn.readfile(redo_path), { MARKER },
      'nothing was pushed to redo.log')

    -- With the stub restored the same undo succeeds and re-logs the reversal.
    H.assert_true(history.undo() ~= nil, 'undo succeeds after the stub is restored')
    H.assert_true(fs.exists(sb.root .. '/a.txt'), 'file restored')
    H.assert_false(fs.exists(sb.root .. '/b.txt'), 'renamed name gone')
    H.assert_eq(vim.fn.readfile(undo_path), { MARKER },
      'undo.log drained back to the header')
    H.assert_eq(vim.fn.readfile(redo_path),
      { MARKER, action.serialize(action.Move(sb.root .. '/b.txt', sb.root .. '/a.txt')) },
      'the inverse record was appended to redo.log')
  end)

  H.it('log() after an undo clears the redo log', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    local move = action.Move(sb.root .. '/a.txt', sb.root .. '/b.txt')
    move['do']()
    history.log(move)
    history.undo()

    local redo_path = vim.fs.joinpath(history_dir(sb), 'redo.log')
    H.assert_eq(#vim.fn.readfile(redo_path), 2,
      'redo holds the marker and the reversal')

    local touch = action.Touch(sb.root .. '/c.txt')
    touch['do']()
    history.log(touch)
    H.assert_eq(vim.fn.readfile(redo_path), { MARKER },
      'log() resets redo to its header')

    H.capture_messages()
    H.assert_nil(history.redo(), 'redo is now a no-op')
    H.assert_notified('Nothing to redo')
  end)

  -- Recognized predecessor logs are discarded with a warning, never replayed.
  -- Unknown or malformed files instead remain byte-identical and block actions.
  H.it('a recognized markerless Python log is reset, never executed or backed up', function()
    local sb = H.sandbox()
    local hist = history_dir(sb)
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'my', { 'UNRELATED-A' })
    H.mkfile(ws, 'file.txt', { 'UNRELATED-B' })
    -- A legacy `p` line whose destination is the workspace, so replaying it as
    -- an Unpaste deletes ws/my and ws/file.txt.
    local legacy_line = 'p\t' .. sb.root .. '/reg\t' .. ws
      .. '\tmy file.txt\tmy file.txt'
    H.mkfile(history_dir(sb), 'undo.log', { legacy_line })

    H.capture_messages()
    local res = history.undo()
    H.assert_nil(res, 'a foreign log yields no undo action')
    H.assert_notified('resetting legacy or empty undo history')

    -- The deleted-file oracle: these readfile calls raise E484 if the foreign
    -- line is ever executed.
    H.assert_eq(vim.fn.readfile(ws .. '/my'), { 'UNRELATED-A' },
      'the unrelated ws/my survives with its content')
    H.assert_eq(vim.fn.readfile(ws .. '/file.txt'), { 'UNRELATED-B' },
      'the unrelated ws/file.txt survives with its content')

    local undo_path = vim.fs.joinpath(history_dir(sb), 'undo.log')
    H.assert_eq(vim.fn.readfile(undo_path), { MARKER },
      'the recognized legacy log was reset to a header-only JSONL file')
    H.assert_false(fs.exists(undo_path .. '.legacy'), 'no backup file was created')

    -- With the foreign log gone, a second undo sees empty history.
    H.capture_messages()
    H.assert_nil(history.undo(), 'the quarantined log is gone')
    H.assert_notified('Nothing to undo')
  end)

  H.it('an unknown log is preserved even when legacy backup names exist', function()
    local sb = H.sandbox()
    local hist = history_dir(sb)
    local undo_path = vim.fs.joinpath(hist, 'undo.log')
    H.mkfile(hist, 'undo.log', { '#direct-history-v99' })
    H.mkfile(hist, 'undo.log.legacy', { 'legacy-older' })
    H.mkfile(hist, 'undo.log.legacy.1', { 'legacy-even-older' })

    H.capture_messages()
    H.assert_nil(history.undo(), 'an unknown log yields no action')
    H.assert_notified('history was preserved')
    H.assert_eq(log.read_raw(undo_path), '#direct-history-v99\n',
      'unknown bytes are unchanged')
    H.assert_eq(vim.fn.readfile(undo_path .. '.legacy'), { 'legacy-older' },
      'an unrelated pre-existing .legacy file is untouched')
    H.assert_eq(vim.fn.readfile(undo_path .. '.legacy.1'), { 'legacy-even-older' },
      'an unrelated pre-existing .legacy.1 file is untouched')
  end)

  H.it('a malformed log is left untouched and never appended to', function()
    local sb = H.sandbox()
    local hist = history_dir(sb)
    local undo_path = vim.fs.joinpath(hist, 'undo.log')
    H.mkfile(hist, 'undo.log', { '#direct-history-v3', 'mv\t/a' })
    local before = vim.fn.readfile(undo_path)

    H.capture_messages()
    H.assert_nil(history.undo(), 'an unquarantinable foreign log yields no action')
    H.assert_notified('history was preserved')
    H.assert_eq(log.read_raw(undo_path), before[1] .. '\n' .. before[2] .. '\n',
      'malformed bytes remain byte-for-byte untouched')

    -- A new action must not append to the foreign file either.
    local touch = action.Touch(sb.root .. '/c.txt')
    touch['do']()
    local ok, err = history.log(touch)
    H.assert_nil(ok, 'log() refuses while the foreign log cannot be quarantined')
    H.assert_true(type(err) == 'string' and #err > 0, 'log() carries an err')
    H.assert_eq(log.read_raw(undo_path), before[1] .. '\n' .. before[2] .. '\n',
      'log() never appends to malformed bytes')
  end)

  H.it('a marker-only log is empty history', function()
    local sb = H.sandbox()
    local hist = history_dir(sb)
    H.mkfile(hist, 'undo.log', { MARKER })
    H.capture_messages()
    H.assert_nil(history.undo(), 'a marker-only undo log has nothing to undo')
    H.assert_notified('Nothing to undo')

    H.mkfile(hist, 'redo.log', { MARKER })
    H.capture_messages()
    H.assert_nil(history.redo(), 'a marker-only redo log has nothing to redo')
    H.assert_notified('Nothing to redo')
  end)

  -- The marker lives on disk, so a log written by one process is replayed
  -- by another. A fresh module graph over the same on-disk state stands in for
  -- the second process.
  H.it('a version-marked log written by one process is undone by another', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    local undo_path = vim.fs.joinpath(history_dir(sb), 'undo.log')

    with_fresh_process(function()
      local h = require('direct.history')
      local a = require('direct.action')
      local move = a.Move(sb.root .. '/a.txt', sb.root .. '/b.txt')
      H.assert_true(move['do']() ~= nil, 'process A moved the file')
      H.assert_true(h.log(move) == true, 'process A logged the move')
    end)

    H.assert_eq(vim.fn.readfile(undo_path)[1], MARKER,
      'the on-disk log carries the JSONL header')
    H.assert_true(H.exists(sb.root, 'b.txt'), 'process A left the moved file')

    local undone = false
    with_fresh_process(function()
      local h = require('direct.history')
      undone = h.undo() ~= nil
    end)
    H.assert_true(undone, 'process B reversed the logged action')
    H.assert_true(H.exists(sb.root, 'a.txt'), 'a.txt is back')
    H.assert_false(H.exists(sb.root, 'b.txt'), 'b.txt is gone')
  end)

  H.it('undo success notifies the joined summary exactly once', function()
    local sb = H.sandbox()
    H.mkfile(sb.root, 'a.txt', { 'a' })
    local touch = action.Touch(sb.root .. '/a.txt')
    touch['do']()
    history.log(touch)

    H.capture_messages()
    H.with_cwd(sb.root, function()
      H.assert_true(history.undo() ~= nil, 'undo succeeds')
    end)
    local text = H.messages()
    H.assert_true(text:find('Removed a.txt', 1, true) ~= nil,
      'the summary names the executed reversal (Remove a.txt)')
    local _, count = text:gsub('Removed a.txt', '')
    H.assert_eq(count, 1, 'the summary is emitted exactly once')
    H.assert_false(text:find('touch', 1, true) ~= nil,
      'the serialized form is never used in the message')
  end)

  H.it('history reports an unavailable data dir instead of raising', function()
    local sb = H.sandbox()
    H.mkfile(sb.data_home, 'direct', { 'occupied' }) -- <home>/direct is a file

    H.capture_messages()
    local ok, err = history.log(action.Touch(sb.root .. '/t.txt'))
    H.assert_nil(ok, 'log() reports the failure')
    H.assert_true(type(err) == 'string' and #err > 0, 'log() carries an err')
    H.assert_notified('history was preserved')

    H.capture_messages()
    local res = history.undo()
    H.assert_nil(res, 'undo() reports the failure')
    H.assert_notified('history was preserved')
    H.assert_false(H.messages():find('Nothing to undo', 1, true) ~= nil,
      'the data-dir failure is not reported as an empty log')
  end)
end)
