-- lua/direct/register.lua -- persistent yank/paste register.
-- Names and destinations are checked before copying; skipped entries are reported.
-- Buffer refresh is delegated through the swappable M.relist hook.

local M = {}

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.action = require('direct.action')
M.history = require('direct.history')
M.log = require('direct.log')
M.ui = require('direct.ui')

-- Called after a successful no-argument paste; the `{dir}` form never re-lists.
M.relist = nil

-- content -> the absolute register path recorded in register/content (the
-- yanked entry directory), or nil when no yank has happened, or nil, err when
-- the register data dir cannot be resolved.
function M.content()
  local dir = M.paths.data_dir_path('register')
  local content_path = M.paths.join(dir, 'content')
  if vim.fn.filereadable(content_path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, content_path)
  if not ok or type(lines) ~= 'table' or #lines == 0 then
    return nil
  end
  return lines[1]
end

-- yank(sources) -> true | nil, err. `sources` is a list of absolute paths.
function M.yank(sources)
  if type(sources) ~= 'table' then
    return nil, 'register.yank: a list of sources is required'
  end
  -- Validate all user paths, source existence, and basename components before
  -- classifying logs: a refused yank must not reset recognized legacy history.
  for _, src in ipairs(sources) do
    local valid, path_err = M.paths.validate_canonical_path(src)
    if not valid then
      local message = 'cannot yank: ' .. tostring(path_err)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    local st = M.fs.stat(src)
    if not st then
      local message = 'cannot yank: ' .. tostring(src)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
    local name = M.fs.basename(M.fs.abspath(src))
    local reason = M.action.entry_name_reason(name)
    if reason ~= nil then
      local msg = 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
      return nil, msg
    end
  end
  local preflight, preflight_err = M.history.preflight(sources)
  if not preflight then return nil, preflight_err end
  local dir, err = M.paths.ensure_data_dir('register')
  if not dir then
    M.ui.notify('direct: register unavailable: ' .. tostring(err),
      vim.log.levels.ERROR)
    return nil, err
  end
  local sorted = vim.deepcopy(sources)
  table.sort(sorted)
  local dst = M.paths.join(dir, M.paths.digest(sorted))
  if not M.fs.exists(dst) then
    local ok, merr = M.fs.mkdirp(dst)
    if not ok then
      return nil, merr
    end
  end
  for _, src in ipairs(sources) do
    -- _yank_one returns true[, skipped] on success and nil, err on failure.
    local ok, skipped = M._yank_one(dst, src)
    if not ok then
      return nil, skipped
    end
    -- Report each raw source path in input order.
    M.ui.notify('Yanked ' .. src, vim.log.levels.INFO)
    -- Yank destroys nothing, so skip unsupported entries rather than fail the
    -- whole operation, but report every omission.
    local n = skipped ~= nil and #skipped or 0
    if n > 0 then
      M.ui.notify('Skipped ' .. n .. ' ' .. (n == 1 and 'entry' or 'entries')
        .. ' that cannot be copied: ' .. src, vim.log.levels.WARN)
    end
  end
  local ok, werr = M.log.write(M.paths.join(dir, 'content'), { dst })
  if not ok then
    return nil, werr
  end
  return true
end

-- _yank_one(dst, src) -> true[, skipped] | nil, err. Copies one source into the
-- register entry directory, replacing an existing entry of the same name: files
-- via copy_file (which overwrites), directories by removing the stale entry and
-- re-copying the tree so no stale members survive a re-yank. A directory copy is
-- best-effort (copy_tree without require_complete): the sources stay in place
-- so an entry that cannot be reproduced is reported to the caller (`skipped`)
-- instead of failing the yank.
function M._yank_one(dst, src)
  local st = M.fs.stat(src)
  if not st then
    return nil, 'cannot yank: ' .. tostring(src)
  end
  local name = M.fs.basename(M.fs.abspath(src))
  if name == nil or name == '' then
    return nil, 'cannot yank: no basename for ' .. tostring(src)
  end
  -- A space splits p/up name lists after reload; a tab splits history fields.
  -- Either could make undo target unrelated paths, so reject the name before it
  -- enters the register (yank also validates before creating the digest dir).
  local reason = M.action.entry_name_reason(name)
  if reason ~= nil then
    local msg = 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)
    M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
    return nil, msg
  end
  local entry = M.paths.join(dst, name)
  if st.type == 'file' then
    return M.fs.copy_file(src, entry)
  elseif st.type == 'directory' then
    if M.fs.exists(entry) then
      local ok, err = M.fs.rm_tree(entry)
      if not ok then
        return nil, err
      end
    end
    return M.fs.copy_tree(src, entry)
  end
  return nil, 'cannot yank: unsupported entry type for ' .. tostring(src)
