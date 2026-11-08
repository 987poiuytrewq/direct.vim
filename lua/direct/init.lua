-- lua/direct/init.lua -- public API facade; dispatch and the direct-buffer guard.
-- Current-buffer operations require filetype=direct; listing and the explicit
-- `:DirectPaste {dir}` form are exempt because they do not operate on that buffer.

local M = {}

local buffer = require('direct.buffer')
local register = require('direct.register')
local history = require('direct.history')
local config = require('direct.config')
local ui = require('direct.ui')
local constants = require('direct.constants')
local pending = require('direct.pending')
local run = require('direct.run')

local function paste_and_refresh(destination, name)
  return register.paste(destination, name, function(result, _, _, changed, pasted_entry)
    if not changed then return end
    local ok, refresh_err = pcall(function()
      return buffer.restore():refresh_after_paste(destination,
        pasted_entry or (type(result) == 'string' and result or nil))
    end)
    if not ok then
      ui.report_error('refresh the directory after pasting', refresh_err)
    end
  end)
end

function M.setup(opts)
  return config.setup(opts)
end

local function guard(name)
  if vim.bo.filetype == constants.FILETYPE then
    return true
  end
  ui.notify('direct: ' .. name .. ' can only be used in a direct buffer',
    vim.log.levels.ERROR)
  return false
end

function M.list(path, options)
  if pending.refuse('list', 'willRenameFiles') then return nil end
  return buffer.list(path, options)
end

function M.list_buffer(options)
  if pending.refuse('list', 'willRenameFiles') then return nil end
  local root
  if vim.bo.buftype ~= '' then
    root = vim.fn.getcwd()
  else
    root = vim.fn.expand('%:p:h')
    if root == '' then
      root = vim.fn.getcwd()
    end
  end
  return buffer.list(root, options)
end

function M.list_cwd(options)
  if pending.refuse('list', 'willRenameFiles') then return nil end
  return buffer.list(vim.fn.getcwd(), options)
end

function M.open(line)
  if pending.refuse('open', 'willRenameFiles') then return nil end
  if not guard('open') then
    return nil
  end
  if line == nil then
    line = vim.fn.getline('.')
  end
  return buffer.restore():open(line)
end

function M.open_parent_expanded()
  local parent = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':h')
  local opened = M.list(parent)
  if not opened then return opened end
  return buffer.expand()
end

function M.sync()
  if not guard('DirectSync') then
    return nil
  end
  if pending.refuse('sync') then return nil end
  return buffer.restore():sync()
end

function M.fold_all()
  if not guard('DirectFoldAll') then return nil end
  return require('direct.folding').collapse_all(buffer)
end

function M.unfold_all()
  if not guard('DirectUnfoldAll') then return nil end
  return require('direct.folding').expand_all(buffer)
end

function M.toggle_hidden()
  if not guard('DirectToggleHidden') then return nil end
  if pending.refuse('toggle hidden entries') then return nil end
  return buffer.toggle_hidden()
end

function M.toggle_git_status()
  if not guard('DirectToggleGitStatus') then return nil end
  if pending.refuse('toggle Git-status filter') then return nil end
  return buffer.toggle_git_status()
end

function M.toggle_gitignore()
  if not guard('DirectToggleGitIgnore') then return nil end
  if pending.refuse('toggle Git-ignore filtering') then return nil end
  return buffer.toggle_gitignore()
end

function M.show_git_status()
  if not guard('DirectGitStatus') then return nil end
  if pending.refuse('show Git-status view') then return nil end
  return buffer.show_git_status()
end

function M.next_change()
  if not guard('DirectNextChange') then return nil end
  return buffer.next_change()
end

function M.previous_change()
  if not guard('DirectPreviousChange') then return nil end
  return buffer.previous_change()
end

function M.next_file()
  if not guard('DirectNextFile') then return nil end
  return buffer.next_file()
end

function M.previous_file()
  if not guard('DirectPreviousFile') then return nil end
  return buffer.previous_file()
end

function M.undo()
  if not guard('DirectUndo') then
    return nil
  end
  if pending.refuse('undo') then return nil end
  return history.undo_async(function(result)
    if result ~= nil then buffer.restore():list({ allow_modified = true }) end
  end)
end

