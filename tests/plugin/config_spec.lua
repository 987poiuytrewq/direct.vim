-- tests/config_spec.lua -- configuration and mapping lifecycle.

local H = require('tests.support.harness')

-- Open direct buffers let these tests verify mapping removal and restoration.
local buffer = require('direct.buffer')

-- A fresh module table: config is stateful (lifecycle flags), and the harness
-- only unloads direct modules at file boundaries, so the spec reloads it where
-- state matters.
local function fresh_config()
  package.loaded['direct.config'] = nil
  return require('direct.config')
end

local function global_dash_count()
  local n = 0
  for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
    if map.lhs == '-' then
      n = n + 1
    end
  end
  return n
end

H.describe('config', function()
  H.it('two setup() calls converge on the same options', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local first = vim.deepcopy(config.options)
    config.setup({ map_default_keys = true })
    H.assert_eq(config.options, first, 'later setup() replaces and converges')
    H.assert_eq(config.options, config.defaults, 'options equal the defaults')
    H.assert_true(vim.fn.maparg('-', 'n') ~= '', 'global - installed')
    config.clear_mappings()
  end)

  H.it('file and folder icon options default off and reject typos', function()
    local config = fresh_config()
    config.clear_mappings()
    H.assert_false(config.defaults.show_folder_icons == true,
      'folder icons are off by default')
    H.assert_false(config.defaults.show_file_icons == true,
      'file icons are off by default')
    local options = config.setup({ show_folder_icons = true, show_file_icons = true })
    H.assert_true(options.show_folder_icons, 'the documented icon option is accepted')
    H.assert_true(options.show_file_icons, 'the documented file icon option is accepted')
    H.capture_messages()
    options = config.setup({
      show_folder_icons = true,
      show_file_icons = true,
      show_folder_icon = true,
    })
    H.assert_true(options.show_folder_icons, 'known option remains applied')
    H.assert_true(options.show_file_icons, 'known file option remains applied')
    H.assert_nil(options.show_folder_icon, 'misspelled option is not stored')
    H.assert_notified('show_folder_icon', vim.log.levels.ERROR)
    config.clear_mappings()
  end)

  H.it('recursive expansion depth defaults to unlimited and accepts only positive integers', function()
    local config = fresh_config()
    config.clear_mappings()
    H.assert_false(config.defaults.max_recursive_expand_depth,
      'recursive expansion is unlimited by default')

    local options = config.setup({ max_recursive_expand_depth = 3 })
    H.assert_eq(options.max_recursive_expand_depth, 3,
      'a positive integer depth limit is accepted')

    H.capture_messages()
    options = config.setup({ max_recursive_expand_depth = 0 })
    H.assert_false(options.max_recursive_expand_depth,
      'invalid depth limits leave the unlimited default in place')
    H.assert_notified('max_recursive_expand_depth', vim.log.levels.ERROR)
    config.clear_mappings()
  end)

  H.it('setup() rejects an unknown key with an ERROR notification', function()
    local config = fresh_config()
    config.clear_mappings()
    H.capture_messages()
    config.setup({ map_default_keys = true, nope = 1 })
    H.assert_notified('nope', vim.log.levels.ERROR)
    H.assert_true(config.options.map_default_keys, 'known key still applied')
    H.assert_nil(config.options.nope, 'unknown key is not stored')
    config.clear_mappings()
  end)

  H.it('install_mappings() is idempotent', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    config.install_mappings()
    config.install_mappings()
    H.assert_eq(global_dash_count(), 1, 'exactly one global - mapping')
    config.clear_mappings()
  end)

  H.it('the VimEnter install runs exactly once and setup() suppresses it', function()
    local config = fresh_config()
    config.clear_mappings()
    -- No setup() call: the deferred install applies the default once.
    H.assert_true(config.install_deferred() == true, 'first VimEnter installs')
    H.assert_true(vim.fn.maparg('-', 'n') ~= '', 'mapping present after install')
    H.assert_false(config.install_deferred() == true, 'second VimEnter is a no-op')
    H.assert_true(vim.fn.maparg('-', 'n') ~= '', 'mapping still present')

    config.clear_mappings()
    -- Once setup() has run, VimEnter never installs.
    local after = fresh_config()
    after.clear_mappings()
    after.setup({ map_default_keys = false })
    H.assert_false(after.install_deferred() == true, 'setup() suppresses the deferred install')
    H.assert_eq(vim.fn.maparg('-', 'n'), '', 'no global mapping under map_default_keys=false')
  end)

  -- Clearing must preserve a user-owned global `-` when the plugin did not
  -- install it, even when setup disables the default mappings.
  H.it('setup({ map_default_keys = false }) spares a user-owned global - mapping', function()
    local config = fresh_config()
    config.clear_mappings() -- remove whatever the plugin installed at the file boundary
    vim.keymap.set('n', '-', ':echo "user"<CR>', {})
    -- Reload so _installed reconciles against the CURRENT keymap: a dash that
    -- is not the plugin's rhs is not ours to remove.
    package.loaded['direct.config'] = nil
    config = require('direct.config')
    H.assert_false(config._installed, 'premise: the plugin owns nothing here')
    config.setup({ map_default_keys = false })
    H.assert_eq(vim.fn.maparg('-', 'n'), ':echo "user"<CR>',
      'the user mapping survives setup(map_default_keys=false)')
    vim.keymap.del('n', '-')
  end)

  H.it('setup({ map_default_keys = false }) still removes the mapping the plugin installed', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    H.assert_true(vim.fn.maparg('-', 'n') ~= '', 'premise: the plugin mapping is installed')
    config.setup({ map_default_keys = false })
    H.assert_eq(vim.fn.maparg('-', 'n'), '', 'the plugin mapping is removed')
  end)

  H.it('clear_mappings with nothing installed is a harmless no-op', function()
    local config = fresh_config()
    config.clear_mappings()
    vim.keymap.set('n', '-', ':echo "user"<CR>', {})
    package.loaded['direct.config'] = nil
    config = require('direct.config')
    H.assert_false(config._installed, 'premise: nothing was installed')
    H.assert_true(config.clear_mappings() == true, 'returns true and does not raise')
    H.assert_eq(vim.fn.maparg('-', 'n'), ':echo "user"<CR>', 'the user dash is untouched')
    vim.keymap.del('n', '-')
  end)

  -- The ftplugin installs buffer-local maps; setup must also clear them from
  -- direct buffers that were already open when the option changed.
  local function open_direct_buffer()
    local sb = H.sandbox()
    local ws = H.mkdir(sb.root, 'ws')
    H.mkfile(ws, 'a.txt', { 'a' })
    buffer.list(ws)
    local bufnr = vim.api.nvim_get_current_buf()
    H.assert_eq(vim.bo[bufnr].filetype, 'direct', 'premise: opened a direct buffer')
    return bufnr
  end

  local function buf_map_rhs(lhs, mode)
    return vim.fn.maparg(lhs, mode, false, true).rhs
  end

  H.it('setup({ map_default_keys = false }) clears buffer-local maps in already-open direct buffers', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local bufnr = open_direct_buffer()
    H.assert_true(buf_map_rhs('u', 'n') ~= nil, 'premise: buffer-local u installed')
    H.assert_true(buf_map_rhs('p', 'n') ~= nil, 'premise: buffer-local p installed')

    config.setup({ map_default_keys = false })

    H.assert_nil(buf_map_rhs('u', 'n'), 'the buffer-local u mapping is gone')
    H.assert_nil(buf_map_rhs('p', 'n'), 'the buffer-local p mapping is gone')
    H.assert_nil(buf_map_rhs('y', 'v'), 'the buffer-local visual y mapping is gone')
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  H.it('clearing does not disturb other buffers and their buffer-local maps', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local direct_buf = open_direct_buffer()

    -- A non-direct buffer with its OWN buffer-local u mapping.
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    vim.keymap.set('n', 'u', ':echo "other user map"<CR>',
      { buffer = true, silent = true, noremap = true })

    config.setup({ map_default_keys = false })

    -- Read the direct buffer's own scope first, then the other buffer's.
    vim.api.nvim_set_current_buf(direct_buf)
    H.assert_nil(buf_map_rhs('u', 'n'), 'the direct buffer was cleared')
    vim.api.nvim_set_current_buf(other)
    H.assert_eq(buf_map_rhs('u', 'n'), ':echo "other user map"<CR>',
      'the other buffer-local mapping is untouched')
    H.assert_eq(vim.fn.maparg('-', 'n'), '',
      'the plugin global mapping was removed, no user global dash was created')
    pcall(vim.api.nvim_buf_delete, direct_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, other, { force = true })
  end)

  H.it('re-enabling map_default_keys restores the maps in already-open direct buffers', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local bufnr = open_direct_buffer()

    config.setup({ map_default_keys = false })
    H.assert_nil(buf_map_rhs('u', 'n'), 'cleared first')

    config.setup({ map_default_keys = true })
    H.assert_true(buf_map_rhs('u', 'n') ~= nil,
      'the buffer-local u mapping is restored in the open direct buffer')
    H.assert_true(buf_map_rhs('p', 'n') ~= nil, 'the buffer-local p mapping is restored')
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  -- maparg reports a global fallback with buffer == 0 when no local map exists;
  -- deleting it as buffer-local raises E31. Skip that fallback and isolate each
  -- deletion so one failure does not prevent clearing the remaining maps.
  H.it('a global-only mapping is left alone and does not stop the rest of the clearing', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local bufnr = open_direct_buffer()

    -- Reachable state: the buffer has no local `u` (its ftplugin
    -- mapping was cleared, or never installed) while a global `u` carrying the
    -- plugin's own rhs resolves through it.
    vim.keymap.del('n', 'u', { buffer = true })
    vim.keymap.set('n', 'u', '<Cmd>undo<CR>', { silent = true, noremap = true })
    local resolved = vim.fn.maparg('u', 'n', false, true)
    H.assert_eq(resolved.buffer, 0, 'premise: only a global u resolves here')
    H.assert_eq(resolved.rhs, '<Cmd>undo<CR>', 'premise: it carries the plugin rhs')

    config.setup({ map_default_keys = false })

    -- The mappings AFTER the fallback in BUFFER_MAPS must still be cleared.
    H.assert_nil(buf_map_rhs('p', 'n'), 'the later buffer-local mappings are still cleared')
    H.assert_nil(buf_map_rhs('yy', 'n'), 'and the ones in between too')
    -- The global fallback is not this buffer's mapping: it must survive.
    local after = vim.fn.maparg('u', 'n', false, true)
    H.assert_eq(after.buffer, 0, 'the global u is still global')
    H.assert_eq(after.rhs, '<Cmd>undo<CR>', 'the global u was not deleted')
    vim.keymap.del('n', 'u')
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  -- A failed deletion should warn without stopping later mappings from clearing.
  H.it('a failing deletion warns and does not stop the remaining mappings', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local bufnr = open_direct_buffer()

    local real_del = vim.keymap.del
    local restore = H.stub(vim.keymap, 'del', function(mode, lhs, o)
      if lhs == 'u' then
        error('forced: cannot delete ' .. lhs, 0)
      end
      return real_del(mode, lhs, o)
    end)
    H.capture_messages()
    config.setup({ map_default_keys = false })
    restore()

    H.assert_nil(buf_map_rhs('p', 'n'), 'the mappings after the failure are still cleared')
    H.assert_nil(buf_map_rhs('yy', 'n'), 'and the ones in between too')
    H.assert_true(buf_map_rhs('u', 'n') ~= nil, 'the mapping that could not be deleted stays')
    H.assert_notified('cannot clear', vim.log.levels.WARN)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  -- Preserve a user's buffer-local `u` override while clearing the plugin's
  -- other mappings in the same direct buffer.
  H.it('clearing spares a user-owned buffer-local override of u', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local bufnr = open_direct_buffer()

    vim.keymap.set('n', 'u', ':echo "mine"<CR>',
      { buffer = true, silent = true, noremap = true })
    H.assert_eq(vim.fn.maparg('u', 'n', false, true).buffer, 1, 'premise: a local override now')

    config.setup({ map_default_keys = false })

    H.assert_eq(buf_map_rhs('u', 'n'), ':echo "mine"<CR>', 'the user override survives')
    H.assert_nil(buf_map_rhs('p', 'n'), 'the plugin maps are still cleared')
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  H.it('ftplugin undo removes only its maps and preserves the previous hook', function()
    local config = fresh_config()
    config.clear_mappings()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'direct'
    -- An already-loaded ftplugin may have populated this buffer variable; add
    -- another hook to exercise composition when this ftplugin is sourced again.
    vim.b[bufnr].undo_ftplugin = 'let b:previous_ftplugin_undo_ran = 1'
    vim.cmd('runtime ftplugin/direct.lua')
    H.assert_true(buf_map_rhs('<CR>', 'n') ~= nil,
      'the direct ftplugin installed its buffer mappings')
    H.assert_true(type(vim.b[bufnr].undo_ftplugin) == 'string'
      and vim.b[bufnr].undo_ftplugin:find('previous_ftplugin_undo_ran', 1, true) ~= nil,
      'the previous undo hook was retained')

    vim.keymap.set('n', '<CR>', ':echo "user map"<CR>', { buffer = bufnr })
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd('execute b:undo_ftplugin')
    end)

    H.assert_eq(vim.b[bufnr].previous_ftplugin_undo_ran, 1,
      'the previous undo hook ran')
    H.assert_eq(buf_map_rhs('<CR>', 'n'), ':echo "user map"<CR>',
      'the same-lhs user mapping survives')
    H.assert_nil(buf_map_rhs('p', 'n'), 'the plugin mapping was removed')
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  -- A buffer can be unloaded between the
  -- snapshot taken by clear_buffer_mappings and the nvim_buf_call that reads
  -- its maps, and nvim_buf_call raises on an invalid handle. The window itself
  -- cannot be opened deterministically from a test, so the API seam synthesises
  -- exactly the documented failure; the guard must swallow it, since the buffer
  -- is going away anyway.
  H.it('clear_buffer_mappings ignores a buffer that goes away before the call', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    local bufnr = open_direct_buffer()

    local calls = 0
    local restore = H.stub(vim.api, 'nvim_buf_call', function()
      calls = calls + 1
      error('Invalid buffer id: ' .. tostring(bufnr), 0)
    end)
    local ok, res = pcall(config.clear_buffer_mappings)
    restore()

    H.assert_true(ok, 'clear_buffer_mappings does not propagate the buf_call failure')
    H.assert_true(res == true, 'it still reports success')
    H.assert_eq(calls, 1, 'the guarded call was attempted once')
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)
