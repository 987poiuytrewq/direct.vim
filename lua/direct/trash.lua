-- direct.trash -- metadata-backed listing and safe management of deleted items.
local M = {}

local fs = require('direct.fs')
local paths = require('direct.paths')
local ui = require('direct.ui')
local history = require('direct.history.history')
local action = require('direct.action.action')
local log = require('direct.log')

local metadata_suffix = '.direct-trash.json'

local function lstat(path)
  local ok, stat = pcall(vim.uv.fs_lstat, path)
  return ok and stat or nil
end

local function trash_dir()
  return paths.data_dir_path('trash')
end

local function format_size(bytes)
  if bytes < 1024 then return string.format('%d B', bytes) end
  local units = { 'KiB', 'MiB', 'GiB', 'TiB' }
  local size, unit = bytes, 0
  repeat
    size, unit = size / 1024, unit + 1
  until size < 1024 or unit == #units
  return string.format('%.1f %s', size, units[unit])
end

local function path_size(path)
  local stat = lstat(path)
  if not stat then return 0 end
  if stat.type ~= 'directory' then return stat.size or 0 end
  local scan = vim.uv.fs_scandir(path)
  if not scan then return stat.size or 0 end
  local total = 0
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if not name then break end
    total = total + path_size(fs.join(path, name))
  end
  return total
end

local function decode_metadata(path)
  local raw, err, exists = log.read_raw(action.trash_metadata_path(path))
  if err then return nil, err end
  if not exists then return nil, 'metadata is unavailable' end
  local ok, value = pcall(vim.json.decode, raw)
  if not ok or type(value) ~= 'table'
    or value.format ~= 'direct-trash' or value.version ~= 1
    or type(value.original) ~= 'string'
    or type(value.deleted_at) ~= 'string'
    or type(value.deleted_at_epoch) ~= 'number'
    or type(value.reserved) ~= 'boolean'
    or (value.kind ~= 'file' and value.kind ~= 'directory'
      and value.kind ~= 'link' and value.kind ~= 'unknown') then
    return nil, 'metadata is damaged'
  end
  local valid, valid_err = paths.validate_canonical_path(value.original)
  if not valid then return nil, 'metadata path is invalid: ' .. tostring(valid_err) end
  return value
end

function M.entries(options)
  options = options or {}
  local directory = trash_dir()
  local dir_stat = directory and lstat(directory)
  if not dir_stat then return {} end
  if dir_stat.type ~= 'directory' then return nil, 'trash path is not a directory' end
  local iter_ok, iter, iter_err = pcall(vim.fs.dir, directory)
  if not iter_ok then return nil, tostring(iter) end
  if not iter then return nil, tostring(iter_err or 'cannot read trash directory') end

  local entries = {}
  for name in iter do
    if not name:match('%.direct%-trash%.json$') then
      local path = fs.join(directory, name)
      local stat = lstat(path)
      if stat then
        local metadata, metadata_err = decode_metadata(path)
        local reserved = metadata and metadata.reserved or false
        if options.include_reserved or not reserved then
          local size = path_size(path)
          local sidecar = lstat(action.trash_metadata_path(path))
          entries[#entries + 1] = {
            id = name,
            path = path,
            original = metadata and metadata.original or nil,
            deleted_at = metadata and metadata.deleted_at or nil,
            deleted_at_epoch = metadata and metadata.deleted_at_epoch or nil,
            kind = metadata and metadata.kind or stat.type,
            reserved = reserved,
            metadata_error = metadata_err,
            size = size,
            storage_size = size + (sidecar and sidecar.size or 0),
          }
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.deleted_at == b.deleted_at then return a.id < b.id end
    if not a.deleted_at then return false end
    if not b.deleted_at then return true end
    return a.deleted_at < b.deleted_at
  end)
  return entries
end

function M.size_bytes()
  local entries, err = M.entries({ include_reserved = true })
  if not entries then return nil, err end
  local total = 0
  for _, entry in ipairs(entries) do total = total + entry.storage_size end
  return total
end

