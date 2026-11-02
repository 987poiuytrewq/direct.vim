-- Directory listing, wildignore snapshots, and filtered-descendant checks.
local M = {}
local fs = require('direct.fs')

local function path_identity(path)
  return fs.path_identity(path, fs.stat(path))
end

local function snapshot_identity(snapshot)
  if not snapshot.path_identity then
    snapshot.path_identity = path_identity(snapshot.path)
  end
  return snapshot.path_identity
end

local function snapshot_matches_identity(snapshot, identity)
  local previous = snapshot_identity(snapshot)
  if not previous or not identity then return false end
  -- A matching normalized spelling remains the same directory even if it was
  -- replaced since capture. Different spellings (symlink/relative aliases)
  -- match by filesystem identity, as same_path does.
  return previous.path == identity.path
    or (previous.inode ~= nil and previous.inode == identity.inode)
end

-- entry_path(root, line) -> the absolute entry a buffer line denotes. The
-- spelling is `root.. '/'.. line`, so a directory line keeps its trailing '/'
-- (Python `os.path.join` parity): the delete auto-yank path and the trash
-- digest are therefore the trailing-slash string, exactly as in the Python
-- version. The only root that already ends in a separator is '/'.
function M.entry_path(root, line)
  if type(root) ~= 'string' or type(line) ~= 'string' then
    return root
  end
  if root:sub(-1) == '/' then
    return root .. line
  end
  return root .. '/' .. line
end

