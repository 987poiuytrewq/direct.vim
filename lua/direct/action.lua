-- lua/direct/action.lua -- filesystem actions, history serialization, and reversal.
-- Grouped moves share a staging path so swaps and chains can be undone without
-- overwriting a name whose contents have not yet been saved elsewhere.

local M = {}

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.ui = require('direct.ui')

local FIELD_SEPARATOR = '\t'

-- Paste clash prompt cap (follow-up): a `ui.prompt` that keeps answering a
-- name that still exists -- a stub, or a broken/hostile prompt -- would
-- otherwise spin forever and freeze the editor. After this many collisions the
-- entry is SKIPPED and reported, exactly like a cancelled answer: the
-- existing destination is never written to.
M.PASTE_CLASH_ATTEMPTS = 10

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- rel(path) -> the CWD-relative spelling of a path, the Lua
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

-- Close buffers for the resolved pathname before destructive actions. Do not
-- use inode identity: that would also close buffers for distinct hard links.
-- realpath normalizes symlink prefixes, `..`, and trailing slashes while keeping
-- different hard-link names distinct.
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
-- free `<digest>-<n>` when that path already exists. The result is
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

-- entry_name_reason(name) -> nil when `name` can round-trip through the `p`
-- `up` serialization, else a short reason: 'empty' | 'contains a space' |
-- 'contains a tab' | 'contains a control character'. A name carrying the ' '
-- ENTRY_SEPARATOR would split into two names on reload and desync the src/dst
-- name lists, letting Unpaste delete an unrelated file; a name
-- carrying the '\t' FIELD_SEPARATOR would break the `NAME\tfield...` line
-- framing itself; and any OTHER control character -- most importantly an
-- embedded '\n' -- is refused too, so the log round trip never depends on
-- `vim.fn.writefile` encoding a NL as NUL to keep the line framing intact.
-- This is the validator for the boundaries that feed a name into the
-- serialization: register.yank / _yank_one refuse such a name before it can
-- enter the register, and Paste refuses a separator-carrying clash answer
-- exactly like an empty/cancelled one. `deserialize` deliberately does
-- not re-validate: it only ever rebuilds actions from the Lua-owned
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

-- path_reason(path) -> nil when `path` can be a `NAME\tfield...` line field
-- else a short reason: 'invalid path' | 'contains a tab' | 'contains a control
-- character'. The '\t' IS the FIELD_SEPARATOR, so a field value carrying one
-- would split into two fields on reload (the data-integrity class); any
-- other control character -- an embedded '\n' included -- cannot survive the
-- line framing either. A ' ' (space) is legal in a path here: only the `p`/`up`
-- NAME lists use the ' ' ENTRY_SEPARATOR, and those names are validated by
-- `entry_name_reason` at their owning boundaries (register.yank/_yank_one and
-- the Paste clash answer). This is the universal guard `serialize` runs over
-- every field, so EVERY caller that can emit a history line is covered -- not
-- only the sync boundary that refuses early.
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

-- Build source/destination pairs in ascending source-name order so serialization
-- and clash-prompt order do not depend on the caller's input order.
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
-- Single-entry actions
-- ---------------------------------------------------------------------------

function M.Move(src, dst)
  local self = { name = 'mv', _kind = 'mv', src = src, dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) and not M.fs.same_entry(self.src, self.dst) then
      return nil, 'destination exists: ' .. tostring(self.dst)
    end
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    return M.fs.rename(self.src, self.dst)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Moved ' .. M.rel(self.src) .. ' to ' .. M.rel(self.dst)
  end
  return self
end

-- Remove(src, [dst]) -- the trash destination is resolved eagerly when `dst`
-- is nil (parity: the Python `__init__` computed it), so a freshly built
-- action is immediately serializable; an explicit `dst` (used by deserialize)
-- is kept verbatim so `Restore` reverses to the exact entry. A
-- resolution failure is deferred to `do`, which returns nil, err (
-- consumers branch, nothing raises).
function M.Remove(src, dst)
  local self = { name = 'rm', _kind = 'rm', src = src }
  if dst ~= nil then
    self.dst = dst
  else
    local trash = M.paths.data_dir('trash')
    if trash then
      self.dst = M.first_free_trash(trash, src)
    end
  end
  self._execute = function()
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
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Removed ' .. M.rel(self.src)
  end
  return self
end

