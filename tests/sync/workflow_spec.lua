-- tests/workflow_spec.lua -- public command workflows across disk and view.
-- These tests pair filesystem assertions with the listing Neovim actually shows.

local H = require('tests.support.harness')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

local function list_dir(path)
  vim.cmd('DirectList ' .. vim.fn.fnameescape(path))
end

local function history_lines(name)
  local path = vim.fs.joinpath(vim.env.XDG_DATA_HOME, 'direct', 'history', name)
  if vim.fn.filereadable(path) ~= 1 then return {} end
  return vim.fn.readfile(path)
end

local function history_state()
  return {
    undo = history_lines('undo.log'),
    redo = history_lines('redo.log'),
  }
end

local function set_listing(lines, bufnr)
  H.set_direct_rows(bufnr or 0, lines)
end

H.describe('command workflows: filesystem and listing stay in sync', function()
  H.it('u and <C-r> undo and redo a saved filesystem rename', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'before.txt', { 'preserve these bytes' })

    list_dir(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    H.assert_buf_eq({ 'before.txt' }, bufnr)

    set_listing({ 'after.txt' }, bufnr)
    local write_ok, write_err = pcall(vim.cmd, 'write')
    H.assert_true(write_ok, 'rename writes through :write: ' .. tostring(write_err))
    H.wait_for_direct()
    H.assert_fs_eq(ws, { 'after.txt' }, 'the rename is on disk')
    H.assert_eq(vim.fn.readfile(ws .. '/after.txt'), { 'preserve these bytes' },
      'rename preserves file contents')
    H.assert_buf_eq({ 'after.txt' }, bufnr, 'the listing reflects the committed rename')
    H.assert_false(vim.bo[bufnr].modified, 'successful write clears modified state')

    vim.api.nvim_feedkeys('u', 'mx', false)
    H.wait_for_direct()
    H.assert_fs_eq(ws, { 'before.txt' }, 'filesystem undo restores the original path')
    H.assert_eq(vim.fn.readfile(ws .. '/before.txt'), { 'preserve these bytes' },
      'undo preserves the original contents')
    H.assert_buf_eq({ 'before.txt' }, bufnr, 'u refreshes the listing')
    H.assert_false(vim.bo[bufnr].modified, 'undo leaves the listing clean')

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-r>', true, false, true),
      'mx', false)
    H.wait_for_direct()
    H.assert_fs_eq(ws, { 'after.txt' }, 'filesystem redo reapplies the rename')
    H.assert_eq(vim.fn.readfile(ws .. '/after.txt'), { 'preserve these bytes' },
      'redo preserves the file contents')
    H.assert_buf_eq({ 'after.txt' }, bufnr, '<C-r> refreshes the listing')
    H.assert_false(vim.bo[bufnr].modified, 'redo leaves the listing clean')
  end)

  H.it('pastes a directory through commands and undo/redo updates the destination view', function()
    clean_buffers()
    local sb = H.sandbox()
    local source = H.mkdir(sb.root, 'source')
    local destination = H.mkdir(sb.root, 'destination')
    H.mkdir(source, 'tree')
    H.mkfile(source, 'tree/inside.txt', { 'nested contents' })

    list_dir(source)
    H.assert_buf_eq({ 'tree/' }, 0, 'the source listing displays the directory')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('DirectYank')
    H.assert_buf_eq({ 'tree/' }, 0, 'yanking keeps the source listing visible')

    list_dir(destination)
    vim.cmd('DirectPaste')
    H.wait_for_direct()
    H.assert_fs_eq(destination, { 'tree/', 'tree/inside.txt' },
      'paste copies the full directory tree')
    H.assert_eq(vim.fn.readfile(destination .. '/tree/inside.txt'), { 'nested contents' },
      'the pasted child content is intact')
    H.assert_buf_eq({ 'tree/', '  inside.txt' }, 0,
      'paste refreshes the destination listing and unfolds the pasted directory')
    H.assert_fs_eq(source, { 'tree/', 'tree/inside.txt' }, 'paste leaves the source intact')

    vim.cmd('DirectUndo')
    H.wait_for_direct()
    H.assert_fs_eq(destination, {}, 'undo removes the pasted tree')
    H.assert_buf_eq({ '' }, 0, 'undo refreshes an empty destination listing')
    H.assert_fs_eq(source, { 'tree/', 'tree/inside.txt' }, 'undo leaves the source intact')

    vim.cmd('DirectRedo')
    H.wait_for_direct()
    H.assert_fs_eq(destination, { 'tree/', 'tree/inside.txt' }, 'redo restores the pasted tree')
    H.assert_buf_eq({ 'tree/' }, 0, 'redo refreshes the destination listing')
  end)

  H.it('keeps a duplicate edit visible and unchanged on disk, then syncs a correction', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'A' })
    H.mkfile(ws, 'b.txt', { 'B' })

    list_dir(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    local before_history = history_state()
    set_listing({ 'a.txt', 'a.txt' }, bufnr)
    H.capture_messages()

    local write_ok, write_err = pcall(vim.cmd, 'write')

    H.assert_false(write_ok, 'the ambiguous edit is refused by :write')
    H.assert_true(tostring(write_err):find('Ambiguous buffer content (duplicate)', 1, true) ~= nil,
      'the write reports the duplicate-row reason: ' .. tostring(write_err))
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'the refused edit changes no files')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'A' }, 'a.txt remains unchanged')
    H.assert_eq(vim.fn.readfile(ws .. '/b.txt'), { 'B' }, 'b.txt remains unchanged')
    H.assert_buf_eq({ 'a.txt', 'a.txt' }, bufnr, 'the unsynced edit remains visible')
    H.assert_true(vim.bo[bufnr].modified, 'the refused edit remains modified')
    H.assert_eq(history_state(), before_history, 'the refusal writes no history')
    H.assert_notified('Ambiguous buffer content (duplicate)')

    set_listing({ 'a.txt', 'renamed-b.txt' }, bufnr)
    local retry_ok, retry_err = pcall(vim.cmd, 'write')

    H.assert_true(retry_ok, 'a corrected edit can be written: ' .. tostring(retry_err))
    H.wait_for_direct()
    H.assert_fs_eq(ws, { 'a.txt', 'renamed-b.txt' }, 'the corrected rename reaches disk')
    H.assert_eq(vim.fn.readfile(ws .. '/a.txt'), { 'A' }, 'the untouched file is preserved')
    H.assert_eq(vim.fn.readfile(ws .. '/renamed-b.txt'), { 'B' },
      'the corrected rename preserves the renamed file')
    H.assert_buf_eq({ 'a.txt', 'renamed-b.txt' }, bufnr,
      'the refreshed listing matches the filesystem')
    H.assert_false(vim.bo[bufnr].modified, 'the corrected write clears modified state')
  end)

  H.it('refuses a rename onto a filtered destination, then accepts a correction', function()
    clean_buffers()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'source.txt', { 'SOURCE' })
    H.mkfile(ws, 'occupied.log', { 'FOREIGN' })

    H.with_option('wildignore', '*.log', function()
      list_dir(ws)
      local bufnr = vim.api.nvim_get_current_buf()
      H.assert_buf_eq({ 'source.txt' }, bufnr,
        'the destination exists on disk but is hidden from the listing')

      local before_history = history_state()
      set_listing({ 'occupied.log' }, bufnr)
      H.capture_messages()
      local sync_ok, sync_err = pcall(vim.cmd, 'DirectSync')

      H.assert_false(sync_ok, 'the conflicting rename is refused')
      H.assert_true(tostring(sync_err):find('destination already exists', 1, true) ~= nil,
        'the refusal explains the occupied destination: ' .. tostring(sync_err))
      H.assert_notified('destination already exists')
      H.assert_fs_eq(ws, { 'occupied.log', 'source.txt' }, 'the conflict changes no files')
      H.assert_eq(vim.fn.readfile(ws .. '/source.txt'), { 'SOURCE' },
        'the source remains intact')
      H.assert_eq(vim.fn.readfile(ws .. '/occupied.log'), { 'FOREIGN' },
        'the concurrent occupant remains intact')
      H.assert_buf_eq({ 'occupied.log' }, bufnr, 'the user edit remains visible for correction')
      H.assert_true(vim.bo[bufnr].modified, 'the refused rename remains modified')
      H.assert_eq(history_state(), before_history, 'the refusal writes no history')

      set_listing({ 'renamed.txt' }, bufnr)
      local retry_ok, retry_err = pcall(vim.cmd, 'DirectSync')
      H.assert_true(retry_ok, 'the corrected rename succeeds: ' .. tostring(retry_err))
      H.wait_for_direct()

      H.assert_fs_eq(ws, { 'occupied.log', 'renamed.txt' }, 'the corrected name is on disk')
      H.assert_eq(vim.fn.readfile(ws .. '/renamed.txt'), { 'SOURCE' },
        'the corrected rename preserves source contents')
      H.assert_eq(vim.fn.readfile(ws .. '/occupied.log'), { 'FOREIGN' },
        'the conflicting file is never overwritten')
      H.assert_buf_eq({ 'renamed.txt' }, bufnr,
        'the refreshed filtered view matches the resulting filesystem')
      H.assert_false(vim.bo[bufnr].modified, 'the successful correction clears modified state')
    end)
  end)
end)
