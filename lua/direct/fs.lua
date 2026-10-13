-- lua/direct/fs.lua -- the single filesystem seam (spec section 8).
--
-- Every filesystem operation goes through this module so tests can run against
-- real temp directories and force specific failures (cross-device, permission
-- denied, mid-action failure) without patching vim.uv.
--
-- Rules (section 8 / D2):
--   * operations never raise: they return `true` or `nil, err[, code]`;
--   * functions call each other through the module table (M.copy_file, ...), so
--     a test stub on M.copy_file is honoured by M.copy_tree;
--   * no vim.cmd, no vim.fn.input, no buffer access -- headless-safe.

local M = {}

-- ---------------------------------------------------------------------------
-- Thin pure wrappers
-- ---------------------------------------------------------------------------

-- abspath(path) -> absolute path | nil, 'invalid path'. Non-string input is
-- rejected before any call (O3): vim.fs.abspath raises on nil.
function M.abspath(path)
  if type(path) ~= 'string' then
    return nil, 'invalid path'
  end
  return vim.fs.abspath(path)
end

-- basename strips a trailing slash before delegating: `vim.fs.basename('/a/b/')`
-- is '' (R4), which would make a directory yank store an empty name. Non-string
-- input returns nil, 'invalid path' without raising (O3).
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

-- is_dir/is_file follow symlinks (stat, not lstat), matching Python's
-- os.path.isdir / os.path.isfile. They are predicates, so they return booleans.
function M.is_dir(path)
  local st = M.stat(path)
  return st ~= nil and st.type == 'directory'
end

function M.is_file(path)
  local st = M.stat(path)
  return st ~= nil and st.type == 'file'
end

-- realpath(path) -> the resolved path, or the input when it cannot be resolved
-- (section 8). vim.fs.realpath does not exist on the target runtime (B4).
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

-- list_dir(path) -> names sorted byte-wise ascending (D17), or nil, err.
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

local function ignored(path, ignore_set)
  if not ignore_set then
    return false
  end
  for _, ignored_path in ipairs(ignore_set) do
    if M.same_path(path, ignored_path) then
      return true
    end
  end
  return false
end

-- read_dir_lines(root, ignore_set) -> the B1 listing pipeline as a string array:
-- directories first (each with a trailing '/'), then files, each group sorted
-- ascending. Symlinks are resolved with a following stat (R3); entries whose
-- stat fails (broken symlink) or whose target is neither a file nor a directory
-- (fifo, socket, device) are omitted, matching Python where isdir and isfile are
-- both false. `ignore_set` is a list of paths (the glob results of &wildignore,
-- B13); an entry is ignored when fs.same_path matches any member.
function M.read_dir_lines(root, ignore_set)
  if not M.is_dir(root) then
    return nil, 'not a directory: ' .. tostring(root)
  end
  local dirs, files = {}, {}
  for name, typ in M.iter_dir(root) do
    local path = M.join(root, name)
    if typ == 'link' then
      local st = M.stat(path)
      if st then
        typ = st.type
      end
    end
    if not ignored(path, ignore_set) then
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
-- Identity (D2)
-- ---------------------------------------------------------------------------

