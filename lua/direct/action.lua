-- lua/direct/action.lua -- filesystem action factories and execution safeguards.
-- Grouped moves share a staging path so swaps and chains can be undone without
-- overwriting a name whose contents have not yet been saved elsewhere.

local M = {}

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.ui = require('direct.ui')

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

-- entry_name_reason(name) -> nil when `name` is one valid basename component.
function M.entry_name_reason(name)
  if type(name) ~= 'string' or name == '' then
    return 'empty'
  end
  if not M.paths.valid_utf8(name) then
    return 'invalid UTF-8'
  end
  if name == '.' or name == '..' or name:find('/', 1, true) ~= nil then
    return 'not a basename component'
  end
  if name:find('\t', 1, true) ~= nil then
    return 'contains a tab'
  end
  if name:find('%c') ~= nil then
    return 'contains a control character'
  end
  return nil
end

-- path_reason(path) -> nil when a path is valid UTF-8 and has no control bytes.
-- Tab keeps a specific diagnostic; all controls, including NUL and newlines,
-- are rejected before a JSONL record is built.
function M.path_reason(path)
  if type(path) ~= 'string' then
    return 'invalid path'
  end
  if path == '' then
    return 'invalid path'
  end
  if not M.paths.valid_utf8(path) then
    return 'invalid UTF-8'
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
    local trash = M.paths.data_dir_path('trash')
    if trash then
      self.dst = M.first_free_trash(trash, src)
    end
  end
  self._execute = function()
    if not self.dst then
      local trash, err = M.paths.ensure_data_dir('trash')
      if not trash then
        return nil, err
      end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local trash, err = M.paths.ensure_data_dir('trash')
    if not trash then return nil, err end
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
    local trash = M.paths.data_dir_path('trash')
    if trash then
      self.dst = M.first_free_trash(trash, src)
    end
  end
  self._execute = function()
    if not self.dst then
      local trash, err = M.paths.ensure_data_dir('trash')
      if not trash then
        return nil, err
      end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local trash, err = M.paths.ensure_data_dir('trash')
    if not trash then return nil, err end
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
      local mok, merr = M.fs.mkdir_exclusive(self.src)
      if not mok then
        M.ui.notify('direct: restored directory, but could not reserve its trash slot '
          .. self.src .. ': ' .. tostring(merr), vim.log.levels.WARN)
      end
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
    return M.fs.mkdir_exclusive(self.dst)
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
-- never delete data that predated the paste. An empty, cancelled, or invalid
-- basename answer skips the entry and reports it; spaces round-trip in JSON.
-- ui.prompt re-raises after inputrestore on
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
        -- on); an empty, cancelled or invalid-component answer skips the entry.
        -- The final file copy is exclusive and directory copy commits by
        -- no-replace rename, so a destination racing in after this check fails
        -- closed too.
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
            -- an empty/cancelled answer or an invalid basename component skips
            -- the ENTRY
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
            local ok, err = M.fs.copy_file_exclusive(full_src, full_dst)
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
            local ok, skipped = M.fs.copy_tree_exclusive(full_src, full_dst)
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

local function unpaste_refusal(reason)
  M.ui.notify('direct: Unpaste refused: ' .. tostring(reason), vim.log.levels.ERROR)
  return nil, reason
end

local function compare_unpaste_contents(path, reference)
  local ok, matches, err = pcall(M.fs.same_contents, path, reference)
  if not ok then return nil, tostring(matches) end
  return matches, err
end

