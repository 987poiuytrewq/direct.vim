-- Filesystem path, directory listing, and entry-identity operations.
-- Methods are installed onto the shared fs table to retain its API.

return function(context)
  local M = context.M
  local platform = context.platform
  local identity_key = context.identity_key

-- Thin pure wrappers
-- ---------------------------------------------------------------------------

-- abspath(path) -> absolute path | nil, 'invalid path'. Reject non-strings
-- before calling vim.fs.abspath, which raises on nil.
function M.abspath(path)
  if type(path) ~= 'string' then
    return nil, 'invalid path'
  end
  return vim.fs.abspath(path)
end

-- Strip trailing separators before basename: vim.fs.basename('/a/b/') is empty,
-- which would make a directory yank store an empty name.
function M.basename(path)
  if type(path) ~= 'string' then
    return nil, 'invalid path'
  end
  local trimmed = require('direct.paths').strip_trailing_separator(path)
  return vim.fs.basename(trimmed)
end

function M.dirname(path)
  return vim.fs.dirname(path)
end

function M.join(...)
  return vim.fs.joinpath(...)
end

-- ---------------------------------------------------------------------------
-- stat / predicates
-- ---------------------------------------------------------------------------

-- stat(path) -> vim.uv.fs_stat result (follows symlinks) or nil, err.
function M.stat(path)
  if type(path) ~= 'string' or path == '' then
    return nil, 'invalid path'
  end
  local ok, st, err = pcall(vim.uv.fs_stat, path)
  if not ok then
    return nil, tostring(st)
  end
  if st then
    return st
  end
  return nil, err
end

function M.exists(path)
  return M.stat(path) ~= nil
end

-- taken(path) is the shared occupancy check for paste clashes, trash names, and
-- copy destinations, so those write paths cannot disagree.
--
-- It uses lstat, NOT the following stat behind M.exists: a DANGLING symlink
-- occupies the name and counts as taken. That is the deliberate choice -- a
-- write through such a path lands on something the user already has (or fails
-- late), whereas reporting the name free would let a copy or paste write onto a
-- path it does not own. M.exists keeps its following semantics for callers that
-- ask "does this resolve to something?".
function M.taken(path)
  if type(path) ~= 'string' or path == '' then
    return false
  end
-- A trailing marker is not part of the filesystem name. In particular,
-- lstat("dangling-link/") follows the final slash and fails, hiding the
-- occupied symlink name. Preserve a filesystem root while trimming it.
  local lookup = require('direct.paths').strip_trailing_separator(path)
  local ok, st = pcall(vim.uv.fs_lstat, lookup)
  return ok and st ~= nil
end

-- is_dir/is_file follow symlinks and always return booleans.
function M.is_dir(path)
  local st = M.stat(path)
  return st ~= nil and st.type == 'directory'
end

function M.is_file(path)
  local st = M.stat(path)
  return st ~= nil and st.type == 'file'
end

-- Return the resolved path, or the original input if resolution fails. Use
-- vim.uv.fs_realpath because vim.fs.realpath is unavailable in this runtime.
function M.realpath(path)
  if type(path) ~= 'string' or path == '' then
    return path
  end
  local ok, real = pcall(vim.uv.fs_realpath, path)
  if ok and real then
    return real
  end
  return path
end

-- ---------------------------------------------------------------------------
-- Directory listing
-- ---------------------------------------------------------------------------

-- iter_dir(path) -> iterator yielding (name, type) from vim.fs.dir. A path that
-- cannot be opened yields nothing rather than raising.
function M.iter_dir(path)
  if not M.is_dir(path) then
    return function()
      return nil
    end
  end
  local iter = vim.fs.dir(path)
  if type(iter) ~= 'function' then
    return function()
      return nil
    end
  end
  return iter
end

-- list_dir(path) -> names sorted byte-wise ascending, or nil, err.
function M.list_dir(path)
  if not M.is_dir(path) then
    return nil, 'not a directory: ' .. tostring(path)
  end
  local names = {}
  for name in M.iter_dir(path) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- A path identity captures the same semantics as same_path without retaining
-- a path-to-path comparison loop. Missing/zero device or inode values are
-- deliberately treated as unknown and use the normalized-name fallback.
function M.path_identity(path, st)
  if type(path) ~= 'string' then return nil end
  local paths = require('direct.paths')
  local identity = { path = platform.identity_path(path) }
  identity.inode = platform.file_identity(path, st and st.type == 'link')
  if not identity.inode and st and st.dev ~= nil and st.ino ~= nil
    and st.dev ~= 0 and st.ino ~= 0 then
    identity.inode = tostring(st.dev) .. ':' .. tostring(st.ino)
  end
  return identity
end

function M.path_identities_match(a, b)
  if not a or not b then return false end
  if a.inode and b.inode then return a.inode == b.inode end
  return a.path == b.path
end

local function index_identity(index, identity)
  index.by_path[identity.path] = true
  if identity.inode then
    index.by_inode[identity.inode] = true
  else
    index.unknown_by_path[identity.path] = true
  end
end

local function index_contains_identity(index, identity)
  if identity.inode and index.by_inode[identity.inode] then return true end
  if identity.inode then return index.unknown_by_path[identity.path] == true end
  return index.by_path[identity.path] == true
end

-- A lookup index for same_path-style membership checks. This keeps aliases
-- matched by device/inode while preserving normalized-path fallback whenever
-- either side cannot be stat'ed.
function M.path_identity_index(paths)
  local index = { by_path = {}, by_inode = {}, unknown_by_path = {} }
  for _, path in ipairs(paths or {}) do
    M.path_identity_index_add(index, path)
  end
  return index
end