function M.redo()
  if not guard('DirectRedo') then
    return nil
  end
  if pending.refuse('redo') then return nil end
  return history.redo_async(function(result)
    if result ~= nil then buffer.restore():list({ allow_modified = true }) end
  end)
end

-- The range is normalised so an upward visual selection works; a nil range means the current line.
function M.yank(first, last)
  if pending.refuse('yank') then return nil end
  if not guard('DirectYank') then
    return nil
  end
  local line = vim.fn.line('.')
  first = first or line
  last = last or line
  if first > last then
    first, last = last, first
  end
  local b = buffer.restore()
  local was_modified = vim.bo[vim.api.nvim_get_current_buf()].modified
  local sources, path_err = b:get_paths(first, last)
  if not sources then
    ui.notify('direct: cannot yank selection: ' .. tostring(path_err),
      vim.log.levels.ERROR)
    return nil, path_err
  end
  if #sources == 0 then return true end
  local yanked, yank_err = register.yank(sources)
  if not yanked then return nil, yank_err end
  if was_modified then return true end
  return b:list()
end

-- No argument pastes relative to the current row and refreshes the listing;
-- `{dir}` pastes elsewhere, unguarded.
function M.paste(dir)
  if pending.refuse('paste') then return nil end
  if dir == nil or dir == '' then
    if not guard('DirectPaste') then
      return nil
    end
    local b = buffer.restore()
    local destination, path_err = b:paste_destination()
    if destination == false then return true end
    if not destination then
      ui.notify('direct: cannot paste: ' .. tostring(path_err), vim.log.levels.ERROR)
      return nil, path_err
    end
    return paste_and_refresh(destination)
  end
  return register.paste(dir)
end

function M.paste_as(name)
  if pending.refuse('paste') then return nil end
  if not guard('DirectPasteAs') then
    return nil
  end
  local b = buffer.restore()
  local destination, path_err = b:paste_destination()
  if destination == false then return true end
  if not destination then
    ui.notify('direct: cannot paste: ' .. tostring(path_err), vim.log.levels.ERROR)
    return nil, path_err
  end
  return paste_and_refresh(destination, name)
end

function M.run(command)
  if not guard('DirectRun') then
    return nil
  end
  if pending.refuse('run a shell command') then return nil end
  return run.current_entry(command)
end

function M.git(command)
  if not guard('DirectGit') then
    return nil
  end
  if pending.refuse('run a Git command') then return nil end
  return run.current_entry(command, function(_, bufnr, root)
    buffer.refresh_git_status(bufnr, root)
  end, { quiet_success = true })
end

-- Public API functions are a final error boundary for both Lua callers and the
-- user commands/mappings that delegate to them. Expected failures are returned
-- normally by the implementations; only unexpected raised errors are reported
-- here, so a failure already handled by an operation does not produce a second
-- notification.
local protected_actions = {
  setup = 'apply the configuration',
  list = 'open the directory listing',
  list_buffer = "open the current buffer's directory",
  list_cwd = 'open the current working directory',
  open = 'open the selected entry',
  open_parent_expanded = 'open and expand the parent directory',
  sync = 'sync the directory listing',
  fold_all = 'collapse the expanded directories',
  unfold_all = 'expand the directories',
  toggle_hidden = 'toggle hidden entries',
  toggle_git_status = 'toggle the Git-status filter',
  toggle_gitignore = 'toggle Git-ignore filtering',
  show_git_status = 'show the Git-status view',
  next_change = 'navigate to the next changed entry',
  previous_change = 'navigate to the previous changed entry',
  next_file = 'navigate to the next file',
  previous_file = 'navigate to the previous file',
  undo = 'undo the last filesystem action',
  redo = 'redo the last filesystem action',
  yank = 'copy the selected entries to the Direct register',
  paste = 'paste the Direct register',
  paste_as = 'paste the Direct register with the requested name',
  run = 'run the command for the selected entry',
  git = 'run the Git command for the selected entry',
}

local pack = function(...) return { n = select('#', ...), ... } end
local unpack_values = table.unpack or unpack
for name, description in pairs(protected_actions) do
  local implementation = M[name]
  M[name] = function(...)
    local args, count = pack(...), select('#', ...)
    local result = pack(xpcall(function()
      return implementation(unpack_values(args, 1, count))
    end, debug.traceback))
    if not result[1] then
      return ui.report_error(description, result[2])
    end
    return unpack_values(result, 2, result.n)
  end
end

return M
