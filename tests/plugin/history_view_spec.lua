-- tests/history_view_spec.lua -- read-only filesystem history view.

local H = require('tests.support.harness')

H.describe(':DirectHistory', function()
  H.it('shows newest-first summaries and paths without changing logs or a dirty listing', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'listed.txt', { 'listed' })
    local history_dir = vim.fs.joinpath(sb.data_home, 'direct/history')
    vim.fn.mkdir(history_dir, 'p')

    local action = require('direct.action.action')
    local history = require('direct.history.history')
    local log = require('direct.log')
    local move = action.Move(
      vim.fs.joinpath(ws, 'from.txt'), vim.fs.joinpath(ws, 'to.txt'))
    local undo_older = action.Touch(vim.fs.joinpath(ws, 'undo-older.txt'))
    local touch = action.Touch(vim.fs.joinpath(ws, 'created.txt'))
    local redo_older = action.Touch(vim.fs.joinpath(ws, 'redo-older.txt'))
    local undo_record = assert(action.serialize(move))
    local undo_older_record = assert(action.serialize(undo_older))
    local redo_record = assert(action.serialize(touch))
    local redo_older_record = assert(action.serialize(redo_older))
    local undo_bytes = history.HEADER .. '\n' .. undo_older_record
      .. '\n' .. undo_record .. '\n'
    local redo_bytes = history.HEADER .. '\n' .. redo_older_record
      .. '\n' .. redo_record .. '\n'
    local undo_path = vim.fs.joinpath(history_dir, 'undo.log')
    local redo_path = vim.fs.joinpath(history_dir, 'redo.log')
    H.assert_true(log.write_raw_atomic(undo_path, undo_bytes), 'write undo fixture')
    H.assert_true(log.write_raw_atomic(redo_path, redo_bytes), 'write redo fixture')

    require('direct').list(ws)
    local source_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(source_buf, -1, -1, false, { 'unsaved row' })
    local source_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
    H.assert_true(vim.bo[source_buf].modified, 'the source listing is dirty')

    vim.cmd('DirectHistory')

    local view_buf = vim.api.nvim_get_current_buf()
    H.assert_true(view_buf ~= source_buf, 'history opens in its own scratch buffer')
    H.assert_eq(vim.bo[view_buf].buftype, 'nofile', 'the view is not a file buffer')
    H.assert_eq(vim.bo[view_buf].filetype, 'direct-history', 'the view has its own filetype')
    H.assert_false(vim.bo[view_buf].modifiable, 'the history view is read-only')
    H.assert_false(vim.bo[view_buf].buflisted, 'the scratch view is unlisted')
    local text = table.concat(vim.api.nvim_buf_get_lines(view_buf, 0, -1, false), '\n')
    H.assert_true(text:find('Undo stack (2)', 1, true) ~= nil, 'the undo stack is shown')
    H.assert_true(text:find('Redo stack (2)', 1, true) ~= nil, 'the redo stack is shown')
    H.assert_true(text:find('Moved', 1, true) ~= nil, 'the action summary is shown')
    H.assert_true(text:find(vim.fs.joinpath(ws, 'from.txt'), 1, true) ~= nil,
      'the move source path is shown')
    H.assert_true(text:find(vim.fs.joinpath(ws, 'to.txt'), 1, true) ~= nil,
      'the move destination path is shown')
    H.assert_true(text:find(vim.fs.joinpath(ws, 'created.txt'), 1, true) ~= nil,
      'the redo action path is shown')
    H.assert_true(text:find(vim.fs.joinpath(ws, 'to.txt'), 1, true)
        < text:find(vim.fs.joinpath(ws, 'undo-older.txt'), 1, true),
      'undo actions are displayed newest first')
    H.assert_true(text:find(vim.fs.joinpath(ws, 'created.txt'), 1, true)
        < text:find(vim.fs.joinpath(ws, 'redo-older.txt'), 1, true),
      'redo actions are displayed newest first')

    H.assert_eq(log.read_raw(undo_path), undo_bytes, 'the undo file is byte-for-byte unchanged')
    H.assert_eq(log.read_raw(redo_path), redo_bytes, 'the redo file is byte-for-byte unchanged')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home,
      'direct/.direct-history.lock')), 'viewing history creates no lock file')
    H.assert_true(vim.api.nvim_buf_is_valid(source_buf), 'the original listing remains loaded')
    H.assert_eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source_lines,
      'the original listing retains its unsaved text')
    H.assert_true(vim.bo[source_buf].modified, 'the original modified flag is preserved')
  end)

  H.it('shows empty stacks without creating a data directory', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct')),
      'the Direct data directory starts absent')

    vim.cmd('DirectHistory')

    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    H.assert_true(text:find('Undo stack (0)', 1, true) ~= nil, 'empty undo is shown')
    H.assert_true(text:find('Redo stack (0)', 1, true) ~= nil, 'empty redo is shown')
    H.assert_true(text:find('(empty)', 1, true) ~= nil, 'empty stacks are identified')
    H.assert_nil(vim.uv.fs_stat(vim.fs.joinpath(sb.data_home, 'direct')),
      'the read-only view creates no history directories')
  end)

  H.it('reports damaged history and leaves its bytes untouched', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local history_dir = vim.fs.joinpath(sb.data_home, 'direct/history')
    vim.fn.mkdir(history_dir, 'p')
    local undo_path = vim.fs.joinpath(history_dir, 'undo.log')
    local bytes = '{"format":"direct-history","version":1}\nnot-json\n'
    H.assert_true(require('direct.log').write_raw_atomic(undo_path, bytes),
      'write damaged history fixture')

    vim.cmd('DirectHistory')

    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    H.assert_true(text:find('History is preserved', 1, true) ~= nil,
      'damaged history is called out')
    H.assert_eq(require('direct.log').read_raw(undo_path), bytes,
      'the damaged log remains byte-for-byte unchanged')
  end)
end)
