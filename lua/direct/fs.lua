-- lua/direct/fs.lua -- filesystem operations and copy semantics.
-- Operations return true or nil, err rather than raising. Destructive cross-device
-- moves require a complete copy; best-effort copies report unsupported entries.

local M = {}
M.uv = vim.uv
local temp_sequence = 0

local function temp_candidate(parent, tag)
  temp_sequence = temp_sequence + 1
  return M.join(parent, string.format('.direct-%s-%d-%d', tag,
    M.uv.os_getpid(), temp_sequence))
end

function M.unique_temp_path(parent, tag)
  if type(parent) ~= 'string' or parent == '' then return nil, 'invalid parent path' end
  temp_sequence = temp_sequence + 1
  local nonce = tostring(M.uv.hrtime()) .. '-' .. tostring(temp_sequence)
  return M.join(parent, string.format('.direct-%s-%d-%s', tag or 'temp',
    M.uv.os_getpid(), nonce))
end

local function is_eexist(err, code)
  return code == 'EEXIST' or code == 17
    or (type(err) == 'string' and (err:find('EEXIST', 1, true) ~= nil
      or err:find('exists', 1, true) ~= nil))
end

local function identity_key(stat)
  if not stat or stat.dev == nil or stat.ino == nil then return nil end
  return tostring(stat.dev) .. ':' .. tostring(stat.ino)
end

local function remove_file_if_same(path, identity)
  local now = M.uv.fs_lstat(path)
  if identity ~= nil and identity_key(now) == identity then
    return M.rm_file(path)
  end
  return nil, 'temporary path changed; preserved at ' .. tostring(path)
end

local function remove_dir_if_same(path, identity)
  local now = M.uv.fs_lstat(path)
  if identity ~= nil and identity_key(now) == identity then
    local ok, err = M.uv.fs_rmdir(path)
    if ok then return true end
    return nil, err
  end
  return nil, 'temporary directory changed; preserved at ' .. tostring(path)
end

-- ---------------------------------------------------------------------------
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

-- Strip trailing slashes before basename: vim.fs.basename('/a/b/') is empty,
-- which would make a directory yank store an empty name.
function M.basename(path)
  if type(path) ~= 'string' then
    return nil, 'invalid path'
  end
  local trimmed = path:gsub('/+$', '')
  if trimmed == '' then
    trimmed = '/'
  end
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
  -- A display marker is not part of the filesystem name. In particular,
  -- lstat("dangling-link/") follows the final slash and fails, hiding the
  -- occupied symlink name. Keep the single slash for the filesystem root.
  local lookup = path:gsub('/+$', '')
  if lookup == '' then
    lookup = '/'
  elseif path:match('^%a:[/\\]+$') then
    -- vim/fs APIs accept forward slashes on Windows; do not turn `C:/` into
    -- the drive-relative path `C:` while removing a display marker.
    lookup = path:sub(1, 2) .. '/'
  end
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
  local identity = { path = vim.fs.normalize(path) }
  if st and st.dev ~= nil and st.ino ~= nil and st.dev ~= 0 and st.ino ~= 0 then
    identity.inode = tostring(st.dev) .. ':' .. tostring(st.ino)
  end
  return identity
end

function M.path_identities_match(a, b)
  if not a or not b then return false end
  if a.inode and b.inode then return a.inode == b.inode end
  return a.path == b.path
end

local function index_identities(paths)
  if not paths or #paths == 0 then return nil end
  local index = { by_path = {}, unknown_by_path = {}, by_inode = {} }
  for _, path in ipairs(paths) do
    local identity = M.path_identity(path, M.stat(path))
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

local function ignored(path, st, index)
  if not index then return false end
  local identity = M.path_identity(path, st)
  if not identity then return false end
  if identity.inode then
    return index.by_inode[identity.inode] == true
      or index.unknown_by_path[identity.path] == true
  end
  return index.by_path[identity.path] == true
end

