-- lua/direct/action.lua -- filesystem action factories and execution safeguards.
-- Grouped moves share a staging path so swaps and chains can be undone without
-- overwriting a name whose contents have not yet been saved elsewhere.

local M = {}

M.fs = require('direct.fs')
M.paths = require('direct.paths')
M.ui = require('direct.ui')
M.log = require('direct.log')

local TRASH_METADATA_SUFFIX = '.direct-trash.json'

local function lstat(path)
  local ok, stat = pcall(vim.uv.fs_lstat, path)
  return ok and stat or nil
end

function M.trash_metadata_path(trash_path) return trash_path .. TRASH_METADATA_SUFFIX end

local function trash_metadata(original_path, reserved, purpose)
  local stat = lstat(original_path)
  local value = {
    format = 'direct-trash',
    version = 1,
    original = M.paths.canonical(M.paths.root(original_path)),
    deleted_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    deleted_at_epoch = os.time(),
    deleted_at_estimated = false,
    kind = stat and stat.type or 'unknown',
    reserved = reserved == true,
  }
  if purpose ~= nil then value.purpose = purpose end
  return value
end

function M.write_trash_metadata(trash_path, original_path, purpose)
  local metadata_path = M.trash_metadata_path(trash_path)
  local parent, parent_err = M.fs.mkdirp(M.fs.dirname(metadata_path))
  if not parent then return nil, parent_err end
  local bytes = vim.json.encode(trash_metadata(original_path, false, purpose)) .. '\n'
  local existing, read_err, exists = M.log.read_raw(metadata_path)
  if read_err then return nil, read_err end
  if exists then
    local ok, old = pcall(vim.json.decode, existing)
    if
      not ok
      or type(old) ~= 'table'
      or old.format ~= 'direct-trash'
      or old.version ~= 1
      or old.reserved ~= true
      or old.original ~= M.paths.canonical(M.paths.root(original_path))
    then
      return nil, 'trash slot metadata already exists'
    end
    return M.log.write_raw_atomic(metadata_path, bytes)
  end
  return M.log.write_raw_exclusive(metadata_path, bytes)
end

function M.recover_trash_metadata(trash_path, original_path, kind, deleted_at_epoch)
  if not M.fs.taken(trash_path) then return nil, 'trash entry is no longer present' end
  local original = M.paths.canonical(M.paths.root(original_path))
  local valid, valid_err = M.paths.validate_canonical_path(original)
  if not valid then return nil, 'invalid recovered trash path: ' .. tostring(valid_err) end
  if type(deleted_at_epoch) ~= 'number' or deleted_at_epoch <= 0 then deleted_at_epoch = os.time() end
  if kind ~= 'file' and kind ~= 'directory' and kind ~= 'link' and kind ~= 'unknown' then kind = 'unknown' end
  local value = {
    format = 'direct-trash',
    version = 1,
    original = original,
    deleted_at = os.date('!%Y-%m-%dT%H:%M:%SZ', deleted_at_epoch),
    deleted_at_epoch = deleted_at_epoch,
    deleted_at_estimated = true,
    kind = kind,
    reserved = false,
  }
  return M.log.write_raw_exclusive(M.trash_metadata_path(trash_path), vim.json.encode(value) .. '\n')
end

function M.write_trash_reservation(trash_path, original_path)
  local metadata_path = M.trash_metadata_path(trash_path)
  local parent, parent_err = M.fs.mkdirp(M.fs.dirname(metadata_path))
  if not parent then return nil, parent_err end
  local bytes = vim.json.encode(trash_metadata(original_path, true)) .. '\n'
  local existing, read_err, exists = M.log.read_raw(metadata_path)
  if read_err then return nil, read_err end
  if exists then
    local ok, old = pcall(vim.json.decode, existing)
    if
      not ok
      or type(old) ~= 'table'
      or old.format ~= 'direct-trash'
      or old.version ~= 1
      or old.original ~= M.paths.canonical(M.paths.root(original_path))
    then
      return nil, 'trash slot metadata is damaged'
    end
    return M.log.write_raw_atomic(metadata_path, bytes)
  end
  return M.log.write_raw_exclusive(metadata_path, bytes)
end

function M.clear_trash_metadata(trash_path)
  local path = M.trash_metadata_path(trash_path)
  if not M.fs.taken(path) then return true end
  return M.fs.rm_file(path)
