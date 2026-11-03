-- lua/direct/config.lua -- options and plugin-owned key mappings.
-- setup is idempotent; disabling mappings removes only mappings installed by
-- this plugin, including its buffer-local mappings in loaded direct buffers.

local M = {}
local constants = require('direct.constants')

local defaults = {
  map_default_keys = true,
  show_hidden = true,
  respect_gitignore = false,
  show_folder_icons = false,
  show_file_icons = false,
  icons = {
    file = '\u{f0214}',
    folder = '\u{f024b}',
    folder_open = '\u{f0770}',
  },
  max_recursive_expand_depth = false,
  git = {
    enabled = true,
    show_deleted = true,
    display = 'gutter',
    statuses = {
      added = {
        gutter = { symbol = '┃', highlight = 'DirectGitAddedGutter' },
      },
      modified = {
        gutter = { symbol = '┃', highlight = 'DirectGitModifiedGutter' },
      },
      renamed = {
        gutter = { symbol = '┃', highlight = 'DirectGitRenamedGutter' },
      },
      conflicted = {
        gutter = { symbol = '┃', highlight = 'DirectGitConflictedGutter' },
      },
      deleted = {
        gutter = { symbol = '┃', highlight = 'DirectGitDeletedGutter' },
      },
    },
    staging = {
      enabled = true,
      staged = {
        icon_hl = 'DirectGitStagedIcon',
        text_hl = 'DirectGitStaged',
        gutter = { symbol = '┃•', highlight = 'DirectGitStagedGutter' },
      },
      unstaged = {
        icon_hl = 'DirectGitUnstagedIcon',
        text_hl = 'DirectGitUnstaged',
        gutter = { symbol = '┃', highlight = 'DirectGitUnstagedGutter' },
      },
      mixed_file = {
        icon_hl = 'DirectGitStagedIcon',
        text_hl = 'DirectGitStaged',
        gutter = { symbol = '┃•', highlight = 'DirectGitStagedGutter' },
      },
      mixed_folder = {
        icon_hl = 'DirectGitStagedIcon',
        text_hl = 'DirectGitStaged',
        gutter = { symbol = '┃•', highlight = 'DirectGitStagedGutter' },
      },
    },
  },
}

local git_statuses = {
  added = true, modified = true, renamed = true, conflicted = true, deleted = true,
}
local git_display_modes = { gutter = true, icon = true, text = true, both = true }
local git_staging_states = {
  staged = true,
  unstaged = true,
  mixed_file = true,
  mixed_folder = true,
}
local icon_variants = { file = true, folder = true, folder_open = true }

local function report_invalid_icon_option(key, reason)
  local option = key == '' and 'icons' or ('icons.' .. key)
  require('direct.ui').notify(
    string.format('direct: invalid %s: %s', option, reason),
    vim.log.levels.ERROR)
end

local function resolve_icon_options(value)
  if type(value) ~= 'table' then
    report_invalid_icon_option('', 'expected a table')
    return vim.deepcopy(defaults.icons)
  end

  local result = vim.deepcopy(defaults.icons)
  for key, glyph in pairs(value) do
    if not icon_variants[key] then
      report_invalid_icon_option(tostring(key), 'unknown icon; expected file, folder, or folder_open')
    elseif type(glyph) ~= 'string' or glyph == '' then
      report_invalid_icon_option(key, 'expected a non-empty glyph string')
    else
      result[key] = glyph
    end
  end
  return result
end

