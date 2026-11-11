-- lua/direct/config.lua -- options and plugin-owned key mappings.
-- setup is idempotent; disabling mappings removes only mappings installed by
-- this plugin, including its buffer-local mappings in loaded direct buffers.

---@class direct.Icons
---@field file? string
---@field folder? string
---@field folder_open? string
---@field deleted_file? string
---@field deleted_folder? string
---@field deleted_folder_open? string

---@class direct.TrashRetention
---@field max_age_days? integer
---@field max_size_bytes? integer

---@alias direct.GitSymbolName 'added'|'deleted'|'modified'|'renamed'|'ignored'|'staged'|'conflict'

---@class direct.GitSymbols
---@field added? string
---@field deleted? string
---@field modified? string
---@field renamed? string
---@field ignored? string
---@field staged? string
---@field conflict? string

---@class direct.GitConfig
---@field enabled? boolean
---@field timeout_ms? integer
---@field show_symbols? boolean
---@field show_deleted? boolean
---@field symbols? table<direct.GitSymbolName, string>

---@class direct.BufferConfig
---@field reuse? boolean Reuse an existing Direct listing for the same directory.
---@field open_in? 'current'|'new' Open targets in the current buffer or preserve the source buffer.

---@class direct.Config
---@field map_default_keys? boolean
---@field directory_separator? '/'|'\\'
---@field show_hidden? boolean
---@field respect_gitignore? boolean
---@field collapse_single_entry_directories? boolean
---@field indent_size? integer
---@field undo_confirm? boolean|'elsewhere'
---@field trash_retention? false|direct.TrashRetention
---@field mappings? table<string, string|false>
---@field show_folder_icons? boolean
---@field show_file_icons? boolean
---@field show_filetype_icons? boolean
---@field icons? direct.Icons
---@field max_recursive_expand_depth? false|integer
---@field git? direct.GitConfig
---@field buffers? direct.BufferConfig

local M = {}
local constants = require('direct.constants')
local platform = require('direct.platform')

---@type direct.Config
local defaults = {
  map_default_keys = true,
  directory_separator = platform.separator,
  show_hidden = true,
  respect_gitignore = true,
  collapse_single_entry_directories = false,
  indent_size = 2,
  undo_confirm = 'elsewhere',
  trash_retention = false,
  mappings = {},
  show_folder_icons = true,
  show_file_icons = true,
  show_filetype_icons = true,
  icons = {
    file = '\u{f15b}',
    folder = '\u{f07b}',
    folder_open = '\u{f07c}',
    deleted_file = '\u{f016}',
    deleted_folder = '\u{f114}',
    deleted_folder_open = '\u{f115}',
  },
  max_recursive_expand_depth = false,
  buffers = {
    reuse = true,
    open_in = 'current',
  },
  git = {
    enabled = true,
    timeout_ms = 1000,
    show_symbols = true,
    show_deleted = true,
    symbols = {
      added = '\u{f067}',
      deleted = '\u{f068}',
      modified = '\u{f01f}',
      renamed = '\u{f061}',
      ignored = '\u{f070}',
      staged = '\u{f00c}',
      conflict = '\u{f00d}',
    },
  },
}

local function resolve_buffer_options(value)
  if type(value) ~= 'table' then
    require('direct.ui').notify('direct: invalid buffers: expected a table', vim.log.levels.ERROR)
    return vim.deepcopy(defaults.buffers)
  end
  local result = vim.deepcopy(defaults.buffers)
  for key, option in pairs(value) do
    if key == 'reuse' then
      if type(option) == 'boolean' then
        result.reuse = option
      else
        require('direct.ui').notify('direct: invalid buffers.reuse: expected a boolean', vim.log.levels.ERROR)
      end
    elseif key == 'open_in' then
      if option == 'current' or option == 'new' then
        result.open_in = option
      else
        require('direct.ui').notify(
          "direct: invalid buffers.open_in: expected 'current' or 'new'",
          vim.log.levels.ERROR
        )
      end
    else
      require('direct.ui').notify(
        'direct: invalid buffers.' .. tostring(key) .. ': unknown setting',
        vim.log.levels.ERROR
      )
    end
  end
  return result
end

local icon_variants = {
  file = true,
  folder = true,
  folder_open = true,
  deleted_file = true,
  deleted_folder = true,
  deleted_folder_open = true,
}

local function report_invalid_icon_option(key, reason)
  local option = key == '' and 'icons' or ('icons.' .. key)
  require('direct.ui').notify(string.format('direct: invalid %s: %s', option, reason), vim.log.levels.ERROR)
end