function M.RemoveDirectory(src, dst)
  local self = { name = 'rmdir', _kind = 'rmdir', src = src }
  if dst ~= nil then
    self.dst = dst
  else
    local trash = M.paths.data_dir('trash')
    if trash then
      self.dst = M.first_free_trash(trash, src)
    end
  end
  self._execute = function()
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
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Removed ' .. M.rel(self.src)
  end
  return self
end

function M.Restore(src, dst)
  local self = { name = 'rs', _kind = 'rs', src = src, dst = dst }
  self._execute = function()
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    local res, rerr = M.fs.rename(self.src, self.dst)
    if res then
      -- the trash slot must stay occupied so a later Remove picks a
      -- fresh `-<n>` sibling instead of reusing the exact slot. Leave an
      -- empty marker FILE there; the next remove/restore rename replaces it
      -- atomically (POSIX rename over an empty file). Best-effort: a marker
      -- that cannot be created does not fail the restore.
      M.fs.touch(self.src)
    end
    return res, rerr
  end
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Restored ' .. M.rel(self.dst)
  end
  return self
end

function M.RestoreDirectory(src, dst)
  local self = { name = 'rsdir', _kind = 'rsdir', src = src, dst = dst }
  self._execute = function()
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      return nil, err
    end
    local res, rerr = M.fs.rename(self.src, self.dst)
    if res then
      -- directory variant: the marker is an empty directory (the POSIX
      -- rename below replaces an empty dir just as easily as a file).
      M.fs.mkdirp(self.src)
    end
    return res, rerr
  end
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Restored ' .. M.rel(self.dst)
  end
  return self
end

function M.Touch(dst)
  local self = { name = 'touch', _kind = 'touch', dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) then
      return nil, 'destination exists: ' .. tostring(self.dst)
    end
    return M.fs.touch(self.dst)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Created ' .. M.rel(self.dst)
  end
  return self
end

function M.MakeDirectory(dst)
  local self = { name = 'mkdir', _kind = 'mkdir', dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) then
      return nil, 'destination exists: ' .. tostring(self.dst)
    end
    return M.fs.mkdirp(self.dst)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Created ' .. M.rel(self.dst)
  end
  return self
end

-- ---------------------------------------------------------------------------
-- Multi-actions
-- ---------------------------------------------------------------------------

-- Paste(src, dst, src_names, dst_names) copies entries from the register
-- `src` into the directory `dst`. `renames` is the ordered zip of the two name
-- lists, sorted ascending by src name. On a destination clash the
-- user is prompted for a new name; renames[i].dst is updated so the
-- serialization always reflects what was actually pasted. The prompt is
-- re-asked while the answer still names an existing path: an existing
-- destination is never written to (a directory is never merged into, a file is
-- never overwritten), so Undo -- which removes what `renames` records -- can
-- never delete data that predated the paste. An empty, cancelled, or
-- separator-carrying answer (one containing the ' '
-- ENTRY_SEPARATOR or the '\t' FIELD_SEPARATOR could not round-trip) skips the
-- entry and reports it. ui.prompt re-raises after inputrestore on
-- cancel/error, so the prompt is wrapped in pcall and a raise behaves exactly
-- like an empty answer. Skipped entries are pruned from `renames` before
-- `do` returns, so serialize/Unpaste never name an entry that was not
-- actually written.
function M.Paste(src, dst, src_names, dst_names)
  local self = {
    name = 'p',
    _kind = 'p',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
  }
  self._execute = function()
    local last = nil
    -- accumulate only the pairs actually written so `renames` (and its
    -- serialized form) never names a skipped entry; Unpaste then reverses
    -- exactly what was copied instead of deleting an untouched original.
    local copied = {}
    for _, pair in ipairs(self.renames) do
      local full_src = M.fs.join(self.src, pair.src)
      local full_dst = M.fs.join(self.dst, pair.dst)
      local st = M.fs.stat(full_src)
      if st then
        local skipped = false
        -- an existing destination is NEVER written to. Previously the
        -- answered name was taken verbatim, so answering a name that still
        -- existed merged a tree into the existing directory (copy_tree) or
        -- overwrote the existing file (copy_file) -- while `renames` recorded it
        -- as newly created, so Undo then deleted the whole destination
        -- pre-existing members included. Re-prompt until the answer names a
        -- path that does not exist (at most PASTE_CLASH_ATTEMPTS times: a
        -- prompt that stays stuck on an existing name is skipped, never spun
        -- on); an empty, cancelled or separator-carrying
        -- answer still skips the entry and leaves the existing
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
            -- an empty/cancelled answer -- or one carrying a
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
            -- A paste destroys nothing, so an entry the
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
    -- only the written pairs remain; a fully-skipped paste ends with an
    -- empty renames list, so its reversal is a no-op.
    self.renames = copied
    return last or true
  end
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Pasted into ' .. M.rel(self.dst) .. '/'
  end
  return self
