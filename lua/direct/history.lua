-- lua/direct/history.lua -- undo/redo over history/undo.log + redo.log.
--
-- Responsibility (spec section 5 / B6 / D13 / T-015): log(action), undo(),
-- redo() over whole-file logs under `<data_home>/direct/history` (resolved
-- through paths.data_dir('history'), the B9 nil, err shape). This module
-- never refreshes buffers (callers do).
--
-- Contract details:
--   * log(action) pushes action:serialize() onto undo.log and clears redo.log;
--   * undo() pops the last undo.log line, reverses it, executes it; on success
--     the serialized reversal is pushed onto redo.log and the B15 summary is
--     notified once; on failure the ORIGINAL line is pushed back onto its
--     source log (D13) and an error is notified;
--   * the `Nothing to undo` / `Nothing to redo` message belongs HERE, not to
--     log.pop, which returns nil silently on an empty log (T-008/T-015);
--   * data-dir failures (B9/O2) are captured and reported, never raised.
--
-- Version gate (T-017/D18). The Python predecessor wrote undo.log/redo.log in
-- the SAME data dir with a format whose separator information is destroyed when
-- the line is written, so no name-level guard can make a legacy line safe to
-- replay (a `p` line naming `my file.txt` splits back into `my` + `file.txt`
-- and an undo then deletes unrelated files). The Lua history therefore owns its
-- log format: the FIRST line of every log it writes is the version marker
-- `#direct-history-v2`, which is never a parseable action line. A log is
-- consumed only when its first line is the marker; an absent, empty or
-- marker-only log is simply empty history. A non-empty log whose first line is
-- NOT the marker is FOREIGN: no line is executed, a WARN is notified, and the
-- file is quarantined aside as `<name>.legacy` (or the first free
-- `<name>.legacy.<n>`). A foreign file is never appended to; when it cannot be
-- renamed it is left untouched and treated as no history.

local M = {}

-- The `direct.log` helper module. A plain local is safe here because the
-- public entry point of THIS module is also named `log` (B6), so a field
-- `M.log` cannot hold both; nothing in the suite stubs direct.log.
local log_mod = require('direct.log')
local fs = require('direct.fs')
M.action = require('direct.action')
M.paths = require('direct.paths')
M.ui = require('direct.ui')

-- The version marker: the FIRST line of every log this module writes. It starts
-- with '#', so `action.deserialize` can never mistake it for an entry (every
-- action name is a bare word), and no separator logic applies to it.
local MARKER = '#direct-history-v2'

-- log_paths() -> undo_path, redo_path | nil, err.
local function log_paths()
  local dir, err = M.paths.data_dir('history')
  if not dir then
    return nil, err
  end
  return M.paths.join(dir, 'undo.log'), M.paths.join(dir, 'redo.log')
end

local function notify_unavailable(err)
  M.ui.notify('direct: history unavailable: ' .. tostring(err),
    vim.log.levels.ERROR)
end

-- The one WARN a foreign log produces, on both the read and the write path.
local function notify_foreign()
  M.ui.notify('Ignoring history written by an older version',
    vim.log.levels.WARN)
end

-- quarantine(path) -> true | nil, err. Renames a foreign log aside so it can
-- never be executed: `<path>.legacy`, or the first free `<path>.legacy.<n>` when
-- that exists. A failed rename leaves the file in place (the caller then treats
-- it as no history and never appends to it). Never raises.
local function quarantine(path)
  local target = path .. '.legacy'
  local n = 1
  while fs.exists(target) do
    target = path .. '.legacy.' .. n
    n = n + 1
  end
  local ok, err = fs.rename(path, target)
  if not ok then
    return nil, err
  end
  return true
end

-- log_state(path) -> 'empty' | 'ready' | 'foreign'. `empty` covers an absent
-- file, a zero-line file and a marker-only file (all mean "no history").
-- `ready` means the marker is the first line and at least one entry follows.
-- `foreign` means the file holds content this versioned history did not write.
local function log_state(path)
  local lines = log_mod.read(path)
  if #lines == 0 then
    return 'empty'
  end
  if lines[1] ~= MARKER then
    return 'foreign'
  end
  if #lines == 1 then
    return 'empty'
  end
  return 'ready'
end

-- prepare(path) -> true | nil, err. Puts `path` in a state where a
-- marker-prefixed entry may be appended: an absent/empty file is (re)created
-- with the marker, a ready file is left as is, and a foreign file is quarantined
-- aside first (with the WARN). Returns nil, err when a foreign file cannot be
-- quarantined, so the caller never appends to a foreign log.
local function prepare(path)
  local state = log_state(path)
  if state == 'ready' then
    return true
  end
  if state == 'foreign' then
    notify_foreign()
    local ok, err = quarantine(path)
    if not ok then
      return nil, err
    end
  end
  return log_mod.write(path, { MARKER })
end

-- append_entry(path, line) -> true | nil, err. Ensures the marker is the first
-- line, then appends one entry after it.
local function append_entry(path, line)
  local ok, err = prepare(path)
  if not ok then
    return nil, err
  end
  return log_mod.push(path, line)