local function report_invalid_git_option(key, reason)
  require('direct.ui').notify(
    string.format("direct: invalid git.%s: %s", key, reason),
    vim.log.levels.ERROR)
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
    elseif key == 'show_deleted' then
      if type(option) == 'boolean' then
        result.show_deleted = option
      else
        report_invalid_git_option(key, 'expected a boolean')
      end
    elseif key == 'display' then
      if type(option) == 'string' and git_display_modes[option] then
        result.display = option
      else
        report_invalid_git_option(key, "expected 'gutter', 'icon', 'text', or 'both'")
      end
    elseif key == 'statuses' then
      if type(option) ~= 'table' then
        report_invalid_git_option(key, 'expected a table')
      else
        for status, settings in pairs(option) do
          if not git_statuses[status] then
            report_invalid_git_option('statuses.' .. tostring(status), 'unknown status')
          elseif type(settings) ~= 'table' then
            report_invalid_git_option('statuses.' .. status, 'expected a table')
          else
            local resolved = result.statuses[status]
            for setting, setting_value in pairs(settings) do
              if setting == 'icon_hl' or setting == 'text_hl' then
                if type(setting_value) == 'string' and setting_value ~= '' then
                  resolved[setting] = setting_value
                else
                  report_invalid_git_option('statuses.' .. status .. '.' .. setting,
                    'expected a non-empty highlight group name')
                end
              elseif setting == 'icon' then
                if type(setting_value) == 'string' then
                  resolved.icon = setting_value
                elseif type(setting_value) == 'table' then
                  resolved.icon = resolved.icon or {}
                  for kind, glyph in pairs(setting_value) do
                    if kind == 'file' or kind == 'folder' or kind == 'folder_open' then
                      if type(glyph) == 'string' then
                        resolved.icon[kind] = glyph
                      else
                        report_invalid_git_option('statuses.' .. status .. '.icon.' .. kind,
                          'expected a string')
                      end
                    else
                      report_invalid_git_option('statuses.' .. status .. '.icon.' .. tostring(kind),
                        'expected file, folder, or folder_open')
                    end
                  end
                else
                  report_invalid_git_option('statuses.' .. status .. '.icon',
                    'expected a string or a table of icon variants')
                end
              elseif setting == 'gutter' then
                if setting_value == false then
                  resolved.gutter = nil
                elseif type(setting_value) == 'table' then
                  local gutter = vim.deepcopy(resolved.gutter or {})
                  for gutter_key, gutter_value in pairs(setting_value) do
                    if gutter_key == 'symbol' or gutter_key == 'highlight' then
                      if type(gutter_value) == 'string' and gutter_value ~= ''
                        and (gutter_key ~= 'symbol'
                          or vim.fn.strdisplaywidth(gutter_value) <= 2) then
                        gutter[gutter_key] = gutter_value
                      else
                        report_invalid_git_option('statuses.' .. status .. '.gutter.' .. gutter_key,
                          gutter_key == 'symbol'
                            and 'expected a non-empty symbol no wider than two cells'
                            or 'expected a non-empty highlight group name')
                      end
                    else
                      report_invalid_git_option('statuses.' .. status .. '.gutter.'
                        .. tostring(gutter_key), 'unknown setting')
                    end
                  end
                  if gutter.symbol and gutter.highlight then
                    resolved.gutter = gutter
                  else
                    report_invalid_git_option('statuses.' .. status .. '.gutter',
                      'symbol and highlight are both required')
                  end
                else
                  report_invalid_git_option('statuses.' .. status .. '.gutter',
                    'expected a table or false')
                end
              else
                report_invalid_git_option('statuses.' .. status .. '.' .. tostring(setting),
                  'unknown setting')
              end
            end
          end
        end
      end
    elseif key == 'staging' then
      if type(option) ~= 'table' then
        report_invalid_git_option(key, 'expected a table')
      else
        for staging_key, settings in pairs(option) do
          if staging_key == 'enabled' then
            if type(settings) == 'boolean' then
              result.staging.enabled = settings
            else
              report_invalid_git_option('staging.enabled', 'expected a boolean')
            end
          elseif git_staging_states[staging_key] then
            if type(settings) ~= 'table' then
              report_invalid_git_option('staging.' .. staging_key, 'expected a table')
            else
              local resolved = result.staging[staging_key]
              for setting, setting_value in pairs(settings) do
                if setting == 'icon_hl' or setting == 'text_hl' then
                  if type(setting_value) == 'string' and setting_value ~= '' then
                    resolved[setting] = setting_value
                  else
                    report_invalid_git_option('staging.' .. staging_key .. '.' .. setting,
                      'expected a non-empty highlight group name')
                  end
                elseif setting == 'icon' then
                  if type(setting_value) == 'string' then
                    resolved.icon = setting_value
                  elseif type(setting_value) == 'table' then
                    resolved.icon = resolved.icon or {}
                    for kind, glyph in pairs(setting_value) do
                      if kind == 'file' or kind == 'folder' or kind == 'folder_open' then
                        if type(glyph) == 'string' then
                          resolved.icon[kind] = glyph
                        else
                          report_invalid_git_option('staging.' .. staging_key .. '.icon.' .. kind,
                            'expected a string')
                        end
                      else
                        report_invalid_git_option('staging.' .. staging_key .. '.icon.'
                          .. tostring(kind), 'expected file, folder, or folder_open')
                      end
                    end
                  else
                    report_invalid_git_option('staging.' .. staging_key .. '.icon',
                      'expected a string or a table of icon variants')
                  end
                elseif setting == 'gutter' then
                  if setting_value == false then
                    resolved.gutter = nil
                  elseif type(setting_value) == 'table' then
                    local gutter = vim.deepcopy(resolved.gutter or {})
                    for gutter_key, gutter_value in pairs(setting_value) do
                      if gutter_key == 'symbol' or gutter_key == 'highlight' then
                        if type(gutter_value) == 'string' and gutter_value ~= ''
                          and (gutter_key ~= 'symbol'
                            or vim.fn.strdisplaywidth(gutter_value) <= 2) then
                          gutter[gutter_key] = gutter_value
                        else
                          report_invalid_git_option('staging.' .. staging_key .. '.gutter.'
                            .. gutter_key, gutter_key == 'symbol'
                              and 'expected a non-empty symbol no wider than two cells'
                              or 'expected a non-empty highlight group name')
                        end
                      else
                        report_invalid_git_option('staging.' .. staging_key .. '.gutter.'
                          .. tostring(gutter_key), 'unknown setting')
                      end
                    end
                    if gutter.symbol and gutter.highlight then
                      resolved.gutter = gutter
                    else
                      report_invalid_git_option('staging.' .. staging_key .. '.gutter',
                        'symbol and highlight are both required')
                    end
                  else
                    report_invalid_git_option('staging.' .. staging_key .. '.gutter',
                      'expected a table or false')
                  end
                elseif setting == 'highlight' then
                  report_invalid_git_option('staging.' .. staging_key .. '.highlight',
                    'use icon_hl, text_hl, or gutter.highlight')
                else
                  report_invalid_git_option('staging.' .. staging_key .. '.' .. tostring(setting),
                    'unknown setting')
                end
              end
            end
          else
            report_invalid_git_option('staging.' .. tostring(staging_key), 'unknown setting')
          end
        end
      end
    else
      report_invalid_git_option(tostring(key), 'unknown setting')
    end
  end
  local staging_options = value.staging
  if type(staging_options) == 'table' then
    for _, state in ipairs({ 'mixed_file', 'mixed_folder' }) do
      local override = staging_options[state]
      local resolved = result.staging[state]
      local inherited = vim.deepcopy(result.staging.staged)
      if type(override) == 'table' then
        for setting, setting_value in pairs(override) do
          if setting == 'icon_hl' or setting == 'text_hl' then
            if type(setting_value) == 'string' and setting_value ~= '' then
              inherited[setting] = resolved[setting]
            end
          elseif setting == 'icon' then
            if type(setting_value) == 'string' then
              inherited.icon = resolved.icon
            elseif type(setting_value) == 'table' then
              if type(inherited.icon) == 'string' then
                local glyph = inherited.icon
                inherited.icon = {
                  file = glyph,
                  folder = glyph,
                  folder_open = glyph,
                }
              else
                inherited.icon = vim.deepcopy(inherited.icon or {})
              end
              for kind, glyph in pairs(setting_value) do
                if (kind == 'file' or kind == 'folder' or kind == 'folder_open')
                  and type(glyph) == 'string' then
                  inherited.icon[kind] = resolved.icon[kind]
                end
              end
            end
          elseif setting == 'gutter' then
            if setting_value == false then
              inherited.gutter = nil
            elseif type(setting_value) == 'table' then
              inherited.gutter = vim.deepcopy(inherited.gutter or resolved.gutter or {})
              for key, gutter_value in pairs(setting_value) do
                if type(gutter_value) == 'string' and gutter_value ~= ''
                  and (key == 'highlight' or (key == 'symbol'
                    and vim.fn.strdisplaywidth(gutter_value) <= 2)) then
                  inherited.gutter[key] = resolved.gutter[key]
                end
              end
            end
          end
        end
      end
      result.staging[state] = inherited
    end
  end
  return result
