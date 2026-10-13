-- lua/direct/init.lua -- public API facade; dispatch and the direct-buffer guard.
-- The `:DirectPaste {dir}` form is deliberately exempt from that guard (it never
-- touches the current buffer); every other mutating command requires filetype=direct.

local M = {}

local buffer = require('direct.buffer')
local register = require('direct.register')
local history = require('direct.history')
local config = require('direct.config')
local ui = require('direct.ui')

-- Wired here so the no-arg `:DirectPaste` re-lists without register.lua touching buffers.
register.relist = function()
  return require('direct.buffer').restore():list()
end

function M.setup(opts)
  return config.setup(opts)
end

local function guard(name)
  if vim.bo.filetype == 'direct' then
    return true
  end
  ui.notify('direct: ' .. name .. ' can only be used in a direct buffer',
    vim.log.levels.ERROR)
  return false
end

function M.list(path)
  return buffer.list(path)
end

function M.list_buffer()
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
  return buffer.list(vim.fn.getcwd())
end

function M.open(line)
  if line == nil then
    line = vim.fn.getline('.')
  end
  return buffer.restore():open(line)
end

-- Intentionally not guarded: bound to BufWriteCmd it only runs in a direct buffer.
function M.sync()
  return buffer.restore():sync()
end

function M.undo()
  if not guard('DirectUndo') then
    return nil
  end
  history.undo()
  return buffer.restore():list()
end

function M.redo()
  if not guard('DirectRedo') then
    return nil
  end
  history.redo()
  return buffer.restore():list()
end

-- The range is normalised so an upward visual selection works; a nil range means the current line.
function M.yank(first, last)
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
  local sources = b:get_paths(first, last)
  register.yank(sources)
  return b:list()
end

-- No argument pastes into the current buffer's root and re-lists; `{dir}` pastes elsewhere, unguarded.
function M.paste(dir)
  if dir == nil or dir == '' then
    if not guard('DirectPaste') then
      return nil
    end
    local b = buffer.restore()
    return register.paste(b.root, true)
  end
  return register.paste(dir, false)
end

function M.paste_as(name)
  if not guard('DirectPasteAs') then
    return nil
  end
  local b = buffer.restore()
  return register.paste(b.root, true, name)
end

return M
