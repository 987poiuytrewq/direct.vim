-- Asynchronous paste prompt, history continuation, and pending-operation guard.
local H = require('tests.support.harness')
local action = require('direct.action')
local buffer = require('direct.buffer')
local direct = require('direct')
local fs = require('direct.fs')
local history = require('direct.history')
local log = require('direct.log')
local paths = require('direct.paths')
local pending = require('direct.pending')
local register = require('direct.register')

local function stack_paths(sb)
  local dir = vim.fs.joinpath(sb.data_home, 'direct/history')
  return vim.fs.joinpath(dir, 'undo.log'), vim.fs.joinpath(dir, 'redo.log')
end

local function input_spy()
  local calls = {}
  local restore = H.stub(vim.ui, 'input', function(opts, callback)
    calls[#calls + 1] = { opts = vim.deepcopy(opts), callback = callback }
  end)
  return calls, restore
end

local function answer_next(calls, answer)
  local request = table.remove(calls, 1)
  H.assert_not_nil(request, 'an async input request is pending')
  request.callback(answer)
end

H.describe('async paste prompts', function()
  H.it('a cancelled async clash preserves the target and writes no history or success notice', function()
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'file.txt', { 'REGISTER' })
    H.assert_true(register.yank({ src }) == true, 'yank source')
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'file.txt', { 'KEEP' })
    local undo_path = stack_paths(sb)
    local calls, restore = input_spy()
    H.capture_messages()

    register.paste(dst)

    H.assert_true(pending.is_pending(), 'paste remains pending until input callback')
    H.assert_eq(#calls, 1, 'vim.ui.input was invoked exactly once')
    H.assert_eq(calls[1].opts.prompt, 'File already exists. Paste as: ')
    H.assert_eq(calls[1].opts.default, 'file.txt')
    H.assert_eq(calls[1].opts.completion, 'file')
    H.assert_eq(vim.fn.readfile(dst .. '/file.txt'), { 'KEEP' }, 'target is untouched')
    H.assert_eq(vim.fn.readfile(undo_path), { history.HEADER }, 'no history before callback')

    answer_next(calls, nil)
    restore()

    H.assert_false(pending.is_pending(), 'cancel clears the pending guard')
    H.assert_eq(vim.fn.readfile(dst .. '/file.txt'), { 'KEEP' }, 'cancel preserves target')
    H.assert_eq(vim.fn.readfile(undo_path), { history.HEADER }, 'cancel writes no record')
    H.assert_notified('Skipped file.txt')
    H.assert_false(H.messages():find('Pasted into', 1, true) ~= nil,
      'cancel emits no success notice')
  end)

  H.it('re-prompts asynchronously, skips a cancelled later entry, and records only partial success', function()
    local sb = H.sandbox()
    local a, b = H.mkfile(sb.root, 'a.txt', { 'A' }), H.mkfile(sb.root, 'b.txt', { 'B' })
    H.assert_true(register.yank({ a, b }) == true, 'yank both files')
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'a.txt', { 'KEEP-A' })
    H.mkfile(dst, 'b.txt', { 'KEEP-B' })
    local calls, restore = input_spy()
    register.paste(dst)
    H.assert_eq(#calls, 1, 'first clash prompts')

    answer_next(calls, 'a.txt')
    H.assert_eq(#calls, 1, 'a still-colliding answer triggers a second input callback')
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'KEEP-A' }, 'clash was not overwritten')
    answer_next(calls, 'a-copy.txt')
    H.assert_eq(#calls, 1, 'processing continues to the next source entry')
    answer_next(calls, nil)
    restore()

    H.assert_false(pending.is_pending(), 'partial completion clears guard')
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'KEEP-A' }, 'original clash remains')
    H.assert_eq(vim.fn.readfile(dst .. '/a-copy.txt'), { 'A' }, 'accepted copy remains')
    H.assert_eq(vim.fn.readfile(dst .. '/b.txt'), { 'KEEP-B' }, 'cancelled entry remains')
    local undo_path = stack_paths(sb)
    local lines = vim.fn.readfile(undo_path)
    H.assert_eq(#lines, 2, 'partial success has one history action')
    local record = assert(action.deserialize(lines[2]))
    H.assert_eq(record.name, 'p')
    H.assert_eq(record.renames, { { src = 'a.txt', dst = 'a-copy.txt' } },
      'history contains only the copied pair')
    H.assert_true(history.undo() ~= nil, 'partial paste is undoable')
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'KEEP-A' }, 'undo preserves the old occupant')
    H.assert_false(fs.exists(dst .. '/a-copy.txt'), 'undo removes only the copied entry')
  end)

  H.it('an execution error after one copy retains and records that partial success', function()
    local sb = H.sandbox()
    local a = H.mkfile(sb.root, 'a.txt', { 'A' })
    local b = H.mkfile(sb.root, 'b.txt', { 'B' })
    H.assert_true(register.yank({ a, b }) == true, 'yank both sources')
    local register_copy = register.content()
    local dst = H.mkdir(sb.root, 'dest')
    local original_copy = fs.copy_file_exclusive
    local restore = H.stub(fs, 'copy_file_exclusive', function(from, to)
      if from == vim.fs.joinpath(register_copy, 'b.txt') then
        return nil, 'injected second-copy failure'
      end
      return original_copy(from, to)
    end)
    H.capture_messages()

    local result, err = register.paste(dst)
    restore()

    H.assert_nil(result, 'a later copy error is reported')
    H.assert_eq(err, 'injected second-copy failure', 'copy error propagates')
    H.assert_false(pending.is_pending(), 'partial error clears pending')
    H.assert_eq(vim.fn.readfile(dst .. '/a.txt'), { 'A' }, 'earlier copy is retained')
    H.assert_nil(vim.uv.fs_lstat(dst .. '/b.txt'), 'failed copy was not created')
    local lines = vim.fn.readfile(stack_paths(sb))
    H.assert_eq(#lines, 2, 'partial action is recorded')
    local record = assert(action.deserialize(lines[2]))
    H.assert_eq(record.renames, { { src = 'a.txt', dst = 'a.txt' } },
      'history describes only the copied entry')
    H.assert_notified('completed entries were kept')
  end)

  H.it('the repeated-clash cap is ten callback requests and all-skipped writes no success history', function()
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'f.txt', { 'F' })
    H.assert_true(register.yank({ src }) == true, 'yank source')
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'f.txt', { 'KEEP' })
    local calls, restore = input_spy()
    H.capture_messages()

    register.paste(dst)
    for _ = 1, action.PASTE_CLASH_ATTEMPTS do
      answer_next(calls, 'f.txt')
    end
    restore()

    H.assert_eq(#calls, 0, 'attempt cap does not enqueue another prompt')
    H.assert_false(pending.is_pending(), 'cap exhaustion clears pending guard')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'KEEP' }, 'existing entry survives')
    H.assert_eq(vim.fn.readfile(stack_paths(sb)), { history.HEADER },
      'all-skipped paste writes no action record')
    H.assert_notified('Skipped f.txt')
    H.assert_false(H.messages():find('Pasted into', 1, true) ~= nil,
      'all-skipped paste emits no success notice')
  end)

  H.it('a synchronous vim.ui.input exception clears pending and preserves history', function()
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'f.txt', { 'F' })
    H.assert_true(register.yank({ src }) == true, 'yank source')
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'f.txt', { 'KEEP' })
    local restore = H.stub(vim.ui, 'input', function()
      error('input backend failed')
    end)
    H.capture_messages()

    register.paste(dst)
    restore()

    H.assert_false(pending.is_pending(), 'backend error clears pending')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'KEEP' }, 'target remains')
    H.assert_eq(vim.fn.readfile(stack_paths(sb)), { history.HEADER }, 'no action was logged')
    H.assert_notified('input backend failed')
  end)

  H.it('an exception in the async input callback clears pending and keeps history', function()
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'f.txt', { 'F' })
    H.assert_true(register.yank({ src }) == true, 'yank source')
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'f.txt', { 'KEEP' })
    local calls, restore_input = input_spy()
    local original_taken = fs.taken
    local restore_taken = H.stub(fs, 'taken', function(path)
      if path == dst .. '/fresh.txt' then error('callback filesystem failure') end
      return original_taken(path)
    end)
    H.capture_messages()

    register.paste(dst)
    answer_next(calls, 'fresh.txt')
    restore_taken()
    restore_input()

    H.assert_false(pending.is_pending(), 'input callback failure clears pending')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'KEEP' }, 'original clash remains')
    H.assert_nil(vim.uv.fs_lstat(dst .. '/fresh.txt'), 'copy was not attempted')
    H.assert_eq(vim.fn.readfile(stack_paths(sb)), { history.HEADER },
      'callback failure adds no action record')
    H.assert_notified('callback filesystem failure')
  end)

  H.it('pending input blocks sync, paste, undo, and redo until callback settles', function()
    pcall(vim.cmd, '%bwipeout!')
    local live_direct = require('direct')
    local live_history = require('direct.history')
    local live_pending = require('direct.pending')
    local live_register = require('direct.register')
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'f.txt', { 'F' })
    H.assert_true(live_register.yank({ src }) == true, 'yank source')
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'f.txt', { 'KEEP' })
    local calls, restore = input_spy()
    live_register.paste(dst)
    H.assert_true(live_pending.is_pending(), 'input keeps operation pending')

    H.assert_nil(live_register.paste(dst), 'second paste is refused')
    H.assert_nil(live_history.undo_async(function() end), 'undo is refused')
    H.assert_nil(live_history.redo_async(function() end), 'redo is refused')
    local listing = live_direct.list(dst)
    H.assert_eq(vim.bo.filetype, 'direct', 'listing attached to direct buffer')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local selected_destination, selection_err = listing:paste_destination()
    H.assert_eq(selected_destination, dst, 'selected row resolves to its directory: '
      .. tostring(selection_err))
    H.assert_nil(live_direct.sync(), 'DirectSync is refused while input is pending')
    H.mkfile(dst, 'late.txt', { 'LATE' })
    pcall(vim.cmd, 'write') -- The clean-listing refresh branch is guarded too.
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'f.txt' },
      'clean :write cannot refresh the listing before callback completion')
    vim.bo.modified = true
    pcall(vim.cmd, 'write') -- BufWriteCmd must reach the same pending guard.
    H.assert_true(vim.bo.modified, 'write does not sync or clear the modified listing')
    H.assert_eq(#calls, 1, 'blocked operations never create another prompt')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'KEEP' }, 'blocked operations do not mutate')

    answer_next(calls, nil)
    restore()
    H.assert_false(live_pending.is_pending(), 'completion clears the guard')
  end)

  H.it('DirectPaste and DirectPasteAs use callback input and relist only after completion', function()
    pcall(vim.cmd, '%bwipeout!')
    local live_direct = require('direct')
    local live_pending = require('direct.pending')
    local live_register = require('direct.register')
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'f.txt', { 'REGISTER' })
    H.assert_true(live_register.yank({ src }) == true, 'yank source')
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'f.txt', { 'KEEP' })
    local undo_path = vim.fs.joinpath(sb.data_home, 'direct/history/undo.log')
    local calls, restore = input_spy()
    live_direct.list(dst)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'f.txt' },
      'initial paste listing')
    vim.cmd('DirectPaste')
    H.assert_true(live_pending.is_pending(), ':DirectPaste is pending')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'KEEP' }, 'no synchronous prompt mutation')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'f.txt' },
      'listing is not refreshed before the callback')
    H.assert_eq(vim.fn.readfile(undo_path), { history.HEADER },
      'history is not appended before the callback')
    vim.cmd('DirectPaste ' .. vim.fn.fnameescape(dst))
    vim.cmd('DirectPasteAs blocked.txt')
    vim.cmd('DirectUndo')
    vim.cmd('DirectRedo')
    vim.cmd('DirectSync')
    H.assert_eq(#calls, 1, 'all user commands are refused while input is pending')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'KEEP' },
      'pending-guarded commands leave the clashing path unchanged')
    answer_next(calls, 'copy.txt')
    H.assert_false(live_pending.is_pending(), ':DirectPaste completion settles')
    H.assert_eq(vim.fn.readfile(dst .. '/copy.txt'), { 'REGISTER' }, 'DirectPaste copy lands')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'copy.txt', 'f.txt' },
      'listing refresh follows completion')
    H.assert_eq(#vim.fn.readfile(undo_path), 2, 'history is appended after callback completion')

    H.mkfile(dst, 'named.txt', { 'KEEP-NAMED' })
    local listing = live_direct.list(dst)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    H.assert_eq(listing:paste_destination(), dst, 'listing resolves for paste-as')
    vim.cmd('DirectPasteAs named.txt')
    H.assert_true(live_pending.is_pending(), ':DirectPasteAs is pending')
    answer_next(calls, 'named-copy.txt')
    restore()
    H.assert_false(live_pending.is_pending(), ':DirectPasteAs completion settles')
    H.assert_eq(vim.fn.readfile(dst .. '/named.txt'), { 'KEEP-NAMED' }, 'named clash survives')
    H.assert_eq(vim.fn.readfile(dst .. '/named-copy.txt'), { 'REGISTER' }, 'renamed copy lands')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false),
      { 'copy.txt', 'f.txt', 'named-copy.txt', 'named.txt' },
      'DirectPasteAs relists after its callback')
  end)

  H.it('redo of an Unpaste uses async Paste and records only after callback completion', function()
    pcall(vim.cmd, '%bwipeout!')
    local live_direct = require('direct')
    local live_history = require('direct.history')
    local live_pending = require('direct.pending')
    local live_register = require('direct.register')
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'f.txt', { 'REGISTER' })
    H.assert_true(live_register.yank({ src }) == true, 'yank source')
    local dst = H.mkdir(sb.root, 'dest')
    live_register.paste(dst)
    H.assert_true(live_history.undo_async(function() end) ~= nil,
      'undo paste succeeds synchronously')
    H.assert_nil(vim.uv.fs_lstat(dst .. '/f.txt'), 'undo removed prior pasted target')
    H.mkfile(dst, 'f.txt', { 'FOREIGN' })
    local calls, restore = input_spy()
    live_direct.list(dst)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('DirectRedo')

    H.assert_true(live_pending.is_pending(), 'redo waits for clash input')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'FOREIGN' }, 'foreign occupant is untouched')
    local undo_path, redo_path = stack_paths(sb)
    H.assert_eq(#vim.fn.readfile(redo_path), 2,
      'redo source stays durable while the async action is pending')
    answer_next(calls, 'f-redo.txt')
    restore()

    H.assert_false(live_pending.is_pending(), 'redo completion clears guard')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'FOREIGN' }, 'foreign occupant remains')
    H.assert_eq(vim.fn.readfile(dst .. '/f-redo.txt'), { 'REGISTER' }, 'redo copy lands')
    H.assert_eq(#vim.fn.readfile(undo_path), 2, 'inverse record is appended after callback')
    H.assert_eq(#vim.fn.readfile(redo_path), 1, 'redo stack is empty after success')
  end)

  H.it('undo of an Unpaste prompts asynchronously; redo then removes only that copy', function()
    pcall(vim.cmd, '%bwipeout!')
    local live_action = require('direct.action')
    local live_direct = require('direct')
    local live_history = require('direct.history')
    local live_pending = require('direct.pending')
    local live_register = require('direct.register')
    local sb = H.sandbox()
    local src = H.mkfile(sb.root, 'f.txt', { 'REGISTER' })
    H.assert_true(live_register.yank({ src }) == true, 'yank source')
    local register_copy = live_register.content()
    local dst = H.mkdir(sb.root, 'dest')
    H.mkfile(dst, 'f.txt', { 'FOREIGN' })
    local unpaste = live_action.Unpaste(dst, register_copy, { 'f.txt' }, { 'f.txt' })
    H.assert_true(live_history.log(unpaste) == true, 'fixture an Unpaste record')
    local calls, restore = input_spy()
    live_direct.list(dst)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    vim.cmd('DirectUndo')

    H.assert_true(live_pending.is_pending(), 'undo waits for clash input')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'FOREIGN' }, 'existing occupant is untouched')
    answer_next(calls, 'f-undo.txt')
    H.assert_false(live_pending.is_pending(), 'undo callback clears pending')
    H.assert_eq(vim.fn.readfile(dst .. '/f-undo.txt'), { 'REGISTER' },
      'undo of Unpaste asynchronously restores the register copy')

    vim.cmd('DirectRedo')
    restore()
    H.assert_false(live_pending.is_pending(), 'redo completes synchronously without a clash')
    H.assert_eq(vim.fn.readfile(dst .. '/f.txt'), { 'FOREIGN' }, 'redo preserves foreign occupant')
    H.assert_nil(vim.uv.fs_lstat(dst .. '/f-undo.txt'), 'redo removes only the restored copy')
  end)

  H.it('group actions remain synchronous and never enter the prompt runner', function()
    local sb = H.sandbox()
    local a = H.mkfile(sb.root, 'a.txt', { 'A' })
    local b = H.mkfile(sb.root, 'b.txt', { 'B' })
    local calls, restore = input_spy()
    local completed, result = false, nil

    action.execute_async(action.Group({ action.Move(a, b), action.Move(b, a) }),
      function(ok, value) completed, result = ok, value end)
    restore()

    H.assert_true(completed, 'group executor does not wait for UI')
    H.assert_true(result == true, 'synchronous group succeeds')
    H.assert_eq(#calls, 0, 'group flow does not call vim.ui.input')
    H.assert_eq(vim.fn.readfile(a), { 'B' }, 'group swap completed')
    H.assert_eq(vim.fn.readfile(b), { 'A' }, 'group swap completed')
  end)
end)