end

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

-- The fourteen buffer-local mappings for filetype=direct buffers, owned
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
  { mode = 'n', lhs = 'u', rhs = '<Cmd>DirectUndo<CR>' },
  { mode = 'n', lhs = '<C-r>', rhs = '<Cmd>DirectRedo<CR>' },
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
  { mode = 'n', lhs = 'gh', rhs = '<Cmd>DirectToggleHidden<CR>' },
  { mode = 'n', lhs = 'ga', rhs = '<Cmd>DirectGit git add -- {}<CR>' },
  { mode = 'n', lhs = 'gr', rhs = '<Cmd>DirectGit git reset -- {}<CR>' },
  { mode = 'n', lhs = 'gc', rhs = '<Cmd>DirectGit git checkout -- {}<CR>' },
  { mode = 'n', lhs = 'gs', rhs = '<Cmd>DirectToggleGitStatus<CR>' },
}

-- The loaded buffers whose filetype is `direct`: the retrofit targets for
-- install/clear of the buffer-local maps.
local function open_direct_buffers()
  local bufs = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].filetype == constants.FILETYPE then
      bufs[#bufs + 1] = bufnr
    end
  end
  return bufs
end

-- install_buffer_mappings(bufnr) -> true. Installs the buffer-local
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
    pcall(vim.api.nvim_buf_call, target, function()
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
                entry.lhs, target, tostring(err)),
              vim.log.levels.WARN)
          end
        end
      end
      require('direct.folding').clear_mappings()
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
    require('direct.folding').install_mappings(bufnr, require('direct.buffer'))
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
    elseif key == 'max_recursive_expand_depth'
      and value ~= false
      and (type(value) ~= 'number' or value < 1 or value % 1 ~= 0) then
      require('direct.ui').notify(
        'direct: max_recursive_expand_depth must be false or a positive integer',
        vim.log.levels.ERROR)
    elseif key == 'icons' then
      next_options.icons = resolve_icon_options(value)
    elseif (key == 'show_hidden' or key == 'respect_gitignore')
      and type(value) ~= 'boolean' then
      require('direct.ui').notify(
        string.format('direct: %s must be a boolean', key), vim.log.levels.ERROR)
    elseif key == 'git' then
      next_options.git = resolve_git_options(value)
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