end

-- paste(dst, relist_flag[, name]) -> the last pasted entry | true | nil |
-- nil, err. relist_flag distinguishes the two `:DirectPaste` forms
-- true for the no-arg form (pastes into the buffer root and re-lists via
-- M.relist), false for `:DirectPaste {dir}` (never re-lists).
--
-- `name` is the `:DirectPasteAs {name}` extension: when given, the
-- first pasted entry (the smallest source name, matching Paste's sorted
-- `renames`) is pasted as `name` instead. The extension is additive -- the three
-- existing call shapes (`paste(dst)`, `paste(dst, true)`, `paste(dst, false)`)
-- are unchanged.
function M.paste(dst, relist_flag, name)
  local valid, path_err = M.paths.validate_path(dst)
  if not valid then
    M.ui.notify('direct: cannot paste: ' .. tostring(path_err), vim.log.levels.ERROR)
    return nil, path_err
  end
  if name ~= nil and name ~= '' then
    local name_err = M.action.entry_name_reason(name)
    if name_err then
      local message = 'cannot paste: entry name ' .. name_err .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. message, vim.log.levels.ERROR)
      return nil, message
    end
  end
  dst = M.paths.root(dst)
  local preflight, preflight_err = M.history.preflight({ dst })
  if not preflight then return nil, preflight_err end
  local src, cerr = M.content()
  if src == nil then
    if cerr ~= nil then
      M.ui.notify('direct: register unavailable: ' .. tostring(cerr),
        vim.log.levels.ERROR)
      return nil, cerr
    end
    M.ui.notify('Register is empty', vim.log.levels.WARN)
    return nil
  end
  local names = M.fs.list_dir(src)
  if not names then
    M.ui.notify('direct: cannot read register: ' .. tostring(src),
      vim.log.levels.ERROR)
    return nil, 'cannot read register'
  end
  -- The persisted register is untrusted. Validate each entry as one basename
  -- component before building the JSONL record or copying it.
  local pasteable = {}
  for _, name in ipairs(names) do
    local reason = M.action.entry_name_reason(name)
    if reason ~= nil then
      M.ui.notify('direct: skipping register entry (' .. reason .. '): '
        .. tostring(name), vim.log.levels.ERROR)
    else
      pasteable[#pasteable + 1] = name
    end
  end
  if #pasteable == 0 then
    -- Do not build a no-op action when filtering leaves nothing: it would claim
    -- a paste succeeded and create a history entry that names no files.
    M.ui.notify('Nothing to paste', vim.log.levels.WARN)
    return nil
  end
  -- `:DirectPasteAs {name}` renames the first pasted entry (the smallest source
  -- name, which is the first pair Paste's sorted `renames` walks).
  local dst_names = vim.deepcopy(pasteable)
  if name ~= nil and name ~= '' then
    local name_reason = M.action.entry_name_reason(name)
    if name_reason ~= nil then
      local msg = 'cannot paste: entry name ' .. name_reason .. ': '
        .. tostring(name)
      M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
      return nil, msg
    end
    dst_names[1] = name
  end
  local paste_action = M.action.Paste(src, dst, pasteable, dst_names)
  -- Validate the exact record before copying; a malformed path must not create
  -- a destination that cannot be undone.
  local _, unsafe = M.action.serialize(paste_action)
  if unsafe ~= nil then
    local msg = 'cannot paste: unrepresentable path: ' .. tostring(unsafe)
    M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
    return nil, msg
  end
  local ok, result = pcall(M.action.execute, paste_action)
  if not ok or result == nil then
    local why = ok and 'action returned nil' or tostring(result)
    M.ui.notify('Failed to paste: ' .. tostring(why), vim.log.levels.ERROR)
    return nil, result
  end
  -- Success (order): notify the summary once, then log history.
  M.ui.notify(M.action.summarize({ paste_action }), vim.log.levels.INFO)
  M.history.log(paste_action)
  if relist_flag and type(M.relist) == 'function' then
    local rok, rerr = pcall(M.relist)
    if not rok then
      M.ui.notify('direct: re-list failed: ' .. tostring(rerr),
        vim.log.levels.ERROR)
    end
  end
  return result
end

return M