end

-- Bound repeated asynchronous answers that still name an occupied destination.
-- On exhaustion, skip the entry; never write to an existing target.
M.PASTE_CLASH_ATTEMPTS = 10

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- rel(path) -> the CWD-relative spelling of a path, the Lua
-- equivalent of Python's os.path.relpath. `:p:.` resolves the path first so a
-- lexical mismatch (e.g. /tmp vs /private/tmp) cannot suppress the relative
-- form; a path equal to the cwd yields '.', matching Python's relpath(cwd).
-- `:p` appends a trailing filesystem separator to directories, which Python's relpath never
-- does, so it is stripped: a directory description is 'Removed tree', never
-- 'Removed tree/' (Paste's describe adds its own separator).
function M.rel(path)
  if type(path) ~= 'string' then return tostring(path) end
  local rel = vim.fn.fnamemodify(path, ':p:.')
  if rel == '' then return '.' end
  rel = M.paths.strip_trailing_separator(rel)
  if rel == '' then return M.paths.separator end
  return rel
end

-- Close buffers for the resolved pathname before destructive actions. Do not
-- use inode identity: that would also close buffers for distinct hard links.
-- realpath normalizes symlink prefixes, `..`, and trailing separators while keeping
-- different hard-link names distinct.
-- Pure defence and parity: nothing here may raise, so every buffer API call is
-- pcall-guarded.
function M.close_src_buffer(src)
  if type(src) ~= 'string' then return true end
  local target = M.fs.realpath(src)
  local ok = pcall(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' and M.fs.realpath(name) == target then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
    end
  end)
  if not ok then return nil, 'failed to close source buffers' end
  return true
end

-- first_free_trash(trash_dir, src) -> `<trash>/<digest(src)>` or the first
-- free `<digest>-<n>` when that path already exists. The result is
-- persisted in the action's `dst` field and serialized, so `Restore` always
-- reverses to the exact entry.
function M.first_free_trash(trash_dir, src)
  local base = M.paths.digest(src)
  local dst = M.fs.join(trash_dir, base)
  if not M.fs.taken(dst) and not M.fs.taken(M.trash_metadata_path(dst)) then return dst end
  local n = 1
  while M.fs.taken(dst .. '-' .. n) or M.fs.taken(M.trash_metadata_path(dst .. '-' .. n)) do
    n = n + 1
  end
  return dst .. '-' .. n
end

-- split_names(str) -> the entry-name list of a serialized `p`/`up` field.
-- Empty fields deserialize to an empty list (Python `''.split(' ')` yields
-- ['']); an empty name can never be a real entry, so it is dropped here.
function M.split_names(str)
  if type(str) ~= 'string' then return {} end
  return vim.split(str, ' ', { plain = true, trimempty = true })
end

-- entry_name_reason(name) -> nil when `name` is one valid basename component.
function M.entry_name_reason(name)
  if type(name) ~= 'string' or name == '' then return 'empty' end
  if not M.paths.valid_utf8(name) then return 'invalid UTF-8' end
  if name == '.' or name == '..' or name:find('/', 1, true) ~= nil then return 'not a basename component' end
  if name:find('\t', 1, true) ~= nil then return 'contains a tab' end
  if name:find('%c') ~= nil then return 'contains a control character' end
  return nil
end

-- path_reason(path) -> nil when a path is valid UTF-8 and has no control bytes.
-- Tab keeps a specific diagnostic; all controls, including NUL and newlines,
-- are rejected before a JSONL record is built.
function M.path_reason(path)
  if type(path) ~= 'string' then return 'invalid path' end
  if path == '' then return 'invalid path' end
  if not M.paths.valid_utf8(path) then return 'invalid UTF-8' end
  if path:find('\t', 1, true) ~= nil then return 'contains a tab' end
  if path:find('%c') ~= nil then return 'contains a control character' end
  return nil
end

-- Build source/destination pairs in ascending source-name order so serialization
-- and clash-prompt order do not depend on the caller's input order.
local function zipped(src_names, dst_names)
  local pairs_list = {}
  local n = math.min(#(src_names or {}), #(dst_names or {}))
  for i = 1, n do
    local ps, pd = src_names[i], dst_names[i]
    if type(ps) == 'string' and type(pd) == 'string' and ps ~= '' and pd ~= '' then
      pairs_list[#pairs_list + 1] = { src = ps, dst = pd }
    end
  end
  table.sort(pairs_list, function(a, b)
    if a.src == b.src then return false end
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

local function move_progress(src, dst)
  local announced, echo_shown = false, false
  local function report(stage, total)
    if stage == 'copying' and not announced then
      announced = true
      M.ui.notify(
        'direct: copying ' .. M.rel(src) .. ' to ' .. M.rel(dst) .. ' across filesystems',
        vim.log.levels.INFO
      )
    elseif type(stage) == 'number' and (stage == total or stage == 1 or stage % 25 == 0) then
      echo_shown = true
      M.ui.notify(string.format('direct: copying %d/%d files', stage, total), vim.log.levels.INFO, { ephemeral = true })
    end
  end
  local function clear()
    if echo_shown then M.ui.notify('', vim.log.levels.INFO, { ephemeral = true }) end
  end
  return report, clear
end

function M.Move(src, dst)
  local self = { name = 'mv', _kind = 'mv', src = src, dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) and not M.fs.same_entry(self.src, self.dst) then
      return nil, 'destination exists: ' .. tostring(self.dst)
    end
    local ok, close_err = M.close_src_buffer(self.src)
    if not ok then return nil, close_err end
    return M.fs.rename(self.src, self.dst)
  end
  self._execute_async = function(callback)
    if M.fs.taken(self.dst) and not M.fs.same_entry(self.src, self.dst) then
      callback(false, nil, 'destination exists: ' .. tostring(self.dst))
      return
    end
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      callback(false, nil, err)
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(moved, result, move_err)
      clear_progress()
      callback(moved, result, move_err)
    end, progress)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Moved ' .. M.rel(self.src) .. ' to ' .. M.rel(self.dst) end
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
    if trash then self.dst = M.first_free_trash(trash, src) end
  end
  self._execute = function()
    if not self.dst then
      local trash, err = M.paths.ensure_data_dir('trash')
      if not trash then return nil, err end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local trash, err = M.paths.ensure_data_dir('trash')
    if not trash then return nil, err end
    local ok, close_err = M.close_src_buffer(self.src)
    if not ok then return nil, close_err end
    if M.fs.taken(self.dst) then return nil, 'destination exists: ' .. tostring(self.dst) end
    local recorded, record_err = M.write_trash_metadata(self.dst, self.src)
    if not recorded then return nil, 'could not record trash metadata: ' .. tostring(record_err) end
    local moved, move_err = M.fs.rename(self.src, self.dst)
    if not moved then
      local cleared, clear_err = M.clear_trash_metadata(self.dst)
      if not cleared then
        M.ui.notify(
          'direct: could not remove unused trash metadata '
            .. M.trash_metadata_path(self.dst)
            .. ': '
            .. tostring(clear_err),
          vim.log.levels.WARN
        )
      end
      return nil, move_err
    end
    return moved
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Removed ' .. M.rel(self.src) end
  self._execute_async = function(callback)
    if not self.dst then
      local trash, err = M.paths.ensure_data_dir('trash')
      if not trash then
        callback(false, nil, err)
        return
      end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local trash, err = M.paths.ensure_data_dir('trash')
    if not trash then
      callback(false, nil, err)
      return
    end
    local ok, close_err = M.close_src_buffer(self.src)
    if not ok then
      callback(false, nil, close_err)
      return
    end
    if M.fs.taken(self.dst) then
      callback(false, nil, 'destination exists: ' .. tostring(self.dst))
      return
    end
    local recorded, record_err = M.write_trash_metadata(self.dst, self.src)
    if not recorded then
      callback(false, nil, 'could not record trash metadata: ' .. tostring(record_err))
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(moved, result, move_err)
      clear_progress()
      if not moved then
        local cleared, clear_err = M.clear_trash_metadata(self.dst)
        if not cleared then
          M.ui.notify(
            'direct: could not remove unused trash metadata '
              .. M.trash_metadata_path(self.dst)
              .. ': '
              .. tostring(clear_err),
            vim.log.levels.WARN
          )
        end
      end
      callback(moved, result, move_err)
    end, progress)
  end
  return self
end

local function warn_cross_device_trash(src, trash)
  local source_stat, trash_stat = lstat(src), M.fs.stat(trash)
  if
    source_stat
    and source_stat.type == 'directory'
    and trash_stat
    and source_stat.dev ~= nil
    and trash_stat.dev ~= nil
    and source_stat.dev ~= trash_stat.dev
  then
    M.ui.notify(
      'direct: deleting ' .. M.rel(src) .. ' copies its directory tree across filesystems to trash; this may take time',
      vim.log.levels.WARN
    )
  end
end

function M.RemoveDirectory(src, dst)
  local self = { name = 'rmdir', _kind = 'rmdir', src = src }
  if dst ~= nil then
    self.dst = dst
  else
    local trash = M.paths.data_dir_path('trash')
    if trash then self.dst = M.first_free_trash(trash, src) end
  end
  self._execute = function()
    if not self.dst then
      local trash, err = M.paths.ensure_data_dir('trash')
      if not trash then return nil, err end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local trash, err = M.paths.ensure_data_dir('trash')
    if not trash then return nil, err end
    local ok, close_err = M.close_src_buffer(self.src)
    if not ok then return nil, close_err end
    warn_cross_device_trash(self.src, trash)
    if M.fs.taken(self.dst) then return nil, 'destination exists: ' .. tostring(self.dst) end
    local recorded, record_err = M.write_trash_metadata(self.dst, self.src)
    if not recorded then return nil, 'could not record trash metadata: ' .. tostring(record_err) end
    local moved, move_err = M.fs.rename(self.src, self.dst)
    if not moved then
      local cleared, clear_err = M.clear_trash_metadata(self.dst)
      if not cleared then
        M.ui.notify(
          'direct: could not remove unused trash metadata '
            .. M.trash_metadata_path(self.dst)
            .. ': '
            .. tostring(clear_err),
          vim.log.levels.WARN
        )
      end
      return nil, move_err
    end
    return moved
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Removed ' .. M.rel(self.src) end
  self._execute_async = function(callback)
    if not self.dst then
      local trash, err = M.paths.ensure_data_dir('trash')
      if not trash then
        callback(false, nil, err)
        return
      end
      self.dst = M.first_free_trash(trash, self.src)
    end
    local trash, err = M.paths.ensure_data_dir('trash')
    if not trash then
      callback(false, nil, err)
      return
    end
    local ok, close_err = M.close_src_buffer(self.src)
    if not ok then
      callback(false, nil, close_err)
      return
    end
    warn_cross_device_trash(self.src, trash)
    if M.fs.taken(self.dst) then
      callback(false, nil, 'destination exists: ' .. tostring(self.dst))
      return
    end
    local recorded, record_err = M.write_trash_metadata(self.dst, self.src)
    if not recorded then
      callback(false, nil, 'could not record trash metadata: ' .. tostring(record_err))
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(moved, result, move_err)
      clear_progress()
      if not moved then
        local cleared, clear_err = M.clear_trash_metadata(self.dst)
        if not cleared then
          M.ui.notify(
            'direct: could not remove unused trash metadata '
              .. M.trash_metadata_path(self.dst)
              .. ': '
              .. tostring(clear_err),
            vim.log.levels.WARN
          )
        end
      end
      callback(moved, result, move_err)
    end, progress)
  end
  return self
end

function M.Restore(src, dst)
  local self = { name = 'rs', _kind = 'rs', src = src, dst = dst }
  self._execute = function()
    local ok, err = M.close_src_buffer(self.src)
    if not ok then return nil, err end
    local res, rerr = M.fs.rename(self.src, self.dst)
    if res then
      local reserved, reserve_err = M.write_trash_reservation(self.src, self.dst)
      if not reserved then
        M.ui.notify(
          'direct: restored entry but could not reserve its trash slot '
            .. self.src
            .. ' ('
            .. tostring(reserve_err)
            .. ')',
          vim.log.levels.WARN
        )
      end
      -- the trash slot must stay occupied so a later Remove picks a
      -- fresh `-<n>` sibling instead of reusing the exact slot. Leave an
      -- empty marker FILE there; the next remove/restore rename replaces it
      -- atomically (POSIX rename over an empty file). Best-effort: a marker
      -- that cannot be created does not fail the restore.
      M.fs.touch(self.src)
    end
    return res, rerr
  end
  self._execute_async = function(callback)
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      callback(false, nil, err)
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(restored, result, restore_err)
      clear_progress()
      if restored then
        local reserved, reserve_err = M.write_trash_reservation(self.src, self.dst)
        if not reserved then
          M.ui.notify(
            'direct: restored entry but could not reserve its trash slot '
              .. self.src
              .. ' ('
              .. tostring(reserve_err)
              .. ')',
            vim.log.levels.WARN
          )
        end
        M.fs.touch(self.src)
      end
      callback(restored, result, restore_err)
    end, progress)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Restored ' .. M.rel(self.dst) end
  return self
