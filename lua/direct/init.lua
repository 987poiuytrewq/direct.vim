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
      ui.notify('direct: re-list failed: ' .. tostring(refresh_err),
        vim.log.levels.ERROR)
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

function M.list(path)
  if pending.refuse('list', 'willRenameFiles') then return nil end
  return buffer.list(path)
end

function M.list_buffer()
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
  return buffer.list(root)
end

function M.list_cwd()
  if pending.refuse('list', 'willRenameFiles') then return nil end
  return buffer.list(vim.fn.getcwd())
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
  local opened = M.open('../')
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

function M.undo()
  if not guard('DirectUndo') then
    return nil
  end
  if pending.refuse('undo') then return nil end
  return history.undo_async(function()
    buffer.restore():list()
  end)
end

function M.redo()
  if not guard('DirectRedo') then
    return nil
  end
  if pending.refuse('redo') then return nil end
  return history.redo_async(function()
    buffer.restore():list()
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
  local sources, path_err = b:get_paths(first, last)
  if not sources then
    ui.notify('direct: cannot yank selection: ' .. tostring(path_err),
      vim.log.levels.ERROR)
    return nil, path_err
  end
  if #sources == 0 then return true end
  local yanked, yank_err = register.yank(sources)
  if not yanked then return nil, yank_err end
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

return M
