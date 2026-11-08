-- tests/history/undo_safety_spec.lua -- safe public undo/redo in listings.
local H = require('tests.support.harness')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

local function rename_in_listing(root, old_name, new_name)
  require('direct').list(root)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { new_name })
  H.assert_true(require('direct').sync(), 'the rename is committed')
  H.assert_true(H.exists(root, new_name), 'the renamed entry exists on disk')
  H.assert_false(H.exists(root, old_name), 'the old name is gone on disk')
end

H.describe('undo and redo safety in listings', function()
  H.it('DirectUndo uses text undo for a modified listing and leaves disk history alone', function()
    clean_buffers()
    require('direct.config').setup({ undo_confirm = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'before.txt', { 'keep' })
    rename_in_listing(ws, 'before.txt', 'after.txt')
    local bufnr = vim.api.nvim_get_current_buf()
    local undo_log = vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log'))

    vim.cmd('normal! dd')
    H.assert_true(vim.bo[bufnr].modified, 'deleting the row modifies the listing')
    vim.cmd('DirectUndo')

    H.assert_buf_eq({ 'after.txt' }, bufnr, 'DirectUndo restores the deleted row')
    H.assert_false(vim.bo[bufnr].modified, 'text undo returns to the saved listing')
    H.assert_true(H.exists(ws, 'after.txt'), 'the filesystem rename is not undone')
    H.assert_false(H.exists(ws, 'before.txt'), 'the original filesystem path stays absent')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), undo_log, 'filesystem history is unchanged')

    vim.cmd('DirectRedo')
    H.assert_buf_eq({ '' }, bufnr, 'the paired redo stays in the local text undo tree')
    H.assert_true(H.exists(ws, 'after.txt'), 'text redo does not change the filesystem')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), undo_log, 'text redo leaves filesystem history unchanged')
  end)

  H.it('DirectRedo uses text redo while the listing is marked modified', function()
    clean_buffers()
    require('direct.config').setup({ undo_confirm = false })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', '')
    H.mkfile(ws, 'b.txt', '')
    require('direct').list(ws)

    vim.cmd('normal! ggdd')
    vim.cmd('undo')
    H.assert_buf_eq({ 'a.txt', 'b.txt' }, 0, 'the text delete is locally undone')
    -- Model an independent pending edit while retaining the text redo branch.
    vim.bo.modified = true

    vim.cmd('DirectRedo')

    H.assert_buf_eq({ 'b.txt' }, 0, 'DirectRedo reapplies the text delete')
    H.assert_true(vim.bo.modified, 'the listing remains marked modified')
    H.assert_fs_eq(ws, { 'a.txt', 'b.txt' }, 'text redo does not change disk entries')
  end)

  H.it('asks before undoing a change outside the current listing and honors decline', function()
    clean_buffers()
    require('direct.config').setup({ undo_confirm = 'elsewhere' })
    local sb = H.sandbox()
    local changed = H.mkdir(sb.root, 'changed')
    local elsewhere = H.mkdir(sb.root, 'elsewhere')
    H.mkfile(changed, 'before.txt', { 'keep' })
    rename_in_listing(changed, 'before.txt', 'after.txt')
    local undo_log = vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log'))
    require('direct').list(elsewhere)
    local bufnr = vim.api.nvim_get_current_buf()
    local prompt, buttons, default
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function(message, choices, choice)
      prompt, buttons, default = message, choices, choice
      return 2
    end
    H.capture_messages()
    local ok, err = pcall(vim.cmd, 'DirectUndo')
    vim.fn.confirm = original_confirm

    H.assert_true(ok, 'declining confirmation is handled normally: ' .. tostring(err))
    H.assert_true(type(prompt) == 'string' and prompt:find('after.txt', 1, true) ~= nil,
      'the prompt describes the filesystem change and affected paths')
    H.assert_true(prompt:find('before.txt', 1, true) ~= nil,
      'the prompt names the other affected path')
    H.assert_true(buttons:find('Undo', 1, true) ~= nil
      and buttons:find('Cancel', 1, true) ~= nil, 'the prompt has undo and cancel choices')
    H.assert_eq(default, 2, 'cancel is the safe default')
    H.assert_true(H.exists(changed, 'after.txt'), 'declining leaves disk unchanged')
    H.assert_false(H.exists(changed, 'before.txt'), 'declining does not restore the old path')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log')), undo_log, 'declining leaves history unchanged')
    H.assert_eq(vim.api.nvim_get_current_buf(), bufnr, 'the current listing is unchanged')

    vim.fn.confirm = function() return 1 end
    local accepted, accept_err = pcall(vim.cmd, 'DirectUndo')
    vim.fn.confirm = original_confirm
    H.assert_true(accepted, 'accepting confirmation runs the undo: ' .. tostring(accept_err))
    H.assert_true(H.exists(changed, 'before.txt'), 'accepting restores the original path')
    H.assert_false(H.exists(changed, 'after.txt'), 'accepting reverses the rename')
  end)

  H.it('does not confirm an undo within the current listing and keeps the path summary', function()
    clean_buffers()
    require('direct.config').setup({ undo_confirm = 'elsewhere' })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'before.txt', { 'keep' })
    rename_in_listing(ws, 'before.txt', 'after.txt')
    local calls = 0
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function() calls = calls + 1; return 1 end
    H.capture_messages()

    local ok, err = pcall(vim.cmd, 'DirectUndo')

    vim.fn.confirm = original_confirm
    H.assert_true(ok, 'same-directory undo succeeds: ' .. tostring(err))
    H.assert_eq(calls, 0, 'the default only confirms changes outside this directory')
    H.assert_true(H.exists(ws, 'before.txt'), 'same-directory undo restores the original')
    H.assert_false(H.exists(ws, 'after.txt'), 'same-directory undo reverses the rename')
    H.assert_buf_eq({ 'before.txt' }, 0, 'the listing refreshes after undo')
    H.assert_notified('before.txt', vim.log.levels.INFO)
    H.assert_notified('after.txt', vim.log.levels.INFO)
  end)

  H.it('undo_confirm=true prompts even for a change in the current listing', function()
    clean_buffers()
    require('direct.config').setup({ undo_confirm = true })
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'before.txt', '')
    rename_in_listing(ws, 'before.txt', 'after.txt')
    local calls = 0
    local original_confirm = vim.fn.confirm
    vim.fn.confirm = function() calls = calls + 1; return 2 end
    local ok, err = pcall(vim.cmd, 'DirectUndo')
    vim.fn.confirm = original_confirm

    H.assert_true(ok, 'declined same-directory undo is handled normally: ' .. tostring(err))
    H.assert_eq(calls, 1, 'always-confirm mode shows the prompt')
    H.assert_true(H.exists(ws, 'after.txt'), 'declining leaves the path unchanged')
    H.assert_false(H.exists(ws, 'before.txt'), 'declining does not reverse the change')
  end)
end)
