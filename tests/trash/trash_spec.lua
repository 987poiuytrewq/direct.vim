-- tests/trash/trash_spec.lua -- metadata-backed trash management.
local H = require('tests.support.harness')
local action = require('direct.action.action')
local fs = require('direct.fs')
local history = require('direct.history.history')
local log = require('direct.log')
local register = require('direct.register')
local trash = require('direct.trash')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

local function list_dir(path)
  return require('direct').list(path)
end

H.describe('trash management', function()
  H.it('records original path and deletion time, and keeps metadata across undo/redo', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local original = H.mkfile(ws, 'gone.txt', { 'trash bytes' })
    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(require('direct').sync(), 'sync deletes the entry')

    local entries = trash.entries()
    H.assert_eq(#entries, 1, 'the deleted file appears in the trash')
    local entry = entries[1]
    H.assert_eq(entry.original, original, 'metadata remembers the original path')
    H.assert_true(type(entry.deleted_at) == 'string' and #entry.deleted_at > 0,
      'metadata includes a deletion time')
    H.assert_eq(entry.kind, 'file', 'metadata records the entry type')
    H.assert_eq(entry.size, #'trash bytes\n', 'trash listing reports payload size')
    local metadata_path = action.trash_metadata_path(entry.path)
    local metadata_raw = log.read_raw(metadata_path)
    local metadata = vim.json.decode(metadata_raw)
    H.assert_eq(metadata.original, original, 'the sidecar contains the original path')
    H.assert_false(metadata.reserved, 'a newly deleted entry is not a reservation')

    vim.cmd('DirectUndo')
    H.wait_for_direct()
    local after_undo = trash.entries()
    H.assert_eq(#after_undo, 0, 'restored entries are not shown as trashed items')
    H.assert_true(vim.uv.fs_lstat(entry.path) ~= nil,
      'undo keeps an empty reservation at the old trash slot')
    H.assert_true(H.exists(ws, 'gone.txt'), 'undo restores the deleted item')

    vim.cmd('DirectRedo')
    H.wait_for_direct()
    local after_redo = trash.entries()
    H.assert_eq(#after_redo, 1,
      'redo uses a fresh trash slot and hides the old reservation')
    local active
    for _, candidate in ipairs(after_redo) do
      if not candidate.reserved then active = candidate end
    end
    H.assert_true(active ~= nil, 'redo creates an active trash entry')
    H.assert_eq(active.id, entry.id .. '-1', 'redo allocates a sibling slot')
    H.assert_eq(active.original, original, 'the active entry remembers the original path')
    H.assert_false(H.exists(ws, 'gone.txt'), 'redo removes the item again')
  end)

  H.it('shows trash entries in a read-only buffer with the restore ID', function()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local source = H.mkfile(ws, 'shown.txt', '')
    local remove = action.Remove(source)
    H.assert_true(remove['do'](), 'create a trash entry without adding history')
    local entry = trash.entries()[1]

    vim.cmd('DirectTrash')

    H.assert_eq(vim.bo.filetype, 'direct-trash', 'trash view has its own filetype')
    H.assert_false(vim.bo.modifiable, 'trash view is read-only')
    H.assert_true(table.concat(H.buf_lines(), '\n'):find(entry.id, 1, true) ~= nil,
      'the view exposes the ID used by the restore command')
    H.assert_true(table.concat(H.buf_lines(), '\n'):find(source, 1, true) ~= nil,
      'the view displays the original path')
    vim.cmd('DirectTrash restore ' .. entry.id)
    H.assert_eq(vim.uv.fs_stat(source).size, 1,
      'the restore subcommand restores the empty entry')
  end)

  H.it('refuses a history-referenced restore unless forced and never overwrites', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local original = H.mkfile(ws, 'restore.txt', { 'restore me' })
    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(require('direct').sync(), 'sync records the deletion')
    local entry = trash.entries()[1]
    H.capture_messages()

    local blocked = require('direct').trash_restore(entry.id)

    H.assert_nil(blocked, 'the history-referenced item is protected')
    H.assert_true(H.exists(entry.path), 'the protected trash entry remains')
    H.assert_notified('still referenced by undo/redo history', vim.log.levels.ERROR)

    H.mkfile(ws, 'restore.txt', { 'occupant' })
    local clobber = require('direct').trash_restore(entry.id, nil, true)
    H.assert_nil(clobber, 'force bypasses only history protection, not no-clobber')
    H.assert_eq(vim.fn.readfile(original), { 'occupant' }, 'the occupant is untouched')
    H.assert_true(H.exists(entry.path), 'the trash source is retained after a collision')

    vim.uv.fs_unlink(original)
    local prompts = {}
    local restore_cancel = H.stub(vim.fn, 'confirm', function(prompt)
      prompts[#prompts + 1] = prompt
      return 2
    end)
    local cancelled = require('direct').trash_restore(entry.id, nil, true)
    restore_cancel()
    H.assert_nil(cancelled, 'cancel preserves the history and the trash payload')
    H.assert_true(H.exists(entry.path), 'cancel leaves the trash payload in place')
    H.assert_false(H.exists(original), 'cancel leaves the restore destination empty')

    local restore_confirm = H.stub(vim.fn, 'confirm', function(prompt, choices, default)
      prompts[#prompts + 1] = { prompt = prompt, choices = choices, default = default }
      return 1
    end)
    vim.cmd('DirectTrash! restore ' .. entry.id)
    restore_confirm()
    H.assert_eq(#prompts, 2, 'force restore confirms before discarding referenced history')
    H.assert_true(prompts[2].prompt:find('1 undo step and 0 redo steps', 1, true) ~= nil,
      'restore confirmation reports the number of history steps affected')
    H.assert_eq(vim.fn.readfile(original), { 'restore me' }, 'restored bytes are intact')
    H.assert_eq(#trash.entries(), 0, 'restored items are no longer listed as trash')
    H.assert_notified('discarded 1 undo step and 0 redo steps', vim.log.levels.WARN)
    local reservation_bytes = log.read_raw(action.trash_metadata_path(entry.path))
    local reservation = vim.json.decode(reservation_bytes)
    H.assert_true(reservation.reserved, 'the hidden slot remains reserved for history redo')
    vim.cmd('DirectUndo')
    H.wait_for_direct()
    H.assert_false(H.exists(original), 'the newly recorded restore action remains undoable')
  end)

  H.it('empties unreferenced entries but protects history references unless forced', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local orphan_src = H.mkfile(ws, 'orphan.txt', { 'orphan' })
    local orphan = action.Remove(orphan_src)
    H.assert_true(orphan['do'](), 'make an unreferenced trash item')

    H.mkfile(ws, 'logged.txt', { 'logged' })
    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(require('direct').sync(), 'delete a second item through history')
    local entries = trash.entries()
    H.assert_eq(#entries, 2, 'both items are listed')

    vim.cmd('DirectTrash empty')
    local remaining = trash.entries()
    H.assert_eq(#remaining, 1, 'one recoverable item remains')
    H.assert_eq(remaining[1].original, ws .. '/logged.txt', 'the retained item is the logged one')

    local restore_confirm = H.stub(vim.fn, 'confirm', function() return 1 end)
    vim.cmd('DirectTrash! empty')
    restore_confirm()
    H.assert_eq(#trash.entries(), 0, 'the trash is empty after force')
  end)

  H.it('force-empty drops only trash-dependent history before deleting payloads', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'logged.txt', { 'logged' })

    list_dir(ws)
    local lines = H.buf_lines()
    lines[#lines + 1] = 'keep-undo.txt'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    H.assert_true(require('direct').sync(), 'record an undo step below the deletion')

    list_dir(ws)
    local current = H.buf_lines()
    for index, line in ipairs(current) do
      if line == 'logged.txt' then table.remove(current, index); break end
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, current)
    H.assert_true(require('direct').sync(), 'record the trash-backed deletion on top')
    local entries = trash.entries()
    H.assert_eq(#entries, 1, 'one active trashed entry exists')
    H.capture_messages()

    local prompts, answers = {}, { 2, 1 }
    local restore_confirm = H.stub(vim.fn, 'confirm', function(prompt, choices, default)
      prompts[#prompts + 1] = { prompt = prompt, choices = choices, default = default }
      return table.remove(answers, 1)
    end)
    local cancelled, cancel_err = require('direct').trash_empty(true)
    H.assert_nil(cancelled, 'the user can cancel the destructive operation')
    H.assert_true(tostring(cancel_err):find('cancelled', 1, true) ~= nil,
      'cancellation is reported')
    H.assert_eq(#trash.entries(), 1, 'cancelling preserves the trash payload')
    H.assert_true(prompts[1].prompt:find('1 undo step and 0 redo steps', 1, true) ~= nil,
      'the cancellation prompt describes the history loss')
    vim.cmd('DirectTrash! empty')
    restore_confirm()

    H.assert_eq(#prompts, 2, 'force asks before dropping history and emptying trash')
    H.assert_true(prompts[2].prompt:find('1 undo step and 0 redo steps', 1, true) ~= nil,
      'confirmation explains exactly how many undo steps are dropped')
    H.assert_eq(#trash.entries(), 0, 'the confirmed force empties the trash')
    H.assert_notified('discarded 1 undo step and 0 redo steps', vim.log.levels.WARN)

    vim.cmd('DirectUndo')
    H.wait_for_direct()
    H.assert_false(H.exists(ws, 'keep-undo.txt'),
      'the next independent undo remains usable after the trash-backed step is removed')
    H.assert_false(H.exists(ws, 'logged.txt'), 'the emptied trash item stays deleted')
  end)

  H.it('force-empty also drops earlier actions that depend on the removed path', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'b.txt', { 'rename then delete' })

    list_dir(ws)
    vim.api.nvim_buf_set_text(0, 0, 0, 0, #'b.txt', { 'a.txt' })
    H.assert_true(require('direct').sync(), 'rename b.txt to a.txt')
    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    H.assert_true(require('direct').sync(), 'delete a.txt into trash')
    H.assert_eq(#trash.entries(), 1, 'the delete has one trash payload')

    local prompts = {}
    local restore_confirm = H.stub(vim.fn, 'confirm', function(prompt)
      prompts[#prompts + 1] = prompt
      return 1
    end)
    local emptied = require('direct').trash_empty(true)
    restore_confirm()

    H.assert_true(emptied, 'the confirmed force empties the trash')
    H.assert_eq(#prompts, 1, 'the dependent steps are confirmed together')
    H.assert_true(prompts[1]:find('2 undo steps and 0 redo steps', 1, true) ~= nil,
      'the prompt includes the earlier rename that depends on the deleted path')
    local state = require('direct.history.history').preflight()
    H.assert_eq(#state.undo_lines, 1,
      'both the delete and dependent rename records are removed from undo history')
    H.assert_false(H.exists(ws, 'a.txt'), 'the deleted path remains empty')
    H.assert_false(H.exists(ws, 'b.txt'), 'the earlier rename is not left as a broken undo')
  end)

  H.it('force-empty treats descendants of a removed directory as dependent paths', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')

    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'sub/' })
    H.assert_true(require('direct').sync(), 'create the directory')
    local sub = vim.fs.joinpath(ws, 'sub')
    list_dir(sub)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'inside.txt' })
    H.assert_true(require('direct').sync(), 'create a child file')
    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, {})
    H.assert_true(require('direct').sync(), 'move the directory tree into trash')
    H.assert_eq(#trash.entries(), 1, 'the directory tree has one trash entry')

    local prompts = {}
    local restore_confirm = H.stub(vim.fn, 'confirm', function(prompt)
      prompts[#prompts + 1] = prompt
      return 1
    end)
    local emptied = require('direct').trash_empty(true)
    restore_confirm()

    H.assert_true(emptied, 'the directory trash entry is emptied')
    H.assert_true(prompts[1]:find('3 undo steps and 0 redo steps', 1, true) ~= nil,
      'the prompt includes mkdir, child creation, and directory deletion')
    local state = require('direct.history.history').preflight()
    H.assert_eq(#state.undo_lines, 1, 'all path-dependent directory history is removed')
  end)

  H.it('force-empty also drops a paste record when a pasted file is deleted', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local source = H.mkfile(sb.root, 'pasted.txt', { 'payload' })
    H.assert_true(register.yank({ source }), 'yank the paste source')
    local register_path = register.content()
    local paste = action.Paste(register_path, ws, { 'pasted.txt' }, { 'pasted.txt' })
    H.assert_not_nil(paste['do'](), 'paste the file into the workspace')
    H.assert_true(history.log(paste), 'record the paste action')

    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(require('direct').sync(), 'delete the pasted file into trash')
    H.assert_eq(#trash.entries(), 1, 'the deleted paste has one trash payload')

    local prompts = {}
    local restore_confirm = H.stub(vim.fn, 'confirm', function(prompt)
      prompts[#prompts + 1] = prompt
      return 1
    end)
    H.assert_true(trash.empty(true), 'force-empty the pasted file')
    restore_confirm()

    H.assert_true(prompts[1]:find('2 undo steps and 0 redo steps', 1, true) ~= nil,
      'confirmation includes both the delete and the paste')
    local state = history.preflight()
    H.assert_eq(#state.undo_lines, 1, 'the deleted paste and its creator are removed')
    H.capture_messages()
    H.assert_nil(history.undo(), 'no broken paste undo remains')
    H.assert_notified('Nothing to undo')
  end)

  H.it('force-empty sees files deleted from a pasted directory as paste dependencies', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local source_dir = H.mkdir(sb.root, 'pasted-dir')
    H.mkfile(source_dir, 'inside.txt', { 'payload' })
    H.assert_true(register.yank({ source_dir }), 'yank the directory source')
    local register_path = register.content()
    local paste = action.Paste(register_path, ws, { 'pasted-dir' }, { 'pasted-dir' })
    H.assert_not_nil(paste['do'](), 'paste the directory into the workspace')
    H.assert_true(history.log(paste), 'record the pasted directory')

    list_dir(vim.fs.joinpath(ws, 'pasted-dir'))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(require('direct').sync(), 'delete a child from the pasted directory')
    H.assert_eq(#trash.entries(), 1, 'the deleted descendant has one trash payload')

    local prompts = {}
    local restore_confirm = H.stub(vim.fn, 'confirm', function(prompt)
      prompts[#prompts + 1] = prompt
      return 1
    end)
    H.assert_true(trash.empty(true), 'force-empty the deleted descendant')
    restore_confirm()

    H.assert_true(prompts[1]:find('2 undo steps and 0 redo steps', 1, true) ~= nil,
      'the directory paste is linked to its deleted descendant')
    local state = history.preflight()
    H.assert_eq(#state.undo_lines, 1, 'the deleted child and its directory paste are removed')
  end)

  H.it('force-empty removes redo references to reserved trash slots', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local original = H.mkfile(ws, 'logged.txt', { 'logged' })
    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(require('direct').sync(), 'delete the entry into trash')
    vim.cmd('DirectUndo')
    H.wait_for_direct()
    H.assert_true(H.exists(original), 'undo restores the deleted entry')
    H.assert_eq(#trash.entries(), 0, 'undo leaves a hidden reservation in the trash')

    local prompts = {}
    local restore_confirm = H.stub(vim.fn, 'confirm', function(prompt)
      prompts[#prompts + 1] = prompt
      return 1
    end)
    local emptied = require('direct').trash_empty(true)
    restore_confirm()

    H.assert_true(emptied, 'the reservation is emptied')
    H.assert_eq(#prompts, 1, 'force confirms loss of the redo reference')
    H.assert_true(prompts[1]:find('0 undo steps and 1 redo step', 1, true) ~= nil,
      'confirmation reports the redo step that will be dropped')
    vim.cmd('DirectRedo')
    H.wait_for_direct()
    H.assert_true(H.exists(original), 'the stale redo entry cannot remove the restored file')
  end)

  H.it('DirectHistory drop removes only the top undo or redo record', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')

    local function add(name)
      list_dir(ws)
      local lines = {}
      for _, line in ipairs(H.buf_lines()) do
        if line ~= '' then lines[#lines + 1] = line end
      end
      lines[#lines + 1] = name
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      H.assert_true(require('direct').sync(), 'create ' .. name)
    end

    add('a.txt')
    add('b.txt')
    add('c.txt')
    vim.cmd('DirectHistory drop undo')
    H.assert_notified('dropped the top undo step')
    vim.cmd('DirectUndo')
    H.wait_for_direct()
    H.assert_true(H.exists(ws, 'a.txt'), 'the older undo entry remains on the stack')
    H.assert_false(H.exists(ws, 'b.txt'), 'the older undo entry is still applied')
    H.assert_true(H.exists(ws, 'c.txt'), 'dropping the top undo leaves its filesystem result alone')

    vim.cmd('DirectUndo')
    H.wait_for_direct()
    vim.cmd('DirectHistory drop redo')
    H.assert_notified('dropped the top redo step')
    vim.cmd('DirectRedo')
    H.wait_for_direct()
    H.assert_false(H.exists(ws, 'a.txt'), 'dropping the top redo prevents that entry from returning')
    H.assert_true(H.exists(ws, 'b.txt'), 'the older redo entry remains available')
  end)

  H.it('size retention prunes unreferenced entries but keeps history references', function()
    clean_buffers()
    require('direct.config').setup({ trash_retention = { max_size_bytes = 1 } })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    local orphan_src = H.mkfile(ws, 'orphan.txt', { 'large orphan' })
    local orphan = action.Remove(orphan_src)
    H.assert_true(orphan['do'](), 'create an unreferenced trash entry')
    H.assert_true(trash.apply_retention(), 'retention removes the unreferenced payload')
    H.assert_eq(#trash.entries(), 0, 'the oversized orphan is pruned')

    H.mkfile(ws, 'logged.txt', { 'protected payload' })
    list_dir(ws)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
    H.assert_true(require('direct').sync(), 'sync records another deletion')
    local entries = trash.entries()
    H.assert_eq(#entries, 1, 'the history-referenced payload survives retention')
    H.assert_eq(entries[1].original, ws .. '/logged.txt', 'the protected path is identified')
  end)
end)