-- ignore_set(root) -> the ignore set: the union of
-- `glob(root.. '/'.. pattern, true, true, true)` over the comma-separated
-- trimmed, non-empty `&wildignore` patterns, or nil when there are none. The
-- four glob arguments are {expr}, {nosuf}, {list}, {alllinks}: `nosuf` must be
-- passed or 'suffixes'/'wildmenu' would fabricate matches, `{list}` makes the
-- result an array, and `{alllinks}` follows symlinks while globbing. Matching
-- uses indexed device/inode identity with normalized-name fallback, preserving
-- same_path semantics for every root spelling.
function M.ignore_set(root, wildignore)
  if wildignore == nil then wildignore = vim.o.wildignore or '' end
  if wildignore == '' then
    return nil
  end
  local set = {}
  for pattern in wildignore:gmatch('[^,]+') do
    pattern = vim.trim(pattern)
    if pattern ~= '' then
      local matches = vim.fn.glob(M.entry_path(root, pattern), true, true, true)
      if type(matches) == 'table' then
        for _, match in ipairs(matches) do
          set[#set + 1] = match
        end
      end
    end
  end
  if #set == 0 then
    return nil
  end
  return set
end

-- read(root[, ignored]) -> listing lines, or nil, err when root is not readable.
-- An explicit `ignored` argument is the exact list-time match set; explicit nil
-- means no entries are ignored. With no second argument, use current &wildignore.
function M.read(root, ...)
  local ignored
  if select('#', ...) == 0 then
    ignored = M.ignore_set(root)
  else
    ignored = select(1, ...)
  end
  return fs.read_dir_lines(root, ignored)
end

-- list_with_snapshot(root) returns the current filtered listing and the names
-- omitted by that exact list-time wildignore value. Sync uses the captured names
-- later instead of consulting a possibly changed option.
local function list_with_snapshot(root, read)
  local wildignore = vim.o.wildignore or ''
  local ignored = M.ignore_set(root, wildignore)
  local visible, err = (read or M.read)(root, ignored)
  if not visible then return nil, nil, err end
  local scan, scan_err = vim.uv.fs_scandir(root)
  if not scan then return nil, nil, scan_err end
  local all_names = {}
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if name == nil then break end
    all_names[#all_names + 1] = name
  end
  local visible_set = {}
  for _, line in ipairs(visible) do
    visible_set[line:gsub('/+$', '')] = true
  end
  local hidden = {}
  for _, name in ipairs(all_names) do
    if not visible_set[name] then hidden[#hidden + 1] = name end
  end
  table.sort(hidden)
  return visible, { path = root, hidden = hidden, wildignore = wildignore }
end

local function set_directory_snapshot(state, snapshot)
  state.directory_snapshots = state.directory_snapshots or {}
  local identity = snapshot_identity(snapshot)
  for index, previous in ipairs(state.directory_snapshots) do
    if snapshot_matches_identity(previous, identity) then
      state.directory_snapshots[index] = snapshot
      return
    end
  end
  state.directory_snapshots[#state.directory_snapshots + 1] = snapshot
end

local function get_directory_snapshot(state, path)
  local identity = path_identity(path)
  for _, snapshot in ipairs(state and state.directory_snapshots or {}) do
    if snapshot_matches_identity(snapshot, identity) then return snapshot end
  end
  return nil
end

-- Build the same device/inode and normalized-name index used by the directory
-- listing. The list-time snapshot can contain many ignored entries, so sync
-- must not compare every visible row against every ignored path.
local function ignored_identity_index(paths)
  if not paths or #paths == 0 then return nil end
  local index = { by_path = {}, unknown_by_path = {}, by_inode = {} }
  for _, path in ipairs(paths) do
    local identity = fs.path_identity(path, fs.stat(path))
    if identity then
      index.by_path[identity.path] = true
      if identity.inode then
        index.by_inode[identity.inode] = true
      else
        index.unknown_by_path[identity.path] = true
      end
    end
  end
  return index
end

local function identity_is_ignored(path, index)
  if not index then return false end
  local identity = fs.path_identity(path, fs.stat(path))
  if not identity then return false end
  if identity.inode then
    return index.by_inode[identity.inode] == true
      or index.unknown_by_path[identity.path] == true
  end
  return index.by_path[identity.path] == true
end

local function path_is_ignored(path, ignored_index)
  return identity_is_ignored(path, ignored_index)
end

local function compile_wildignore(wildignore)
  local patterns = {}
  for pattern in (wildignore or ''):gmatch('[^,]+') do
    pattern = vim.trim(pattern)
    if pattern ~= '' then
      local ok, matched = pcall(function()
        local directory_only = pattern:sub(-1) == '/'
        local comparable = directory_only and pattern:gsub('/+$', '') or pattern
        return {
          regex = vim.fn.glob2regpat(pattern),
          comparable_regex = vim.fn.glob2regpat(comparable),
          directory_only = directory_only,
          basename_only = not comparable:find('/', 1, true),
        }
      end)
      if not ok then return nil, matched end
      patterns[#patterns + 1] = matched
    end
  end
  return patterns
end

local function wildignore_matches(name, relative_name, path, stat, patterns)
  local is_directory = stat.type == 'directory'
  if stat.type == 'link' then
    local target = fs.stat(path)
    is_directory = target ~= nil and target.type == 'directory'
  end
  for _, pattern in ipairs(patterns) do
    if not pattern.directory_only or is_directory then
      local candidates
      if pattern.directory_only then
        if pattern.basename_only then
          candidates = { name }
        else
          candidates = { relative_name }
        end
      else
        candidates = { name, relative_name }
      end
      for _, candidate in ipairs(candidates) do
        local regex = pattern.directory_only
          and pattern.comparable_regex or pattern.regex
        local ok, matched = pcall(function()
          return vim.fn.match(candidate, regex) >= 0
        end)
        if not ok then return nil, matched end
        if matched then return true end
      end
    end
  end
  return false
end

local function apply_snapshot(root, lines, snapshot)
  local hidden = {}
  for _, line in ipairs(snapshot.hidden or {}) do hidden[line] = true end
  -- Retain the list-time patterns as well as names seen at list time. Reapply
  -- those patterns to the current directory so matching entries that appeared
  -- after listing cannot be mistaken for user-visible DELETE sources.
  local ignored = ignored_identity_index(M.ignore_set(root, snapshot.wildignore or ''))
  local visible = {}
  for _, line in ipairs(lines) do
    local identity = line:gsub('/+$', '')
    if not hidden[identity]
      and not identity_is_ignored(M.entry_path(root, line), ignored) then
      visible[#visible + 1] = line
    end
  end
  return visible
end

local function path_without_marker(path)
  local trimmed = tostring(path):gsub('/+$', '')
  if trimmed == '' then return '/' end
  return trimmed
end

local function relative_path(root, path)
  local function normalize(value)
    value = vim.fs.normalize(tostring(value)):gsub('\\', '/')
    if value:match('^%a:/$') then return value end
    value = value:gsub('/+$', '')
    return value == '' and '/' or value
  end
  root, path = normalize(root), normalize(path)
  if path == root then return '' end
  local prefix = root
  if prefix:sub(-1) ~= '/' then prefix = prefix .. '/' end
  if path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1)
end

local function lstat(path)
  local ok, result, err = pcall(vim.uv.fs_lstat, path_without_marker(path))
  if not ok then return nil, tostring(result) end
  return result, err
end

local function is_real_directory(path)
  local stat = lstat(path)
  return stat ~= nil and stat.type == 'directory'
end

-- Return a hidden descendant path (or an inspection error) when moving/removing
-- a visible directory would carry a list-time-wildignored entry with it. The
-- walk uses raw scandir names: the filtered entry may be a dangling symlink or
-- an unsupported filesystem type that the display listing intentionally omits.
local function hidden_descendant(directory, root_snapshot, state)
  local visited = {}
  local filters = {}
  local initial_relative = relative_path(root_snapshot.path, directory)
  if initial_relative == nil then
    return nil, 'directory is outside its list-time snapshot'
  end
  local function visit(path, inherited_snapshot, relative_directory)
    local real = fs.realpath(path)
    if visited[real] then return nil end
    visited[real] = true

    local local_snapshot = get_directory_snapshot(state, path)
    local snapshot = local_snapshot or inherited_snapshot
    if local_snapshot then relative_directory = '' end
    local filter = snapshot and filters[snapshot]
    if not filter then
      local wildignore = snapshot and snapshot.wildignore or ''
      local patterns, pattern_err = compile_wildignore(wildignore)
      if not patterns then return nil, pattern_err end
      filter = {
        ignored = ignored_identity_index(
          M.ignore_set(snapshot and snapshot.path or path, wildignore)),
        patterns = patterns,
      }
      if snapshot then filters[snapshot] = filter end
    end
    local names, scan_err = {}, nil
    local scan
    scan, scan_err = vim.uv.fs_scandir(path_without_marker(path))
    if not scan then return nil, scan_err end
    while true do
      local name = vim.uv.fs_scandir_next(scan)
      if name == nil then break end
      names[#names + 1] = name
    end
    table.sort(names)

    local hidden = {}
    if snapshot and fs.same_path(snapshot.path, path) then
      for _, name in ipairs(snapshot.hidden or {}) do
        hidden[name:gsub('/+$', '')] = true
      end
    end
    for _, name in ipairs(names) do
      local child_path = M.entry_path(path_without_marker(path), name)
      local relative_name = relative_directory == '' and name
        or (relative_directory .. '/' .. name)
      if hidden[name] or path_is_ignored(child_path, filter.ignored) then
        return child_path
      end

      local child_stat, stat_err = lstat(child_path)
      if not child_stat then return nil, stat_err or ('cannot inspect ' .. child_path) end
      local matches, match_err = wildignore_matches(name, relative_name,
        child_path, child_stat, filter.patterns)
      if matches == nil then return nil, match_err end
      if matches then return child_path end
      if child_stat.type == 'link' then
        local target_stat = fs.stat(child_path)
        if not target_stat
          or (target_stat.type ~= 'file' and target_stat.type ~= 'directory') then
          return child_path
        end
      elseif child_stat.type ~= 'file' and child_stat.type ~= 'directory' then
        return child_path
      end
      -- A directory symlink is a leaf, not permission to inspect its target.
      if child_stat.type == 'directory' then
        local found, child_err = visit(child_path, snapshot or root_snapshot,
          relative_name)
        if found or child_err then return found, child_err end
      end
    end
    return nil
  end
  return visit(directory, root_snapshot, initial_relative)
end

M.list_with_snapshot = list_with_snapshot
M.set_directory_snapshot = set_directory_snapshot
M.get_directory_snapshot = get_directory_snapshot
M.apply_snapshot = apply_snapshot
M.path_without_marker = path_without_marker
M.lstat = lstat
M.is_real_directory = is_real_directory
M.hidden_descendant = hidden_descendant

return M