end

function M.RestoreDirectory(src, dst)
  local self = { name = 'rsdir', _kind = 'rsdir', src = src, dst = dst }
  self._execute = function()
    local ok, err = M.close_src_buffer(self.src)
    if not ok then return nil, err end
    local res, rerr = M.fs.rename(self.src, self.dst)
    if res then
      local reserved, reserve_err = M.write_trash_reservation(self.src, self.dst)
      if not reserved then
        M.ui.notify(
          'direct: restored directory but could not reserve its trash slot '
            .. self.src
            .. ' ('
            .. tostring(reserve_err)
            .. ')',
          vim.log.levels.WARN
        )
      end
      -- directory variant: the marker is an empty directory (the POSIX
      -- rename below replaces an empty dir just as easily as a file).
      local mok, merr = M.fs.mkdir_exclusive(self.src)
      if not mok then
        M.ui.notify(
          'direct: restored directory, but could not reserve its trash slot ' .. self.src .. ': ' .. tostring(merr),
          vim.log.levels.WARN
        )
      end
    end
    return res, rerr
  end
  self._execute_async = function(callback)
    local ok, err = M.close_src_buffer(self.src)
    if not ok then
      callback(false, nil, err)
      return
    end
    local progress, clear_progress = move_progress(self.src, self.dst)
    M.fs.rename_async(self.src, self.dst, function(restored, result, restore_err)
      clear_progress()
      if restored then
        local reserved, reserve_err = M.write_trash_reservation(self.src, self.dst)
        if not reserved then
          M.ui.notify(
            'direct: restored directory but could not reserve its trash slot '
              .. self.src
              .. ' ('
              .. tostring(reserve_err)
              .. ')',
            vim.log.levels.WARN
          )
        end
        local made, make_err = M.fs.mkdir_exclusive(self.src)
        if not made then
          M.ui.notify(
            'direct: restored directory, but could not reserve its trash slot '
              .. self.src
              .. ': '
              .. tostring(make_err),
            vim.log.levels.WARN
          )
        end
      end
      callback(restored, result, restore_err)
    end, progress)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Restored ' .. M.rel(self.dst) end
  return self
