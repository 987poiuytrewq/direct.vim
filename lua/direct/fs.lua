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
    local cok, cerr = M.copy_tree(src, dst)
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

-- copy_tree(src, dst) -> true | nil, err. Recursive, hand-rolled (no `cp -r`),
-- with mkdir -p semantics. Symlinks are followed (matching shutil.copytree's
-- default); entries that are neither files nor directories are skipped so the
-- copy stays total. Iteration goes through M.list_dir, so ordering is
-- deterministic (D17) and stubs on the module table are honoured.
function M.copy_tree(src, dst)
  if not M.is_dir(src) then
    return nil, 'not a directory: ' .. tostring(src)
  end
  local mok, merr = M.mkdirp(dst)
  if not mok then
    return nil, merr
  end
  local names = M.list_dir(src)
  if not names then
    return nil, 'cannot list: ' .. tostring(src)
  end
  for _, name in ipairs(names) do
    local from = M.join(src, name)
    local to = M.join(dst, name)
    local st = M.stat(from)
    if st and st.type == 'directory' then
      local cok, cerr = M.copy_tree(from, to)
      if not cok then
        return nil, cerr
      end
    elseif st and st.type == 'file' then
      local cok, cerr = M.copy_file(from, to)
      if not cok then
        return nil, cerr
      end
    end
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
