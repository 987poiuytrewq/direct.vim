-- tests/trash/trash_spec.lua -- metadata-backed trash management.
local H = require('tests.support.harness')
local action = require('direct.action.action')
local fs = require('direct.fs')
local log = require('direct.log')
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
    vim.cmd('DirectTrash! restore ' .. entry.id)
    H.assert_eq(vim.fn.readfile(original), { 'restore me' }, 'restored bytes are intact')
    H.assert_eq(#trash.entries(), 0, 'restored items are no longer listed as trash')
    local reservation_bytes = log.read_raw(action.trash_metadata_path(entry.path))
    local reservation = vim.json.decode(reservation_bytes)
    H.assert_true(reservation.reserved, 'the hidden slot remains reserved for history redo')
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

    vim.cmd('DirectTrash! empty')
    H.assert_eq(#trash.entries(), 0, 'the trash is empty after force')
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