function M.show()
  local retained, retention_err = M.apply_retention()
  if not retained and retention_err then
    ui.notify('direct: trash retention was skipped: ' .. tostring(retention_err),
      vim.log.levels.WARN)
  end
  local entries, err = M.entries()
  if not entries then
    ui.notify('direct: cannot list trash: ' .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end
  local lines = {
    'direct.vim trash',
    'ID\tDELETED\tSIZE\tORIGINAL PATH\tSTATE',
  }
  if #entries == 0 then
    lines[#lines + 1] = '(empty)'
  else
    for _, entry in ipairs(entries) do
      lines[#lines + 1] = table.concat({
        entry.id,
        entry.deleted_at or 'unknown',
        format_size(entry.size),
        entry.original or ('(unknown: ' .. tostring(entry.metadata_error) .. ')'),
        entry.reserved and 'reserved' or 'deleted',
      }, '\t')
    end
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'direct-trash'
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

local function lookup(id)
  if type(id) ~= 'string' or id == '' or id:find('[/\\]') then
    return nil, 'a trash entry ID is required'
  end
  local directory, dir_err = trash_dir()
  if not directory then return nil, dir_err end
  local path = fs.join(directory, id)
  if not fs.taken(path) then return nil, 'trash entry does not exist: ' .. id end
  return path
end

local function referenced_message(path)
  return 'trash entry is still referenced by undo/redo history: ' .. path
    .. '; use :DirectTrash! restore to force it'
end

function M.restore(id, destination, force)
  local path, lookup_err = lookup(id)
  if not path then return nil, lookup_err end
  local metadata, metadata_err = decode_metadata(path)
  if metadata and metadata.reserved then
    return nil, 'trash entry is a history reservation, not a deleted item'
  end
  destination = destination or (metadata and metadata.original)
  if type(destination) ~= 'string' or destination == '' then
    return nil, 'trash metadata is unavailable; supply an explicit restore path'
  end
  destination = paths.root(destination)
  local valid, valid_err = paths.validate_canonical_path(destination)
  if not valid then return nil, 'invalid restore path: ' .. tostring(valid_err) end
  if fs.taken(destination) then
    return nil, 'restore destination already exists: ' .. destination
  end
  local restore_action = action.Restore(path, destination)
  local restored, restore_err = history.apply(restore_action, function()
    return restore_action['do']()
  end, function(_, references)
    if not force and references[paths.canonical(path)] then
      return nil, referenced_message(path)
    end
    return true
  end)
  if restored then ui.notify(action.summarize({ restore_action }), vim.log.levels.INFO) end
  return restored, restore_err
end

local function remove_entry(path)
  local stat = lstat(path)
  if not stat then return false, 'trash entry is no longer present' end
  local removed, err
  if stat.type == 'directory' then
    removed, err = fs.rm_tree(path)
  else
    removed, err = fs.rm_file(path)
  end
  if not removed then return nil, err end
  local metadata_removed, metadata_err = action.clear_trash_metadata(path)
  if not metadata_removed then
    ui.notify('direct: removed trash entry but could not remove its metadata: '
      .. tostring(metadata_err), vim.log.levels.WARN)
  end
  return true
end

local function empty_locked(force, references)
  local entries, err = M.entries({ include_reserved = true })
  if not entries then return nil, err end
  local removed, protected, failed = 0, 0, {}
  for _, entry in ipairs(entries) do
    if not force and references[paths.canonical(entry.path)] then
      protected = protected + 1
    else
      local ok, remove_err = remove_entry(entry.path)
      if ok then
        removed = removed + 1
      elseif ok == nil then
        failed[#failed + 1] = entry.id .. ': ' .. tostring(remove_err)
      end
    end
  end
  if #failed > 0 then
    return nil, 'could not empty all trash entries: ' .. table.concat(failed, '; ')
  end
  ui.notify(string.format('direct: trash emptied (%d removed, %d protected)',
    removed, protected), vim.log.levels.INFO)
  return true, { removed = removed, protected = protected }
end

function M.apply_retention()
  local retention = require('direct.config').options.trash_retention
  if retention == false then return true end
  return history.with_trash_references(function(references)
    local entries, err = M.entries({ include_reserved = true })
    if not entries then return nil, err end
    local total, candidates = 0, {}
    for _, entry in ipairs(entries) do
      total = total + entry.storage_size
      if entry.deleted_at_epoch and not references[paths.canonical(entry.path)] then
        candidates[#candidates + 1] = entry
      end
    end
    table.sort(candidates, function(a, b)
      if a.deleted_at_epoch == b.deleted_at_epoch then return a.id < b.id end
      return a.deleted_at_epoch < b.deleted_at_epoch
    end)

    local removed, removed_ids = 0, {}
    local function prune(entry)
      local ok, remove_err = remove_entry(entry.path)
      if not ok then return nil, remove_err end
      removed, total = removed + 1, total - entry.storage_size
      removed_ids[entry.id] = true
      return true
    end

    local max_age = retention.max_age_days
    if max_age then
      local cutoff = os.time() - max_age * 24 * 60 * 60
      for _, entry in ipairs(candidates) do
        if entry.deleted_at_epoch < cutoff then
          local ok, prune_err = prune(entry)
          if not ok then return nil, prune_err end
        end
      end
    end

    local max_size = retention.max_size_bytes
    if max_size and total > max_size then
      for _, entry in ipairs(candidates) do
        if total <= max_size then break end
        if not removed_ids[entry.id] then
          local ok, prune_err = prune(entry)
          if not ok then return nil, prune_err end
        end
      end
    end

    if removed > 0 then
      ui.notify(string.format('direct: trash retention removed %d unreferenced entr%s',
        removed, removed == 1 and 'y' or 'ies'), vim.log.levels.INFO)
    end
    if max_size and total > max_size then
      ui.notify(string.format('direct: trash exceeds its %d-byte retention limit; '
        .. 'history-referenced or unindexed entries were kept', max_size),
        vim.log.levels.WARN)
    end
    return true, { removed = removed, size_bytes = total }
  end)
end

function M.empty(force)
  return history.with_trash_references(function(references)
    return empty_locked(force == true, references)
  end)
end

M.METADATA_SUFFIX = metadata_suffix
return M
