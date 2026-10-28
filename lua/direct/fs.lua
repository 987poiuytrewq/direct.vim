-- lua/direct/fs.lua -- filesystem operations and copy semantics.
-- Operations return true or nil, err rather than raising. Destructive cross-device
-- moves require a complete copy; best-effort copies report unsupported entries.

local M = {}

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
  local ok, st = pcall(vim.uv.fs_lstat, path)
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

-- ---------------------------------------------------------------------------
-- Mutation
-- ---------------------------------------------------------------------------

-- rename(src, dst) -> true | nil, err, code. On EXDEV only, it falls back
-- to copy-then-remove; every other libuv error propagates untouched, so a
-- permission failure is never masked as a successful move.
function M.rename(src, dst)
  if type(src) ~= 'string' or type(dst) ~= 'string' then
    return nil, 'invalid path'
  end
  local ok, err, code = vim.uv.fs_rename(src, dst)
  if ok then
    return true
  end
  local is_exdev = code == 'EXDEV'
    or (type(err) == 'string' and err:match('^EXDEV:') ~= nil)
  if not is_exdev then
    return nil, err, code
  end
  if M.is_dir(src) then
    -- This path removes the source after copying, so require a complete copy.
    -- Non-destructive yank/paste callers can continue using best-effort mode.
    local cok, cerr = M.copy_tree(src, dst, { require_complete = true })
    if not cok then
      return nil, cerr
    end
    local rok, rerr = M.rm_tree(src)
    if not rok then
      return nil, rerr
    end
    return true
  end
  local cok, cerr = M.copy_file(src, dst)
  if not cok then
    return nil, cerr
  end
  local rok, rerr = M.rm_file(src)
  if not rok then
    return nil, rerr
  end
  return true
end

-- rename_noreplace(src, dst) -> true | nil, err. Rollback must not use the
-- ordinary rename contract: POSIX rename replaces an occupied destination, and
-- checking M.taken(dst) first would still leave a TOCTOU window. Use the native
-- atomic exclusive-rename operation on supported Unix platforms. If it is not
-- available, fail closed so the caller can preserve and report the staged path.
function M.rename_noreplace(src, dst)
  if type(src) ~= 'string' or type(dst) ~= 'string' then
    return nil, 'invalid path'
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

  local sysname = vim.uv.os_uname().sysname
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
  return nil, (err_ok and err or ('errno ' .. tostring(code)))
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

-- classify(path) -> kind, itype. THE single classification of one source entry
-- shared by the destructive pre-scan and the copy walk so the two can never
-- disagree about what a copy can reproduce
-- kind: nil when the copy can reproduce the entry, otherwise a short name
-- of what it is (why it cannot be reproduced faithfully).
-- itype: the lstat type ('file', 'directory', 'link',...), nil when the
-- entry could not be lstat'ed at all.
-- lstat never follows the final component, which is what distinguishes a symlink
-- from its target. A symlink is uncopyable: following it would silently turn the
-- link into a copy of its target, and cp -a style preservation is deliberately
-- out of scope. Any other non-file, non-directory type (FIFO, socket, device) is
-- uncopyable too.
--
-- A directory is copyable only when its entries can actually be READ. M.list_dir
-- reports nil only for a non-directory, and a scan that fails (EACCES) goes
-- through vim.fs.dir, which yields nothing instead of raising, so such a
-- directory would otherwise read as EMPTY and its contents would be dropped -- or
-- an empty stand-in directory would be created for it. luv's fs_scandir surfaces
-- that failure, so the probe lives here, once, for both callers.
local function classify(path)
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
      vim.uv.fs_rmdir(entry.path)
    else
      M.rm_file(entry.path)
    end
  end
end

-- copy_dir is the live copy walk and the authority on what can be reproduced.
-- It classifies entries as it goes, so a path created after the pre-scan is
-- still refused or reported before an EXDEV fallback removes the source.
--
-- A destination belongs to its owner. Complete mode refuses an occupied path
-- rather than overwrite data a later failure might not restore. Best-effort
-- mode retains overwrite behavior for non-destructive yank/paste. Calls use the
-- module table so stubs on M.mkdirp, M.list_dir, M.copy_file, and M.taken work.
--
-- A skipped directory (best-effort mode) is a SUCCESS carrying a ctx.skipped
-- record, not a failure: only a real I/O failure or a refusal returns nil, err.
local function copy_dir(from, to, ctx)
  local kind = classify(from)
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
  local mok, merr = M.mkdirp(to)
  if not mok then
    return nil, merr
  end
  if not existed then
    ctx.created[#ctx.created + 1] = { path = to, dir = true }
  end
  local names = M.list_dir(from)
  if not names then
    return nil, 'cannot list: ' .. tostring(from)
  end
  for _, name in ipairs(names) do
    local child_from = M.join(from, name)
    local child_to = M.join(to, name)
    local child_kind, itype = classify(child_from)
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
      local cok, cerr = M.copy_file(child_from, child_to)
      if not cok then
        return nil, cerr
      end
    end
  end
  return true
end

-- prescan performs a deterministic depth-first walk before any writes. Complete
-- mode can therefore refuse unsupported entries without touching the
-- destination; the live copy walk still catches entries that appear later.
local function prescan(path, offender)
  local names = M.list_dir(path)
  if not names then
    return nil, 'cannot list: ' .. tostring(path)
  end
  for _, name in ipairs(names) do
    local child = M.join(path, name)
    local kind, itype = classify(child)
    if kind ~= nil then
      offender.path = child
      offender.kind = kind
      return offender
    end
    if itype == 'directory' then
      local nested, err = prescan(child, offender)
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
-- walk also catches late entries. Failure cleanup removes only paths this copy
-- created, leaving the source and foreign destination data intact.
--
-- Default best-effort mode is for non-destructive yank/paste: unsupported
-- entries are skipped and returned in `skipped` for the caller to report, while
-- existing destinations retain their overwrite behavior.
function M.copy_tree(src, dst, opts)
  if not M.is_dir(src) then
    return nil, 'not a directory: ' .. tostring(src)
  end
  local ctx = {
    require_complete = opts ~= nil and opts.require_complete == true,
    skipped = {},
    created = {},
  }
  if ctx.require_complete then
    local offender, perr = prescan(src, {})
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
    return true, ctx.skipped
  end
  return true
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

-- touch creates or truncates an empty file with writefile; reject non-strings
-- before the call so nil cannot reach writefile.
function M.touch(path)
  if type(path) ~= 'string' then
    return nil, 'invalid path'
  end
  local ok, err = pcall(vim.fn.writefile, {}, path)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

return M