-- read_dir_lines(root, ignore_set) -> the listing pipeline as a string array
-- directories first (each with a trailing '/'), then files, each group sorted
-- ascending. Symlinks are resolved with a following stat; entries whose
-- stat fails (broken symlink) or whose target is neither a file nor a directory
-- (fifo, socket, device) are omitted, matching Python where isdir and isfile are
-- both false. `ignore_set` is a list of paths (the glob results of &wildignore);
-- entries are compared to its stat-indexed filesystem identities.
function M.read_dir_lines(root, ignore_set)
  if not M.is_dir(root) then
    return nil, 'not a directory: ' .. tostring(root)
  end
  local ignored_index = index_identities(ignore_set)
  local dirs, files = {}, {}
  for name, typ in M.iter_dir(root) do
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
    if not ignored(path, st, ignored_index) then
      if typ == 'directory' then
        dirs[#dirs + 1] = name
      elseif typ == 'file' then
        files[#files + 1] = name
      end
    end
  end
  table.sort(dirs)
  table.sort(files)
  local lines = {}
  for _, name in ipairs(dirs) do
    lines[#lines + 1] = name .. '/'
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
    path = path:gsub('/+$', '')
    if path == '' then path = '/' end
    return vim.fs.normalize(path)
  end
  local normalized_a, normalized_b = normalize(a), normalize(b)
  if normalized_a == normalized_b then return true end
  local parent_a, name_a = normalized_a:match('^(.*)/([^/]+)$')
  local parent_b, name_b = normalized_b:match('^(.*)/([^/]+)$')
  if not parent_a or not parent_b then return false end
  if parent_a == '' then parent_a = '/' end
  if parent_b == '' then parent_b = '/' end
  if parent_a ~= parent_b and not M.same_path(parent_a, parent_b) then return false end
  local identity_a, stat_a = M.entry_identity(normalized_a)
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
      local stat = lstat(vim.fs.joinpath(parent_a, name))
      if stat and stat.dev == stat_a.dev and stat.ino == stat_a.ino then
        matching_entries = matching_entries + 1
      end
    end
  end
  return matching_entries == 1
end

-- ---------------------------------------------------------------------------
-- Mutation
-- ---------------------------------------------------------------------------

local function is_exdev(err, code)
  return code == 'EXDEV' or code == 18
    or (type(err) == 'string'
      and (err:find('EXDEV', 1, true) ~= nil
        or err:find('Cross-device link', 1, true) ~= nil))
end

local function rename_case_only(src, dst)
  local source_path = src:gsub('/+$', '')
  if source_path == '' then source_path = '/' end
  local parent = M.dirname(vim.fs.normalize(source_path))
  local temp, ok, err, code
  for _ = 1, 100 do
    temp = temp_candidate(parent, 'case-rename')
    ok, err, code = M.rename_noreplace(src, temp)
    if ok then break end
    if not is_eexist(err, code) then return nil, err, code end
  end
  if not ok then return nil, 'could not allocate a case-rename temp' end

  ok, err, code = M.rename_noreplace(temp, dst)
  if ok then return true end

  local restored, restore_err = M.rename_noreplace(temp, src)
  if not restored then
    local message = 'case-only rename failed (' .. tostring(err)
      .. '); source preserved at ' .. temp .. '; restore to ' .. src
      .. ' failed (' .. tostring(restore_err) .. ')'
    require('direct.ui').notify('direct: ' .. message, vim.log.levels.ERROR)
    return nil, message, code
  end
  return nil, err, code
end

-- rename(src, dst) -> true | nil, err, code. Placement is always atomic
-- no-replace. EXDEV is handled by an exclusive-temp copy path below.
function M.rename(src, dst)
  if type(src) ~= 'string' or src == '' or type(dst) ~= 'string' or dst == '' then
    return nil, 'invalid path'
  end
  local src_spelling = src:gsub('/+$', '')
  local dst_spelling = dst:gsub('/+$', '')
  if src_spelling == '' then src_spelling = '/' end
  if dst_spelling == '' then dst_spelling = '/' end
  local src_norm = vim.fs.normalize(src_spelling)
  local dst_norm = vim.fs.normalize(dst_spelling)
  if src_norm == dst_norm then
    if M.taken(src) then return true end
    return nil, 'source does not exist: ' .. tostring(src), 'ENOENT'
  end
  if M.same_entry(src, dst) then
    return rename_case_only(src, dst)
  end
  local ok, err, code = M.rename_noreplace(src, dst)
  if ok then
    return true
  end
  if not is_exdev(err, code) then
    return nil, err, code
  end
  return M.move_exdev(src, dst)
end

-- rename_noreplace(src, dst) -> true | nil, err. POSIX rename replaces an
-- occupied destination, and checking M.taken(dst) first leaves a TOCTOU window.
-- Use the native atomic exclusive-rename operation on supported Unix platforms;
-- if unavailable, fail closed rather than placing onto a user path.
function M.rename_noreplace(src, dst, expected_source_identity)
  if type(src) ~= 'string' or src == '' or type(dst) ~= 'string' or dst == '' then
    return nil, 'invalid path'
  end
  if src:find('\0', 1, true) or dst:find('\0', 1, true) then
    return nil, 'invalid path: contains NUL'
  end
  if expected_source_identity ~= nil then
    local actual = identity_key(M.uv.fs_lstat(src))
    if expected_source_identity.inode == nil
      or actual ~= expected_source_identity.inode then
      return nil, 'source identity changed: ' .. src, 'ESTALE'
    end
  end
  local ffi_ok, ffi = pcall(require, 'ffi')
  if not ffi_ok then
    return nil, 'atomic no-replace rename is unavailable (LuaJIT FFI unavailable)'
  end
  pcall(ffi.cdef, [[
    int renamex_np(const char *from, const char *to, unsigned int flags);
    int renameat2(int olddirfd, const char *oldpath, int newdirfd,
      const char *newpath, unsigned int flags);
    char *strerror(int errnum);
  ]])

  local sysname = M.uv.os_uname().sysname
  local ok, result = pcall(function()
    if sysname == 'Darwin' then
      -- macOS RENAME_EXCL (renamex_np): atomically refuse an existing target.
      return ffi.C.renamex_np(src, dst, 0x00000004)
    elseif sysname == 'Linux' then
      -- Linux RENAME_NOREPLACE (renameat2), with both paths relative to cwd.
      return ffi.C.renameat2(-100, src, -100, dst, 0x00000001)
    end
    error('atomic no-replace rename is unavailable on ' .. tostring(sysname))
  end)
  if not ok then
    return nil, tostring(result)
  end
  if result == 0 then
    return true
  end
  local code = ffi.errno()
  local err_ok, err = pcall(function()
    return ffi.string(ffi.C.strerror(code))
  end)
  local message = err_ok and err or ('errno ' .. tostring(code))
  if code == 17 then
    return nil, 'destination exists: ' .. dst, 'EEXIST'
  elseif code == 18 then
    return nil, 'EXDEV: ' .. tostring(message), 'EXDEV'
  end
  return nil, tostring(message), code
end

-- copy_file(src, dst) -> true | nil, err, code (vim.uv.fs_copyfile preserves
-- mode by default).
function M.copy_file(src, dst)
  if type(src) ~= 'string' or type(dst) ~= 'string' then
    return nil, 'invalid path'
  end
  local ok, err, code = vim.uv.fs_copyfile(src, dst)
  if ok then
    return true
  end
  return nil, err, code
end

-- copy_file_exclusive refuses any existing destination atomically. Unlike
-- copy_file, it is suitable for user paths where an occupant must never be
-- overwritten.
function M.copy_file_exclusive(src, dst)
  if type(src) ~= 'string' or src == '' or type(dst) ~= 'string' or dst == '' then
    return nil, 'invalid path'
  end
  local ok, err, code = M.uv.fs_copyfile(src, dst, { excl = true })
  if ok then return true end
  if code == 'EEXIST' or (type(err) == 'string' and err:find('EEXIST', 1, true)) then
    return nil, 'destination exists: ' .. tostring(dst), 'EEXIST'
  end
  return nil, err, code
end

-- classify(path) -> kind, itype. THE single classification of one source entry
-- shared by the destructive pre-scan and the copy walk so the two can never
-- disagree about what a copy can reproduce
-- kind: nil when the copy can reproduce the entry, otherwise a short name
-- of what it is (why it cannot be reproduced faithfully).
-- itype: the lstat type ('file', 'directory', 'link',...), nil when the
-- entry could not be lstat'ed at all.
-- lstat never follows the final component, which is what distinguishes a symlink
-- from its target. Best-effort register copies skip symlinks; an EXDEV move can
-- opt into copying the raw link target and recreating the link without following
-- it. Any other non-file, non-directory type (FIFO, socket, device) is refused.
--
-- A directory is copyable only when its entries can actually be READ. M.list_dir
-- reports nil only for a non-directory, and a scan that fails (EACCES) goes
-- through vim.fs.dir, which yields nothing instead of raising, so such a
-- directory would otherwise read as EMPTY and its contents would be dropped -- or
-- an empty stand-in directory would be created for it. luv's fs_scandir surfaces
-- that failure, so the probe lives here, once, for both callers.
local function classify(path, opts)
  local ok, lst = pcall(vim.uv.fs_lstat, path)
  if not ok or lst == nil then
    return 'unreadable entry', nil
  end
  if lst.type == 'directory' then
    local scan, scan_err = vim.uv.fs_scandir(path)
    if scan == nil then
      return 'unreadable directory (' .. tostring(scan_err) .. ')', 'directory'
    end
    -- Drain the handle: luv closes it at the end of iteration.
    while vim.uv.fs_scandir_next(scan) ~= nil do end
    return nil, 'directory'
  end
  if lst.type == 'file' then
    return nil, 'file'
  end
  if lst.type == 'link' and opts ~= nil and opts.recreate_symlinks then
    return nil, 'link'
  end
  -- 'link' is the luv name for a symlink; keep reporting it as 'symlink'
  -- which is the vocabulary the skipped-entry records already use.
  return (lst.type == 'link' and 'symlink' or tostring(lst.type)), lst.type
end

-- uncopyable(ctx, path, kind) -> err | nil. Records one entry the copy cannot
-- reproduce. Under `ctx.require_complete` -- the destructive caller's contract --
-- it returns the refusal message, which stops the copy and leaves the caller's
-- source where it is. Otherwise the entry is SKIPPED and recorded in ctx.skipped
-- for the caller to report: it is never dropped silently.
local function uncopyable(ctx, path, kind)
  if ctx.require_complete then
    return 'cannot copy ' .. kind .. ': ' .. path
  end
  ctx.skipped[#ctx.skipped + 1] = { path = path, kind = kind }
  return nil
end

-- discard(created) undoes what a failed copy created, newest first. It is
-- structurally incapable of deleting anything else: recorded files are
-- unlinked one by one, and recorded directories are removed only when they are
-- EMPTY (fs_rmdir), innermost-first because the list is walked newest-first.
-- There is no recursive forced delete anywhere in this path, so an entry that
-- any other process, plugin or Neovim instance placed inside a directory this
-- copy created -- after the copy created it -- is never taken with it; a
-- directory that is no longer empty is simply left behind. Cleanup itself is
-- best-effort: the invariant that matters -- the source is untouched -- already
-- holds, and the copy's own error is what the caller reports.
local function discard(created)
  for i = #created, 1, -1 do
    local entry = created[i]
    if entry.dir then
      remove_dir_if_same(entry.path, entry.identity)
    else
      remove_file_if_same(entry.path, entry.identity)
    end
  end
end

-- copy_dir is the live copy walk and the authority on what can be reproduced.
-- It classifies entries as it goes, so a path created after the pre-scan is
-- still refused or reported before an EXDEV fallback removes the source.
--
-- A destination belongs to its owner. Complete mode refuses an occupied path
-- rather than overwrite data a later failure might not restore. Best-effort
-- mode retains overwrite behavior for non-destructive register refresh. Calls
-- use the module table so stubs on M.mkdirp/M.mkdir_exclusive, M.list_dir,
-- M.copy_file/M.copy_file_exclusive, and M.taken work.
--
-- A skipped directory (best-effort mode) is a SUCCESS carrying a ctx.skipped
-- record, not a failure: only a real I/O failure or a refusal returns nil, err.
local function copy_dir(from, to, ctx)
  local kind = classify(from, ctx)
  if kind ~= nil then
    local uerr = uncopyable(ctx, from, kind)
    if uerr ~= nil then
      return nil, uerr
    end
    return true
  end

  local existed = M.taken(to)
  if existed and ctx.require_complete then
    return nil, 'destination exists: ' .. tostring(to)
  end
  local mok, merr
  if ctx.require_complete or ctx.exclusive then
    mok, merr = M.mkdir_exclusive(to)
  else
    mok, merr = M.mkdirp(to)
  end
  if not mok then
    return nil, merr
  end
  if not existed then
    ctx.created[#ctx.created + 1] = {
      path = to, dir = true, identity = identity_key(M.uv.fs_lstat(to)),
    }
  end
  local names = M.list_dir(from)
  if not names then
    return nil, 'cannot list: ' .. tostring(from)
  end
  for _, name in ipairs(names) do
    local child_from = M.join(from, name)
    local child_to = M.join(to, name)
    local child_kind, itype = classify(child_from, ctx)
    if child_kind ~= nil then
      local uerr = uncopyable(ctx, child_from, child_kind)
      if uerr ~= nil then
        return nil, uerr
      end
    elseif itype == 'directory' then
      local cok, cerr = copy_dir(child_from, child_to, ctx)
      if not cok then
        return nil, cerr
      end
    elseif itype == 'link' and ctx.recreate_symlinks then
      local target, read_err = M.uv.fs_readlink(child_from)
      if not target then
        return nil, 'cannot read symlink: ' .. tostring(read_err)
      end
      local linked, link_err, link_code = M.uv.fs_symlink(target, child_to)
      if not linked then
        return nil, tostring(link_err or link_code or 'cannot recreate symlink')
      end
      ctx.created[#ctx.created + 1] = {
        path = child_to, dir = false, identity = identity_key(M.uv.fs_lstat(child_to)),
      }
    else
      -- A plain file. Recorded BEFORE the copy, so a half-written file is
      -- cleaned up too -- but only when the destination path was free: a path
      -- that was already taken belongs to whoever put it there, and a failure
      -- there (EISDIR when the source entry clashes with an existing
      -- destination directory, say) must not delete it.
      local child_taken = M.taken(child_to)
      if child_taken and ctx.require_complete then
        return nil, 'destination exists: ' .. tostring(child_to)
      end
      if not child_taken then
        ctx.created[#ctx.created + 1] = { path = child_to, dir = false }
      end
      local cok, cerr, ccode
      if ctx.require_complete or ctx.exclusive then
        cok, cerr, ccode = M.copy_file_exclusive(child_from, child_to)
      else
        cok, cerr, ccode = M.copy_file(child_from, child_to)
      end
      if not cok then
        if not child_taken and (ccode == 'EEXIST'
          or (type(cerr) == 'string' and cerr:find('EEXIST', 1, true))) then
          -- An exclusive copy lost a race; the occupant belongs to someone else.
          table.remove(ctx.created)
        elseif not child_taken then
          -- A failed exclusive copy may leave its partial file behind. Capture
          -- its inode so cleanup cannot unlink a replacement at this pathname.
          local entry = ctx.created[#ctx.created]
          entry.identity = identity_key(M.uv.fs_lstat(child_to))
        end
        return nil, cerr
      end
      if not child_taken then
        ctx.created[#ctx.created].identity = identity_key(M.uv.fs_lstat(child_to))
      end
    end
  end
  return true
end

-- prescan performs a deterministic depth-first walk before any writes. Complete
-- mode can therefore refuse unsupported entries without touching the
-- destination; the live copy walk still catches entries that appear later.
local function prescan(path, offender, ctx)
  local names = M.list_dir(path)
  if not names then
    return nil, 'cannot list: ' .. tostring(path)
  end
  for _, name in ipairs(names) do
    local child = M.join(path, name)
    local kind, itype = classify(child, ctx)
    if kind ~= nil then
      offender.path = child
      offender.kind = kind
      return offender
    end
    if itype == 'directory' then
      local nested, err = prescan(child, offender, ctx)
      if err ~= nil then
        return nil, err
      end
      if nested ~= nil then
        return nested
      end
    end
  end
  return nil
end

-- copy_tree recursively copies with mkdir -p semantics and deterministic
-- module-table iteration, so operation stubs remain effective.
--
-- `require_complete` is for destructive callers that remove the source after
-- copying. It refuses unsupported entries and occupied destinations; the live
-- walk also catches late entries. `recreate_symlinks` is reserved for EXDEV
-- moves and preserves link targets without following links. Failure cleanup
-- removes only the same inodes this copy created.
--
-- Default best-effort mode is for non-destructive register copies: unsupported
-- entries are skipped and returned in `skipped` for the caller to report, while
-- existing register entries may be refreshed. User paste uses the exclusive
-- temp-and-commit path below.
function M.copy_tree(src, dst, opts)
  if not M.is_dir(src) then
    return nil, 'not a directory: ' .. tostring(src)
  end
  local ctx = {
    require_complete = opts ~= nil and opts.require_complete == true,
    recreate_symlinks = opts ~= nil and opts.recreate_symlinks == true,
    exclusive = opts ~= nil and opts.exclusive == true,
    skipped = {},
    created = {},
  }
  if ctx.require_complete then
    local offender, perr = prescan(src, {}, ctx)
    if perr ~= nil then
      return nil, perr
    end
    if offender ~= nil then
      return nil, 'cannot copy ' .. offender.kind .. ': ' .. offender.path
    end
    if M.taken(dst) then
      return nil, 'destination exists: ' .. tostring(dst)
    end
  end
  local cok, cerr = copy_dir(src, dst, ctx)
  if not cok then
    discard(ctx.created)
    return nil, cerr
  end
  if #ctx.skipped > 0 then
    return true, ctx.skipped, ctx.created
  end
  return true, nil, ctx.created
end

local function destination_parent(path)
  local trimmed = path:gsub('/+$', '')
  if trimmed == '' then trimmed = '/' end
  return M.dirname(trimmed)
end

local function allocate_private_dir(dst, tag)
  local parent = destination_parent(dst)
  for _ = 1, 100 do
    local candidate = temp_candidate(parent, tag)
    local ok, err, code = M.mkdir_exclusive(candidate, 448) -- private mode 0700
    if ok then
      return candidate, identity_key(M.uv.fs_lstat(candidate))
    end
    if not is_eexist(err, code) then return nil, err, code end
  end
  return nil, 'could not allocate a unique private temp directory'
end

local function cleanup_private_dir(path, identity)
  local ok, err = remove_dir_if_same(path, identity)
  if not ok then
    require('direct.ui').notify(
      'direct: temporary directory preserved at ' .. path .. ': ' .. tostring(err),
      vim.log.levels.ERROR)
  end
end

local same_tree

-- copy_tree_exclusive copies into an exclusive private directory under the
-- destination parent, then commits the tree with one atomic no-replace rename.
function M.copy_tree_exclusive(src, dst, opts)
  opts = opts or {}
  local temp_dir, temp_identity, alloc_err = allocate_private_dir(dst, 'copy-tree')
  if not temp_dir then return nil, temp_identity or alloc_err end
  local payload = M.join(temp_dir, 'payload')
  local copy_opts = {
    require_complete = opts.require_complete == true,
    recreate_symlinks = opts.recreate_symlinks == true,
    exclusive = true,
  }
  local copied, skipped, created = M.copy_tree(src, payload, copy_opts)
  if not copied then
    cleanup_private_dir(temp_dir, temp_identity)
    return nil, skipped
  end

  local payload_identity = created and created[1] and created[1].identity
  if payload_identity == nil then
    discard(created or {})
    cleanup_private_dir(temp_dir, temp_identity)
    return nil, 'could not verify private copy tree identity'
  end
  if opts.verify_source then
    local matches, compare_err = same_tree(src, payload)
    if not matches then
      discard(created or {})
      cleanup_private_dir(temp_dir, temp_identity)
      return nil, 'source or private copy changed before placement: '
        .. tostring(compare_err or 'content mismatch')
    end
  end
  local placed, place_err, place_code = M.rename_noreplace(payload, dst,
    { inode = payload_identity })
  if not placed then
    discard(created or {})
    cleanup_private_dir(temp_dir, temp_identity)
    return nil, place_err, place_code
  end
  cleanup_private_dir(temp_dir, temp_identity)
  return true, skipped
end

local function report_partial_move(src, dst, err)
  require('direct.ui').notify('direct: destination committed at ' .. dst
    .. ' but source could not be removed at ' .. src .. ': ' .. tostring(err)
    .. '; both copies may remain', vim.log.levels.ERROR)
end

local function read_file_equal(a, b)
  local fa, err_a = M.uv.fs_open(a, 'r', 0)
  if not fa then return nil, 'cannot read source: ' .. tostring(err_a) end
  local fb, err_b = M.uv.fs_open(b, 'r', 0)
  if not fb then
    M.uv.fs_close(fa)
    return nil, 'cannot read destination: ' .. tostring(err_b)
  end
  local stat_a, stat_err_a = M.uv.fs_fstat(fa)
  local stat_b, stat_err_b = M.uv.fs_fstat(fb)
  local equal, reason = true, nil
  if not stat_a or not stat_b then
    equal, reason = nil, tostring(stat_err_a or stat_err_b or 'fstat failed')
  elseif stat_a.size ~= stat_b.size then
    equal = false
  else
    local offset = 0
    while offset < stat_a.size do
      local size = math.min(65536, stat_a.size - offset)
      local bytes_a, read_err_a = M.uv.fs_read(fa, size, offset)
      local bytes_b, read_err_b = M.uv.fs_read(fb, size, offset)
      if not bytes_a or not bytes_b then
        equal, reason = nil, tostring(read_err_a or read_err_b or 'read failed')
        break
      end
      if #bytes_a == 0 or #bytes_b == 0 then
        equal, reason = nil, 'file changed while being verified'
        break
      end
      if bytes_a ~= bytes_b then
        equal = false
        break
      end
      offset = offset + #bytes_a
    end
  end
  local after_a, after_err_a = M.uv.fs_fstat(fa)
  local after_b, after_err_b = M.uv.fs_fstat(fb)
  local function stable(before, after)
    if not before or not after or before.size ~= after.size then return false end
    for _, field in ipairs({ 'mtime', 'ctime' }) do
      local left, right = before[field] or {}, after[field] or {}
      if left.sec ~= right.sec or left.nsec ~= right.nsec then return false end
    end
    return true
  end
  if equal and (not stable(stat_a, after_a) or not stable(stat_b, after_b)) then
    equal, reason = false, 'file changed while being verified'
  elseif equal and (not after_a or not after_b) then
    equal, reason = nil, tostring(after_err_a or after_err_b or 'fstat failed')
  end
  local close_a, close_err_a = M.uv.fs_close(fa)
  local close_b, close_err_b = M.uv.fs_close(fb)
  if equal and (not close_a or not close_b) then
    equal, reason = nil, tostring(close_err_a or close_err_b or 'close failed')
  end
  return equal, reason
end

-- same_tree compares without following symlinks. EXDEV fallback uses it after
-- destination commit to avoid deleting source edits made while the copy ran.
same_tree = function(src, dst)
  local a, b = M.uv.fs_lstat(src), M.uv.fs_lstat(dst)
  if not a or not b then return nil, 'source or destination disappeared' end
  if a.type ~= b.type then return false end
  if a.type == 'file' then return read_file_equal(src, dst) end
  if a.type == 'link' then
    local target_a, err_a = M.uv.fs_readlink(src)
    local target_b, err_b = M.uv.fs_readlink(dst)
    if not target_a or not target_b then
      return nil, tostring(err_a or err_b or 'readlink failed')
    end
    return target_a == target_b
  end
  if a.type ~= 'directory' then return false end
  local initial_src, initial_dst = a, b
  local names_a, err_a = M.list_dir(src)
  local names_b, err_b = M.list_dir(dst)
  if not names_a or not names_b then
    return nil, tostring(err_a or err_b or 'cannot list directory')
  end
  if not vim.deep_equal(names_a, names_b) then return false end
  for _, name in ipairs(names_a) do
    local equal, err = same_tree(M.join(src, name), M.join(dst, name))
    if not equal then return equal, err end
  end
  local final_src, final_dst = M.uv.fs_lstat(src), M.uv.fs_lstat(dst)
  local function directory_stable(before, after)
    if not after or before.dev ~= after.dev or before.ino ~= after.ino
      or before.size ~= after.size then
      return false
    end
    for _, field in ipairs({ 'mtime', 'ctime' }) do
      local left, right = before[field] or {}, after[field] or {}
      if left.sec ~= right.sec or left.nsec ~= right.nsec then return false end
    end
    return true
  end
  if not directory_stable(initial_src, final_src)
    or not directory_stable(initial_dst, final_dst) then
    return false, 'directory changed while being verified'
  end
  return true
end

M.same_contents = same_tree

local function restore_quarantined_source(quarantine_dir, dir_identity,
    quarantine, src, dst, reason)
  local restored, restore_err = M.rename_noreplace(quarantine, src)
  if restored then
    cleanup_private_dir(quarantine_dir, dir_identity)
    report_partial_move(src, dst, reason)
    return true
  end
  require('direct.ui').notify('direct: destination committed at ' .. dst
    .. '; source could not be restored to ' .. src .. ' (' .. tostring(restore_err)
    .. '); original source preserved at ' .. quarantine .. ' (' .. tostring(reason) .. ')',
    vim.log.levels.ERROR)
  return true
end

local function remove_source_after_copy(src, dst, kind, original_identity)
  -- Capture the pathname with one atomic same-filesystem rename before verifying
  -- or deleting it. This prevents a new object placed at `src` after the copy
  -- from being removed by a later pathname-based unlink/rm_tree.
  local quarantine_dir, dir_identity, dir_err = allocate_private_dir(src, 'exdev-source')
  if not quarantine_dir then
    report_partial_move(src, dst, 'could not allocate source quarantine: '
      .. tostring(dir_identity or dir_err))
    return true
  end
  local quarantine = M.join(quarantine_dir, 'source')
  local captured, capture_err = M.rename_noreplace(src, quarantine)
  if not captured then
    cleanup_private_dir(quarantine_dir, dir_identity)
    report_partial_move(src, dst, 'could not capture source for safe removal: '
      .. tostring(capture_err))
    return true
  end

  local captured_identity = identity_key(M.uv.fs_lstat(quarantine))
  if original_identity == nil or captured_identity ~= original_identity then
    return restore_quarantined_source(quarantine_dir, dir_identity, quarantine,
      src, dst, 'source identity changed before removal')
  end
  local equal, compare_err = same_tree(quarantine, dst)
  if not equal then
    return restore_quarantined_source(quarantine_dir, dir_identity, quarantine,
      src, dst, 'source changed or could not be verified after copy: '
        .. tostring(compare_err or 'content mismatch'))
  end

  local removed, remove_err
  if kind == 'directory' then
    removed, remove_err = M.rm_tree(quarantine)
  else
    removed, remove_err = M.rm_file(quarantine)
  end
  if not removed or M.taken(quarantine) then
    return restore_quarantined_source(quarantine_dir, dir_identity, quarantine,
      src, dst, 'source removal failed: ' .. tostring(remove_err or 'source remains'))
  end
  cleanup_private_dir(quarantine_dir, dir_identity)
  return true
end

local function move_exdev_file(src, dst, source_identity)
  local temp_dir, temp_dir_identity, temp, copy_err, copy_code
  for _ = 1, 100 do
    temp_dir, temp_dir_identity, copy_err = allocate_private_dir(dst, 'move-file')
    if not temp_dir then return nil, temp_dir_identity or copy_err, copy_code end
    temp = M.join(temp_dir, 'payload')
    local copied
    copied, copy_err, copy_code = M.copy_file_exclusive(src, temp)
    if copied then break end
    if not is_eexist(copy_err, copy_code) then
      local partial_identity = identity_key(M.uv.fs_lstat(temp))
      if partial_identity ~= nil then
        local cleanup_ok, cleanup_err = remove_file_if_same(temp, partial_identity)
        if not cleanup_ok then
          require('direct.ui').notify('direct: failed copy temp preserved at ' .. temp
            .. ': ' .. tostring(cleanup_err), vim.log.levels.ERROR)
        end
      end
      cleanup_private_dir(temp_dir, temp_dir_identity)
      return nil, copy_err, copy_code
    end
    cleanup_private_dir(temp_dir, temp_dir_identity)
    temp_dir, temp_dir_identity = nil, nil
    temp = nil
  end
  if not temp then return nil, copy_err or 'could not allocate a unique copy temp' end

  local temp_identity = M.entry_identity(temp)
  if temp_identity == nil or temp_identity.inode == nil then
    cleanup_private_dir(temp_dir, temp_dir_identity)
    return nil, 'could not verify private file temp identity'
  end
  local matches, compare_err = same_tree(src, temp)
  if not matches then
    local cleanup_ok, cleanup_err = remove_file_if_same(temp, temp_identity.inode)
    if not cleanup_ok then
      require('direct.ui').notify('direct: copy temp preserved at ' .. temp
        .. ': ' .. tostring(cleanup_err), vim.log.levels.ERROR)
    end
    cleanup_private_dir(temp_dir, temp_dir_identity)
    return nil, 'source or private copy changed before placement: '
      .. tostring(compare_err or 'content mismatch')
  end
  local placed, place_err, place_code = M.rename_noreplace(temp, dst, temp_identity)
  if not placed then
    local cleanup_ok, cleanup_err = remove_file_if_same(temp, temp_identity.inode)
    if not cleanup_ok then
      require('direct.ui').notify('direct: copy temp preserved at ' .. temp
        .. ': ' .. tostring(cleanup_err), vim.log.levels.ERROR)
    end
    cleanup_private_dir(temp_dir, temp_dir_identity)
    return nil, place_err, place_code
  end
  cleanup_private_dir(temp_dir, temp_dir_identity)
  return remove_source_after_copy(src, dst, 'file', source_identity)
end

local function move_exdev_link(src, dst, source_identity)
  local target, read_err = M.uv.fs_readlink(src)
  if not target then return nil, 'cannot read symlink: ' .. tostring(read_err) end
  local temp_dir, temp_dir_identity, temp, link_err, link_code
  for _ = 1, 100 do
    temp_dir, temp_dir_identity, link_err = allocate_private_dir(dst, 'move-link')
    if not temp_dir then return nil, temp_dir_identity or link_err, link_code end
    temp = M.join(temp_dir, 'payload')
    local linked
    linked, link_err, link_code = M.uv.fs_symlink(target, temp)
    if linked then break end
    cleanup_private_dir(temp_dir, temp_dir_identity)
    if not is_eexist(link_err, link_code) then return nil, link_err, link_code end
    temp_dir, temp_dir_identity = nil, nil
    temp = nil
  end
  if not temp then return nil, link_err or 'could not allocate a symlink temp' end

  local temp_identity = M.entry_identity(temp)
  if temp_identity == nil or temp_identity.inode == nil then
    cleanup_private_dir(temp_dir, temp_dir_identity)
    return nil, 'could not verify private symlink temp identity'
  end
  local current_target = M.uv.fs_readlink(src)
  local temp_target = M.uv.fs_readlink(temp)
  if current_target ~= target or temp_target ~= target then
    remove_file_if_same(temp, temp_identity.inode)
    cleanup_private_dir(temp_dir, temp_dir_identity)
    return nil, 'source or private symlink changed before placement'
  end
  local placed, place_err, place_code = M.rename_noreplace(temp, dst, temp_identity)
  if not placed then
    local cleanup_ok, cleanup_err = remove_file_if_same(temp, temp_identity.inode)
    if not cleanup_ok then
      require('direct.ui').notify('direct: symlink temp preserved at ' .. temp
        .. ': ' .. tostring(cleanup_err), vim.log.levels.ERROR)
    end
    cleanup_private_dir(temp_dir, temp_dir_identity)
    return nil, place_err, place_code
  end
  cleanup_private_dir(temp_dir, temp_dir_identity)
  return remove_source_after_copy(src, dst, 'link', source_identity)
end

-- move_exdev is only reached after the native no-replace rename reports EXDEV.
-- It classifies with lstat before opening anything, copies into an exclusive temp
-- under the destination parent, commits with no-replace, then removes the source.
function M.move_exdev(src, dst)
  local source = M.uv.fs_lstat(src)
  if not source then return nil, 'cannot stat source: ' .. tostring(src) end
  local source_identity = identity_key(source)
  if source.type == 'file' then
    return move_exdev_file(src, dst, source_identity)
  elseif source.type == 'link' then
    return move_exdev_link(src, dst, source_identity)
  elseif source.type == 'directory' then
    local ok, err = M.copy_tree_exclusive(src, dst, {
      require_complete = true,
      recreate_symlinks = true,
      verify_source = true,
    })
    if not ok then return nil, err end
    return remove_source_after_copy(src, dst, 'directory', source_identity)
  end
  return nil, 'cannot move unsupported source type ' .. tostring(source.type)
end

-- rm_file(path) -> true | nil, err, code.
function M.rm_file(path)
  if type(path) ~= 'string' then
    return nil, 'invalid path'
  end
  local ok, err, code = vim.uv.fs_unlink(path)
  if ok then
    return true
  end
  return nil, err, code
end

-- rm_tree(path) -> true | nil, err. vim.fs.rm returns nil on success, so
-- success is "did not raise".
function M.rm_tree(path)
  local ok, err = pcall(vim.fs.rm, path, { recursive = true, force = true })
  if not ok then
    return nil, tostring(err)
  end
  return true
end

-- mkdirp(path) -> true | nil, err. vim.fn.mkdir raises when a file occupies the
-- path, so it is pcall-guarded; a 0 return also signals failure. Non-string
-- input is rejected before any call: vim.fn.mkdir would otherwise coerce a
-- number to a directory name in the cwd and create a literal `v:null`
-- directory for a nil argument.
function M.mkdirp(path)
  if type(path) ~= 'string' then
    return nil, 'invalid path'
  end
  local ok, res = pcall(vim.fn.mkdir, path, 'p')
  if not ok then
    return nil, tostring(res)
  end
  if res == 0 then
    return nil, 'mkdir failed: ' .. tostring(path)
  end
  return true
end

-- mkdir_exclusive creates exactly one directory and never merges into an
-- existing destination. Internal directory setup should continue using mkdirp.
function M.mkdir_exclusive(path, mode)
  if type(path) ~= 'string' or path == '' then return nil, 'invalid path' end
  local ok, err, code = M.uv.fs_mkdir(path, mode or 493) -- default 0755, subject to umask
  if ok then return true end
  if is_eexist(err, code) then
    return nil, 'destination exists: ' .. tostring(path), 'EEXIST'
  end
  return nil, err, code
end

-- touch uses exclusive create (`wx`): a file appearing after a caller's
-- occupancy check is still never truncated.
function M.touch(path)
  if type(path) ~= 'string' or path == '' then
    return nil, 'invalid path'
  end
  local fd, err, code = M.uv.fs_open(path, 'wx', 420) -- 0644, subject to umask
  if not fd then
    if is_eexist(err, code) then
      return nil, 'destination exists: ' .. tostring(path), 'EEXIST'
    end
    return nil, err, code
  end
  local stat = M.uv.fs_fstat(fd)
  if not stat then
    local close_ok = M.uv.fs_close(fd)
    if close_ok == nil or close_ok == false then
      return nil, 'could not verify or close the newly created file: ' .. tostring(path)
    end
    return nil, 'could not verify the newly created file: ' .. tostring(path)
  end
  local closed, close_err = M.uv.fs_close(fd)
  if closed == nil or closed == false then
    local err = tostring(close_err or 'close failed')
    require('direct.ui').notify('direct: created file preserved at ' .. path
      .. ' but close failed: ' .. err, vim.log.levels.ERROR)
    return nil, 'close failed; created file preserved at ' .. path .. ': ' .. err
  end
  return true
end

return M
