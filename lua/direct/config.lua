-- lua/direct/config.lua -- default options and setup() merge.
--
-- Responsibility (spec section 5): defaults, setup(opts), install_mappings,
-- clear_mappings. No filesystem or buffer access.
--
-- The only default option is `map_default_keys` (section 6). setup() is
-- idempotent: later calls replace the option table and re-apply mappings.
-- Unknown keys are rejected with an ERROR notification naming the key, so a
-- typo is surfaced instead of silently ignored.
--
-- Mapping timing (D10): the global `-` is installed either immediately from
-- setup(), or -- when the user never calls setup() -- once from the VimEnter
-- handler. Under `nvim --headless -l` `v:vim_did_enter` is already 1, so the
-- immediate path is the one the harness exercises. The nine buffer-local
-- mappings are owned by `ftplugin/direct.lua` (T-026); this module only wires
-- the global mapping and the deferred-install structure (P4 fills the rest).

local M = {}

local defaults = {
  map_default_keys = true,
}

M.defaults = defaults
M.options = vim.deepcopy(defaults)

-- Global mapping (section 6): normal `-` opens the current buffer's directory.
M.GLOBAL_MAP = {
  mode = 'n',
  lhs = '-',
  rhs = ':<C-U>DirectListBuffer<CR>',
}

-- Lifecycle state. `_setup_called` short-circuits the VimEnter handler once the
-- user has configured the plugin; `_vim_enter_installed` makes that handler
-- one-shot.
M._setup_called = false
M._vim_enter_installed = false
M._installed = false

function M.install_mappings()
  if not M.options.map_default_keys then
    return M.clear_mappings()
  end
  vim.keymap.set(M.GLOBAL_MAP.mode, M.GLOBAL_MAP.lhs, M.GLOBAL_MAP.rhs, {
    noremap = true,
    silent = true,
    desc = 'direct: list current buffer directory',
  })
  M._installed = true
  return true
end

function M.clear_mappings()
  pcall(vim.keymap.del, M.GLOBAL_MAP.mode, M.GLOBAL_MAP.lhs)
  M._installed = false
  return true
end

-- setup(opts) -> the resolved option table. Later calls replace (not merge
-- into) the previous table; an unknown key is reported as an ERROR and not
-- applied (its default is kept).
function M.setup(opts)
  opts = opts or {}
  local next_options = vim.deepcopy(defaults)
  for key, value in pairs(opts) do
    if defaults[key] == nil then
      require('direct.ui').notify(
        string.format("direct: unknown option '%s'", tostring(key)),
        vim.log.levels.ERROR)
    else
      next_options[key] = value
    end
  end
  M.options = next_options
  M._setup_called = true
  if M.options.map_default_keys then
    M.install_mappings()
  else
    M.clear_mappings()
  end
  return M.options
end

-- on_vim_enter() -> boolean (installed?). The VimEnter handler (D10): installs
-- the default mapping at most once and only when setup() was never called.
function M.on_vim_enter()
  if M._setup_called or M._vim_enter_installed then
    return false
  end
  M._vim_enter_installed = true
  if M.options.map_default_keys then
    M.install_mappings()
  end
  return true
end

-- install_deferred() -> boolean (installed now?). The D10 entry point that
-- plugin/direct.lua calls at load: when VimEnter has already fired (`-l`, or a
-- startup that sourced the plugin late) install immediately; otherwise defer to
-- a one-shot VimEnter autocmd.
function M.install_deferred()
  if vim.v.vim_did_enter == 1 then
    return M.on_vim_enter()
  end
  local group = vim.api.nvim_create_augroup('direct_deferred', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    pattern = '*',
    once = true,
    callback = function()
      M.on_vim_enter()
    end,
  })
  return false
end

return M
