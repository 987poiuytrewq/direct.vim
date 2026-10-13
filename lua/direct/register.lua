-- lua/direct/register.lua -- persistent yank/paste register.
-- Names are validated before storage and again when read; paste destinations
-- are checked before copying. Non-destructive copies report skipped entries.
-- This module does not access buffers; M.relist is the swappable refresh hook.

local M = {}

-- Entry-name validation is owned by action.entry_name_reason (the single
-- source of truth): a name carrying the ' ' ENTRY_SEPARATOR -- the join
-- separator of the serialized p/up name lists (Python ENTRY_SEPARATOR parity
-- action.serialize) -- or the '\t' FIELD_SEPARATOR (the NAME\tfield... line
-- separator) cannot round-trip, so both are refused at the yank boundary
--  and at the Paste clash answer .

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.action = require('direct.action')
M.history = require('direct.history')
M.ui = require('direct.ui')

-- relist: function field, nil until wires the command surface to the real
-- buffer re-list. Called by paste(dst, true) after a successful paste; the
-- `{dir}`-form paste never calls it.
M.relist = nil

-- content -> the absolute register path recorded in register/content (the
-- yanked entry directory), or nil when no yank has happened, or nil, err when
-- the register data dir cannot be resolved.
function M.content()
  local dir, err = M.paths.data_dir('register')
  if not dir then
    return nil, err
  end
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
  local dir, err = M.paths.data_dir('register')
  if not dir then
    M.ui.notify('direct: register unavailable: ' .. tostring(err),
      vim.log.levels.ERROR)
    return nil, err
  end
  -- validate every entry name BEFORE the first write (the digest mkdirp
  -- below), so a refused yank -- space / tab, decided by
  -- action.entry_name_reason -- leaves no stray register digest dir behind.
  -- Each source must also exist, or the yank fails before anything is copied.
  for _, src in ipairs(sources) do
    local st = M.fs.stat(src)
    if not st then
      return nil, 'cannot yank: ' .. tostring(src)
    end
    local name = M.fs.basename(M.fs.abspath(src))
    local reason = M.action.entry_name_reason(name)
    if reason ~= nil then
      local msg = 'cannot yank: entry name ' .. reason .. ': ' .. tostring(name)
      M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
      return nil, msg
    end
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
    -- the raw source path, one line per source, in input order.
    M.ui.notify('Yanked ' .. src, vim.log.levels.INFO)
    -- follow-up : a yank destroys nothing, so an entry the copy
    -- cannot reproduce (a symlink, a FIFO, an unreadable directory) is skipped
    -- rather than failing the yank -- but it must not vanish silently either.
    local n = skipped ~= nil and #skipped or 0
    if n > 0 then
      M.ui.notify('Skipped ' .. n .. ' ' .. (n == 1 and 'entry' or 'entries')
        .. ' that cannot be copied: ' .. src, vim.log.levels.WARN)
    end
  end
  local ok, werr = pcall(vim.fn.writefile, { dst }, M.paths.join(dir, 'content'))
  if not ok then
    return nil, tostring(werr)
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
  -- an entry name carrying the ' ' ENTRY_SEPARATOR or the '\t'
  -- FIELD_SEPARATOR cannot round-trip through the p/up serialization
  -- (action.entry_name_reason): a space would split into two names on reload
  -- and desync the renames lists, letting Unpaste delete an unrelated file; a
  -- tab would break the `NAME\tfield...` line framing. Refuse it here, before
  -- it can enter the register (yank also pre-validates so no digest dir is
  -- created; this keeps a direct _yank_one caller just as safe).
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
-- `name`  is the `:DirectPasteAs {name}` extension: when given, the
-- first pasted entry (the smallest source name, matching Paste's sorted
-- `renames`) is pasted as `name` instead. The extension is additive -- the three
-- existing call shapes (`paste(dst)`, `paste(dst, true)`, `paste(dst, false)`)
-- are unchanged.
function M.paste(dst, relist_flag, name)
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
  -- the register dir is PERSISTED, untrusted data. The Python
  -- predecessor wrote entry names here with no validation into the SAME dir
  -- (the Python-era register module), so a legacy name carrying the ' '
  -- ENTRY_SEPARATOR (or a control char) exists on disk even though Lua refuses
  -- to WRITE one. Feeding such a name to action.Paste would enter it in
  -- `renames` and serialize a ' '-joined undo line that splits into two names
  -- on reload, so Unpaste would delete an unrelated file in the paste
  -- destination. Validate every name BEFORE the Paste is built: keep only the
  -- separator-free names that can actually round-trip, and notify on each
  -- dropped one.
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
    -- nothing survived filtering (a legacy dir whose every entry carries a
    -- separator/control char, or an empty listing). Do NOT build a no-op Paste
    -- it would claim `Pasted into <dir>/` and log a `p\t...\t\t` history line
    -- that names nothing and arms a pointless undo. Report and stop.
    M.ui.notify('Nothing to paste', vim.log.levels.WARN)
    return nil
  end
  -- `:DirectPasteAs {name}` renames the FIRST pasted entry (the
  -- smallest source name, which is the first pair Paste's sorted `renames`
  -- walks). The name must be representable for the same reason a yanked name
  -- must: a ' ' would split the dst name list and a '\t' would break the line.
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
  -- this is the SECOND ingress into the `NAME\tfield...` framing.
  -- The register entry NAMES above are validated, but the destination `dst` is
  -- not: a destination such as `de<TAB>st` would serialize into a corrupted
  -- line, `deserialize` would split it into extra fields, the reversal would
  -- target a nonexistent path (a silent no-op whose message still claimed
  -- success) and a second undo would desync differently. Refuse through the
  -- SAME `action.serialize` guard the persisted undo line will itself pass
  -- BEFORE any copy: nothing is written and no history line is produced.
  local _, unsafe = M.action.serialize(paste_action)
  if unsafe ~= nil then
    local msg = 'cannot paste: unrepresentable path: ' .. tostring(unsafe)
    M.ui.notify('direct: ' .. msg, vim.log.levels.ERROR)
    return nil, msg
  end
  local ok, result = pcall(paste_action['do'])
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