local function restore_unpaste_captures(captured)
  local failures = {}
  for i = #captured, 1, -1 do
    local item = captured[i]
    if M.fs.taken(item.quarantine) then
      local called, restored, err = pcall(M.fs.rename_noreplace,
        item.quarantine, item.path, item.identity)
      if not called then err, restored = tostring(restored), nil end
      if not restored then
        failures[#failures + 1] = item.quarantine
        M.ui.notify('direct: could not restore Unpaste quarantine '
          .. item.quarantine .. ' to ' .. item.path .. ' (' .. tostring(err)
          .. '); quarantine preserved', vim.log.levels.ERROR)
      end
    end
  end
  return failures
end

local function capture_unpaste_item(item)
  for _ = 1, 100 do
    local quarantine = M.fs.unique_temp_path(M.fs.dirname(item.path), 'unpaste')
    if type(quarantine) ~= 'string' then
      return nil, 'could not allocate a unique Unpaste quarantine'
    end
    local called, moved, err, code = pcall(M.fs.rename_noreplace,
      item.path, quarantine, item.identity)
    if not called then err, moved = tostring(moved), nil end
    if moved then
      item.quarantine = quarantine
      local identity, stat = M.fs.entry_identity(quarantine)
      if identity == nil or identity.inode == nil then
        return nil, 'could not verify captured entry identity'
      end
      if item.identity == nil or item.identity.inode ~= identity.inode then
        return nil, 'captured entry identity differs from the inspected source'
      end
      item.identity = identity
      item.kind = stat and stat.type or nil
      return true
    end
    if code ~= 'EEXIST' and not tostring(err):find('destination exists', 1, true) then
      return nil, err
    end
  end
  return nil, 'could not allocate a unique Unpaste quarantine'
end

-- Unpaste verifies every pasted target against the current register copy, then
-- captures all targets under same-directory quarantine names before deleting
-- any of them. This is the inverse of Paste; it never deletes by the original P
-- pathname after the capture phase.
function M.Unpaste(src, dst, src_names, dst_names)
  local self = {
    name = 'up',
    _kind = 'up',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
  }
  self._execute = function()
    -- A re-yank changes the register pointer. The old content path is not enough
    -- to authorize deletion if the live register no longer refers to it.
    local current_register, register_err = require('direct.register').content()
    if current_register == nil or current_register ~= self.dst then
      return unpaste_refusal(register_err or 'register is missing or was re-yanked')
    end

    -- Phase A: validate the complete operation without mutation. Files compare
    -- bytes; directories compare exact descendants; symlinks compare readlink
    -- targets without following them. Any unsupported/missing/unreadable object
    -- refuses the whole batch before capture begins.
    local items = {}
    for _, pair in ipairs(self.renames) do
      local path = M.fs.join(self.src, pair.src)
      local reference = M.fs.join(self.dst, pair.dst)
      local identity, stat = M.fs.entry_identity(path)
      if identity == nil or identity.inode == nil then
        return unpaste_refusal('cannot inspect pasted entry: ' .. path)
      end
      if not stat or (stat.type ~= 'file' and stat.type ~= 'directory'
          and stat.type ~= 'link') then
        return unpaste_refusal('unsupported pasted entry type: ' .. path)
      end
      local matches, compare_err = compare_unpaste_contents(path, reference)
      if matches ~= true then
        return unpaste_refusal('pasted entry does not match register content: '
          .. path .. (compare_err and (' (' .. tostring(compare_err) .. ')') or ''))
      end
      items[#items + 1] = {
        path = path,
        reference = reference,
        identity = identity,
        kind = stat.type,
      }
    end

    -- Phase B: atomically capture and re-verify every target. If any capture or
    -- verification fails, restore prior captures only with no-replace; if a path
    -- is blocked, preserve and report its quarantine path. No deletion yet.
    local captured = {}
    for _, item in ipairs(items) do
      captured[#captured + 1] = item
      local ok, err = capture_unpaste_item(item)
      if not ok then
        local reason = 'could not capture pasted entry: ' .. item.path
          .. ' (' .. tostring(err) .. ')'
        restore_unpaste_captures(captured)
        return unpaste_refusal(reason)
      end
      local matches, compare_err = compare_unpaste_contents(item.quarantine, item.reference)
      if matches ~= true then
        local reason = 'captured entry no longer matches register content: '
          .. item.path .. (compare_err and (' (' .. tostring(compare_err) .. ')') or '')
        restore_unpaste_captures(captured)
        return unpaste_refusal(reason)
      end
    end

    -- Phase C: delete only the captured Q paths, never the original P paths.
    -- A failure can leave earlier deletions committed; all remaining Q paths
    -- are preserved and reported rather than force-cleaned.
    for i, item in ipairs(captured) do
      local current = M.fs.entry_identity(item.quarantine)
      if current == nil or current.inode == nil or current.inode ~= item.identity.inode then
        M.ui.notify('direct: Unpaste quarantine changed; preserved at '
          .. item.quarantine, vim.log.levels.ERROR)
        for j = i + 1, #captured do
          if M.fs.taken(captured[j].quarantine) then
            M.ui.notify('direct: Unpaste entry preserved at '
              .. captured[j].quarantine, vim.log.levels.ERROR)
          end
        end
        return unpaste_refusal('captured entry changed before deletion: '
          .. item.quarantine)
      end
      local matches, compare_err = compare_unpaste_contents(item.quarantine, item.reference)
      if matches ~= true then
        M.ui.notify('direct: Unpaste entry preserved at ' .. item.quarantine,
          vim.log.levels.ERROR)
        for j = i + 1, #captured do
          if M.fs.taken(captured[j].quarantine) then
            M.ui.notify('direct: Unpaste entry preserved at '
              .. captured[j].quarantine, vim.log.levels.ERROR)
          end
        end
        return unpaste_refusal('captured entry changed before deletion: '
          .. tostring(compare_err or item.quarantine))
      end
      local deleted, delete_err
      local called
      if item.kind == 'directory' then
        called, deleted, delete_err = pcall(M.fs.rm_tree, item.quarantine)
      else
        called, deleted, delete_err = pcall(M.fs.rm_file, item.quarantine)
      end
      if not called then delete_err, deleted = tostring(deleted), nil end
      if not deleted or M.fs.taken(item.quarantine) then
        for j = i, #captured do
          if M.fs.taken(captured[j].quarantine) then
            M.ui.notify('direct: Unpaste entry preserved at '
              .. captured[j].quarantine, vim.log.levels.ERROR)
          end
        end
        return unpaste_refusal('could not delete captured entry '
          .. item.quarantine .. ': ' .. tostring(delete_err))
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

-- stage_moves(actions) -> { overrides = { src -> tmp }, temps = { tmp },
-- identities = { src -> identity } } when a
-- rename `dst` is also some action's `src` (a swap, a chain or a rotation), else
-- nil. Only `mv` actions participate. A staging rename failure returns
-- `nil, err, temps, overrides, identities`, where `temps` are the entries
-- ALREADY renamed to temp paths and `identities` records the staged inodes. The
-- caller must verify identity and restore only with no-replace, or report any
-- stranded path instead of deleting it.
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
  local overrides, temps, identities = {}, {}, {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.src ~= nil and stage_sources[move_key(act.src)]
      and overrides[act.src] == nil then
      local tmp = M.first_free_temp(parent_dir(act.src))
      local identity = M.fs.entry_identity(act.src)
      local ok, err = M.fs.rename(act.src, tmp)
      if not ok then
        -- return the temps accumulated so far ALONGSIDE the error
        -- (and the partial overrides that name each temp's original path), so
        -- the caller can report -- and, where it must, restore -- each entry
        -- that is now parked at a temp path instead of returning the error
        -- alone and orphaning them silently.
        return nil, err, temps, overrides, identities
      end
      overrides[act.src] = tmp
      identities[act.src] = identity
      temps[#temps + 1] = tmp
    end
  end
  return { overrides = overrides, temps = temps, identities = identities }
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
    local staging, stage_err, stage_temps, stage_overrides, stage_identities =
      M.stage_moves(members)
    if staging == nil and stage_err ~= nil then
      -- Restore only to an unoccupied original path with atomic no-replace
      -- rename. If that fails, leave and report the temp entry; retry only after
      -- manual recovery. The history entry remains available for that retry.
      local overrides = stage_overrides or {}
      local identities = stage_identities or {}
      local reported = {}
      for _, act in ipairs(members) do
        local tmp = act.src ~= nil and overrides[act.src] or nil
        if tmp ~= nil and M.fs.taken(tmp) then
          local expected = identities[act.src]
          local rok, rerr = M.fs.rename_noreplace(tmp, act.src, expected)
          if not rok then
            reported[tmp] = true
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
        if M.fs.taken(tmp) and not reported[tmp] then
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

-- Attach dispatch, serialization, deserialization, and reversal after all
-- action factories and facade helpers have been defined.
require('direct.action_registry')(M)

return M