local function resolve_icon_options(value)
  if type(value) ~= 'table' then
    report_invalid_icon_option('', 'expected a table')
    return vim.deepcopy(defaults.icons)
  end

  local result = vim.deepcopy(defaults.icons)
  for key, glyph in pairs(value) do
    if not icon_variants[key] then
      report_invalid_icon_option(
        tostring(key),
        'unknown icon; expected file, folder, folder_open, deleted_file, deleted_folder, or deleted_folder_open'
      )
    elseif type(glyph) ~= 'string' or glyph == '' then
      report_invalid_icon_option(key, 'expected a non-empty glyph string')
    else
      result[key] = glyph
    end
  end
  return result
end

local function report_invalid_git_option(key, reason)
  require('direct.ui').notify(string.format('direct: invalid git.%s: %s', key, reason), vim.log.levels.ERROR)
end

local function resolve_git_options(value)
  if type(value) ~= 'table' then
    report_invalid_git_option('', 'expected a table')
    return vim.deepcopy(defaults.git)
  end

  local result = vim.deepcopy(defaults.git)
  for key, option in pairs(value) do
    if key == 'enabled' then
      if type(option) == 'boolean' then
        result.enabled = option
      else
        report_invalid_git_option(key, 'expected a boolean')
      end
    elseif key == 'timeout_ms' then
      if type(option) == 'number' and option >= 1 and option % 1 == 0 then
        result.timeout_ms = option
      else
        report_invalid_git_option(key, 'expected a positive integer')
      end
    elseif key == 'show_symbols' then
      if type(option) == 'boolean' then
        result.show_symbols = option
      else
        report_invalid_git_option(key, 'expected a boolean')
      end
    elseif key == 'show_deleted' then
      if type(option) == 'boolean' then
        result.show_deleted = option
      else
        report_invalid_git_option(key, 'expected a boolean')
      end
    elseif key == 'symbols' then
      if type(option) ~= 'table' then
        report_invalid_git_option(key, 'expected a table')
      else
        for status, symbol in pairs(option) do
          if result.symbols[status] == nil then
            report_invalid_git_option('symbols.' .. tostring(status), 'unknown status symbol')
          elseif type(symbol) ~= 'string' or vim.fn.strdisplaywidth(symbol) > 1 then
            report_invalid_git_option('symbols.' .. status, 'expected an empty string or one display cell')
          else
            result.symbols[status] = symbol
          end
        end
      end
    else
      report_invalid_git_option(tostring(key), 'unknown setting')
    end
  end
  return result
end

local function resolve_trash_retention(value)
  if value == false then return false end
  if type(value) ~= 'table' then
    require('direct.ui').notify(
      'direct: trash_retention must be false or a table with max_age_days and/or max_size_bytes',
      vim.log.levels.ERROR
    )
    return false
  end
  local result = {}
  for key, limit in pairs(value) do
    if
      (key ~= 'max_age_days' and key ~= 'max_size_bytes')
      or type(limit) ~= 'number'
      or limit < 1
      or limit % 1 ~= 0
    then
      require('direct.ui').notify(
        'direct: trash_retention limits must be positive integers named max_age_days or max_size_bytes',
        vim.log.levels.ERROR
      )
    else
      result[key] = limit
    end
  end
  if next(result) == nil then
    require('direct.ui').notify(
      'direct: trash_retention needs a valid max_age_days or max_size_bytes limit',
      vim.log.levels.ERROR
    )
    return false
  end
  return result
end

---@type direct.Config
M.defaults = defaults
---@type direct.Config
M.options = vim.deepcopy(defaults)