function M.path_identity_index_add(index, path)
  local identity = M.path_identity(path, M.stat(path))
  if not identity then return false end
  index_identity(index, identity)
  return true
end

function M.path_identity_index_contains(index, path)
  local identity = M.path_identity(path, M.stat(path))
  if not identity then return false end
  return index_contains_identity(index, identity)
end

local function index_identities(paths)
  if not paths or #paths == 0 then return nil end
  local index = { by_path = {}, unknown_by_path = {}, by_inode = {} }
  for _, path in ipairs(paths) do
    local identity = M.path_identity(path, M.stat(path))
    if identity then
      index_identity(index, identity)
    end
  end
  return index
end

local function ignored(path, st, index)
  if not index then return false end
  local identity = M.path_identity(path, st)
  if not identity then return false end
  return index_contains_identity(index, identity)
end

-- read_dir_lines(root, ignore_set) -> the listing pipeline as a string array
-- directories first (each with the configured trailing marker), then files, each group sorted
-- ascending. Symlinks are resolved with a following stat; entries whose
-- stat fails (broken symlink) or whose target is neither a file nor a directory
-- (fifo, socket, device) are omitted, matching Python where isdir and isfile are
-- both false. `ignore_set` is a list of paths (the glob results of &wildignore);
-- entries are compared to its stat-indexed filesystem identities. Callers that
-- already scanned the directory may pass those `{ name, type }` records as
-- `entries` to avoid reopening and walking it a second time.
function M.read_dir_lines(root, ignore_set, entries)
  if not M.is_dir(root) then
    return nil, 'not a directory: ' .. tostring(root)
  end
  local ignored_index = index_identities(ignore_set)
  local display_separator = require('direct.paths').directory_separator()
  local dirs, files = {}, {}
  local function add_entry(name, typ)
    local path = M.join(root, name)
    local st, did_stat
    if typ == 'link' then
      st = M.stat(path)
      did_stat = true
      if st then
        typ = st.type
      end
    end
    if ignored_index and not did_stat then st = M.stat(path) end
    -- The marker is also the row grammar. A configured marker inside a raw name
    -- would make one component ambiguous, so leave such entries out of the
    -- visible model; list snapshots retain them as hidden for sync safety.
    if not name:find(display_separator, 1, true)
      and not ignored(path, st, ignored_index) then
      if typ == 'directory' then
        dirs[#dirs + 1] = name
      elseif typ == 'file' then
        files[#files + 1] = name
      end
    end
  end
  if entries then
    for _, entry in ipairs(entries) do
      add_entry(entry.name, entry.type)
    end
  else
    for name, typ in M.iter_dir(root) do
      add_entry(name, typ)
    end
  end
  table.sort(dirs)
  table.sort(files)
  local lines = {}
  for _, name in ipairs(dirs) do
    lines[#lines + 1] = name .. display_separator
  end
  for _, name in ipairs(files) do
    lines[#lines + 1] = name
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

-- same_path(a, b) -> ino+dev equality, the Lua equivalent of
-- os.path.samefile; falls back to normalised-string equality when either side
-- cannot be stat'ed. This is spelling-independent, so it is correct for a root
-- reached through a symlinked prefix. Reject non-strings before normalize.
function M.same_path(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then
    return nil, 'invalid path'
  end
  return M.path_identities_match(
    M.path_identity(a, M.stat(a)), M.path_identity(b, M.stat(b)))
end

local function lstat(path)
  local ok, stat = pcall(vim.uv.fs_lstat, path)
  if ok then return stat end
  return nil
end

-- entry_identity(path) returns the normalized spelling and, when available,
-- the lstat device/inode identity. Unlike path_identity, this keeps symlinks
-- distinct from their targets, matching directory-entry semantics.
function M.entry_identity(path)
  if type(path) ~= 'string' then return nil end
  local stat = lstat(path)
  return M.path_identity(path, stat), stat
end

-- same_entry(a, b) -> whether two spellings resolve to the same directory
-- entry, using lstat identity so symlink names remain distinct from their
-- targets. This is used when deciding whether an occupied rename destination is
-- merely another spelling of its source (for example a case-only rename).
function M.same_entry(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then return false end
  local function normalize(path)
    return require('direct.paths').canonical(path)
  end
  local normalized_a, normalized_b = normalize(a), normalize(b)
  if normalized_a == normalized_b then return true end
  local parent_a, name_a = normalized_a:match('^(.*)/([^/]+)$')
  local parent_b, name_b = normalized_b:match('^(.*)/([^/]+)$')
  if not parent_a or not parent_b then return false end
  if parent_a == '' then parent_a = '/' end
  if parent_b == '' then parent_b = '/' end
  if parent_a ~= parent_b and not M.same_path(parent_a, parent_b) then return false end
  local identity_a = M.entry_identity(normalized_a)
  local identity_b = M.entry_identity(normalized_b)
  if not (identity_a and identity_b and identity_a.inode
    and identity_a.inode == identity_b.inode) then
    return false
  end
  -- A hard link is the same inode but a different pathname. On a sensitive
  -- filesystem, names differing only by case can also be hard links, so verify
  -- that the parent contains only one actual name corresponding to these two
  -- spellings. The source name normally comes from the directory listing.
  local scan = vim.uv.fs_scandir(parent_a)
  if not scan then return false end
  local matching_entries = 0
  while true do
    local name = vim.uv.fs_scandir_next(scan)
    if name == nil then break end
    if name == name_a or name == name_b then
      local entry_path = vim.fs.joinpath(parent_a, name)
      local stat = lstat(entry_path)
      local same_identity = identity_key(stat, entry_path) == identity_a.inode
      if same_identity then
        matching_entries = matching_entries + 1
      end
    end
  end
  return matching_entries == 1
end

-- ---------------------------------------------------------------------------
end
