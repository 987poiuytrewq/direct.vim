-- lua/direct/action.lua -- filesystem actions, serialize/reverse, trash naming.
--
-- Responsibility (spec section 5): the action table, serialize, deserialize,
-- reverse, human descriptions, trash naming, Paste/Unpaste multi-actions, and
-- the B15 joined-summary helper. Modules DO NOT touch history or register
-- directly (history is pushed by callers, as the Python version did).
--
-- Contracts implemented here (spec B5/B6/B7/B10/B15, section 9 D12-D17):
--   * serialization is `NAME\tfield...` (FIELD_SEPARATOR = '\t'), with the
--     `p`/`up` multi-actions appending two ' '-joined name lists (parity with
--     the Python ENTRY_SEPARATOR). A name containing a space cannot round-trip
--     (the name list would desync on reload and Unpaste could then delete an
--     unrelated file), and a name containing the '\t' FIELD_SEPARATOR would
--     break the line framing itself. `serialize` itself refuses to emit a line
--     whose field values carry a '\t' or any other control character
--     (`path_reason`, B2/P2-NB2), so EVERY caller that persists a line --
--     including `history.log` -- is covered, not only the sync boundary.
--     `entry_name_reason` guards the boundaries
--     that feed a name into the serialization: the register yank refusal
--     (`register.yank`/`_yank_one`, B2/N2) and the Paste clash answer (B3/N2 --
--     a separator-carrying answer is treated like the empty/cancelled answer and
--     skips the entry). `deserialize`/`reverse_action` rebuild actions from
--     PERSISTED log fields and therefore trust their input; that is safe only
--     because the history log is Lua-owned and version-marked (T-017/D18), so
--     every serialized name is separator-free by construction -- it is NOT
--     re-validated here;
--   * `reverse` swaps src/dst and inverts the renames per the exact
--     action<->reversal mapping (T-014; follows the Python REVERSALS table);
--   * trash naming is `<digest(src)>` with the first free `-<n>` suffix (B10/
--     D16), and the chosen path is stored in `dst` so Restore reverses to the
--     exact entry; a Restore/RestoreDirectory leaves an empty marker (file /
--     directory) at the freed slot so remove/restore/remove yields two sibling
--     entries (`digest` marker + `digest-1` content) with no nesting;
--   * `Paste` iterates entries in sorted order (D17/R19), prompts through
--     `ui.prompt` for a clash, and an empty/cancelled answer skips the entry
--     and reports it (D8a) instead of overwriting it;
--   * a mid-paste copy failure returns `nil, err` BEFORE `self.renames =
--     copied` (action.Paste 'do'), leaving the entries already copied by that
--     same Paste on disk with NO history entry -- the caller logs history only
--     on success. This is intentional and B5-consistent: history never records
--     a reversal for entries that were never written, and never half-reverses
--     a batch that only partly landed;
--   * the same `entry_name_reason` validator also refuses a name carrying any
--     other control character (an embedded NL included, O2), not just the two
--     serialization separators, so the round trip cannot depend on
--     `vim.fn.writefile`'s NUL encoding of a NL;
--   * every description is CWD-relative (`fnamemodify <path> :.`), the Python
--     `relpath` equivalent (B15/N8).
--
-- Never-raise rule: every executed action returns `true` (or the last created
-- entry for `Paste`) on success and `nil, err` on failure; `deserialize` /
-- `reverse` return `nil, err` for a malformed or unknown line.
--
-- Dependency rule (section 8 / D2 + D9): cross-module calls go through the
-- module tables (`M.fs.rename`, `M.ui.prompt`, `M.paths.data_dir`), so a harness
-- stub on `fs`, `ui.prompt` or `paths` is honoured.

local M = {}

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.ui = require('direct.ui')

