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
--   * interlinked moves (a swap, an N-way rotation, an open chain) are recorded
--     and reversed as ONE `g` group entry, because reversing them one action at
--     a time renames a live name straight over a name another reversal still has
--     to read -- the Greptile PR #1 `buffer.lua:595` data-loss path ("undo
--     destroys swapped contents"). `moves` are staged through the SAME
--     `.direct-tmp-<n>` mechanism the save uses (`M.stage_moves`), on the save
--     path and on the reversal path alike, so no intermediate state can pass
--     through a colliding name (B11/D3). `M.move_groups` decides which moves
--     are interlinked; `M.Group` owns their execution and their serialization
--     (`g\t<count>\t<src>\t<dst>...`, see `M.serialize_group`);
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

-- Paste clash prompt cap (P1 follow-up): a `ui.prompt` that keeps answering a
-- name that still exists -- a stub, or a broken/hostile prompt -- would
-- otherwise spin forever and freeze the editor. After this many collisions the
-- entry is SKIPPED and reported, exactly like a cancelled answer (D8a): the
-- existing destination is never written to.
M.PASTE_CLASH_ATTEMPTS = 10

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
-- denotes the same path as `src` (fs.realpath, spelling-independent) before a
-- destructive action, matching the Python `_close_src_buffer`. Identity is the
-- resolved PATHNAME, not fs.same_path: same_path compares ino+dev, so it also
-- matched every HARD LINK to `src` and force-closed unrelated modified buffers
-- (P1). realpath collapses a symlinked prefix (B9, the `/tmp` -> `/private/tmp`
-- case), `..` and trailing slashes, so the same file reached by a different
-- spelling still closes, while two distinct hardlink names stay distinct.
-- Pure defence and parity: nothing here may raise, so every buffer API call is
-- pcall-guarded.
function M.close_src_buffer(src)
  if type(src) ~= 'string' then
    return true
  end
  local target = M.fs.realpath(src)
  local ok = pcall(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' and M.fs.realpath(name) == target then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
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
  if not M.fs.taken(dst) then
    return dst
  end
  local n = 1
  while M.fs.taken(dst .. '-' .. n) do
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
        -- path that does not exist (at most PASTE_CLASH_ATTEMPTS times: a
        -- prompt that stays stuck on an existing name is skipped, never spun
        -- on); an empty, cancelled or separator-carrying
        -- answer (D8a/B3/N2) still skips the entry and leaves the existing
        -- destination untouched.
        local attempts = 0
        while M.fs.taken(full_dst) do
          attempts = attempts + 1
          if attempts > M.PASTE_CLASH_ATTEMPTS then
            M.ui.notify('Skipped ' .. pair.src, vim.log.levels.WARN)
            skipped = true
            break
          end
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
            -- P1 follow-up (review): a paste destroys nothing, so an entry the
            -- copy cannot reproduce is skipped and REPORTED (the register is
            -- persisted, untrusted data) rather than failing the paste or
            -- vanishing silently.
            local ok, skipped = M.fs.copy_tree(full_src, full_dst)
            if not ok then
              return nil, skipped
            end
            local n = skipped ~= nil and #skipped or 0
            if n > 0 then
              M.ui.notify('Skipped ' .. n .. ' ' .. (n == 1 and 'entry' or 'entries')
                .. ' that cannot be copied: ' .. full_src, vim.log.levels.WARN)
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
-- Interlinked moves: staging, grouping, group reversal (B6/B11/D3)
-- ---------------------------------------------------------------------------

-- parent_dir(path) -> the directory the staging temp for `path` belongs in. The
-- trailing slash of a directory line is stripped BEFORE the parent is taken:
-- `vim.fs.dirname('/ws/old/')` is '/ws/old', not '/ws' (measured on 0.12.5), so
-- it cannot be used here. Every entry staged for one sync belongs to the sync
-- root, so the temp spelling is exactly the `<root>/.direct-tmp-<n>` the save
-- has always used -- and because the temp is created in the entry's OWN
-- directory, the staging rename can never cross a filesystem.
local function parent_dir(path)
  local trimmed = tostring(path):gsub('/+$', '')
  local dir = trimmed:match('^(.*)/[^/]*$')
  if dir == nil or dir == '' then
    return '/'
  end
  return dir
end

-- first_free_temp(dir) -> the first free `<dir>/.direct-tmp-<n>`.
function M.first_free_temp(dir)
  local n = 1
  local candidate = M.fs.join(dir, '.direct-tmp-' .. n)
  while M.fs.taken(candidate) do
    n = n + 1
    candidate = M.fs.join(dir, '.direct-tmp-' .. n)
  end
  return candidate
end

-- stage_moves(actions) -> { overrides = { src -> tmp }, temps = { tmp } } when a
-- rename `dst` is also some action's `src` (a swap, a chain or a rotation), else
-- nil. Only `mv` actions participate. A staging rename failure returns
-- `nil, err, temps, overrides`, where `temps` are the entries ALREADY renamed to
-- their temp path and `overrides` is the partial src -> tmp map that put them
-- there: the caller must report them, because the entry no longer sits at its
-- original name and silently discarding the list would orphan it (B1/T-023) --
-- and `overrides` is what lets a caller UNWIND the renames that landed and
-- restore the pre-attempt state (B1).
-- The caller executes each Move from `overrides[src]` when present, while
-- `history.log` and `current_entry` keep using the ORIGINAL action (B11:
-- `current_entry` must never be a temp path).
--
-- This is the ONE staging mechanism: `Buffer:sync` applies a save through it and
-- `M.Group` applies a group reversal through it, so the reversal of a swap gets
-- exactly the protection the swap itself gets (the reported bug was that the
-- reversal had none: it renamed a live name over a name whose contents had not
-- been saved anywhere yet).
function M.stage_moves(actions)
  actions = actions or {}
  local dst_set = {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.dst ~= nil then
      dst_set[act.dst] = true
    end
  end
  local needed = false
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.src ~= nil and dst_set[act.src] then
      needed = true
      break
    end
  end
  if not needed then
    return nil
  end
  local overrides, temps = {}, {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.src ~= nil and dst_set[act.src]
      and overrides[act.src] == nil then
      local tmp = M.first_free_temp(parent_dir(act.src))
      local ok, err = M.fs.rename(act.src, tmp)
      if not ok then
        -- B1/T-023: return the temps accumulated so far ALONGSIDE the error
        -- (and the partial overrides that name each temp's original path), so
        -- the caller can report -- and, where it must, restore -- each entry
        -- that is now parked at a temp path instead of returning the error
        -- alone and orphaning them silently.
        return nil, err, temps, overrides
      end
      overrides[act.src] = tmp
      temps[#temps + 1] = tmp
    end
  end
  return { overrides = overrides, temps = temps }
end

-- move_groups(actions) -> an ordered partition of the action list into the
-- groups history records together. Two `mv` actions belong together when one's
-- `dst` is the other's `src` (transitively): that link is exactly what makes a
-- one-action-at-a-time rename unsafe, because the destination of one move still
-- has to be read by another (B11/D3). Every other action -- a Touch, a
-- MakeDirectory, a Remove, a Paste/Unpaste, or a `mv` sharing no name with
-- another -- is its own single-action group.
--
-- What the UI can produce and what it therefore groups: a two-file swap (a
-- 2-cycle), an N-way rotation (a cycle of length > 2, from permuting the
-- equal-length listing), and an open chain (a -> b -> ..., when the permutation
-- consumes a fresh name at its tail). Two moves that share no name stay two
-- entries. In a RENAME plan the `src` names are distinct and the `dst` names are
-- distinct (the duplicate check runs first), so a shared name links at most two
-- moves and the components are paths and cycles.
--
-- Returns { { <index>, ... }, ... }: groups in ascending first-index order,
-- every action index exactly once, a group of one being an independent action.
function M.move_groups(actions)
  actions = actions or {}
  local parent = {}
  for i = 1, #actions do
    parent[i] = i
  end
  local function root(i)
    while parent[i] ~= i do
      parent[i] = parent[parent[i]]
      i = parent[i]
    end
    return i
  end
  local at_path = {}
  for i, act in ipairs(actions) do
    local paths = {}
    if type(act.src) == 'string' then
      paths[#paths + 1] = act.src
    end
    if type(act.dst) == 'string' then
      paths[#paths + 1] = act.dst
    end
    if act.name == 'mv' then
      for _, path in ipairs(paths) do
        local other = at_path[path]
        if other == nil then
          at_path[path] = i
        else
          local a, b = root(other), root(i)
          if a ~= b then
            parent[b] = a
          end
        end
      end
    end
  end
  local groups, at_root = {}, {}
  for i = 1, #actions do
    local r = root(i)
    if at_root[r] == nil then
      at_root[r] = {}
      groups[#groups + 1] = at_root[r]
    end
    at_root[r][#at_root[r] + 1] = i
  end
  return groups
end

-- Group(actions) -- the interlinked `mv` actions of one sync, recorded and
-- reversed as ONE history entry (B6). `do()` reuses `M.stage_moves`, so a group
-- reversal is staged exactly like the save that created it. A staging failure
-- attempts to UNWIND every rename that landed, using atomic no-replace renames.
-- When that succeeds, the pre-attempt state is restored and the entry is
-- retryable. When a destination is occupied or the platform lacks the atomic
-- primitive, the original remains at its named temp path; the error calls for
-- manual recovery before retry. Every stranded temp is reported (B1/T-023/B5),
-- and the caller retains the history entry (D13) rather than silently dropping
-- it to mask the failure.
--
-- The name `g` never collides with an action name: every other serialized line
-- starts with the name of a single-entry action. `describe()` joins the member
-- descriptions, so `summarize` still emits ONE B15 summary per undo press.
function M.Group(actions)
  local self = { name = 'g', actions = actions }
  local function report_temps(staging)
    for _, tmp in ipairs(staging ~= nil and staging.temps or {}) do
      if M.fs.taken(tmp) then
        M.ui.notify('direct: a failed move left the staged entry ' .. tmp,
          vim.log.levels.ERROR)
      end
    end
  end
  self['do'] = function()
    local members = self.actions or {}
    local staging, stage_err, stage_temps, stage_overrides =
      M.stage_moves(members)
    if staging == nil and stage_err ~= nil then
      -- B1: unwind the staging renames that ALREADY landed before reporting,
      -- so a failed group application leaves the pre-attempt state where safe.
      -- Restores use atomic no-replace rename: ordinary rename could destroy a
      -- concurrent destination, and checking before it would be racy. If a
      -- restore fails, the original remains at its temp path. History retains
      -- the action, but it is not safe to retry until the user manually recovers
      -- that temp and resolves the collision.
      local overrides = stage_overrides or {}
      for _, act in ipairs(members) do
        local tmp = act.src ~= nil and overrides[act.src] or nil
        if tmp ~= nil and M.fs.taken(tmp) then
          local rok, rerr = M.fs.rename_noreplace(tmp, act.src)
          if not rok then
            local occupied = M.fs.taken(act.src)
            local cause = occupied and 'destination is occupied' or tostring(rerr)
            M.ui.notify('direct: could not restore staged entry ' .. tmp
              .. ' to ' .. tostring(act.src) .. ' (' .. cause
              .. '); temp preserved; manual recovery required before retry',
              vim.log.levels.ERROR)
          end
        end
      end
      for _, tmp in ipairs(stage_temps or {}) do
        if M.fs.taken(tmp) then
          M.ui.notify('direct: a failed rename left the staged entry ' .. tmp,
            vim.log.levels.ERROR)
        end
      end
      return nil, 'could not stage renames: ' .. tostring(stage_err)
    end
    for _, act in ipairs(members) do
      local exec = act
      if staging ~= nil and act.name == 'mv'
        and staging.overrides[act.src] ~= nil then
        exec = M.Move(staging.overrides[act.src], act.dst)
      end
      local ok, res, err = pcall(exec['do'])
      if not ok then
        report_temps(staging)
        return nil, tostring(res)
      end
      if res == nil then
        report_temps(staging)
        return nil, err ~= nil and tostring(err) or 'action failed'
      end
    end
    return true
  end
  function self.describe()
    local parts = {}
    for _, member in ipairs(self.actions or {}) do
      parts[#parts + 1] = M.describe_action(member)
    end
    return table.concat(parts, ', ')
  end
  return self
end

-- ---------------------------------------------------------------------------
-- Serialization (T-014)
-- ---------------------------------------------------------------------------

-- checked_line(words) -> the FIELD_SEPARATOR-joined line | nil, err. The P2-NB2/
-- B2 representability gate runs over every assembled field HERE, so every entry
-- kind (`NAME\tfield...` and the `g\t<count>\t<src>\t<dst>...` group) is checked
-- by the same code and no caller can emit an unrepresentable line.
local function checked_line(words)
  for _, word in ipairs(words) do
    local reason = M.path_reason(word)
    if reason ~= nil then
      return nil, 'cannot serialize action: ' .. reason .. ': ' .. tostring(word)
    end
  end
  return table.concat(words, FIELD_SEPARATOR)
end

-- serialize_group(action) -> `g\t<count>\t<src>\t<dst>...` | nil, err.
--
-- The format decision (Greptile PR #1 review). Only the interlinked moves of one
-- RENAME sync can be grouped (see `M.move_groups`), so a group is serialized as
-- its member count followed by that many src/dst pairs: fixed arity makes the
-- line unambiguous without nesting the field separator inside a field, and a
-- count that does not match the field number is refused by `deserialize` rather
-- than half-replayed. A different group shape (a non-`mv` member) would need a
-- new marker, which the version gate already handles. The tab framing of an
-- ACTION line is untouched: a path carrying a tab is still refused.
function M.serialize_group(action)
  local members = action.actions
  if type(members) ~= 'table' or #members < 2 then
    return nil, 'cannot serialize group: at least two actions are required'
  end
  local words = { 'g', tostring(#members) }
  for _, member in ipairs(members) do
    if type(member) ~= 'table' or member.name ~= 'mv'
      or type(member.src) ~= 'string' or type(member.dst) ~= 'string' then
      return nil, 'cannot serialize group: only move actions can be grouped'
    end
    words[#words + 1] = member.src
    words[#words + 1] = member.dst
  end
  return checked_line(words)
end

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
  if action.name == 'g' then
    return M.serialize_group(action)
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
  return checked_line(words)
end

-- deserialize(line) -> the action the line denotes, or nil, err for a
-- malformed or unknown line. Destructive actions are rebuilt through their
-- factories with the serialized dst passed verbatim, so a trashed entry is
-- always restored to (and from) the exact recorded path (B10).
--
-- A `g` line is validated before anything is rebuilt: the member count must be a
-- plain decimal of at least two and must match the number of src/dst fields
-- exactly, otherwise the whole line is refused (the history then keeps it, D13).
-- A group is never partially executed: a refusal here means nothing ran at all.
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
  elseif name == 'g' then
    local count = words[2]
    if type(count) ~= 'string' or count:match('^%d+$') == nil then
      return nil, 'invalid group line: bad member count'
    end
    count = tonumber(count)
    if count < 2 or #words ~= 2 + 2 * count then
      return nil, string.format('invalid group line: %d field(s) for %d move(s)',
        #words - 2, count)
    end
    local members = {}
    for i = 1, count do
      members[#members + 1] = M.Move(words[1 + 2 * i], words[2 + 2 * i])
    end
    return M.Group(members)
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
--   g       -> g         (every member reversed, in reverse order)
--
-- A group reversal applies all its members through the staging path, so the
-- recorded order cannot change the filesystem outcome; reversing order as well
-- keeps the pair a true involution (undo -> redo -> undo reproduces the original
-- record), which is what makes the redo log entry byte-identical for a swap.
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
  elseif action.name == 'g' then
    local members = {}
    for i = #(action.actions or {}), 1, -1 do
      local rev, err = M.reverse_action(action.actions[i])
      if not rev then
        return nil, err
      end
      members[#members + 1] = rev
    end
    if #members < 2 then
      return nil, 'no reversal for group: fewer than two actions'
    end
    return M.Group(members)
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