end

-- Unpaste(src, dst, src_names, dst_names) deletes the entries a Paste created
-- (`src` is the directory the paste landed in) without trashing them. This is
-- `reverse(Paste)`: see the reversal mapping.
function M.Unpaste(src, dst, src_names, dst_names)
  local self = {
    name = 'up',
    _kind = 'up',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
  }
  self._execute = function()
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
  self['do'] = function() return M.execute(self) end
  function self.describe()
    return 'Reversed paste into ' .. M.rel(self.src) .. '/'
  end
  return self
end

-- ---------------------------------------------------------------------------
-- Interlinked moves: staging, grouping, group reversal
-- ---------------------------------------------------------------------------

-- parent_dir(path) -> the directory the staging temp for `path` belongs in. The
-- trailing slash of a directory line is stripped BEFORE the parent is taken
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
-- original name and silently discarding the list would orphan it. The overrides
-- also let callers unwind landed renames and restore the pre-attempt state.
-- The caller executes each Move from `overrides[src]` when present, while
-- `history.log` and `current_entry` keep using the original action, never a temp path.
--
-- This is the ONE staging mechanism: `Buffer:sync` applies a save through it and
-- `M.Group` applies a group reversal through it, so the reversal of a swap gets
-- exactly the protection the swap itself gets (the reported bug was that the
-- reversal had none: it renamed a live name over a name whose contents had not
-- been saved anywhere yet).
function M.stage_moves(actions)
  actions = actions or {}
  local function move_key(path)
    return type(path) == 'string' and path:gsub('/+$', '') or path
  end
  local destinations, destinations_by_inode = {}, {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.dst ~= nil then
      local destination = move_key(act.dst)
      destinations[destination] = true
      local identity = M.fs.entry_identity(destination)
      if identity and identity.inode then
        local bucket = destinations_by_inode[identity.inode]
        if not bucket then
          bucket = {}
          destinations_by_inode[identity.inode] = bucket
        end
        bucket[#bucket + 1] = destination
      end
    end
  end
  local function shares_destination(path)
    path = move_key(path)
    if destinations[path] then return true end
    local identity = M.fs.entry_identity(path)
    local bucket = identity and identity.inode and destinations_by_inode[identity.inode]
    for _, destination in ipairs(bucket or {}) do
      if M.fs.same_entry(path, destination) then return true end
    end
    return false
  end
  local stage_sources, needed = {}, false
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.src ~= nil and shares_destination(act.src) then
      stage_sources[move_key(act.src)] = true
      needed = true
    end
  end
  if not needed then
    return nil
  end
  local overrides, temps = {}, {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.src ~= nil and stage_sources[move_key(act.src)]
      and overrides[act.src] == nil then
      local tmp = M.first_free_temp(parent_dir(act.src))
      local ok, err = M.fs.rename(act.src, tmp)
      if not ok then
        -- return the temps accumulated so far ALONGSIDE the error
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
-- has to be read by another. Every other action -- a Touch, a
-- MakeDirectory, a Remove, a Paste/Unpaste, or a `mv` sharing no name with
-- another -- is its own single-action group.
--
-- What the UI can produce and what it therefore groups: a two-file swap (a
-- 2-cycle), an N-way rotation (a cycle of length > 2, from permuting the
-- equal-length listing), and an open chain (a -> b ->..., when the permutation
-- consumes a fresh name at its tail). Two moves that share no name stay two
-- entries. In a RENAME plan the `src` names are distinct and the `dst` names are
-- distinct (the duplicate check runs first), so a shared name links at most two
-- moves and the components are paths and cycles.
--
-- Returns { { <index>,... },... }: groups in ascending first-index order
-- every action index exactly once, a group of one being an independent action.
function M.move_groups(actions)
  actions = actions or {}
  local function move_key(path)
    return type(path) == 'string' and path:gsub('/+$', '') or path
  end
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
  local at_path, at_inode = {}, {}
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
        path = move_key(path)
        local exact = at_path[path]
        for _, previous in ipairs(exact or {}) do
          local a, b = root(previous), root(i)
          if a ~= b then parent[b] = a end
        end
        local identity = M.fs.entry_identity(path)
        local bucket = identity and identity.inode and at_inode[identity.inode]
        for _, previous in ipairs(bucket or {}) do
          if M.fs.same_entry(path, previous.path) then
            local a, b = root(previous.index), root(i)
            if a ~= b then parent[b] = a end
          end
        end
        if not exact then
          exact = {}
          at_path[path] = exact
        end
        exact[#exact + 1] = i
        if identity and identity.inode then
          local inode_entries = at_inode[identity.inode]
          if not inode_entries then
            inode_entries = {}
            at_inode[identity.inode] = inode_entries
          end
          inode_entries[#inode_entries + 1] = { path = path, index = i }
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
-- reversed as ONE history entry. `do` reuses `M.stage_moves`, so a group
-- reversal is staged exactly like the save that created it. A staging failure
-- attempts to unwind landed staging renames with atomic no-replace operations.
-- This prevents overwriting a destination created concurrently. If restoration
-- is unsafe or unsupported, the entry stays at its reported temp path and the
-- history entry is retained for retry after manual recovery.
--
-- The name `g` never collides with an action name: every other serialized line
-- starts with the name of a single-entry action. `describe` joins the member
-- descriptions, so `summarize` still emits ONE summary per undo press.
function M.Group(actions)
  local self = { name = 'g', _kind = 'g', actions = actions }
  local function report_temps(staging)
    for _, tmp in ipairs(staging ~= nil and staging.temps or {}) do
      if M.fs.taken(tmp) then
        M.ui.notify('direct: a failed move left the staged entry ' .. tmp,
          vim.log.levels.ERROR)
      end
    end
  end
  self._execute = function()
    local members = self.actions or {}
    local staging, stage_err, stage_temps, stage_overrides =
      M.stage_moves(members)
    if staging == nil and stage_err ~= nil then
      -- Restore only to an unoccupied original path with atomic no-replace
      -- rename. If that fails, leave and report the temp entry; retry only after
      -- manual recovery. The history entry remains available for that retry.
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
      local ok, res, err = pcall(M.execute, exec)
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
  self['do'] = function() return M.execute(self) end
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
-- Serialization
-- ---------------------------------------------------------------------------

-- checked_line(words) -> the FIELD_SEPARATOR-joined line | nil, err. The
-- representability gate runs over every assembled field HERE, so every entry
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
-- The format decision. Only the interlinked moves of one
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

-- Every action kind declares its serialized fields, parser, and reversal in one
-- place. Factories keep the behavior on each action instance; execute dispatch
-- uses this table so callers do not need to know that implementation detail.
local KINDS = {
  mv = {
    fields = { 'src', 'dst' },
    deserialize = function(words) return M.Move(words[2], words[3]) end,
    reverse = function(action) return M.Move(action.dst, action.src) end,
  },
  rm = {
    fields = { 'src', 'dst' },
    deserialize = function(words) return M.Remove(words[2], words[3]) end,
    reverse = function(action) return M.Restore(action.dst, action.src) end,
  },
  rmdir = {
    fields = { 'src', 'dst' },
    deserialize = function(words) return M.RemoveDirectory(words[2], words[3]) end,
    reverse = function(action) return M.RestoreDirectory(action.dst, action.src) end,
  },
  rs = {
    fields = { 'src', 'dst' },
    deserialize = function(words) return M.Restore(words[2], words[3]) end,
    reverse = function(action) return M.Remove(action.dst) end,
  },
  rsdir = {
    fields = { 'src', 'dst' },
    deserialize = function(words) return M.RestoreDirectory(words[2], words[3]) end,
    reverse = function(action) return M.RemoveDirectory(action.dst) end,
  },
  touch = {
    fields = { 'dst' },
    deserialize = function(words) return M.Touch(words[2]) end,
    reverse = function(action) return M.Remove(action.dst) end,
  },
  mkdir = {
    fields = { 'dst' },
    deserialize = function(words) return M.MakeDirectory(words[2]) end,
    reverse = function(action) return M.RemoveDirectory(action.dst) end,
  },
  p = {
    fields = { 'src', 'dst' },
    name_lists = true,
    deserialize = function(words)
      return M.Paste(words[2], words[3], M.split_names(words[4]), M.split_names(words[5]))
    end,
    reverse = function(action)
      local src_names, dst_names = M.split_pairs(action.renames)
      return M.Unpaste(action.dst, action.src, dst_names, src_names)
    end,
  },
  up = {
    fields = { 'src', 'dst' },
    name_lists = true,
    deserialize = function(words)
      return M.Unpaste(words[2], words[3], M.split_names(words[4]), M.split_names(words[5]))
    end,
    reverse = function(action)
      local src_names, dst_names = M.split_pairs(action.renames)
      return M.Paste(action.dst, action.src, dst_names, src_names)
    end,
  },
  g = {
    fields = { 'actions' },
    serialize = M.serialize_group,
    deserialize = function(words)
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
    end,
    reverse = function(action)
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
    end,
  },
}

for name, kind in pairs(KINDS) do
  local expected = name
  kind.execute = function(action)
    if action._kind ~= expected then
      return nil, 'action kind mismatch: expected ' .. expected
        .. ', got ' .. tostring(action._kind)
    end
    if type(action._execute) ~= 'function' then
      return nil, 'action has no executor: ' .. expected
    end
    return action._execute()
  end
end

function M.execute(action)
  if type(action) ~= 'table' then
    return nil, 'invalid action'
  end
  local kind = KINDS[action.name]
  if kind == nil then
    return nil, 'no executor for action: ' .. tostring(action.name)
  end
  return kind.execute(action)
end

-- serialize(action) -> `NAME\tfield...` | nil, err. The field order follows the
-- Python version verbatim: src then dst (each present on the action), then for
-- `p`/`up` the ' '-joined src_names and dst_names lists.
--
-- this is the LAST gate every caller passes through before a line is
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
  local kind = KINDS[action.name]
  if kind == nil then
    return nil, 'cannot serialize action'
  end
  if kind.serialize ~= nil then
    return kind.serialize(action)
  end
  local words = { action.name }
  for _, field in ipairs(kind.fields) do
    if action[field] ~= nil then
      words[#words + 1] = action[field]
    end
  end
  if kind.name_lists then
    local src_names, dst_names = M.split_pairs(action.renames)
    words[#words + 1] = table.concat(src_names, ' ')
    words[#words + 1] = table.concat(dst_names, ' ')
  end
  return checked_line(words)
end

-- deserialize(line) -> the action the line denotes, or nil, err for a
-- malformed or unknown line. Destructive actions are rebuilt through their
-- factories with the serialized dst passed verbatim, so a trashed entry is
-- always restored to and from the exact recorded path.
--
-- A `g` line is validated before anything is rebuilt: the member count must be a
-- plain decimal of at least two and must match the number of src/dst fields
-- exactly; otherwise refuse the whole line so history can retain it. A group is
-- never partially executed: a refusal means nothing ran.
function M.deserialize(line)
  if type(line) ~= 'string' or line == '' then
    return nil, 'invalid action line'
  end
  local words = vim.split(line, FIELD_SEPARATOR, { plain = true })
  local name = words[1]
  local kind = KINDS[name]
  if kind ~= nil then
    return kind.deserialize(words)
  end
  return nil, 'unknown action name: ' .. tostring(name)
end

-- reverse_action(action) -> the reversal per the exact mapping
-- mv -> mv (src/dst swapped)
-- rm -> rs
-- rmdir -> rsdir
-- rs -> rm
-- rsdir -> rmdir
-- touch -> rm
-- mkdir -> rmdir
-- p -> up (src/dst swapped, renames inverted)
-- up -> p (src/dst swapped, renames inverted)
-- g -> g (every member reversed, in reverse order)
--
-- A group reversal applies all its members through the staging path, so the
-- recorded order cannot change the filesystem outcome; reversing order as well
-- keeps the pair a true involution (undo -> redo -> undo reproduces the original
-- record), which is what makes the redo log entry byte-identical for a swap.
function M.reverse_action(action)
  if type(action) ~= 'table' then
    return nil, 'invalid action'
  end
  local kind = KINDS[action.name]
  if kind ~= nil then
    return kind.reverse(action)
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
-- Human summaries
-- ---------------------------------------------------------------------------

-- describe_action(action) -> a human-readable description, never serialized text.
function M.describe_action(action)
  if type(action) == 'table' and type(action.describe) == 'function' then
    return action.describe()
  end
  return tostring(action)
end

-- summarize(actions) joins descriptions with `, ` and uppercases only the first
-- character of the resulting string.
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