local FIELD_SEPARATOR = '\t'

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- rel(path) -> the CWD-relative spelling of a path (B15/N8), the Lua
-- equivalent of Python's os.path.relpath. `:p:.` resolves the path first so a
-- lexical mismatch (e.g. /tmp vs /private/tmp) cannot suppress the relative
-- form; a path equal to the cwd yields '.', matching Python's relpath(cwd).
-- `:p` appends a trailing slash to directories, which Python's relpath never
-- does, so it is stripped: a directory description is 'Removed tree', never
-- 'Removed tree/' (Paste's describe adds its own separator).
function M.rel(path)
  if type(path) ~= 'string' then
    return tostring(path)
  end
  local rel = vim.fn.fnamemodify(path, ':p:.')
  if rel == '' then
    return '.'
  end
  rel = rel:gsub('/+$', '')
  if rel == '' then
    return '/'
  end
  return rel
end

-- close_src_buffer(src) -> true | nil, err. Closes every buffer whose name
-- denotes the same path as `src` (fs.same_path, spelling-independent) before a
-- destructive action, matching the Python `_close_src_buffer`. Pure defence and
-- parity: nothing here may raise, so every buffer API call is pcall-guarded.
function M.close_src_buffer(src)
  if type(src) ~= 'string' then
    return true
  end
  local ok = pcall(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' then
        local same = M.fs.same_path(name, src)
        if same then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
    end
  end)
  if not ok then
    return nil, 'failed to close source buffers'
  end
  return true
end

-- first_free_trash(trash_dir, src) -> `<trash>/<digest(src)>` or the first
-- free `<digest>-<n>` when that path already exists (B10/D16). The result is
-- persisted in the action's `dst` field and serialized, so `Restore` always
-- reverses to the exact entry.
function M.first_free_trash(trash_dir, src)
  local base = M.paths.digest(src)
  local dst = M.fs.join(trash_dir, base)
  if not M.fs.exists(dst) then
    return dst
  end
  local n = 1
  while M.fs.exists(dst .. '-' .. n) do
    n = n + 1
  end
  return dst .. '-' .. n
end

-- split_names(str) -> the entry-name list of a serialized `p`/`up` field.
-- Empty fields deserialize to an empty list (Python `''.split(' ')` yields
-- ['']); an empty name can never be a real entry, so it is dropped here.
function M.split_names(str)
  if type(str) ~= 'string' then
    return {}
  end
  return vim.split(str, ' ', { plain = true, trimempty = true })
end

-- entry_name_reason(name) -> nil when `name` can round-trip through the `p`/
-- `up` serialization, else a short reason: 'empty' | 'contains a space' |
-- 'contains a tab' | 'contains a control character'. A name carrying the ' '
-- ENTRY_SEPARATOR would split into two names on reload and desync the src/dst
-- name lists, letting Unpaste delete an unrelated file (B2/B3); a name
-- carrying the '\t' FIELD_SEPARATOR would break the `NAME\tfield...` line
-- framing itself (N2); and any OTHER control character -- most importantly an
-- embedded '\n' -- is refused too (O2), so the log round trip never depends on
-- `vim.fn.writefile` encoding a NL as NUL to keep the line framing intact.
-- This is the validator for the boundaries that feed a name into the
-- serialization: register.yank / _yank_one refuse such a name before it can
-- enter the register, and Paste refuses a separator-carrying clash answer
-- exactly like an empty/cancelled one (B3/N2). `deserialize` deliberately does
-- not re-validate: it only ever rebuilds actions from the Lua-owned,
-- version-marked history log, where a separator-free name is guaranteed by
-- construction.
function M.entry_name_reason(name)
  if type(name) ~= 'string' or name == '' then
    return 'empty'
  end
  if name:find(' ', 1, true) ~= nil then
    return 'contains a space'
  end
  if name:find('\t', 1, true) ~= nil then
    return 'contains a tab'
  end
  if name:find('%c') ~= nil then
    return 'contains a control character'
  end
  return nil
end

-- path_reason(path) -> nil when `path` can be a `NAME\tfield...` line field,
-- else a short reason: 'invalid path' | 'contains a tab' | 'contains a control
-- character'. The '\t' IS the FIELD_SEPARATOR, so a field value carrying one
-- would split into two fields on reload (the P2-NB2 data-integrity class); any
-- other control character -- an embedded '\n' included -- cannot survive the
-- line framing either. A ' ' (space) is legal in a path here: only the `p`/`up`
-- NAME lists use the ' ' ENTRY_SEPARATOR, and those names are validated by
-- `entry_name_reason` at their owning boundaries (register.yank/_yank_one and
-- the Paste clash answer). This is the universal guard `serialize` runs over
-- every field, so EVERY caller that can emit a history line is covered -- not
-- only the sync boundary that refuses early (P2-NB2/B2).
function M.path_reason(path)
  if type(path) ~= 'string' then
    return 'invalid path'
  end
  if path:find('\t', 1, true) ~= nil then
    return 'contains a tab'
  end
  if path:find('%c') ~= nil then
    return 'contains a control character'
  end
  return nil
end

-- zipped(src_names, dst_names) -> ordered `{ { src, dst }, ... }` pairs (the
-- Python `dict(zip(...))` kept deterministic by D17). Ordering is by ascending
-- src name, so the renames list is sorted regardless of the caller's order and
-- the clash-prompt answers are consumed in that documented order (R19).
local function zipped(src_names, dst_names)
  local pairs_list = {}
  local n = math.min(#(src_names or {}), #(dst_names or {}))
  for i = 1, n do
    local ps, pd = src_names[i], dst_names[i]
    if type(ps) == 'string' and type(pd) == 'string'
      and ps ~= '' and pd ~= '' then
      pairs_list[#pairs_list + 1] = { src = ps, dst = pd }
    end
  end
  table.sort(pairs_list, function(a, b)
    if a.src == b.src then
      return false
    end
    return a.src < b.src
  end)
  return pairs_list
end

-- split_pairs(pairs_list) -> src_names, dst_names (the two serialized lists).
function M.split_pairs(pairs_list)
  local src_names, dst_names = {}, {}
  for _, pair in ipairs(pairs_list or {}) do
    src_names[#src_names + 1] = pair.src
    dst_names[#dst_names + 1] = pair.dst
  end
  return src_names, dst_names
end

-- ---------------------------------------------------------------------------
-- Single-entry actions (T-012)
-- ---------------------------------------------------------------------------

function M.Move(src, dst)
  local self = { name = 'mv', src = src, dst = dst }
  self['do'] = function()
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    return M.fs.rename(self.src, self.dst)
  end
  function self.describe()
    return 'Moved ' .. M.rel(self.src) .. ' to ' .. M.rel(self.dst)
  end
  return self
end

-- Remove(src, [dst]) -- the trash destination is resolved eagerly when `dst`
-- is nil (parity: the Python `__init__` computed it), so a freshly built
-- action is immediately serializable; an explicit `dst` (used by deserialize)
-- is kept verbatim so `Restore` reverses to the exact entry (B10). A
-- resolution failure is deferred to `do()`, which returns nil, err (B9/O2:
-- consumers branch, nothing raises).
function M.Remove(src, dst)
  local self = { name = 'rm', src = src }
  if dst ~= nil then
    self.dst = dst
  else
    local trash = M.paths.data_dir('trash')
    if trash then
      self.dst = M.first_free_trash(trash, src)
    end
  end
  self['do'] = function()
    if not self.dst then
      local trash, err = M.paths.data_dir('trash')
      if not trash then
        return nil, err
      end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    return M.fs.rename(self.src, self.dst)
  end
  function self.describe()
    return 'Removed ' .. M.rel(self.src)
  end
  return self
end

function M.RemoveDirectory(src, dst)
  local self = { name = 'rmdir', src = src }
  if dst ~= nil then
    self.dst = dst
  else
    local trash = M.paths.data_dir('trash')
    if trash then
      self.dst = M.first_free_trash(trash, src)
    end
  end
  self['do'] = function()
    if not self.dst then
      local trash, err = M.paths.data_dir('trash')
      if not trash then
        return nil, err
      end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    return M.fs.rename(self.src, self.dst)
  end
  function self.describe()
    return 'Removed ' .. M.rel(self.src)
  end
  return self
end

function M.Restore(src, dst)
  local self = { name = 'rs', src = src, dst = dst }
  self['do'] = function()
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    local res, rerr = M.fs.rename(self.src, self.dst)
    if res then
      -- D16: the trash slot must stay occupied so a later Remove picks a
      -- fresh `-<n>` sibling instead of reusing the exact slot. Leave an
      -- empty marker FILE there; the next remove/restore rename replaces it
      -- atomically (POSIX rename over an empty file). Best-effort: a marker
      -- that cannot be created does not fail the restore.
      M.fs.touch(self.src)
    end
    return res, rerr
  end
  function self.describe()
    return 'Restored ' .. M.rel(self.dst)
  end
  return self
end

function M.RestoreDirectory(src, dst)
  local self = { name = 'rsdir', src = src, dst = dst }
  self['do'] = function()
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    local res, rerr = M.fs.rename(self.src, self.dst)
    if res then
      -- D16 directory variant: the marker is an empty directory (the POSIX
      -- rename below replaces an empty dir just as easily as a file).
      M.fs.mkdirp(self.src)
    end
    return res, rerr
  end
  function self.describe()
    return 'Restored ' .. M.rel(self.dst)
  end
  return self
end

function M.Touch(dst)
  local self = { name = 'touch', dst = dst }
  self['do'] = function()
    return M.fs.touch(self.dst)
  end
  function self.describe()
    return 'Created ' .. M.rel(self.dst)
  end
  return self
end

function M.MakeDirectory(dst)
  local self = { name = 'mkdir', dst = dst }
  self['do'] = function()
    return M.fs.mkdirp(self.dst)
  end
  function self.describe()
    return 'Created ' .. M.rel(self.dst)
  end
  return self
end

-- ---------------------------------------------------------------------------
-- Multi-actions (T-013)
-- ---------------------------------------------------------------------------

-- Paste(src, dst, src_names, dst_names) copies entries from the register
-- `src` into the directory `dst`. `renames` is the ordered zip of the two name
-- lists, sorted ascending by src name (D17/R19). On a destination clash the
-- user is prompted for a new name; renames[i].dst is updated so the
-- serialization always reflects what was actually pasted (T-014). The prompt is
-- re-asked while the answer still names an existing path: an existing
-- destination is never written to (a directory is never merged into, a file is
-- never overwritten), so Undo -- which removes what `renames` records -- can
-- never delete data that predated the paste (P1). An empty,
-- cancelled or separator-carrying answer (B3/N2: one containing the ' '
-- ENTRY_SEPARATOR or the '\t' FIELD_SEPARATOR could not round-trip) skips the
-- entry and reports it (D8a) -- ui.prompt re-raises after inputrestore on
-- cancel/error, so the prompt is wrapped in pcall and a raise behaves exactly
-- like an empty answer. Skipped entries are pruned from `renames` before
-- `do()` returns, so serialize/Unpaste never name an entry that was not
-- actually written (B1).
function M.Paste(src, dst, src_names, dst_names)
  local self = {
    name = 'p',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
  }
  self['do'] = function()
    local last = nil
    -- B1: accumulate only the pairs actually written so `renames` (and its
    -- serialized form) never names a skipped entry; Unpaste then reverses
    -- exactly what was copied instead of deleting an untouched original.
    local copied = {}
    for _, pair in ipairs(self.renames) do
      local full_src = M.fs.join(self.src, pair.src)
      local full_dst = M.fs.join(self.dst, pair.dst)
      local st = M.fs.stat(full_src)
      if st then
        local skipped = false
        -- P1: an existing destination is NEVER written to. Previously the
        -- answered name was taken verbatim, so answering a name that still
        -- existed merged a tree into the existing directory (copy_tree) or
        -- overwrote the existing file (copy_file) -- while `renames` recorded it
        -- as newly created, so Undo then deleted the whole destination,
        -- pre-existing members included. Re-prompt until the answer names a
        -- path that does not exist; an empty, cancelled or separator-carrying
        -- answer (D8a/B3/N2) still skips the entry and leaves the existing
        -- destination untouched.
        while M.fs.exists(full_dst) do
          local entry_type = 'File'
          if not M.fs.is_file(full_dst) then
            entry_type = 'Directory'
          end
          local okp, answer = pcall(M.ui.prompt,
            entry_type .. ' already exists. Paste as: ', pair.src, 'file')
          if not okp or answer == nil or M.entry_name_reason(answer) ~= nil then
            -- D8a/B3/N2: an empty/cancelled answer -- or one carrying a
            -- serialization separator (' ' ENTRY_SEPARATOR, '\t'
            -- FIELD_SEPARATOR), which could not round-trip -- skips the ENTRY
            -- entirely; the original destination must not be touched.
            M.ui.notify('Skipped ' .. pair.src, vim.log.levels.WARN)
            skipped = true
            break
          end
          pair.dst = answer
          full_dst = M.fs.join(self.dst, pair.dst)
        end
        if not skipped then
          if st.type == 'file' then
            local ok, err = M.fs.copy_file(full_src, full_dst)
            if not ok then
              return nil, err
            end
            last = full_dst
            copied[#copied + 1] = { src = pair.src, dst = pair.dst }
          elseif st.type == 'directory' then
            local ok, err = M.fs.copy_tree(full_src, full_dst)
            if not ok then
              return nil, err
            end
            last = full_dst
            copied[#copied + 1] = { src = pair.src, dst = pair.dst }
          end
        end
      end
    end
    -- B1: only the written pairs remain; a fully-skipped paste ends with an
    -- empty renames list, so its reversal is a no-op.
    self.renames = copied
    return last or true
  end
  function self.describe()
    return 'Pasted into ' .. M.rel(self.dst) .. '/'
  end
  return self
end

-- Unpaste(src, dst, src_names, dst_names) deletes the entries a Paste created
-- (`src` is the directory the paste landed in) without trashing them. This is
-- `reverse(Paste)`: see the T-014 reversal mapping.
function M.Unpaste(src, dst, src_names, dst_names)
  local self = {
    name = 'up',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
  }
  self['do'] = function()
    for _, pair in ipairs(self.renames) do
      local full = M.fs.join(self.src, pair.src)
      local st = M.fs.stat(full)
      if st then
        if st.type == 'file' then
          local ok, err = M.fs.rm_file(full)
          if not ok then
            return nil, err
          end
        elseif st.type == 'directory' then
          local ok, err = M.fs.rm_tree(full)
          if not ok then
            return nil, err
          end
        end
      end
    end
    return true
  end
  function self.describe()
    return 'Reversed paste into ' .. M.rel(self.src) .. '/'
  end
  return self
end

-- ---------------------------------------------------------------------------
-- Serialization (T-014)
-- ---------------------------------------------------------------------------

-- serialize(action) -> `NAME\tfield...` | nil, err. The field order follows the
-- Python version verbatim: src then dst (each present on the action), then for
-- `p`/`up` the ' '-joined src_names and dst_names lists.
--
-- P2-NB2/B2: this is the LAST gate every caller passes through before a line is
-- persisted, so the representability check lives HERE (`M.path_reason`, run over
-- every assembled field) instead of only at the sync boundary: a field value
-- carrying the '\t' FIELD_SEPARATOR -- or any other control character -- would
-- not survive `deserialize`/`reverse`, so NO line is emitted and a reason is
-- returned for the caller to report. The line is never silently truncated. The
-- sync boundary keeps its early, friendlier refusal; `register.paste`
-- pre-serializes the Paste for the same reason before it copies anything.
function M.serialize(action)
  if type(action) ~= 'table' or type(action.name) ~= 'string' then
    return nil, 'cannot serialize action'
  end
  local words = { action.name }
  if action.src ~= nil then
    words[#words + 1] = action.src
  end
  if action.dst ~= nil then
    words[#words + 1] = action.dst
  end
  if action.name == 'p' or action.name == 'up' then
    local src_names, dst_names = M.split_pairs(action.renames)
    words[#words + 1] = table.concat(src_names, ' ')
    words[#words + 1] = table.concat(dst_names, ' ')
  end
  for _, word in ipairs(words) do
    local reason = M.path_reason(word)
    if reason ~= nil then
      return nil, 'cannot serialize action: ' .. reason .. ': ' .. tostring(word)
    end
  end
  return table.concat(words, FIELD_SEPARATOR)
end

-- deserialize(line) -> the action the line denotes, or nil, err for a
-- malformed or unknown line. Destructive actions are rebuilt through their
-- factories with the serialized dst passed verbatim, so a trashed entry is
-- always restored to (and from) the exact recorded path (B10).
function M.deserialize(line)
  if type(line) ~= 'string' or line == '' then
    return nil, 'invalid action line'
  end
  local words = vim.split(line, FIELD_SEPARATOR, { plain = true })
  local name = words[1]
  if name == 'mv' then
    return M.Move(words[2], words[3])
  elseif name == 'rm' then
    return M.Remove(words[2], words[3])
  elseif name == 'rmdir' then
    return M.RemoveDirectory(words[2], words[3])
  elseif name == 'rs' then
    return M.Restore(words[2], words[3])
  elseif name == 'rsdir' then
    return M.RestoreDirectory(words[2], words[3])
  elseif name == 'touch' then
    return M.Touch(words[2])
  elseif name == 'mkdir' then
    return M.MakeDirectory(words[2])
  elseif name == 'p' then
    return M.Paste(words[2], words[3],
      M.split_names(words[4]), M.split_names(words[5]))
  elseif name == 'up' then
    return M.Unpaste(words[2], words[3],
      M.split_names(words[4]), M.split_names(words[5]))
  end
  return nil, 'unknown action name: ' .. tostring(name)
end

-- reverse_action(action) -> the reversal per the exact mapping (T-014):
--   mv      -> mv        (src/dst swapped)
--   rm      -> rs
--   rmdir   -> rsdir
--   rs      -> rm
--   rsdir   -> rmdir
--   touch   -> rm
--   mkdir   -> rmdir
--   p       -> up        (src/dst swapped, renames inverted)
--   up      -> p         (src/dst swapped, renames inverted)
function M.reverse_action(action)
  if type(action) ~= 'table' then
    return nil, 'invalid action'
  end
  if action.name == 'mv' then
    return M.Move(action.dst, action.src)
  elseif action.name == 'rm' then
    return M.Restore(action.dst, action.src)
  elseif action.name == 'rmdir' then
    return M.RestoreDirectory(action.dst, action.src)
  elseif action.name == 'rs' then
    return M.Remove(action.dst)
  elseif action.name == 'rsdir' then
    return M.RemoveDirectory(action.dst)
  elseif action.name == 'touch' then
    return M.Remove(action.dst)
  elseif action.name == 'mkdir' then
    return M.RemoveDirectory(action.dst)
  elseif action.name == 'p' then
    local src_names, dst_names = M.split_pairs(action.renames)
    return M.Unpaste(action.dst, action.src, dst_names, src_names)
  elseif action.name == 'up' then
    local src_names, dst_names = M.split_pairs(action.renames)
    return M.Paste(action.dst, action.src, dst_names, src_names)
  end
  return nil, 'no reversal for action: ' .. tostring(action.name)
end

-- reverse(line) -> the reversal of the action serialized on `line`, or
-- nil, err. Accepts an already-deserialized action table as well.
function M.reverse(line)
  local action = line
  if type(action) ~= 'table' then
    local err
    action, err = M.deserialize(line)
    if not action then
      return nil, err or 'invalid action line'
    end
  end
  return M.reverse_action(action)
end

-- ---------------------------------------------------------------------------
-- Human summaries (B15)
-- ---------------------------------------------------------------------------

-- describe_action(action) -> the human description (never the serialized
-- form, N8).
function M.describe_action(action)
  if type(action) == 'table' and type(action.describe) == 'function' then
    return action.describe()
  end
  return tostring(action)
end

-- summarize(actions) -> the B15 joined summary: descriptions `, `-joined with
-- the first character of the whole string upper-cased and every other
-- character untouched (the Python `print_actions` behaviour).
function M.summarize(actions)
  local parts = {}
  for _, action in ipairs(actions or {}) do
    parts[#parts + 1] = M.describe_action(action)
  end
  local summary = table.concat(parts, ', ')
  if #summary > 0 then
    summary = summary:sub(1, 1):upper() .. summary:sub(2)
  end
  return summary
end

return M