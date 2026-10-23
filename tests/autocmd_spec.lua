-- tests/autocmd_spec.lua -- ownership and re-source behavior for autocmds.

local H = require('tests.support.harness')
local buffer = require('direct.buffer')

local function count_autocmds(event, bufnr)
  return #vim.api.nvim_get_autocmds({ event = event, buffer = bufnr })
end

local function count_global(event)
  return #vim.api.nvim_get_autocmds({ group = 'direct', event = event })
end

local function count_buffer_groups()
  local count = 0
  for _, name in ipairs(vim.fn.getcompletion('', 'augroup')) do
    if name:match('^direct%-buffer') then
      count = count + 1
    end
  end
  return count
end

H.describe('autocmd ownership', function()
  H.it('keeps each direct write handler across re-source and isolates buffer wipes', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local first_dir = H.mkdir(sb.root, 'first')
    local second_dir = H.mkdir(sb.root, 'second')
    H.mkfile(first_dir, 'first-existing', 'first')
    H.mkfile(second_dir, 'second-existing', 'second')

    for _ = 1, 6 do
      buffer.list(first_dir)
      vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })
    end
    H.assert_eq(count_buffer_groups(), 1,
      'listing and wiping buffers keeps one shared direct buffer augroup')

    buffer.list(first_dir)
    local first_buf = vim.api.nvim_get_current_buf()
    buffer.list(second_dir)
    local second_buf = vim.api.nvim_get_current_buf()

    H.assert_eq(count_autocmds('BufWriteCmd', first_buf), 1,
      'first direct buffer starts with one write handler')
    H.assert_eq(count_autocmds('BufWriteCmd', second_buf), 1,
      'second direct buffer starts with one write handler')
    H.assert_eq(count_global('BufEnter'), 1, 'one global BufEnter handler before source')
    H.assert_eq(count_global('VimEnter'), 1, 'one global VimEnter handler before source')

    buffer.list(first_dir)
    H.assert_eq(count_autocmds('BufWriteCmd', first_buf), 1,
      'relisting the first buffer does not duplicate its handler')

    vim.cmd('runtime! plugin/direct.lua')
    vim.cmd('runtime! plugin/direct.lua')

    H.assert_eq(count_autocmds('BufWriteCmd', first_buf), 1,
      'first write handler survives repeated plugin source')
    H.assert_eq(count_autocmds('BufWriteCmd', second_buf), 1,
      'second write handler survives repeated plugin source')
    H.assert_eq(count_global('BufEnter'), 1, 'BufEnter remains idempotent')
    H.assert_eq(count_global('VimEnter'), 1, 'VimEnter remains idempotent')

    vim.api.nvim_buf_set_lines(first_buf, 0, -1, false,
      { 'first-existing', 'first-created' })
    vim.api.nvim_set_current_buf(first_buf)
    local first_ok, first_err = pcall(vim.cmd, 'write')
    H.assert_true(first_ok, 'first buffer writes without error: ' .. tostring(first_err))
    H.assert_fs_eq(first_dir, { 'first-created', 'first-existing' },
      'first write syncs only the first directory')
    H.assert_fs_eq(second_dir, { 'second-existing' },
      'first write leaves the second directory unchanged')

    vim.api.nvim_buf_set_lines(second_buf, 0, -1, false,
      { 'second-existing', 'second-created' })
    vim.api.nvim_set_current_buf(second_buf)
    local second_ok, second_err = pcall(vim.cmd, 'write')
    H.assert_true(second_ok, 'second buffer writes without error: ' .. tostring(second_err))
    H.assert_fs_eq(second_dir, { 'second-created', 'second-existing' },
      'second write syncs only the second directory')

    vim.api.nvim_buf_delete(first_buf, { force = true })
    local remaining_first_handler = false
    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = 'BufWriteCmd' })) do
      if au.buffer == first_buf then remaining_first_handler = true end
    end
    H.assert_false(remaining_first_handler, 'wiping first buffer removes its handler')
    H.assert_eq(count_autocmds('BufWriteCmd', second_buf), 1,
      'wiping first buffer leaves second handler intact')

    vim.api.nvim_buf_set_lines(second_buf, 0, -1, false,
      { 'second-existing', 'second-created', 'second-created-again' })
    vim.api.nvim_set_current_buf(second_buf)
    local remaining_ok, remaining_err = pcall(vim.cmd, 'write')
    H.assert_true(remaining_ok,
      'second buffer remains writable after first wipe: ' .. tostring(remaining_err))
    H.assert_fs_eq(second_dir, { 'second-created', 'second-created-again', 'second-existing' },
      'second buffer still syncs its own directory after first wipe')

    vim.api.nvim_buf_set_lines(second_buf, 0, -1, false,
      { 'second-created', 'second-ambiguous' })
    vim.api.nvim_set_current_buf(second_buf)
    local failed_ok, failed_err = pcall(vim.cmd, 'write')
    H.assert_false(failed_ok, 'an ambiguous sync is refused')
    H.assert_true(tostring(failed_err):find('Ambiguous buffer content', 1, true) ~= nil,
      'the failure is the expected sync refusal: ' .. tostring(failed_err))
    H.assert_false(tostring(failed_err):find('E676', 1, true) ~= nil,
      'the buffer still has its BufWriteCmd handler')
    H.assert_fs_eq(second_dir, { 'second-created', 'second-created-again', 'second-existing' },
      'a refused sync leaves the filesystem unchanged')
    H.assert_notified('Ambiguous buffer content', 'ERROR')

    vim.api.nvim_buf_set_lines(second_buf, 0, -1, false,
      { 'second-existing', 'second-created', 'second-created-again', 'second-after-failure' })
    vim.api.nvim_set_current_buf(second_buf)
    local recovered_ok, recovered_err = pcall(vim.cmd, 'write')
    H.assert_true(recovered_ok,
      'second buffer writes after a refused sync: ' .. tostring(recovered_err))
    H.assert_fs_eq(second_dir,
      { 'second-after-failure', 'second-created', 'second-created-again', 'second-existing' },
      'second buffer remains usable after a refused sync')
  end)
end)
