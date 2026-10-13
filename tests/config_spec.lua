-- tests/config_spec.lua -- defaults, setup merge, and mapping lifecycle (T-010,
-- D10).

local H = require('tests.support.harness')

-- P2 (Greptile, PR #1): buffer-local direct mappings must be removable and
-- restorable for ALREADY-open direct buffers, which needs `buffer` to open one.
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
    -- No setup() call: the D10 deferred install applies the default once.
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

  -- P2 (Greptile, PR #1): clear_mappings used to delete the global `-`
  -- unconditionally, so setup({ map_default_keys = false }) removed a mapping
  -- the USER installed even when the plugin never installed one.
  H.it('setup({ map_default_keys = false }) spares a user-owned global - mapping (P2)', function()
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

  H.it('setup({ map_default_keys = false }) still removes the mapping the plugin installed (P2)', function()
    local config = fresh_config()
    config.clear_mappings()
    config.setup({ map_default_keys = true })
    H.assert_true(vim.fn.maparg('-', 'n') ~= '', 'premise: the plugin mapping is installed')
    config.setup({ map_default_keys = false })
    H.assert_eq(vim.fn.maparg('-', 'n'), '', 'the plugin mapping is removed')
  end)

  H.it('clear_mappings with nothing installed is a harmless no-op (P2)', function()
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

  -- P2 (Greptile, PR #1): the buffer-local maps are installed by the ftplugin
  -- and were never cleared, so setup({ map_default_keys = false }) after a
  -- direct buffer is already open left the option looking ineffective.
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

  H.it('setup({ map_default_keys = false }) clears buffer-local maps in already-open direct buffers (P2)', function()
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

  H.it('clearing does not disturb other buffers and their buffer-local maps (P2)', function()
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

  H.it('re-enabling map_default_keys restores the maps in already-open direct buffers (P2)', function()
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
end)