-- Global mapping: normal `-` opens the current buffer's directory.
M.GLOBAL_MAP = {
  action = 'list_buffer',
  mode = 'n',
  lhs = '-',
  rhs = ':<C-U>DirectListBuffer<CR>',
  desc = 'direct: list current buffer directory',
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

-- The buffer-local mappings for filetype=direct buffers, owned
-- here so setup can clear and restore them in
-- ALREADY-open direct buffers. Installed by `ftplugin/direct.lua` via
-- `install_buffer_mappings(0)`. Built on `<Cmd>` (never a `:` command that
-- would leave visual mode / re-trigger mappings); the buffer-local `-` wins
-- over the global one inside a direct buffer, which is why the global mapping
-- resolving to `getcwd` there is never observable.
M.BUFFER_MAPS = {
  { action = 'open', mode = 'n', lhs = '<CR>', rhs = '<Cmd>lua require("direct").open()<CR>' },
  {
    action = 'open_horizontal',
    mode = 'n',
    lhs = '<C-s>',
    rhs = '<Cmd>lua require("direct").open({ split = "horizontal" })<CR>',
  },
  {
    action = 'open_vertical',
    mode = 'n',
    lhs = '<C-v>',
    rhs = '<Cmd>lua require("direct").open({ split = "vertical" })<CR>',
  },
  {
    action = 'open_tab',
    mode = 'n',
    lhs = '<C-t>',
    rhs = '<Cmd>lua require("direct").open({ split = "tab" })<CR>',
  },
  {
    action = 'list_buffer',
    mode = 'n',
    lhs = '-',
    rhs = '<Cmd>lua require("direct").list(vim.fn.fnamemodify(vim.b.direct_root or vim.api.nvim_buf_get_name(0), ":h"))<CR>',
  },
  {
    action = 'open_parent_expanded',
    mode = 'n',
    lhs = 'z-',
    rhs = '<Cmd>lua require("direct").open_parent_expanded()<CR>',
  },
  { action = 'undo', mode = 'n', lhs = 'u', rhs = '<Cmd>DirectUndo<CR>' },
  { action = 'redo', mode = 'n', lhs = '<C-r>', rhs = '<Cmd>DirectRedo<CR>' },
  { action = 'yank', mode = 'n', lhs = 'yy', rhs = '<Cmd>DirectYank<CR>' },
  { action = 'yank_uppercase', mode = 'n', lhs = 'Y', rhs = '<Cmd>DirectYank<CR>' },
  -- Visual `y`: a ranged command (`:<C-U>'<,'>DirectYank<CR>`) raises E20 and
  -- unsets the marks here, so the Lua entry point is called with the visual
  -- range (start from `'v'`, end from the cursor); `M.yank` normalises the
  -- order.
  {
    action = 'yank_visual',
    mode = 'v',
    lhs = 'y',
    rhs = '<Cmd>lua require("direct").yank(vim.fn.line("v"), vim.fn.line("."))<CR>',
  },
  { action = 'paste', mode = 'n', lhs = 'p', rhs = '<Cmd>DirectPaste<CR>' },
  { action = 'paste_uppercase', mode = 'n', lhs = 'P', rhs = '<Cmd>DirectPaste<CR>' },
  { action = 'toggle_hidden', mode = 'n', lhs = 'gh', rhs = '<Cmd>DirectToggleHidden<CR>' },
  { action = 'toggle_gitignore', mode = 'n', lhs = 'gi', rhs = '<Cmd>DirectToggleGitIgnore<CR>' },
  { action = 'git_add', mode = 'n', lhs = 'ga', rhs = '<Cmd>DirectGit git add -- {}<CR>' },
  { action = 'git_unstage', mode = 'n', lhs = '<leader>gu', rhs = '<Cmd>DirectGit git reset -- {}<CR>' },
  { action = 'git_restore', mode = 'n', lhs = '<leader>gr', rhs = '<Cmd>DirectGitRestore<CR>' },
  { action = 'toggle_git_status', mode = 'n', lhs = 'gs', rhs = '<Cmd>DirectToggleGitStatus<CR>' },
  { action = 'git_diff', mode = 'n', lhs = 'gd', rhs = '<Cmd>lua require("direct").git_diff()<CR>' },
  { action = 'next_change', mode = 'n', lhs = ']c', rhs = '<Cmd>DirectNextChange<CR>' },
  { action = 'previous_change', mode = 'n', lhs = '[c', rhs = '<Cmd>DirectPreviousChange<CR>' },
  { action = 'next_file', mode = 'n', lhs = ']f', rhs = '<Cmd>DirectNextFile<CR>' },
  { action = 'previous_file', mode = 'n', lhs = '[f', rhs = '<Cmd>DirectPreviousFile<CR>' },
}

local function mapping_catalog()
  local result = { [M.GLOBAL_MAP.action] = true }
  for _, entry in ipairs(M.BUFFER_MAPS) do
    result[entry.action] = true
  end
  for _, entry in ipairs(require('direct.folding').KEY_MAPS) do
    result[entry.action] = true
  end
  return result
end

---@param action string
---@param default string
---@return string?
function M.mapping_lhs(action, default)
  local mapping = M.options.mappings and M.options.mappings[action]
  if mapping == false then return nil end
  if type(mapping) == 'string' then return mapping end
  return M.options.map_default_keys and default or nil
end

local function resolve_mappings(value)
  if type(value) ~= 'table' then
    require('direct.ui').notify('direct: mappings must be a table', vim.log.levels.ERROR)
    return {}
  end
  local known, result = mapping_catalog(), {}
  for action, key in pairs(value) do
    if not known[action] then
      require('direct.ui').notify('direct: unknown mapping action ' .. tostring(action), vim.log.levels.ERROR)
    elseif key == false or (type(key) == 'string' and key ~= '') then
      result[action] = key
    else
      require('direct.ui').notify(
        'direct: mappings.' .. tostring(action) .. ' must be a non-empty key or false',
        vim.log.levels.ERROR
      )
    end
  end
  return result
end

-- The loaded buffers whose filetype is `direct`: the retrofit targets for
-- install/clear of the buffer-local maps.
local function open_direct_buffers()
  local bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == constants.FILETYPE then
      bufs[#bufs + 1] = bufnr
    end
  end
  return bufs
end

local function buffer_mapping_rhs()
  local rhs = {}
  for _, entry in ipairs(M.BUFFER_MAPS) do
    rhs[entry.rhs] = true
  end
  for _, entry in ipairs(require('direct.folding').KEY_MAPS) do
    if entry.rhs then rhs[entry.rhs] = true end
  end
  for _, entry in ipairs(require('direct.folding').MOUSE_MAPS) do
    if entry.rhs then rhs[entry.rhs] = true end
  end
  return rhs
end

local function plug_entries()
  local entries, seen = {}, {}
  local function add(action, mode, rhs)
    if seen[action] then return end
    seen[action] = true
    entries[#entries + 1] = {
      action = action,
      mode = mode or 'n',
      lhs = '<Plug>(direct-' .. action:gsub('_', '-') .. ')',
      rhs = rhs,
      desc = 'direct: Plug ' .. action,
    }
  end
  add(M.GLOBAL_MAP.action, M.GLOBAL_MAP.mode, M.GLOBAL_MAP.rhs)
  for _, entry in ipairs(M.BUFFER_MAPS) do
    add(entry.action, entry.mode, entry.rhs)
  end
  local folding = require('direct.folding')
  local buffer = require('direct.buffer.buffer')
  for _, entry in ipairs(require('direct.folding').KEY_MAPS) do
    add(entry.action, 'n', folding.action_callback(entry.action, buffer))
  end
  return entries
end

local function clear_owned_buffer_maps(target)
  local rhs = buffer_mapping_rhs()
  for _, mode in ipairs({ 'n', 'v' }) do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(target, mode)) do
      if rhs[map.rhs] then
        local ok, err = pcall(vim.keymap.del, mode, map.lhs, { buffer = target })
        if not ok then
          require('direct.ui').notify(
            string.format('direct: cannot clear the %s mapping in buffer %d: %s', map.lhs, target, tostring(err)),
            vim.log.levels.WARN
          )
        end
      end
    end
  end
  require('direct.folding').clear_mappings(target)
end

-- install_buffer_mappings(bufnr) -> true. Physical buffer mappings follow the
-- `mappings` table; global <Plug> entry points are installed separately.
function M.install_buffer_mappings(bufnr)
  local target = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  clear_owned_buffer_maps(target)
  for _, entry in ipairs(M.BUFFER_MAPS) do
    local lhs = M.mapping_lhs(entry.action, entry.lhs)
    if lhs then
      vim.keymap.set(entry.mode, lhs, entry.rhs, {
        buffer = target,
        silent = true,
        noremap = true,
      })
    end
  end
  require('direct.folding').install_mappings(target, require('direct.buffer.buffer'))
  return true
end

-- clear_buffer_mappings -> true. Removes only mappings with Direct-owned RHSs.
function M.clear_buffer_mappings(bufnr)
  local buffers
  if bufnr ~= nil then
    buffers = { bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr }
  else
    buffers = open_direct_buffers()
  end
  for _, target in ipairs(buffers) do
    -- The handle can go invalid between the snapshot above and this call (the
    -- buffer is unloaded in the meantime) and nvim_buf_call raises on an
    -- invalid buffer id. The buffer is going away anyway, so the failure is
    -- ignored rather than propagated.
    pcall(vim.api.nvim_buf_call, target, function() clear_owned_buffer_maps(target, true) end)
  end
  return true
end

local function clear_global_mapping()
  local owned_desc = { ['direct: list current buffer directory'] = true }
  for _, entry in ipairs(plug_entries()) do
    owned_desc[entry.desc] = true
  end
  for _, mode in ipairs({ 'n', 'v' }) do
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if owned_desc[map.desc] then pcall(vim.keymap.del, mode, map.lhs) end
    end
  end
  M._installed = false
end

function M.install_mappings()
  clear_global_mapping()
  local global_lhs = M.mapping_lhs(M.GLOBAL_MAP.action, M.GLOBAL_MAP.lhs)
  if global_lhs then
    vim.keymap.set(M.GLOBAL_MAP.mode, global_lhs, M.GLOBAL_MAP.rhs, {
      noremap = true,
      silent = true,
      desc = 'direct: list current buffer directory',
    })
    M._installed = true
  end
  for _, entry in ipairs(plug_entries()) do
    vim.keymap.set(entry.mode, entry.lhs, entry.rhs, {
      noremap = true,
      silent = true,
      desc = entry.desc,
    })
  end
  -- re-applying the option must also re-install the buffer-local maps in
  -- direct buffers that are already open (the ftplugin only runs when a direct
  -- buffer is created).
  for _, bufnr in ipairs(open_direct_buffers()) do
    M.install_buffer_mappings(bufnr)
  end
  return true
end

function M.clear_mappings()
  clear_global_mapping()
  -- Explicitly clear all owned mappings. `setup()` uses install_mappings() to
  -- reconcile defaults and per-action overrides while retaining <Plug> maps.
  for _, bufnr in ipairs(open_direct_buffers()) do
    pcall(vim.api.nvim_buf_call, bufnr, function() clear_owned_buffer_maps(bufnr) end)
  end
  return true
end

-- setup(opts) -> the resolved option table. Later calls replace (not merge
-- into) the previous table; an unknown key is reported as an ERROR and not
-- applied (its default is kept).
---@param opts direct.Config|nil
---@return direct.Config
function M.setup(opts)
  opts = opts or {}
  local next_options = vim.deepcopy(defaults)
  for key, value in pairs(opts) do
    if defaults[key] == nil then
      require('direct.ui').notify(string.format("direct: unknown option '%s'", tostring(key)), vim.log.levels.ERROR)
    elseif
      key == 'max_recursive_expand_depth'
      and value ~= false
      and (type(value) ~= 'number' or value < 1 or value % 1 ~= 0)
    then
      require('direct.ui').notify(
        'direct: max_recursive_expand_depth must be false or a positive integer',
        vim.log.levels.ERROR
      )
    elseif key == 'indent_size' and (type(value) ~= 'number' or value <= 1 or value % 1 ~= 0) then
      require('direct.ui').notify('direct: indent_size must be an integer greater than 1', vim.log.levels.ERROR)
    elseif key == 'undo_confirm' and value ~= false and value ~= true and value ~= 'elsewhere' then
      require('direct.ui').notify("direct: undo_confirm must be true, false, or 'elsewhere'", vim.log.levels.ERROR)
    elseif key == 'trash_retention' then
      next_options.trash_retention = resolve_trash_retention(value)
    elseif key == 'buffers' then
      next_options.buffers = resolve_buffer_options(value)
    elseif key == 'directory_separator' and value ~= '/' and value ~= '\\' then
      require('direct.ui').notify('direct: directory_separator must be "/" or "\\\\"', vim.log.levels.ERROR)
    elseif key == 'icons' then
      next_options.icons = resolve_icon_options(value)
    elseif key == 'mappings' then
      next_options.mappings = resolve_mappings(value)
    elseif
      (
        key == 'show_hidden'
        or key == 'respect_gitignore'
        or key == 'collapse_single_entry_directories'
        or key == 'show_filetype_icons'
      ) and type(value) ~= 'boolean'
    then
      require('direct.ui').notify(string.format('direct: %s must be a boolean', key), vim.log.levels.ERROR)
    elseif key == 'git' then
      next_options.git = resolve_git_options(value)
    else
      next_options[key] = value
    end
  end
  M.options = next_options
  M._setup_called = true
  M.install_mappings()
  return M.options
end

-- on_vim_enter -> boolean (installed?). The VimEnter handler installs
-- the default mapping at most once and only when setup was never called.
function M.on_vim_enter()
  if M._setup_called or M._vim_enter_installed then return false end
  M._vim_enter_installed = true
  M.install_mappings()
  return true
end

-- install_deferred -> boolean (installed now?). The entry point that
-- plugin/direct.lua calls at load: when VimEnter has already fired (`-l`, or a
-- startup that sourced the plugin late) install immediately; otherwise defer to
-- a one-shot VimEnter autocmd.
function M.install_deferred()
  if vim.v.vim_did_enter == 1 then return M.on_vim_enter() end
  local group = vim.api.nvim_create_augroup('direct_deferred', { clear = true })
  vim.api.nvim_create_autocmd('VimEnter', {
    group = group,
    pattern = '*',
    once = true,
    callback = function() M.on_vim_enter() end,
  })
  return false
end

return M
