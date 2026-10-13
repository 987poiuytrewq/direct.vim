-- tests/config_spec.lua -- defaults, setup merge, and mapping lifecycle (T-010,
-- D10).

local H = require('tests.support.harness')

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
end)