end

function M.Touch(dst)
  local self = { name = 'touch', _kind = 'touch', dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) then return nil, 'destination exists: ' .. tostring(self.dst) end
    return M.fs.touch(self.dst)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Created ' .. M.rel(self.dst) end
  return self
end

function M.MakeDirectory(dst)
  local self = { name = 'mkdir', _kind = 'mkdir', dst = dst }
  self._execute = function()
    if M.fs.taken(self.dst) then return nil, 'destination exists: ' .. tostring(self.dst) end
    return M.fs.mkdir_exclusive(self.dst)
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Created ' .. M.rel(self.dst) end
  return self
end

-- ---------------------------------------------------------------------------
-- Multi-actions
-- ---------------------------------------------------------------------------

-- Paste creates an action. Its callback executor prompts asynchronously on
-- clashes; the synchronous executor refuses clashes rather than blocking.
function M.Paste(src, dst, src_names, dst_names)
  local self = {
    name = 'p',
    _kind = 'p',
    src = src,
    dst = dst,
    renames = zipped(src_names, dst_names),
  }
  self._execute = function()
    local copied, last = {}, nil
    for _, pair in ipairs(self.renames) do
      local full_src = M.fs.join(self.src, pair.src)
      local full_dst = M.fs.join(self.dst, pair.dst)
      local st = M.fs.stat(full_src)
      if st then
        if M.fs.taken(full_dst) then
          return nil, 'paste requires async execution for a destination clash: ' .. tostring(full_dst)
        end
        if st.type == 'file' then
          local ok, err = M.fs.copy_file_exclusive(full_src, full_dst)
          if not ok then return nil, err end
        elseif st.type == 'directory' then
          local ok, skipped = M.fs.copy_tree_exclusive(full_src, full_dst)
          if not ok then return nil, skipped end
          if skipped ~= nil and #skipped > 0 then
            M.ui.notify(
              'Skipped '
                .. #skipped
                .. ' '
                .. (#skipped == 1 and 'entry' or 'entries')
                .. ' that cannot be copied: '
                .. full_src,
              vim.log.levels.WARN
            )
          end
        end
        copied[#copied + 1] = { src = pair.src, dst = pair.dst }
        last = full_dst
      end
    end
    self.renames = copied
    return last or true
  end
  self._execute_async = function(callback)
    local copied, index, last = {}, 1, nil
    local completed = false
    local function finish(ok, result, err)
      if completed then return end
      completed = true
      self.renames = copied
      callback(ok, result, err)
    end
    local function fail(err) finish(false, nil, tostring(err or 'paste failed')) end
    local process_next
    local function skip(pair)
      M.ui.notify('Skipped ' .. pair.src, vim.log.levels.WARN)
      index = index + 1
      process_next()
    end
    local function copy_pair(pair, full_src, full_dst, st)
      if type(self._before_copy) == 'function' then
        local ready, ready_err = self._before_copy(pair, full_src, full_dst)
        if not ready then
          fail(ready_err or 'could not journal paste entry')
          return
        end
      end
      local called, ok, extra, code = pcall(function()
        if st.type == 'file' then
          return M.fs.copy_file_exclusive(full_src, full_dst)
        elseif st.type == 'directory' then
          return M.fs.copy_tree_exclusive(full_src, full_dst)
        end
        return true
      end)
      if not called then
        fail(ok)
        return
      end
      if not ok then
        if code == 'EEXIST' and type(self._on_copy_conflict) == 'function' then
          local cleared, clear_err = self._on_copy_conflict(pair)
          if not cleared then
            fail(clear_err or extra or code or 'destination exists')
            return
          end
        end
        fail(extra or code or 'copy failed')
        return
      end
      if st.type == 'directory' and type(extra) == 'table' and #extra > 0 then
        M.ui.notify(
          'Skipped '
            .. #extra
            .. ' '
            .. (#extra == 1 and 'entry' or 'entries')
            .. ' that cannot be copied: '
            .. full_src,
          vim.log.levels.WARN
        )
      end
      last = full_dst
      copied[#copied + 1] = { src = pair.src, dst = pair.dst }
      index = index + 1
      if type(self._after_copy) == 'function' then
        local recorded, record_err = self._after_copy(pair, full_src, full_dst)
        if not recorded then
          fail(record_err or 'could not record pasted entry')
          return
        end
      end
      process_next()
    end
    local function request_name(pair, full_src, st, attempts)
      if attempts >= M.PASTE_CLASH_ATTEMPTS then
        skip(pair)
        return
      end
      local current = M.fs.join(self.dst, pair.dst)
      local entry_type = M.fs.is_file(current) and 'File' or 'Directory'
      local called, started, start_err = pcall(
        M.ui.input,
        entry_type .. ' already exists. Paste as: ',
        pair.src,
        'file',
        function(answer)
          if answer == nil or M.entry_name_reason(answer) ~= nil then
            skip(pair)
            return
          end
          pair.dst = answer
          local chosen = M.fs.join(self.dst, pair.dst)
          if M.fs.taken(chosen) then
            request_name(pair, full_src, st, attempts + 1)
          else
            copy_pair(pair, full_src, chosen, st)
          end
        end,
        function(input_err) fail(input_err) end
      )
      if not called then
        fail(started)
      elseif started ~= true then
        fail(start_err or 'could not start paste input')
      end
    end
    process_next = function()
      if index > #self.renames then
        finish(true, last, nil)
        return
      end
      local pair = self.renames[index]
      local full_src = M.fs.join(self.src, pair.src)
      local full_dst = M.fs.join(self.dst, pair.dst)
      local st = M.fs.stat(full_src)
      if not st then
        index = index + 1
        process_next()
      elseif st.type ~= 'file' and st.type ~= 'directory' then
        M.ui.notify('Skipped unsupported register entry: ' .. full_src, vim.log.levels.WARN)
        index = index + 1
        process_next()
      elseif M.fs.taken(full_dst) then
        request_name(pair, full_src, st, 0)
      else
        copy_pair(pair, full_src, full_dst, st)
      end
    end
    process_next()
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Pasted into ' .. M.rel(self.dst) .. M.paths.separator end
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
      local called, restored, err = pcall(M.fs.rename_noreplace, item.quarantine, item.path, item.identity)
      if not called then
        err, restored = tostring(restored), nil
      end
      if not restored then
        failures[#failures + 1] = item.quarantine
        M.ui.notify(
          'direct: could not restore Unpaste quarantine '
            .. item.quarantine
            .. ' to '
            .. item.path
            .. ' ('
            .. tostring(err)
            .. '); quarantine preserved',
          vim.log.levels.ERROR
        )
      end
    end
  end
  return failures
end

local function capture_unpaste_item(item)
  if item.quarantine then
    local called, moved, err = pcall(M.fs.rename_noreplace, item.path, item.quarantine, item.identity)
    if not called then
      err, moved = tostring(moved), nil
    end
    if not moved then return nil, err end
    local identity, stat = M.fs.entry_identity(item.quarantine)
    if identity == nil or identity.inode == nil or item.identity == nil or identity.inode ~= item.identity.inode then
      return nil, 'captured entry identity differs from the inspected source'
    end
    item.identity = identity
    item.kind = stat and stat.type or nil
    return true
  end
  for _ = 1, 100 do
    local quarantine = M.fs.unique_temp_path(M.fs.dirname(item.path), 'unpaste')
    if type(quarantine) ~= 'string' then return nil, 'could not allocate a unique Unpaste quarantine' end
    local called, moved, err, code = pcall(M.fs.rename_noreplace, item.path, quarantine, item.identity)
    if not called then
      err, moved = tostring(moved), nil
    end
    if moved then
      item.quarantine = quarantine
      local identity, stat = M.fs.entry_identity(quarantine)
      if identity == nil or identity.inode == nil then return nil, 'could not verify captured entry identity' end
      if item.identity == nil or item.identity.inode ~= identity.inode then
        return nil, 'captured entry identity differs from the inspected source'
      end
      item.identity = identity
      item.kind = stat and stat.type or nil
      return true
    end
    if code ~= 'EEXIST' and not tostring(err):find('destination exists', 1, true) then return nil, err end
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
    _completed_renames = {},
  }
  self._execute = function()
    self._completed_renames = {}
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
      if not stat or (stat.type ~= 'file' and stat.type ~= 'directory' and stat.type ~= 'link') then
        return unpaste_refusal('unsupported pasted entry type: ' .. path)
      end
      local matches, compare_err = compare_unpaste_contents(path, reference)
      if matches ~= true then
        return unpaste_refusal(
          'pasted entry does not match register content: '
            .. path
            .. (compare_err and (' (' .. tostring(compare_err) .. ')') or '')
        )
      end
      local item = {
        path = path,
        reference = reference,
        identity = identity,
        kind = stat.type,
        pair = pair,
      }
      local planned = self._journal_items and self._journal_items[#items + 1]
      if planned then
        if planned.src ~= pair.src or planned.dst ~= pair.dst or planned.identity.inode ~= identity.inode then
          return unpaste_refusal('journaled Unpaste plan no longer matches: ' .. path)
        end
        item.quarantine = planned.quarantine
      end
      items[#items + 1] = item
    end

    if type(self._on_unpaste_begin) == 'function' then
      local ready, ready_err = self._on_unpaste_begin(items)
      if not ready then return unpaste_refusal('could not prepare Unpaste recovery: ' .. tostring(ready_err)) end
      self._journal_active = true
    end

    -- Phase B: atomically capture and re-verify every target. If any capture or
    -- verification fails, restore prior captures only with no-replace; if a path
    -- is blocked, preserve and report its quarantine path. No deletion yet.
    local captured = {}
    for _, item in ipairs(items) do
      captured[#captured + 1] = item
      local ok, err = capture_unpaste_item(item)
      if not ok then
        local reason = 'could not capture pasted entry: ' .. item.path .. ' (' .. tostring(err) .. ')'
        if not self._journal_active then
          restore_unpaste_captures(captured)
        else
          for _, captured_item in ipairs(captured) do
            if M.fs.taken(captured_item.quarantine) then
              M.ui.notify('direct: Unpaste quarantine preserved at ' .. captured_item.quarantine, vim.log.levels.ERROR)
            end
          end
        end
        return unpaste_refusal(reason)
      end
      if type(self._after_unpaste_capture) == 'function' then
        local recorded, record_err = self._after_unpaste_capture(#captured, item)
        if not recorded then
          return unpaste_refusal('could not record captured Unpaste entry: ' .. tostring(record_err))
        end
      end
      local matches, compare_err = compare_unpaste_contents(item.quarantine, item.reference)
      if matches ~= true then
        local reason = 'captured entry no longer matches register content: '
          .. item.path
          .. (compare_err and (' (' .. tostring(compare_err) .. ')') or '')
        if not self._journal_active then
          restore_unpaste_captures(captured)
        else
          M.ui.notify('direct: Unpaste quarantine preserved at ' .. item.quarantine, vim.log.levels.ERROR)
        end
        return unpaste_refusal(reason)
      end
    end

    if type(self._before_unpaste_delete) == 'function' then
      local ready, ready_err = self._before_unpaste_delete(captured)
      if not ready then return unpaste_refusal('could not prepare Unpaste deletion: ' .. tostring(ready_err)) end
    end

    -- Phase C: delete only the captured Q paths, never the original P paths.
    -- A failure can leave earlier deletions committed; all remaining Q paths
    -- are preserved and reported rather than force-cleaned.
    for i, item in ipairs(captured) do
      local current = M.fs.entry_identity(item.quarantine)
      if current == nil or current.inode == nil or current.inode ~= item.identity.inode then
        M.ui.notify('direct: Unpaste quarantine changed; preserved at ' .. item.quarantine, vim.log.levels.ERROR)
        for j = i + 1, #captured do
          if M.fs.taken(captured[j].quarantine) then
            M.ui.notify('direct: Unpaste entry preserved at ' .. captured[j].quarantine, vim.log.levels.ERROR)
          end
        end
        return unpaste_refusal('captured entry changed before deletion: ' .. item.quarantine)
      end
      local matches, compare_err = compare_unpaste_contents(item.quarantine, item.reference)
      if matches ~= true then
        M.ui.notify('direct: Unpaste entry preserved at ' .. item.quarantine, vim.log.levels.ERROR)
        for j = i + 1, #captured do
          if M.fs.taken(captured[j].quarantine) then
            M.ui.notify('direct: Unpaste entry preserved at ' .. captured[j].quarantine, vim.log.levels.ERROR)
          end
        end
        return unpaste_refusal('captured entry changed before deletion: ' .. tostring(compare_err or item.quarantine))
      end
      local deleted, delete_err
      local called
      if item.kind == 'directory' then
        called, deleted, delete_err = pcall(M.fs.rm_tree, item.quarantine)
      else
        called, deleted, delete_err = pcall(M.fs.rm_file, item.quarantine)
      end
      if not called then
        delete_err, deleted = tostring(deleted), nil
      end
      if not deleted or M.fs.taken(item.quarantine) then
        for j = i, #captured do
          if M.fs.taken(captured[j].quarantine) then
            M.ui.notify('direct: Unpaste entry preserved at ' .. captured[j].quarantine, vim.log.levels.ERROR)
          end
        end
        return unpaste_refusal('could not delete captured entry ' .. item.quarantine .. ': ' .. tostring(delete_err))
      end
      self._completed_renames[#self._completed_renames + 1] = {
        src = item.pair.src,
        dst = item.pair.dst,
      }
      if type(self._after_unpaste_delete) == 'function' then
        local recorded, record_err = self._after_unpaste_delete(i, item)
        if not recorded then
          return unpaste_refusal('could not record deleted Unpaste entry: ' .. tostring(record_err))
        end
      end
    end
    return true
  end
  self['do'] = function() return M.execute(self) end
  function self.describe() return 'Reversed paste into ' .. M.rel(self.src) .. M.paths.separator end
  return self
end

-- Human summaries
-- ---------------------------------------------------------------------------

-- describe_action(action) -> a human-readable description, never serialized text.
function M.describe_action(action)
  if type(action) == 'table' and type(action.describe) == 'function' then return action.describe() end
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
  if #summary > 0 then summary = summary:sub(1, 1):upper() .. summary:sub(2) end
  return summary
end

require('direct.action.moves')(M)
require('direct.action.registry')(M)

return M
