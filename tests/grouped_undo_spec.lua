-- tests/grouped_undo_spec.lua -- dependent renames are one undoable action.
-- Group staging prevents a sequential reversal from overwriting swapped contents.

-- Logging a swap as two moves let one-step undo rename over unsaved contents.
-- The save was staged, but the old reversal was not.
--
-- UI edits produce swaps, rotations, and open chains. These are exactly the
-- connected move sets where one destination is another move's source; a
-- one-at-a-time reversal would collide. Independent moves stay separate.
-- The group is PERSISTED as one JSONL log entry,
-- not grouped in memory: the critical test below performs the swap in THIS
-- process and undoes it in a real second `nvim --headless -l` process.
--
-- Legacy logs are reset only when their framing is recognized; unknown and
-- malformed logs are preserved without executing entries.

local H = require('tests.support.harness')
local fixtures = require('tests.support.history_fixtures')

-- Resolve the repository root from this test file for the fresh-session script.
local SPEC_FILE = debug.getinfo(1, 'S').source:gsub('^@', '')
local REPO_ROOT = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(SPEC_FILE, ':p')))

local MARKER = fixtures.header
local V2_MARKER = '#direct-history-v2'
local move_record = fixtures.move
local group_record = fixtures.group

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

H.describe('grouped move undo', function()
  -- Modules are required INSIDE each spec body so the tables the harness
  -- re-sourced at the file boundary are the ones under test (and the ones a
  -- stub is installed on).
  local function modules()
    return require('direct.buffer'), require('direct.history'),
      require('direct.fs'), require('direct.action'), require('direct.paths'),
      require('direct.ui')
  end

  -- history_lines(name) -> the lines of history/<name>, {} when absent.
  local function history_lines(name)
    local paths = require('direct.paths')
    local path = paths.join(paths.data_dir('history'), name)
    if vim.fn.filereadable(path) ~= 1 then
      return {}
    end
    return vim.fn.readfile(path)
  end

  -- swap_line(ws) -> the exact on-disk record of a `a.txt <-> b.txt` swap: the
  -- two interlinked moves in the order the sync applied them.
local function swap_line(ws)
  return group_record({
    { ws .. '/a.txt', ws .. '/b.txt' },
    { ws .. '/b.txt', ws .. '/a.txt' },
  })
  end

  -- swap_through_sync(ws) -> lists ws, swaps the two lines and :writes, i.e.
  -- the real user path through `Buffer:sync()`.
  local function swap_through_sync(ws)
    local buffer = require('direct.buffer')
    buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b.txt', 'a.txt' })
    vim.cmd('write')
  end

  H.it('undo restores a swapped pair byte-identically in one step, redo re-applies it', function()
    local _, history = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })

    swap_through_sync(ws)
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-B' },
      'the swap applied: a.txt now holds b.txt content')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-A' },
      'the swap applied: b.txt now holds a.txt content')

    H.capture_messages()
    H.with_cwd(ws, function()
      H.assert_true(history.undo() ~= nil, 'undo succeeds')
    end)
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'no .direct-tmp-* left behind')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' },
      'a.txt is byte-identical to before the swap')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' },
      'b.txt is byte-identical to before the swap')
    -- the whole group is ONE user-visible summary, not one per move.
    H.assert_notified('Moved a.txt to b.txt, Moved b.txt to a.txt')

    -- ONE step: an immediate second undo has nothing left to do.
    H.capture_messages()
    H.assert_nil(history.undo(), 'the swap was a single undo step')
    H.assert_notified('Nothing to undo')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'the extra undo changed nothing')

    H.assert_true(history.redo() ~= nil, 'redo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-B' },
      'redo re-applied the swap')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-A' },
      'redo re-applied the swap')
    H.capture_messages()
    H.assert_nil(history.redo(), 'the redo was a single step')
    H.assert_notified('Nothing to redo')

    -- And the round trip closes.
    H.assert_true(history.undo() ~= nil, 'a further undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' })
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' })
  end)

  H.it('the swap is recorded as ONE group entry on disk, in both logs (format lock)', function()
    local _, history = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })

    swap_through_sync(ws)

    H.assert_eq(history_lines('undo.log'), { MARKER, swap_line(ws) },
      'the two interlinked moves are one group entry, not two mv lines')
    H.assert_eq(history_lines('redo.log'), { MARKER },
      'a new action still resets the redo branch to its marker')

    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(history_lines('undo.log'), { MARKER }, 'the group left undo.log')
    -- A 2-cycle is its own inverse, so the recorded reversal is the same line.
    H.assert_eq(history_lines('redo.log'), { MARKER, swap_line(ws) },
      'the reversal is recorded as ONE group entry')
  end)

  -- The test that matters: the grouping must be on disk. A fix that only grouped
  -- actions in memory would pass every in-process test above and still lose data
  -- after a restart, so the undo below runs in a REAL second Neovim process
  -- whose only shared state is the sandbox data dir.
  H.it('a swap recorded here is undone by a real second Neovim session', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })

    swap_through_sync(ws)
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-B' }, 'the swap applied')

    local script = H.mkfile(sb.root, 'fresh_undo.lua', {
      "local root = assert(vim.env.DIRECT_FRESH_ROOT, 'DIRECT_FRESH_ROOT required')",
      "package.path = root .. '/lua/?.lua;' .. root .. '/?.lua;' .. package.path",
      "local history = require('direct.history')",
      "local ok, res = pcall(history.undo)",
      "io.stdout:write(string.format('FRESH-UNDO ok=%s returned=%s\\n',"
        .. ' tostring(ok), tostring(res ~= nil)))',
    })

    local out
    H.with_env({ XDG_DATA_HOME = sb.data_home, DIRECT_FRESH_ROOT = REPO_ROOT },
      function()
        out = vim.fn.system({ vim.v.progpath, '--headless', '-l', script })
      end)

    H.assert_true(out:find('FRESH-UNDO ok=true returned=true', 1, true) ~= nil,
      'the fresh session undid the recorded swap; output was: ' .. vim.inspect(out))
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' },
      'the fresh session restored a.txt byte-identically')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' },
      'the fresh session restored b.txt byte-identically')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'no temp leftover')
  end)

  H.it('a directory-to-directory swap is one undo step and keeps tree contents', function()
    local _, history = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkdir(ws, 'd1')
    H.mkfile(ws, 'd1/inner.txt', { 'INNER-1' })
    H.mkdir(ws, 'd2')
    H.mkfile(ws, 'd2/inner.txt', { 'INNER-2' })

    local buffer = require('direct.buffer')
    buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'd2/', 'd1/' })
    vim.cmd('write')

    H.assert_eq(vim.fn.readfile(ws .. '/d1/inner.txt'), { 'INNER-2' },
      'the directories swapped')
    H.assert_eq(vim.fn.readfile(ws .. '/d2/inner.txt'), { 'INNER-1' },
      'the directories swapped')
    H.assert_eq(vim.json.decode(history_lines('undo.log')[2]).op, 'g',
      'a directory swap is a group entry too')

    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_eq(vim.fn.readfile(ws .. '/d1/inner.txt'), { 'INNER-1' },
      'd1 came back byte-identically')
    H.assert_eq(vim.fn.readfile(ws .. '/d2/inner.txt'), { 'INNER-2' },
      'd2 came back byte-identically')
    H.assert_fs_eq(ws, { 'd1/', 'd1/inner.txt', 'd2/', 'd2/inner.txt' },
      'both trees intact, no temp leftover')
    H.capture_messages()
    H.assert_nil(history.undo(), 'the directory swap was a single undo step')
    H.assert_notified('Nothing to undo')
  end)

  H.it('two independent moves stay two undo steps', function()
    local _, history = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })

    local buffer = require('direct.buffer')
    buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'x.txt', 'y.txt' })
    vim.cmd('write')

    H.assert_eq(vim.fn.readfile(ws .. '/x.txt'), { 'CONTENT-A' })
    H.assert_eq(vim.fn.readfile(ws .. '/y.txt'), { 'CONTENT-B' })
    H.assert_eq(history_lines('undo.log'), {
      MARKER,
      move_record(ws .. '/a.txt', ws .. '/x.txt'),
      move_record(ws .. '/b.txt', ws .. '/y.txt'),
    }, 'moves that share no name are two entries, never a group')

    H.assert_true(history.undo() ~= nil, 'the first undo reverses only the last move')
    H.assert_fs_eq(ws, { 'b.txt', 'x.txt' }, 'only b.txt -> y.txt was reversed')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' })
    H.assert_eq(vim.fn.readfile(ws .. '/x.txt'), { 'CONTENT-A' })

    H.assert_true(history.undo() ~= nil, 'the second undo reverses the first move')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'the original pair is back')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' })
  end)

  H.it('an N-way rotation is one undo step and round-trips', function()
    local _, history = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    H.mkfile(ws, 'c.txt', { 'CONTENT-C' })

    local buffer = require('direct.buffer')
    buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b.txt', 'c.txt', 'a.txt' })
    vim.cmd('write')

    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-C' }, 'a<-c')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-A' }, 'b<-a')
    H.assert_eq(vim.fn.readfile(ws .. '/c.txt'), { 'CONTENT-B' }, 'c<-b')
    H.assert_eq(history_lines('undo.log'), {
      MARKER,
      group_record({
        { ws .. '/a.txt', ws .. '/b.txt' },
        { ws .. '/b.txt', ws .. '/c.txt' },
        { ws .. '/c.txt', ws .. '/a.txt' },
      }),
    }, 'the whole 3-cycle is one group entry')

    H.assert_true(history.undo() ~= nil, 'undo succeeds')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt', 'c.txt' }, 'no temp leftover')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' })
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' })
    H.assert_eq(vim.fn.readfile(ws .. '/c.txt'), { 'CONTENT-C' })
    H.capture_messages()
    H.assert_nil(history.undo(), 'the rotation was a single undo step')
    H.assert_notified('Nothing to undo')

    H.assert_true(history.redo() ~= nil, 'redo re-applies the rotation')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-C' })
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-A' })
    H.assert_eq(vim.fn.readfile(ws .. '/c.txt'), { 'CONTENT-B' })
  end)

  H.it('a recognized superseded #direct-history-v2 log resets without replay or backup', function()
    local _, history, fs = modules()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    -- The state an older version left after a swap, with its log: TWO
    -- independent mv lines. Replaying them one per press is the reported bug.
    H.mkfile(ws, 'a.txt', { 'CONTENT-B' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-A' })
    H.mkfile(sb.data_home, 'direct/history/undo.log', {
      V2_MARKER,
      'mv\t' .. ws .. '/a.txt\t' .. ws .. '/b.txt',
      'mv\t' .. ws .. '/b.txt\t' .. ws .. '/a.txt',
    })

    H.capture_messages()
    H.assert_nil(history.undo(), 'a superseded log yields no undo step')
    H.assert_notified('resetting legacy or empty undo history')

    -- Nothing was half-applied and no content was destroyed.
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-B' },
      'the superseded log was not executed')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-A' },
      'the superseded log was not executed')

    local undo_path = vim.fs.joinpath(sb.data_home, 'direct/history/undo.log')
    H.assert_eq(vim.fn.readfile(undo_path), { MARKER },
      'the recognized v2 log is reset to header-only current JSONL')
    H.assert_false(fs.exists(undo_path .. '.legacy'), 'no backup is created')

    H.capture_messages()
    H.assert_nil(history.undo(), 'the reset log has no records')
    H.assert_notified('Nothing to undo')
  end)

  H.it('a group reversal whose staging fails is reported, lossless and retryable', function()
    local _, history, fs = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    swap_through_sync(ws)

    -- Fail every staging rename of the reversal.
    local real_rename = fs.rename
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        return nil, 'EACCES'
      end
      return real_rename(src, dst)
    end)
    H.capture_messages()
    H.with_cwd(ws, function()
      H.assert_nil(history.undo(), 'the failed staging refuses the undo')
    end)
    restore()

    H.assert_notified('Failed to undo action')
    -- Nothing was renamed, so the swapped state is fully intact.
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-B' },
      'the failed undo did not touch a.txt')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-A' },
      'the failed undo did not touch b.txt')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'no half-applied group, no temp')
    -- the group entry is kept so the undo can be retried.
    H.assert_eq(history_lines('undo.log'), { MARKER, swap_line(ws) },
      'the group entry is pushed back onto its source log')
    H.assert_eq(history_lines('redo.log'), { MARKER },
      'nothing was recorded as redone')

    H.assert_true(history.undo() ~= nil, 'the same undo succeeds once the fault clears')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' })
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' })
  end)

  H.it('a staging failure on a LATE member leaves no member displaced', function()
    local _, history, fs = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    swap_through_sync(ws)

    -- Fail the SECOND staging rename: the first member is ALREADY parked at
    -- .direct-tmp-1 when the failure hits (the check above only ever failed
    -- the first rename, so nothing was staged there).
    local real_rename = fs.rename
    local staged = 0
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if staged == 2 then
          return nil, 'EACCES'
        end
      end
      return real_rename(src, dst)
    end)
    H.capture_messages()
    H.with_cwd(ws, function()
      H.assert_nil(history.undo(), 'the failed staging refuses the undo')
    end)
    restore()

    H.assert_notified('could not stage renames')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' },
      'the failure left no .direct-tmp-* anywhere in the tree')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-B' },
      'a.txt holds its pre-attempt content at its original path')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-A' },
      'b.txt holds its pre-attempt content at its original path')
    -- The entry is kept for the retry; it is NOT dropped to make the
    -- retry stop failing.
    H.assert_eq(history_lines('undo.log'), { MARKER, swap_line(ws) },
      'the group entry is pushed back onto its source log')
  end)

  H.it('rollback collision does not overwrite an occupant', function()
    local _, history, fs = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    swap_through_sync(ws)

    local real_rename = fs.rename
    local staged, temp, destination, staged_contents = 0, nil, nil, nil
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if staged == 1 then
          temp, destination = dst, src
          staged_contents = vim.fn.readfile(src)
          local ok, err = real_rename(src, dst)
          if not ok then return nil, err end
          H.mkfile(ws, vim.fs.basename(destination), 'CONCURRENT-OCCUPANT')
          return true
        end
        return nil, 'forced late staging failure'
      end
      return real_rename(src, dst)
    end)
    H.capture_messages()
    H.with_cwd(ws, function()
      H.assert_nil(history.undo(), 'late staging failure aborts the group')
    end)
    restore()

    H.assert_eq(vim.fn.readfile(destination), { 'CONCURRENT-OCCUPANT' },
      'rollback must not replace the concurrently created occupant')
    H.assert_eq(vim.fn.readfile(temp), staged_contents,
      'the staged original remains recoverable at its temp path')
    H.assert_notified(temp)
    H.assert_notified(destination)
    H.assert_eq(history_lines('undo.log'), { MARKER, swap_line(ws) },
      'the failed group remains in history')
    H.assert_notified('manual recovery required')
  end)

  H.it('dangling symlink is restored on rollback', function()
    local _, history, fs, action = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local link = ws .. '/a.txt'
    local target = 'missing-target'
    H.assert_true(vim.uv.fs_symlink(target, link) ~= nil,
      'create the dangling symlink fixture')
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    local group = action.Group({
      action.Move(link, ws .. '/b.txt'),
      action.Move(ws .. '/b.txt', link),
    })
    H.assert_true(history.log(group), 'record the group for undo')

    local real_rename = fs.rename
    local staged = 0
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if staged == 2 then return nil, 'forced late staging failure' end
      end
      return real_rename(src, dst)
    end)
    H.capture_messages()
    H.with_cwd(ws, function()
      H.assert_nil(history.undo(), 'late staging failure aborts the group')
    end)
    restore()

    H.assert_eq(vim.uv.fs_readlink(link), target,
      'rollback restores the dangling symlink with its original target')
    H.assert_false(fs.taken(ws .. '/.direct-tmp-1'),
      'no staged symlink remains')
    H.assert_eq(history_lines('undo.log'), {
      MARKER,
      group_record({ { link, ws .. '/b.txt' }, { ws .. '/b.txt', link } }),
    }, 'the group remains available for retry')
    H.assert_true(history.undo() ~= nil,
      'retry succeeds after the staging fault clears')
    H.assert_eq(vim.uv.fs_readlink(ws .. '/b.txt'), target,
      'the retry moves the same dangling symlink without changing its target')
    H.assert_eq(vim.fn.readfile(link), { 'CONTENT-B' },
      'the other group member is restored at its expected path')
  end)

  H.it('rollback failure reports temp and retains history', function()
    local _, history, fs, action, _, ui = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    local group = action.Group({
      action.Move(ws .. '/b.txt', ws .. '/a.txt'),
      action.Move(ws .. '/a.txt', ws .. '/b.txt'),
    })
    H.assert_true(history.log(group), 'record the group for undo')

    local real_rename, real_rename_noreplace = fs.rename, fs.rename_noreplace
    local staged, temp, destination = 0, nil, nil
    local restore_rename = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if staged == 1 then temp, destination = dst, src end
        if staged == 2 then return nil, 'forced late staging failure' end
      end
      return real_rename(src, dst)
    end)
    local restore_noreplace = H.stub(fs, 'rename_noreplace', function(src, dst)
      if src == temp and dst == destination then
        return nil, 'forced rollback failure'
      end
      return real_rename_noreplace(src, dst)
    end)
    local notifications = {}
    local restore_notify = H.stub(ui, 'notify', function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end)
    H.with_cwd(ws, function()
      H.assert_nil(history.undo(), 'late staging and restoration failures abort')
    end)
    restore_notify()
    restore_noreplace()
    restore_rename()

    local rollback_error
    for _, notification in ipairs(notifications) do
      if notification.message:find('could not restore staged entry', 1, true) then
        rollback_error = notification
        break
      end
    end
    H.assert_not_nil(rollback_error, 'restoration failure is reported')
    H.assert_eq(rollback_error.level, vim.log.levels.ERROR,
      'restoration failure uses ERROR severity')
    H.assert_true(rollback_error.message:find(temp, 1, true) ~= nil,
      'the error names the preserved temp path')
    H.assert_true(rollback_error.message:find(destination, 1, true) ~= nil,
      'the error names the original destination')
    H.assert_true(rollback_error.message:find('manual recovery required before retry', 1, true) ~= nil,
      'a stranded staged entry is not presented as automatically retryable')
    H.assert_eq(history_lines('undo.log'), {
      MARKER,
      group_record({ { ws .. '/b.txt', ws .. '/a.txt' },
        { ws .. '/a.txt', ws .. '/b.txt' } }),
    }, 'the group remains in history after rollback itself fails')
  end)

  H.it('group rollback does not move a replacement found at a staged temp path', function()
    local _, _, fs, action, _, ui = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local src_a = H.mkfile(ws, 'a.txt', { 'A' })
    local src_b = H.mkfile(ws, 'b.txt', { 'B' })
    local temp, backup = ws .. '/.direct-tmp-1', ws .. '/saved-staged-entry'
    local real_rename = fs.rename
    local staged, replaced = 0, false
    local restore_rename = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if dst == temp and not replaced then
          local ok, err = real_rename(src, dst)
          assert(ok, err)
          assert(vim.uv.fs_rename(temp, backup) == true)
          H.mkfile(ws, vim.fs.basename(temp), { 'FOREIGN TEMP' })
          replaced = true
          return true
        end
        return nil, 'forced late staging failure'
      end
      return real_rename(src, dst)
    end)
    local notices = {}
    local restore_notify = H.stub(ui, 'notify', function(message)
      notices[#notices + 1] = message
    end)

    local result, err = action.Group({
      action.Move(src_a, src_b), action.Move(src_b, src_a),
    })['do']()
    restore_notify()
    restore_rename()

    H.assert_nil(result, 'late staging failure aborts the group')
    H.assert_true(type(err) == 'string', 'group error is returned')
    H.assert_true(replaced, 'the staged temp path was replaced')
    H.assert_eq(vim.fn.readfile(backup), { 'A' }, 'the staged user data survives elsewhere')
    H.assert_eq(vim.fn.readfile(temp), { 'FOREIGN TEMP' }, 'foreign temp stays untouched')
    H.assert_nil(vim.uv.fs_lstat(src_a), 'group rollback did not move foreign data to src')
    H.assert_eq(vim.fn.readfile(src_b), { 'B' }, 'the unstaged source remains')
    local reported = false
    for _, message in ipairs(notices) do
      if message:find('source identity changed: ' .. temp, 1, true) then
        reported = true
      end
    end
    H.assert_true(reported, 'replacement at the temp path is reported')
  end)

  H.it('a grouped undo that failed at a late member is retryable once the fault clears', function()
    local _, history, fs = modules()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    swap_through_sync(ws)

    local real_rename = fs.rename
    local staged = 0
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if staged == 2 then
          return nil, 'EACCES'
        end
      end
      return real_rename(src, dst)
    end)
    H.capture_messages()
    H.with_cwd(ws, function()
      H.assert_nil(history.undo(), 'the first undo fails on the late member')
    end)
    restore()

    -- The obstruction is gone: the SAME undo entry must now succeed.
    H.capture_messages()
    local retried
    H.with_cwd(ws, function()
      retried = history.undo()
    end)
    H.assert_not_nil(retried, 'the retried undo succeeds after the fault clears')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'no .direct-tmp-* left behind')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' },
      'the retry restored a.txt')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' },
      'the retry restored b.txt')
  end)

  H.it('a group reversal that fails midway reports the entry left at its temp', function()
    local _, _, fs, action, _, ui = modules()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    -- The post-swap state, reversed by the recorded group.
    H.mkfile(ws, 'a.txt', { 'CONTENT-B' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-A' })

    local group = action.Group({
      action.Move(ws .. '/a.txt', ws .. '/b.txt'),
      action.Move(ws .. '/b.txt', ws .. '/a.txt'),
    })

    -- Fail the second executed move: its source is the second staged temp.
    local real_rename = fs.rename
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(src):match('%.direct%-tmp%-2$') then
        return nil, 'EIO'
      end
      return real_rename(src, dst)
    end)
    local notify = H.stub(ui, 'notify', function() end)
    local ok, err = group['do']()
    notify()
    restore()

    H.assert_nil(ok, 'the group reports the mid-way failure')
    H.assert_true(type(err) == 'string' and err:find('EIO', 1, true) ~= nil,
      'the reason is carried, got: ' .. tostring(err))
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' },
      'the first move landed')
    H.assert_eq(vim.fn.readfile(ws .. '/.direct-tmp-2'), { 'CONTENT-A' },
      'the entry the failed move could not place survives at its temp')
  end)

  H.it('move_groups groups exactly the interlinked moves, in order', function()
    local _, _, _, action = modules()
    local function mv(src, dst)
      return action.Move(src, dst)
    end

    H.assert_eq(action.move_groups({
      mv('/w/a', '/w/b'), mv('/w/b', '/w/a'),
    }), { { 1, 2 } }, 'a swap is one group')

    H.assert_eq(action.move_groups({
      mv('/w/a', '/w/b'), mv('/w/b', '/w/c'), mv('/w/c', '/w/d'),
    }), { { 1, 2, 3 } }, 'an open chain is one group')

    H.assert_eq(action.move_groups({
      mv('/w/a', '/w/b'), mv('/w/b', '/w/c'), mv('/w/c', '/w/a'),
    }), { { 1, 2, 3 } }, 'an N-way rotation is one group')

    H.assert_eq(action.move_groups({
      mv('/w/a', '/w/x'), mv('/w/b', '/w/y'),
    }), { { 1 }, { 2 } }, 'independent moves stay separate')

    H.assert_eq(action.move_groups({
      mv('/w/a', '/w/x'), mv('/w/b', '/w/c'), mv('/w/c', '/w/b'),
    }), { { 1 }, { 2, 3 } }, 'only the dependent pair is grouped')

    H.assert_eq(action.move_groups({
      action.Touch('/w/t.txt'), mv('/w/b', '/w/a'), mv('/w/a', '/w/b'),
      action.MakeDirectory('/w/d/'),
    }), { { 1 }, { 2, 3 }, { 4 } }, 'a non-move action is its own singleton')
  end)

  H.it('a malformed JSON group record is refused and preserved, never executed', function()
    local _, history, fs = modules()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'CONTENT-A' })
    H.mkfile(ws, 'b.txt', { 'CONTENT-B' })
    -- A group has fewer than the required two move pairs.
    local bad = '{"op":"g","moves":[{"src":' .. vim.json.encode(ws .. '/a.txt')
      .. ',"dst":' .. vim.json.encode(ws .. '/b.txt') .. '}]}'
    H.mkfile(sb.data_home, 'direct/history/undo.log', { MARKER, bad })

    H.capture_messages()
    H.assert_nil(history.undo(), 'malformed history refuses undo')
    H.assert_notified('history was preserved')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'CONTENT-A' },
      'nothing was moved')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'CONTENT-B' },
      'nothing was moved')
    H.assert_false(fs.exists(ws .. '/.direct-tmp-1'), 'no staging happened')
    H.assert_eq(history_lines('undo.log'), { MARKER, bad },
      'the malformed record is preserved exactly')
  end)
end)