-- same_path(a, b) -> ino+dev equality, the Lua equivalent of
-- os.path.samefile; falls back to normalised-string equality when either side
-- cannot be stat'ed. This is spelling-independent, so it is correct for a root
-- reached through a symlinked prefix (B9). Non-string inputs return
-- nil, 'invalid path' instead of raising inside vim.fs.normalize (B2).
function M.same_path(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then
    return nil, 'invalid path'
  end
  local sa = M.stat(a)
  local sb = M.stat(b)
  if sa and sb then
    return sa.ino == sb.ino and sa.dev == sb.dev
  end
  return vim.fs.normalize(a) == vim.fs.normalize(b)
end

-- ---------------------------------------------------------------------------
-- Mutation
-- ---------------------------------------------------------------------------

-- rename(src, dst) -> true | nil, err, code. On EXDEV only (D5) it falls back
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
    -- The source is REMOVED below, so the copy must be complete: an entry it
    -- could not reproduce must refuse the move instead of being destroyed
    -- silently (P1; review follow-up moved the refusal from copy_tree's default
    -- behaviour to this explicit request).
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

-- uncopyable(ctx, path, kind) -> err | nil. Classifies one entry the copy cannot
-- reproduce faithfully: a symlink (following it would silently turn the link
-- into a copy of its target, and cp -a style preservation is deliberately out of
-- scope), any other lstat type (FIFO, socket, device), an entry that cannot be
-- lstat'ed, or a directory whose contents cannot be read (see copy_dir).
--
-- Under `ctx.require_complete` -- the destructive caller's contract -- it returns
-- the refusal message, which stops the walk and leaves the caller's source where
-- it is. Otherwise the entry is SKIPPED and recorded in ctx.skipped for the
-- caller to report: it is never dropped silently.
local function uncopyable(ctx, path, kind)
  if ctx.require_complete then
    return 'cannot copy ' .. kind .. ': ' .. path
  end
  ctx.skipped[#ctx.skipped + 1] = { path = path, kind = kind }
  return nil
end

-- discard(created) undoes what a FAILED copy created, newest first, so a refused
-- copy leaves no partial destination behind. Only paths THIS copy created are in
-- the list, so a destination that already existed is never removed from under
-- its owner. Cleanup itself is best-effort: the invariant that matters -- the
-- source is untouched -- already holds, and the copy's own error is what the
-- caller reports.
local function discard(created)
  for i = #created, 1, -1 do
    local path = created[i]
    if M.is_dir(path) then
      M.rm_tree(path)
    else
      M.rm_file(path)
    end
  end
end

-- copy_dir(from, to, ctx) -> true | nil, err. The recursion behind copy_tree and
-- the SINGLE AUTHORITY on what a copy reproduces: it classifies every entry with
-- lstat as it walks (never following the final component) and copies plain files
-- and real directories. The verdict therefore does not depend on any earlier
-- pass, so an entry that appears after the copy started is still seen -- the
-- round that narrowed the refusal to one up-front scan could miss such an entry,
-- and `rename`'s EXDEV fallback then removed the source, destroying it silently
-- (Greptile P1 on 7d5ce12).
--
-- Every directory is probed with fs_scandir BEFORE its destination is created.
-- M.list_dir reports nil only for a non-directory, and a scan that fails (EACCES)
-- goes through vim.fs.dir, which yields nothing instead of raising, so an
-- unreadable directory would otherwise read as EMPTY and its contents would be
-- dropped -- or, best-effort, an empty stand-in directory would be created for
-- it. The probe runs before mkdirp(to) so nothing stands in for what could not
-- be read, while the listing runs AFTER mkdirp(to) so the walk classifies each
-- directory as late as it can. Calls go through the module table (M.mkdirp,
-- M.list_dir, M.copy_file), so the S8 seam rule holds here too.
--
-- A skipped directory (best-effort mode) is a SUCCESS carrying a ctx.skipped
-- record, not a failure: only a real I/O failure or a refusal returns nil, err.
local function copy_dir(from, to, ctx)
  local scan, scan_err = vim.uv.fs_scandir(from)
  if scan == nil then
    local uerr = uncopyable(ctx, from,
      'unreadable directory (' .. tostring(scan_err) .. ')')
    if uerr ~= nil then
      return nil, uerr
    end
    return true
  end
  -- Drain the handle: luv closes it at the end of iteration.
  while vim.uv.fs_scandir_next(scan) ~= nil do end

  local existed = M.exists(to)
  local mok, merr = M.mkdirp(to)
  if not mok then
    return nil, merr
  end
  if not existed then
    ctx.created[#ctx.created + 1] = to
  end
  local names = M.list_dir(from)
  if not names then
    return nil, 'cannot list: ' .. tostring(from)
  end
  for _, name in ipairs(names) do
    local child_from = M.join(from, name)
    local child_to = M.join(to, name)
    local ok, lst = pcall(vim.uv.fs_lstat, child_from)
    if not ok or lst == nil then
      local uerr = uncopyable(ctx, child_from, 'unreadable entry')
      if uerr ~= nil then
        return nil, uerr
      end
    elseif lst.type == 'directory' then
      local cok, cerr = copy_dir(child_from, child_to, ctx)
      if not cok then
        return nil, cerr
      end
    elseif lst.type == 'file' then
      -- Recorded BEFORE the copy, so a half-written file is cleaned up too.
      ctx.created[#ctx.created + 1] = child_to
      local cok, cerr = M.copy_file(child_from, child_to)
      if not cok then
        return nil, cerr
      end
    else
      -- 'link' is the luv name for a symlink; keep reporting it as 'symlink',
      -- which is the vocabulary the skipped-entry records already use.
      local kind = lst.type == 'link' and 'symlink' or tostring(lst.type)
      local uerr = uncopyable(ctx, child_from, kind)
      if uerr ~= nil then
        return nil, uerr
      end
    end
  end
  return true
end

-- copy_tree(src, dst[, opts]) -> true[, skipped] | nil, err. Recursive,
-- hand-rolled (no `cp -r`), with mkdir -p semantics; iteration goes through
-- M.list_dir, so ordering is deterministic (D17) and module-table stubs are
-- honoured.
--
-- `opts.require_complete` is the DESTRUCTIVE caller's contract: the caller
-- removes the source after a successful copy (`rename`'s EXDEV fallback), so an
-- entry the walk cannot reproduce is REFUSED, naming it -- and whatever the
-- failed copy had already created is removed first, so the source is left
-- completely intact and no partial destination remains.
--
-- Without it the copy is best-effort, which is what a yank or a paste needs:
-- they destroy nothing, so an entry that merely cannot be reproduced must not
-- fail the whole operation. Such entries are SKIPPED and returned as `skipped`
-- (a list of `{ path, kind }`, nil when nothing was skipped) so the caller can
-- report them; an uncopyable entry is never dropped silently.
function M.copy_tree(src, dst, opts)
  if not M.is_dir(src) then
    return nil, 'not a directory: ' .. tostring(src)
  end
  local ctx = {
    require_complete = opts ~= nil and opts.require_complete == true,
    skipped = {},
    created = {},
  }
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
-- directory for a nil argument (O3).
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

-- touch(path) -> true | nil, err. Spec section 8 defines touch as
-- `vim.fn.writefile({}, path)` (create/truncate to empty). Non-string input is
-- rejected before any call so a nil cannot reach writefile (O3).
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
