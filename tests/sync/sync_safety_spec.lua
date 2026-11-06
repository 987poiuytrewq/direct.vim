-- sync_safety_spec.lua -- sync: safety guards.
-- Exercises the sync facade and filesystem effects.

local sync = require('tests.support.sync_helpers').new()
local H = sync.H
local buffer = sync.buffer
local fs = sync.fs
local paths = sync.paths
local history = sync.history
local register = sync.register
local fixtures = sync.fixtures
local HEADER = sync.HEADER
local decode_record = sync.decode_record
local clean_buffers = sync.clean_buffers
local route_write_to_test_buffer = sync.route_write_to_test_buffer
local history_lines = sync.history_lines
local list_edit_and_sync = sync.list_edit_and_sync

H.describe('sync: safety guards', function()
  H.it('uses the list-time wildignore snapshot when the option changes before sync', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'x.log', { 'preserve these bytes' })
    local listing

    H.with_option('wildignore', '', function()
      listing = buffer.list(ws)
    end)
    local before = vim.fn.readfile(ws .. '/x.log', 'b')
    H.with_option('wildignore', '*.log', function()
      vim.bo.modified = true
      H.capture_messages()
      local classified, classify = nil, buffer.classify
      buffer.classify = function(actual, expected)
        local plan = classify(actual, expected)
        classified = { actual = vim.deepcopy(actual), expected = vim.deepcopy(expected),
          plan = vim.deepcopy(plan) }
        return plan
      end
      local ok, reason = listing:sync()
      buffer.classify = classify
      H.assert_true(ok == true, tostring(reason))
      H.assert_eq(classified, {
        actual = { 'x.log' }, expected = { 'x.log' },
        plan = { kind = 'RENAME', moves = {} },
      }, 'list-time filtering produces no add/delete/move action')
      H.assert_eq(vim.fn.readfile(ws .. '/x.log', 'b'), before,
        'changing the option does not delete or rewrite a listed file')
      H.assert_eq(history_lines('undo.log'), {}, 'no filesystem action is recorded')
      H.assert_eq(H.messages(), '', 'the no-op sync does not report an error')
    end)
  end)

  H.it('excludes matching entries created after the list from sync classification', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    H.assert_buf_eq({ '' }, 0, 'the initially empty directory lists no entries')

    local created = H.mkfile(ws, 'created-after-list.log', { 'preserve these bytes' })
    local before = vim.fn.readfile(created, 'b')
    local classified, classify = nil, buffer.classify
    buffer.classify = function(actual, expected)
      local plan = classify(actual, expected)
      classified = { actual = vim.deepcopy(actual), expected = vim.deepcopy(expected),
        plan = vim.deepcopy(plan) }
      return plan
    end

    local ok, reason = listing:sync()
    buffer.classify = classify

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(classified, {
      actual = {}, expected = {}, plan = { kind = 'RENAME', moves = {} },
    }, 'the list-time filter excludes new matching names from classification')
    H.assert_eq(vim.fn.readfile(created, 'b'), before,
      'the newly appearing ignored file is not moved to trash')
    H.assert_eq(history_lines('undo.log'), {}, 'no filesystem action is recorded')
  end)

  H.it('takes a changed wildignore into account after an explicit re-list', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'x.log', { 'preserve these bytes' })
    local listing
    H.with_option('wildignore', '', function()
      listing = buffer.list(ws)
    end)
    H.with_option('wildignore', '*.log', function()
      H.assert_true(listing:list() == true, 're-list captures the changed filter')
      H.assert_buf_eq({ '' }, 0, 'the newly hidden file is omitted after re-list')
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'x.log' })
      H.capture_messages()
      local ok, reason = listing:sync()
      H.assert_nil(ok, 'sync refuses creating a row over the now-hidden file')
      H.assert_true(tostring(reason):find(ws .. '/x.log', 1, true) ~= nil,
        'the hidden destination is named')
      H.assert_eq(vim.fn.readfile(ws .. '/x.log', 'b'), { 'preserve these bytes', '' },
        're-list never authorizes writing over the existing file')
    end)
  end)

  H.it('never classifies a list-time hidden entry as a delete or move source', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'visible.txt', { 'visible' })
    H.mkfile(ws, 'keep.txt', { 'keep' })
    H.mkfile(ws, 'hidden.log', { 'hidden' })
    local hidden_before = vim.fn.readfile(ws .. '/hidden.log', 'b')
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local classified, classify = nil, buffer.classify
    buffer.classify = function(actual, expected)
      local plan = classify(actual, expected)
      classified = { actual = vim.deepcopy(actual), expected = vim.deepcopy(expected),
        plan = vim.deepcopy(plan) }
      return plan
    end
    local ok = listing:sync()
    buffer.classify = classify

    H.assert_true(ok == true, 'the visible delete applies normally')
    H.assert_eq(classified, {
      actual = { 'keep.txt' }, expected = { 'keep.txt', 'visible.txt' },
      plan = { kind = 'DELETE', removed = { 'visible.txt' } },
    }, 'the filtered entry is excluded from DELETE/MOVE sources')
    H.assert_eq(vim.fn.readfile(ws .. '/hidden.log', 'b'), hidden_before,
      'the hidden entry remains byte-identical')
  end)

  H.it('keeps a hidden file excluded when it becomes a directory before sync', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local hidden = H.mkfile(ws, 'x.log', { 'initial file contents' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)

    vim.uv.fs_unlink(hidden)
    vim.fn.mkdir(hidden, 'p')
    local inside = H.mkfile(hidden, 'inside.txt', { 'preserve directory contents' })
    local before = H.fs_snapshot(ws)
    local contents_before = vim.fn.readfile(inside, 'b')
    local classified, classify = nil, buffer.classify
    buffer.classify = function(actual, expected)
      local plan = classify(actual, expected)
      classified = { actual = vim.deepcopy(actual), expected = vim.deepcopy(expected),
        plan = vim.deepcopy(plan) }
      return plan
    end

    local ok, reason = listing:sync()
    buffer.classify = classify

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(classified.actual, {}, 'the unchanged listing remains empty')
    H.assert_eq(classified.expected, {}, 'the type-changed hidden path stays excluded')
    H.assert_eq(classified.plan.kind, 'RENAME', 'the plan is a no-op, not a delete')
    H.assert_eq(classified.plan.moves, {}, 'the plan contains no destructive move')
    H.assert_eq(H.fs_snapshot(ws), before, 'the hidden directory and its contents are untouched')
    H.assert_eq(vim.fn.readfile(inside, 'b'), contents_before,
      'the hidden directory file contents remain intact')
    H.assert_eq(history_lines('undo.log'), {}, 'no destructive action is recorded')
    H.assert_eq(history_lines('redo.log'), {}, 'redo history remains unchanged')
  end)

  H.it('keeps a hidden directory excluded when it becomes a file before sync', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local hidden = H.mkdir(ws, 'x.log')
    H.mkfile(hidden, 'inside.txt', { 'initial directory contents' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)

    vim.uv.fs_unlink(hidden .. '/inside.txt')
    vim.uv.fs_rmdir(hidden)
    local file = H.mkfile(ws, 'x.log', { 'preserve file contents' })
    local before = H.fs_snapshot(ws)
    local contents_before = vim.fn.readfile(file, 'b')
    local classified, classify = nil, buffer.classify
    buffer.classify = function(actual, expected)
      local plan = classify(actual, expected)
      classified = { actual = vim.deepcopy(actual), expected = vim.deepcopy(expected),
        plan = vim.deepcopy(plan) }
      return plan
    end

    local ok, reason = listing:sync()
    buffer.classify = classify

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(classified.actual, {}, 'the unchanged listing remains empty')
    H.assert_eq(classified.expected, {}, 'the type-changed hidden path stays excluded')
    H.assert_eq(classified.plan.kind, 'RENAME', 'the plan is a no-op, not a delete')
    H.assert_eq(classified.plan.moves, {}, 'the plan contains no destructive move')
    H.assert_eq(H.fs_snapshot(ws), before, 'the hidden file and its contents are untouched')
    H.assert_eq(vim.fn.readfile(file, 'b'), contents_before,
      'the hidden file contents remain intact')
    H.assert_eq(history_lines('undo.log'), {}, 'no destructive action is recorded')
    H.assert_eq(history_lines('redo.log'), {}, 'redo history remains unchanged')
  end)

  H.it('refuses an added line that names a list-time hidden file before side effects', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'visible.txt', { 'visible' })
    H.mkfile(ws, 'x.log', { 'preserve these bytes' })
    local before = vim.fn.readfile(ws .. '/x.log', 'b')
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'x.log' })

    local notifications = {}
    local restore_notify = H.stub(vim, 'notify', function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end)
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    local ok, reason = listing:sync()
    restore_notify()

    H.assert_nil(ok, 'an existing filtered destination refuses the entire sync')
    H.assert_true(tostring(reason):find(ws .. '/x.log', 1, true) ~= nil,
      'the conflicting path is returned')
    H.assert_eq(vim.fn.readfile(ws .. '/x.log', 'b'), before, 'hidden file bytes are unchanged')
    H.assert_eq(#notifications, 1, 'the refusal emits exactly one notification')
    H.assert_eq(notifications[1].level, vim.log.levels.ERROR, 'the refusal is an error')
    H.assert_true(notifications[1].message:find(ws .. '/x.log', 1, true) ~= nil,
      'the notification names the conflicting path')
    H.assert_eq(history_lines('undo.log'), undo_before, 'no undo history is written')
    H.assert_eq(history_lines('redo.log'), redo_before, 'redo history is unchanged')
    H.assert_true(vim.bo.modified, 'the buffer remains modified')
  end)

  H.it('refuses a visible rename onto an existing list-time hidden destination', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'source.txt', { 'source bytes' })
    H.mkfile(ws, 'target.log', { 'hidden bytes' })
    local source_before = vim.fn.readfile(ws .. '/source.txt', 'b')
    local target_before = vim.fn.readfile(ws .. '/target.log', 'b')
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'target.log' })

    local notifications = {}
    local restore_notify = H.stub(vim, 'notify', function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end)
    local ok = listing:sync()
    restore_notify()

    H.assert_nil(ok, 'the occupied rename destination refuses the entire sync')
    H.assert_eq(vim.fn.readfile(ws .. '/source.txt', 'b'), source_before,
      'the rename source is unchanged')
    H.assert_eq(vim.fn.readfile(ws .. '/target.log', 'b'), target_before,
      'the hidden destination is unchanged')
    H.assert_eq(#notifications, 1, 'the refusal emits one notification')
    H.assert_true(notifications[1].message:find(ws .. '/target.log', 1, true) ~= nil,
      'the notification names the destination')
    H.assert_eq(history_lines('undo.log'), {}, 'no history is written')
    H.assert_true(vim.bo.modified, 'the buffer remains modified')
  end)

  H.it('refuses the whole add batch when a directory marker targets a dangling symlink', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local target = ws .. '/target.log'
    H.assert_true(H.symlink(ws .. '/missing', target) == true,
      'dangling symlink created')
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'target.log/', 'new.txt' })

    local notifications = {}
    local restore_notify = H.stub(vim, 'notify', function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end)
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    local ok, reason = listing:sync()
    restore_notify()

    H.assert_nil(ok, 'an occupied directory destination refuses the complete batch')
    H.assert_true(tostring(reason):find(target, 1, true) ~= nil,
      'the occupied path is reported')
    H.assert_false(fs.taken(ws .. '/new.txt'), 'the other add was not partially created')
    H.assert_true(vim.uv.fs_lstat(target) ~= nil, 'the dangling symlink remains')
    H.assert_eq(#notifications, 1, 'one error notification is emitted')
    H.assert_eq(notifications[1].level, vim.log.levels.ERROR, 'the notification is an error')
    H.assert_eq(history_lines('undo.log'), undo_before, 'no undo history is written')
    H.assert_eq(history_lines('redo.log'), redo_before, 'redo history is unchanged')
    H.assert_true(vim.bo.modified, 'the unsynced batch remains modified')
  end)

  H.it('fails closed when a restored direct buffer has no list-time snapshot', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'existing.txt', { 'existing' })
    local listing = buffer.Buffer(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'existing.txt', 'new.txt' })
    local before = H.fs_snapshot(ws)
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'a buffer without a snapshot must be re-listed')
    H.assert_true(tostring(reason):find('snapshot', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'no filesystem changes occur')
    H.assert_eq(history_lines('undo.log'), {}, 'no history is written')
    H.assert_true(vim.bo.modified, 'the buffer remains modified')
    H.assert_notified('re-list', vim.log.levels.ERROR)
  end)

  H.it('captures hidden entries in expanded directories without changing their bytes', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local child = H.mkdir(ws, 'child')
    H.mkfile(child, 'visible.txt', { 'visible' })
    H.mkfile(child, 'hidden.log', { 'keep child bytes' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
      listing:expand(1)
    end)
    H.assert_buf_eq({ 'child/', '  visible.txt' }, 0, 'filtered child listing stays intact')
    local before = vim.fn.readfile(child .. '/hidden.log', 'b')
    H.with_option('wildignore', '', function()
      vim.bo.modified = true
      H.assert_true(listing:sync() == true, 'no root change is applied')
    end)
    H.assert_eq(vim.fn.readfile(child .. '/hidden.log', 'b'), before,
      'a child hidden at expansion time is never touched by sync')
  end)

  H.it('refuses to remove a visible directory containing list-time hidden descendants', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local hidden = H.mkfile(parent, 'hidden.log', { 'preserve hidden descendant' })
    H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local before = H.fs_snapshot(ws)
    local hidden_before = vim.fn.readfile(hidden, 'b')
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'deleting the visible parent must not move its hidden child')
    H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'the directory and hidden descendant remain in place')
    H.assert_eq(vim.fn.readfile(hidden, 'b'), hidden_before, 'hidden bytes are unchanged')
    H.assert_eq(history_lines('undo.log'), undo_before, 'no undo history is written')
    H.assert_eq(history_lines('redo.log'), redo_before, 'redo history is unchanged')
    H.assert_true(vim.bo.modified, 'the unsynced deletion remains visible in the buffer')
    H.assert_notified('hidden', vim.log.levels.ERROR)
  end)

  H.it('matches path-qualified list-time wildignore patterns in descendants', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local hidden = H.mkfile(parent, 'hidden.log', { 'preserve path-qualified bytes' })
    H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
    local listing
    H.with_option('wildignore', 'parent/*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local before = H.fs_snapshot(ws)
    local hidden_before = vim.fn.readfile(hidden, 'b')
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'deleting parent must not move a path-qualified hidden descendant')
    H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'the directory and hidden descendant remain in place')
    H.assert_eq(vim.fn.readfile(hidden, 'b'), hidden_before, 'hidden bytes are unchanged')
    H.assert_eq(history_lines('undo.log'), undo_before, 'no undo history is written')
    H.assert_eq(history_lines('redo.log'), redo_before, 'redo history is unchanged')
    H.assert_true(vim.bo.modified, 'the unsynced deletion remains visible in the buffer')
    H.assert_notified('hidden', vim.log.levels.ERROR)
  end)

  H.it('refuses to move a parent containing a filtered dangling symlink', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local hidden = parent .. '/hidden.log'
    H.assert_true(H.symlink(parent .. '/missing-target', hidden) == true,
      'filtered dangling symlink created')
    H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local before = H.fs_snapshot(ws)
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'deleting the visible parent must not move its hidden symlink')
    H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'the parent and dangling symlink stay in place')
    H.assert_true(vim.uv.fs_lstat(hidden) ~= nil, 'the dangling symlink is preserved')
    H.assert_eq(history_lines('undo.log'), undo_before, 'no undo history is written')
    H.assert_eq(history_lines('redo.log'), redo_before, 'redo history is unchanged')
    H.assert_true(vim.bo.modified, 'the unsynced deletion remains modified')
    H.assert_notified('hidden', vim.log.levels.ERROR)
  end)

  H.it('refuses to move a parent containing a filtered unsupported raw entry', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local hidden = parent .. '/hidden.log'
    local created, reason = H.mkfifo(hidden)
    if not created then H.skip(reason) end
    H.assert_eq(vim.uv.fs_lstat(hidden).type, 'fifo', 'fixture is an unsupported raw entry')
    H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local before = H.fs_snapshot(ws)
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'deleting the visible parent must not move its filtered FIFO')
    H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'the parent and unsupported entry stay in place')
    H.assert_eq(vim.uv.fs_lstat(hidden).type, 'fifo', 'the FIFO is preserved')
    H.assert_eq(history_lines('undo.log'), {}, 'no undo history is written')
    H.assert_true(vim.bo.modified, 'the unsynced deletion remains modified')
    H.assert_notified('hidden', vim.log.levels.ERROR)
  end)

  H.it('refuses both parent moves and deletes containing nested directory-only matches', function()
    for _, operation in ipairs({ 'move', 'delete' }) do
      clean_buffers()
      local sb = H.sandbox()
      local ws = H.mkdir(sb.root, 'ws')
      local parent = H.mkdir(ws, 'parent')
      local hidden = H.mkdir(parent, 'cache')
      H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
      local listing
      H.with_option('wildignore', 'cache/', function()
        listing = buffer.list(ws)
      end)
      if operation == 'move' then
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'moved/', 'keep.txt' })
      else
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
      end
      local before = H.fs_snapshot(ws)
      local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')

      local ok, reason = listing:sync()

      H.assert_nil(ok, operation .. ' must refuse the nested cache directory')
      H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
      H.assert_eq(H.fs_snapshot(ws), before, operation .. ' leaves filesystem unchanged')
      H.assert_true(fs.taken(hidden), operation .. ' preserves the empty cache directory')
      H.assert_eq(history_lines('undo.log'), undo_before, operation .. ' writes no undo history')
      H.assert_eq(history_lines('redo.log'), redo_before, operation .. ' preserves redo history')
      H.assert_true(vim.bo.modified, operation .. ' leaves the attempted edit modified')
    end
  end)

  H.it('still refuses dangling symlinks and FIFOs hidden from the listing with empty wildignore', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local dangling = parent .. '/dangling'
    H.assert_true(H.symlink(parent .. '/missing-target', dangling) == true,
      'dangling symlink created')
    local fifo = parent .. '/pipe'
    local created, reason = H.mkfifo(fifo)
    if not created then H.skip(reason) end
    H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
    local listing
    H.with_option('wildignore', '', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local before = H.fs_snapshot(ws)
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'the raw entries omitted from listing still block parent deletion')
    H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'the parent and both raw entries remain')
    H.assert_true(vim.uv.fs_lstat(dangling) ~= nil, 'dangling symlink remains present')
    H.assert_eq(vim.uv.fs_lstat(fifo).type, 'fifo', 'FIFO remains present')
    H.assert_eq(history_lines('undo.log'), undo_before, 'no undo history is written')
    H.assert_eq(history_lines('redo.log'), redo_before, 'redo history is unchanged')
    H.assert_true(vim.bo.modified, 'the unsynced deletion remains modified')
  end)

  H.it('does not apply a root FIFO snapshot name to an unrelated descendant', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    H.mkfile(parent, 'pipe', { 'ordinary descendant file' })
    local fifo = ws .. '/pipe'
    local created, reason = H.mkfifo(fifo)
    if not created then H.skip(reason) end
    local listing
    H.with_option('wildignore', '', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'moved/' })
    local ok, reason = listing:sync()

    H.assert_true(ok == true, 'the unrelated root FIFO must not block the move: ' .. tostring(reason))
    H.assert_true(not fs.taken(parent), 'the original directory was moved')
    H.assert_eq(vim.fn.readfile(ws .. '/moved/pipe'), { 'ordinary descendant file' },
      'the ordinary descendant file moved with its parent')
    H.assert_eq(vim.uv.fs_lstat(fifo).type, 'fifo', 'the root FIFO remains untouched')
    H.assert_eq(history_lines('undo.log'), {
      HEADER,
      fixtures.move(ws .. '/parent/', ws .. '/moved/'),
    }, 'the successful directory move is recorded in history')
    H.assert_eq(history_lines('redo.log'), { HEADER },
      'the successful move leaves redo history empty')
  end)

  H.it('uses each expanded directory list-time filter before moving its parent', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local hidden = H.mkfile(parent, 'hidden.log', { 'preserve child snapshot bytes' })
    H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
    local listing
    H.with_option('wildignore', '', function()
      listing = buffer.list(ws)
    end)
    H.with_option('wildignore', '*.log', function()
      listing:expand(1)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep.txt' })
    local before = H.fs_snapshot(ws)
    local hidden_before = vim.fn.readfile(hidden, 'b')
    local undo_before, redo_before = history_lines('undo.log'), history_lines('redo.log')
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'the expanded child snapshot blocks moving its parent')
    H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'the parent and filtered child remain in place')
    H.assert_eq(vim.fn.readfile(hidden, 'b'), hidden_before, 'hidden child bytes are unchanged')
    H.assert_eq(history_lines('undo.log'), undo_before, 'no undo history is written')
    H.assert_eq(history_lines('redo.log'), redo_before, 'redo history is unchanged')
    H.assert_true(vim.bo.modified, 'the unsynced deletion remains modified')
    H.assert_notified('hidden', vim.log.levels.ERROR)
  end)

  H.it('renames a visible directory symlink without scanning its target', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local target = H.mkdir(sb.root, 'target')
    H.mkfile(target, 'hidden.log', { 'target stays untouched' })
    local link = ws .. '/visible-link'
    H.assert_true(H.symlink(target, link) == true, 'directory symlink created')
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    H.assert_buf_eq({ 'visible-link/' }, 0, 'directory symlink is visible as a directory row')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'renamed-link/' })

    local ok, reason = listing:sync()

    H.assert_true(ok == true, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), { 'renamed-link@' }, 'only the symlink name changes')
    H.assert_eq(vim.fn.readfile(target .. '/hidden.log', 'b'), { 'target stays untouched', '' },
      'the symlink target remains untouched')
    H.assert_eq(history_lines('undo.log'), {
      HEADER,
      fixtures.move(link, ws .. '/renamed-link'),
    }, 'exactly one symlink rename is recorded')
  end)

  H.it('refuses to rename a visible directory containing list-time hidden descendants', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local parent = H.mkdir(ws, 'parent')
    local hidden = H.mkfile(parent, 'hidden.log', { 'preserve hidden descendant' })
    H.mkfile(ws, 'keep.txt', { 'keep visible sibling' })
    local listing
    H.with_option('wildignore', '*.log', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'renamed-parent/', 'keep.txt' })
    local before = H.fs_snapshot(ws)
    local hidden_before = vim.fn.readfile(hidden, 'b')
    H.capture_messages()

    local ok, reason = listing:sync()

    H.assert_nil(ok, 'renaming the visible parent must not move its hidden child')
    H.assert_true(tostring(reason):find('hidden', 1, true) ~= nil, tostring(reason))
    H.assert_eq(H.fs_snapshot(ws), before, 'the directory and hidden descendant remain in place')
    H.assert_eq(vim.fn.readfile(hidden, 'b'), hidden_before, 'hidden bytes are unchanged')
    H.assert_eq(history_lines('undo.log'), {}, 'no undo history is written')
    H.assert_true(vim.bo.modified, 'the unsynced rename remains visible in the buffer')
    H.assert_notified('hidden', vim.log.levels.ERROR)
  end)

  H.it('swap rename (a<->b) completes with no data loss and no leftover temp', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })

    local _, ok = list_edit_and_sync(ws, { 'b.txt', 'a.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'exactly two files, no .direct-tmp-*')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'B' }, 'a.txt received the swapped content')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'A' }, 'b.txt received the swapped content')
  end)

  H.it('case-only rename preserves content and is undoable and redoable on insensitive filesystems', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'foo.txt', { 'case-only content' })
    if vim.uv.fs_lstat(ws .. '/FOO.TXT') == nil then
      -- Linux and other case-sensitive filesystems correctly treat this as a
      -- different, absent pathname; the rename behavior is platform-specific.
      H.skip('the filesystem is case-sensitive')
    end

    local _, ok, reason = list_edit_and_sync(ws, { 'Foo.txt' })

    H.assert_true(ok == true, 'case-only sync succeeds: ' .. tostring(reason))
    H.assert_eq(vim.fn.readfile(ws .. '/Foo.txt'), { 'case-only content' }, 'content is preserved')
    H.assert_eq(history_lines('undo.log'), {
      HEADER, fixtures.move(ws .. '/foo.txt', ws .. '/Foo.txt'),
    }, 'the original and destination spellings are logged')
    H.assert_true(history.undo() ~= nil, 'the rename can be undone')
    H.assert_eq(vim.fn.readfile(ws .. '/foo.txt'), { 'case-only content' }, 'undo restores old spelling')
    H.assert_true(history.redo() ~= nil, 'the rename can be redone')
    H.assert_eq(vim.fn.readfile(ws .. '/Foo.txt'), { 'case-only content' }, 'redo restores new spelling')
  end)

  H.it('refuses a case-only-looking rename onto a different occupied entry on sensitive filesystems', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'foo.txt', { 'source' })
    H.mkfile(ws, 'Foo.txt', { 'destination' })
    if vim.uv.fs_lstat(ws .. '/FOO.TXT') ~= nil then
      -- On an insensitive filesystem these names are the same directory entry.
      H.skip('the filesystem is case-insensitive')
    end

    local listing
    H.with_option('wildignore', 'Foo.txt', function()
      listing = buffer.list(ws)
    end)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'Foo.txt' })
    local ok, reason = listing:sync()

    H.assert_nil(ok, 'a different occupied destination refuses the batch')
    H.assert_true(tostring(reason):find('destination already exists', 1, true) ~= nil,
      'the collision is reported')
    H.assert_eq(vim.fn.readfile(ws .. '/foo.txt'), { 'source' }, 'source is unchanged')
    H.assert_eq(vim.fn.readfile(ws .. '/Foo.txt'), { 'destination' }, 'destination is unchanged')
    H.assert_eq(history_lines('undo.log'), {}, 'refusal writes no history')
    H.assert_true(vim.bo.modified, 'the unsynced change remains visible')
  end)

  H.it('chain rename (a->b->c->d) completes with no leftovers', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })
    H.mkfile(ws, 'c.txt', { 'C' })

    local _, ok = list_edit_and_sync(ws, { 'b.txt', 'c.txt', 'd.txt' })

    H.assert_true(ok == true, 'sync applied')
    H.assert_fs_eq(ws, { 'b.txt', 'c.txt', 'd.txt' }, 'no .direct-tmp-* remains')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'A' })
    H.assert_eq(vim.fn.readfile(ws .. '/c.txt'), { 'B' })
    H.assert_eq(vim.fn.readfile(ws .. '/d.txt'), { 'C' })
  end)

  H.it('completes a mixed real-directory and directory-symlink rename chain', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local real_dir = H.mkdir(ws, 'a')
    H.mkfile(real_dir, 'payload.txt', { 'directory payload' })
    local target = H.mkdir(sb.root, 'symlink-target')
    H.mkfile(target, 'target.txt', { 'symlink target' })
    local link = ws .. '/b'
    H.assert_true(H.symlink(target, link) == true, 'directory symlink created')
    local listing = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b/', 'c/' })

    local ok, reason = listing:sync()

    local completed = H.fs_snapshot(ws)
    local expected = { 'b/', 'b/payload.txt', 'c@' }
    H.assert_true(ok == true, 'the safe mixed chain should apply completely: ' .. tostring(reason))
    H.assert_eq(completed, expected,
      'successful sync completes both renames without losing either entry')
    H.assert_eq(vim.fn.readfile(ws .. '/b/payload.txt'), { 'directory payload' },
      'the real directory reaches b/')
    H.assert_eq(vim.uv.fs_readlink(ws .. '/c'), target,
      'the directory symlink reaches c without moving its target')
    H.assert_eq(history_lines('undo.log'), {
      HEADER,
      fixtures.group({
        { ws .. '/a/', ws .. '/b/' },
        { ws .. '/b', ws .. '/c' },
      }),
    }, 'group history keeps the original directory and symlink path spellings')
  end)

  H.it('a failed staging rename restores prior temps with no-replace', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b.txt', 'a.txt' })

    -- Fail the SECOND staging rename (b.txt -> .direct-tmp-2) after the first
    -- staged source has moved; the sync boundary should restore it atomically.
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
    local ok, reason = buf:sync()
    restore()

    H.assert_nil(ok, 'the staging failure refuses the sync')
    H.assert_eq(reason, 'EACCES', 'the staging error is returned')
    H.assert_notified('Action failed')

    H.assert_false(fs.taken(ws .. '/.direct-tmp-1'), 'the staged temp was consumed by rollback')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'A' },
      'rollback restored the first staged source')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'B' },
      'b.txt is untouched (its staging rename failed before it moved)')
    -- No action ran after the failed staging. Preflight may have initialized the
    -- empty stack, but no history record was written.
    H.assert_eq(history_lines('undo.log'), { HEADER }, 'no history record was written')
    H.assert_true(vim.bo.modified, 'the refused sync leaves the buffer modified')
  end)

  H.it('failed staging rollback preserves and reports a temp when its source is reoccupied', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })
    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b.txt', 'a.txt' })

    local real_rename, real_noreplace = fs.rename, fs.rename_noreplace
    local staged, occupant_created = 0, false
    local restore_rename = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        staged = staged + 1
        if staged == 2 then return nil, 'EACCES' end
      end
      return real_rename(src, dst)
    end)
    local restore_noreplace = H.stub(fs, 'rename_noreplace', function(src, dst)
      if tostring(src):match('%.direct%-tmp%-%d+$') and dst == ws .. '/a.txt'
        and not occupant_created then
        occupant_created = true
        H.mkfile(ws, 'a.txt', { 'FOREIGN' })
      end
      return real_noreplace(src, dst)
    end)

    H.capture_messages()
    local ok, reason = buf:sync()
    restore_noreplace()
    restore_rename()

    local temp = ws .. '/.direct-tmp-1'
    H.assert_nil(ok, 'the staging failure refuses the sync')
    H.assert_true(reason:find('EACCES', 1, true) ~= nil,
      'staging failure and any preserved recovery detail are returned')
    H.assert_true(occupant_created, 'the original source name was raced back in')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'FOREIGN' },
      'rollback never overwrites the new occupant')
    H.assert_eq(vim.fn.readfile(temp), { 'A' }, 'staged user data is preserved')
    H.assert_notified(temp, 'the stranded temp path is reported')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'B' }, 'the other source is untouched')
    H.assert_eq(history_lines('undo.log'), { HEADER }, 'no action record is written')
  end)

  H.it('staging rollback refuses to move a replacement found at a temp path', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })
    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'b.txt', 'a.txt' })

    local temp, backup = ws .. '/.direct-tmp-1', ws .. '/saved-staged-entry'
    local real_rename = fs.rename
    local injected = false
    local restore = H.stub(fs, 'rename', function(src, dst)
      if tostring(dst):match('%.direct%-tmp%-%d+$') then
        if dst == temp and not injected then
          local staged, stage_err = real_rename(src, dst)
          H.assert_true(staged == true, 'the original entry was staged: ' .. tostring(stage_err))
          H.assert_true(vim.uv.fs_rename(temp, backup) == true,
            'the staged entry is moved to a safe fixture path')
          H.mkfile(ws, vim.fs.basename(temp), { 'FOREIGN TEMP' })
          injected = true
          return true
        elseif dst ~= temp then
          return nil, 'forced late staging failure'
        end
      end
      return real_rename(src, dst)
    end)

    H.capture_messages()
    local ok, reason = buf:sync()
    restore()

    H.assert_nil(ok, 'late staging failure refuses sync')
    H.assert_true(reason:find('ambiguous', 1, true) ~= nil,
      'a replaced staging path is reported as ambiguous')
    H.assert_true(injected, 'a foreign object replaced the staged temp pathname')
    H.assert_eq(vim.fn.readfile(backup), { 'A' }, 'the original staged data survives elsewhere')
    H.assert_eq(vim.fn.readfile(temp), { 'FOREIGN TEMP' }, 'replacement temp is preserved')
    H.assert_nil(vim.uv.fs_stat(ws .. '/a.txt'),
      'rollback did not move the foreign temp into the source slot')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'B' }, 'other source remains intact')
    H.assert_notified('identity is ambiguous')
  end)

  H.it('a control-character path is refused before any change', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    local buf = buffer.list(ws)
    -- Control bytes are invalid JSONL path strings and must be refused early.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'we\tird' })
    H.capture_messages()
    local ok, reason = buf:sync()

    H.assert_false(ok == true, 'nothing was applied')
    H.assert_eq(reason, 'contains a tab')
    H.assert_fs_eq(ws, { 'a.txt' }, 'no filesystem change')
    H.assert_eq(history_lines('undo.log'), {}, 'no history was written')
    H.assert_true(vim.bo.modified, 'the buffer stays modified')
    H.assert_notified('Unsafe entry', vim.log.levels.ERROR)
  end)

  H.it('an unsafe name on the DISK side is refused too', function()
    if H.is_windows() then
      H.skip('Windows filenames cannot contain control characters')
    end
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    -- A file literally named with a tab; the fresh listing therefore carries an
    -- unrepresentable path even though the buffer was not edited.
    H.mkfile(ws, 'a\tb', { 'x' })

    local buf = buffer.list(ws)
    H.capture_messages()
    local ok, reason = buf:sync()

    H.assert_false(ok == true, 'nothing was applied')
    H.assert_eq(reason, 'contains a tab')
    H.assert_notified('Unsafe entry', vim.log.levels.ERROR)
  end)

  H.it('a failing action is reported, the others apply, and only successes are logged/undoable', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })

    local buf = buffer.list(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'a.txt', 'b.txt', 'c.txt' })

    local real_touch = fs.touch
    local restore = H.stub(fs, 'touch', function(path)
      if path == ws .. '/c.txt' then
        return nil, 'boom'
      end
      return real_touch(path)
    end)
    H.capture_messages()
    local ok, reason
    H.with_cwd(ws, function()
      ok, reason = buf:sync()
    end)
    restore()

    H.assert_nil(ok, 'sync reports that an action failed despite re-listing reality')
    H.assert_eq(reason, 'boom', 'the action failure reason is returned')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'b.txt applied, c.txt failed')
    H.assert_buf_eq({ 'a.txt', 'b.txt' }, 0, 'the buffer matches reality after partial failure')
    H.assert_notified('Action failed - Created c.txt', vim.log.levels.ERROR)
    H.assert_notified('1 action(s) failed', vim.log.levels.ERROR)
    H.assert_eq(history_lines('undo.log'),
      { HEADER, fixtures.touch(ws .. '/b.txt') },
      'only the successful action reached history')

    H.assert_true(history.undo() ~= nil, 'the logged success is undoable')
    H.assert_fs_eq(ws, { 'a.txt' }, 'undo reversed the created file')
  end)
end)
