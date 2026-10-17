-- lua/direct/init.lua -- public API facade (spec section 6 / T-024).
--
-- Responsibility (spec section 5): setup, list, list_buffer, list_cwd, open,
-- sync, undo, redo, yank, paste, paste_as, plus the direct-buffer guard that
-- the command surface (plugin/direct.lua) delegates to. This module holds no
-- logic beyond dispatch and the guard messages.
--
-- Guard (section 6): DirectUndo / DirectRedo / DirectYank / DirectPaste /
-- DirectPasteAs must notify an ERROR and do nothing when the current buffer is
-- not a direct buffer (`&filetype !=# 'direct'`). The single exemption is the
-- **`:DirectPaste {dir}`** form (B7/N6): it pastes into an explicitly named
-- directory and never touches the current buffer, so it is not guarded. The
-- no-arg `:DirectPaste` IS guarded -- it pastes into the current buffer's root.
-- `DirectSync` is deliberately NOT in section 6's guarded list, so it is not
-- guarded here either; bound to `BufWriteCmd` it only runs in a direct buffer.
--
-- NB6 (P3 carry-forward): the register's swappable re-list hook
-- (`register.relist`, B7/N6) is wired here to the real buffer re-list:
-- `require('direct.buffer').restore():list()`. Wiring at facade load keeps the
-- closure out of `register.lua` ("no buffer code lives here", section 5) while
-- still making the no-arg `:DirectPaste` refresh the current listing.

local M = {}

local buffer = require('direct.buffer')
local register = require('direct.register')
local history = require('direct.history')
local config = require('direct.config')
local ui = require('direct.ui')

-- NB6: the no-arg `:DirectPaste` form (relist_flag == true) calls this after a
-- successful paste; the `:DirectPaste {dir}` form never does (B7/N6).
register.relist = function()
  return require('direct.buffer').restore():list()
end

-- setup(opts) -> the resolved option table (section 6). Optional; idempotent;
-- later calls replace the option table and re-apply mappings.
function M.setup(opts)
  return config.setup(opts)
end

-- guard(name) -> true when the current buffer is a direct buffer, else notify an
-- ERROR naming the command and return false (section 6).
local function guard(name)
  if vim.bo.filetype == 'direct' then
    return true
  end
  ui.notify('direct: ' .. name .. ' can only be used in a direct buffer',
    vim.log.levels.ERROR)
  return false
end

-- list(path) -> attach/create the direct buffer for `path` and list it.
function M.list(path)
  return buffer.list(path)
end

-- list_buffer() -> list the parent directory of the current file, or getcwd()
-- when the buffer has no file name (`&buftype ~= ''`, section 6).
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

-- list_cwd() -> list the current working directory.
function M.list_cwd()
  return buffer.list(vim.fn.getcwd())
end

-- open([line]) -> open the entry under the cursor (default) or the given line,
-- relative to the current direct buffer's root (B8/D8b).
function M.open(line)
  if line == nil then
    line = vim.fn.getline('.')
  end
  return buffer.restore():open(line)
end

-- sync() -> run the B4/B5 sync classification on the current buffer (bound to
-- BufWriteCmd). Not guarded (section 6); outside a direct buffer
-- `Buffer.restore()` resolves to a root the listing cannot read and reports.
function M.sync()
  return buffer.restore():sync()
end

-- undo() -> reverse the last filesystem action, then re-list the current buffer
-- (B6 parity). Guarded.
function M.undo()
  if not guard('DirectUndo') then
    return nil
  end
  history.undo()
  return buffer.restore():list()
end

-- redo() -> re-apply the last undone action, then re-list (B6). Guarded.
function M.redo()
  if not guard('DirectRedo') then
    return nil
  end
  history.redo()
  return buffer.restore():list()
end

-- yank(first, last) -> yank the ranged entries into the register (B7). The
-- range is normalised so a visual selection made upwards works too; no range
-- (nil) means the current line. The buffer is re-listed afterwards (parity).
-- Guarded.
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
  local sources, path_err = b:get_paths(first, last)
  if not sources then
    ui.notify('direct: cannot yank selection: ' .. tostring(path_err),
      vim.log.levels.ERROR)
    return nil, path_err
  end
  register.yank(sources)
  return b:list()
end

-- paste(dir) -> the two `:DirectPaste` forms (B7/N6). With no argument it
-- pastes into the current buffer's root and RE-LISTS (guarded); with an explicit
-- `{dir}` it pastes into that directory and does NOT re-list (exempt from the
-- direct-buffer guard).
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

-- paste_as(name) -> paste into the current buffer's root as `{name}` and
-- re-list (B7). Guarded.
function M.paste_as(name)
  if not guard('DirectPasteAs') then
    return nil
  end
  local b = buffer.restore()
  return register.paste(b.root, true, name)
end

return M
