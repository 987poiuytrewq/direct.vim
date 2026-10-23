-- lua/direct/config.lua -- options and plugin-owned key mappings.
-- setup is idempotent; disabling mappings removes only mappings installed by
-- this plugin, including its buffer-local mappings in loaded direct buffers.

local M = {}

local defaults = {
  map_default_keys = true,
}

M.defaults = defaults
M.options = vim.deepcopy(defaults)

-- Global mapping: normal `-` opens the current buffer's directory.
M.GLOBAL_MAP = {
  mode = 'n',
  lhs = '-',
  rhs = ':<C-U>DirectListBuffer<CR>',
}

-- Lifecycle state. `_setup_called` short-circuits the VimEnter handler once the
-- user has configured the plugin; `_vim_enter_installed` makes that handler
-- one-shot.
--
-- `_installed` is reconciled against the keymap at load
-- the module is re-required across sessions and at runtime boundaries while a
-- `-` mapping may exist that the plugin never installed (the user's own, or
-- another plugin's), and `clear_mappings` must only remove a mapping the
-- plugin owns. Ownership is decided by rhs identity, never by lhs alone.
M._setup_called = false
M._vim_enter_installed = false
M._installed = vim.fn.maparg(M.GLOBAL_MAP.lhs, M.GLOBAL_MAP.mode) == M.GLOBAL_MAP.rhs

-- The nine buffer-local mappings for filetype=direct buffers, owned
-- here so setup can clear and restore them in
-- ALREADY-open direct buffers. Installed by `ftplugin/direct.lua` via
-- `install_buffer_mappings(0)`. Built on `<Cmd>` (never a `:` command that
-- would leave visual mode / re-trigger mappings); the buffer-local `-` wins
-- over the global one inside a direct buffer, which is why the global mapping
-- resolving to `getcwd` there is never observable.
M.BUFFER_MAPS = {
  { mode = 'n', lhs = '<CR>',
    rhs = '<Cmd>lua require("direct").open()<CR>' },
  { mode = 'n', lhs = '-',
    rhs = '<Cmd>lua require("direct").open("../")<CR>' },
  { mode = 'n', lhs = 'u', rhs = '<Cmd>undo<CR>' },
  { mode = 'n', lhs = '<C-r>', rhs = '<Cmd>redo<CR>' },
  { mode = 'n', lhs = 'yy', rhs = '<Cmd>DirectYank<CR>' },
  { mode = 'n', lhs = 'Y', rhs = '<Cmd>DirectYank<CR>' },
  -- Visual `y`: a ranged command (`:<C-U>'<,'>DirectYank<CR>`) raises E20 and
  -- unsets the marks here, so the Lua entry point is called with the visual
  -- range (start from `'v'`, end from the cursor); `M.yank` normalises the
  -- order.
  { mode = 'v', lhs = 'y',
    rhs = '<Cmd>lua require("direct").yank(vim.fn.line("v"), vim.fn.line("."))<CR>' },
  { mode = 'n', lhs = 'p', rhs = '<Cmd>DirectPaste<CR>' },
  { mode = 'n', lhs = 'P', rhs = '<Cmd>DirectPaste<CR>' },
}

-- The loaded buffers whose filetype is `direct`: the retrofit targets for
-- install/clear of the buffer-local maps.
local function open_direct_buffers()
  local bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == 'direct' then
      bufs[#bufs + 1] = bufnr
    end
  end
  return bufs
end

-- install_buffer_mappings(bufnr) -> true. Installs the nine buffer-local
-- mappings into `bufnr` (0 = the current buffer). Idempotent: re-setting a
-- mapping replaces it in place, so repeated ftplugin runs cannot stack.
function M.install_buffer_mappings(bufnr)
  for _, entry in ipairs(M.BUFFER_MAPS) do
    vim.keymap.set(entry.mode, entry.lhs, entry.rhs, {
      buffer = bufnr,
      silent = true,
      noremap = true,
    })
  end
  return true
end

-- clear_buffer_mappings -> true. Removes the plugin's buffer-local maps from
-- every loaded direct buffer. Each candidate is re-read through nvim_buf_call
-- (maparg reads the CURRENT buffer's scope) and deleted only when it really IS
-- this buffer's mapping (current.buffer == 1) AND is the plugin's own (rhs
-- identity, the same ownership rule the global `-` uses): a buffer-local map
-- with the same lhs but a different rhs belongs to the user and is left alone
-- and a GLOBAL fallback (buffer == 0) is not this buffer's mapping at all --
-- `keymap.del(..., { buffer = true })` raises E31 on it, so it must not even be
-- attempted.
--
-- The guard is PER MAPPING: a deletion that fails is reported and must not
-- silently abort the rest of that buffer's mappings (a single pcall around the
-- whole loop did exactly that while still returning true, leaving the buffer
-- half-cleared with no sign of it).
function M.clear_buffer_mappings()
  for _, bufnr in ipairs(open_direct_buffers()) do
    -- The handle can go invalid between the snapshot above and this call (the
    -- buffer is unloaded in the meantime) and nvim_buf_call raises on an
    -- invalid buffer id. The buffer is going away anyway, so the failure is
    -- ignored rather than propagated.
    pcall(vim.api.nvim_buf_call, bufnr, function()
      for _, entry in ipairs(M.BUFFER_MAPS) do
        local current = vim.fn.maparg(entry.lhs, entry.mode, false, true)
        local ours = current.rhs ~= nil
          and current.rhs == entry.rhs
          and current.buffer == 1
        if ours then
          local ok, err = pcall(vim.keymap.del, entry.mode, entry.lhs, { buffer = true })
          if not ok then
            require('direct.ui').notify(
              string.format('direct: cannot clear the %s mapping in buffer %d: %s',
                entry.lhs, bufnr, tostring(err)),
              vim.log.levels.WARN)
          end
        end
      end
    end)
  end
  return true
end

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
  -- re-applying the option must also re-install the buffer-local maps in
  -- direct buffers that are already open (the ftplugin only runs when a direct
  -- buffer is created).
  for _, bufnr in ipairs(open_direct_buffers()) do
    M.install_buffer_mappings(bufnr)
  end
  return true
end

function M.clear_mappings()
  -- Only remove the global `-` when this plugin installed it: a user-owned
  -- mapping with a different rhs must survive.
  if M._installed then
    pcall(vim.keymap.del, M.GLOBAL_MAP.mode, M.GLOBAL_MAP.lhs)
    M._installed = false
  end
  -- disabling the maps must also clear the buffer-local ones in direct
  -- buffers that are already open.
  M.clear_buffer_mappings()
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

-- on_vim_enter -> boolean (installed?). The VimEnter handler installs
-- the default mapping at most once and only when setup was never called.
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

-- install_deferred -> boolean (installed now?). The entry point that
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