end

-- log(action) -> true | nil, err. B6: an undo entry is pushed and redo is
-- cleared (a new action invalidates the redo branch).
function M.log(action)
  local undo_path, redo_path = log_paths()
  if not undo_path then
    notify_unavailable(redo_path)
    return nil, redo_path
  end
  if type(action) ~= 'table' then
    return nil, 'history.log: an action is required'
  end
  local line, serr = M.action.serialize(action)
  if not line then
    M.ui.notify('direct: cannot write history: ' .. tostring(serr),
      vim.log.levels.ERROR)
    return nil, serr
  end
  local ok, perr = append_entry(undo_path, line)
  if not ok then
    M.ui.notify('direct: cannot write history: ' .. tostring(perr),
      vim.log.levels.ERROR)
    return nil, perr
  end
  -- A new action invalidates the redo branch. The redo log is reset to its
  -- marker-only (empty-history) state rather than plain `{}`, so it stays
  -- Lua-owned and a later marker check is unambiguous. `prepare` runs FIRST so a
  -- FOREIGN redo log (D18/T-017) is quarantined aside instead of being silently
  -- clobbered by the marker write; a failure to prepare or to write is reported
  -- rather than swallowed (P2-NB1/NB4), so the caller still sees the new action
  -- as logged while the reset failure is surfaced.
  local pok, prep_err = prepare(redo_path)
  if not pok then
    M.ui.notify('direct: cannot write history: ' .. tostring(prep_err),
      vim.log.levels.ERROR)
    return nil, prep_err
  end
  local wok, werr = log_mod.write(redo_path, { MARKER })
  if not wok then
    M.ui.notify('direct: cannot write history: ' .. tostring(werr),
      vim.log.levels.ERROR)
    return nil, werr
  end
  return true
end

function M.undo()
  return M._reverse('undo')
end

function M.redo()
  return M._reverse('redo')
end

-- _reverse(which) -> the executed reversal | nil (empty log) | nil, err.
-- `which` is 'undo' or 'redo'; the source log is the one named by it and the
-- destination log receives the serialized reversal on success.
function M._reverse(which)
  local undo_path, redo_path = log_paths()
  if not undo_path then
    notify_unavailable(redo_path)
    return nil, redo_path
  end
  local src_path, dst_path
  if which == 'undo' then
    src_path, dst_path = undo_path, redo_path
  else
    src_path, dst_path = redo_path, undo_path
  end

  local state = log_state(src_path)
  if state == 'empty' then
    -- Absent, empty or marker-only: this is the T-008 case -- pop() would
    -- return nil silently, so the message belongs to this caller.
    M.ui.notify(which == 'undo' and 'Nothing to undo' or 'Nothing to redo',
      vim.log.levels.INFO)
    return nil
  end
  if state == 'foreign' then
    -- A log this version did not write. Execute NOTHING; quarantine it aside
    -- so the data survives but is inert. A failed rename leaves the file in
    -- place -- still no line is executed, and nothing is ever appended to it.
    notify_foreign()
    quarantine(src_path)
    return nil
  end

  local line, pop_err = log_mod.pop(src_path)
  if line == nil then
    if pop_err ~= nil then
      M.ui.notify('Failed to ' .. which .. ' action: ' .. tostring(pop_err),
        vim.log.levels.ERROR)
      return nil, pop_err
    end
    -- The log drained between the state read and the pop (single-threaded
    -- here, but a concurrent writer is possible): treat it as empty.
    M.ui.notify(which == 'undo' and 'Nothing to undo' or 'Nothing to redo',
      vim.log.levels.INFO)
    return nil
  end

  local rev, rev_err = M.action.reverse(line)
  if not rev then
    -- A line we cannot parse must not be lost either (D13 spirit).
    log_mod.push(src_path, line)
    M.ui.notify('Failed to ' .. which .. ' action - ' .. tostring(rev_err),
      vim.log.levels.ERROR)
    return nil, rev_err
  end

  local ok, result = pcall(rev['do'])
  if ok and result ~= nil then
    -- The reversal is recorded on the destination log. `append_entry` keeps the
    -- marker first and refuses to append to a foreign file.
    local wok, werr = append_entry(dst_path, M.action.serialize(rev))
    if not wok then
      M.ui.notify('Failed to ' .. which .. ' action - cannot write history: '
        .. tostring(werr), vim.log.levels.ERROR)
    end
    -- B15: exactly one joined summary of the executed reversal.
    M.ui.notify(M.action.summarize({ rev }), vim.log.levels.INFO)
    return rev
  end

  -- D13: a failed reversal pushes the original line back onto its source log
  -- (the Python version silently dropped it).
  log_mod.push(src_path, line)
  local why = ok and 'action failed' or tostring(result)
  M.ui.notify('Failed to ' .. which .. ' action - '
    .. M.action.summarize({ rev }) .. ' (' .. why .. ')',
    vim.log.levels.ERROR)
  return nil, why
end

return M