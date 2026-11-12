-- lua/direct/fs.lua -- filesystem operations and copy semantics.
-- Operations return true or nil, err rather than raising. Destructive cross-device
-- moves require a complete copy; best-effort copies report unsupported entries.

local M = {}
M.uv = vim.uv
local platform = require('direct.platform')
local temp_sequence = 0

local function temp_candidate(parent, tag)
  temp_sequence = temp_sequence + 1
  return M.join(parent, string.format('.direct-%s-%d-%d', tag, M.uv.os_getpid(), temp_sequence))
end

function M.unique_temp_path(parent, tag)
  if type(parent) ~= 'string' or parent == '' then return nil, 'invalid parent path' end
  temp_sequence = temp_sequence + 1
  local nonce = tostring(M.uv.hrtime()) .. '-' .. tostring(temp_sequence)
  return M.join(parent, string.format('.direct-%s-%d-%s', tag or 'temp', M.uv.os_getpid(), nonce))
end

local function is_eexist(err, code)
  return code == 'EEXIST'
    or code == 17
    or (type(err) == 'string' and (err:find('EEXIST', 1, true) ~= nil or err:find('exists', 1, true) ~= nil))
end

local function identity_key(stat, path)
  local windows_identity = platform.file_identity(path, true)
  if windows_identity then return windows_identity end
  if not stat or stat.dev == nil or stat.ino == nil then return nil end
  return tostring(stat.dev) .. ':' .. tostring(stat.ino)
end

-- libuv needs the Windows directory-symlink flag when recreating a link whose
-- target is a directory. Resolve through the source link so relative targets
-- are interpreted relative to the link's parent, not the process cwd.
local function remove_file_if_same(path, identity)
  local now = M.uv.fs_lstat(path)
  if identity ~= nil and identity_key(now, path) == identity then return M.rm_file(path) end
  return nil, 'temporary path changed; preserved at ' .. tostring(path)
end

local function remove_dir_if_same(path, identity)
  local now = M.uv.fs_lstat(path)
  if identity ~= nil and identity_key(now, path) == identity then
    local ok, err = M.uv.fs_rmdir(path)
    if ok then return true end
    return nil, err
  end
  return nil, 'temporary directory changed; preserved at ' .. tostring(path)
end

-- ---------------------------------------------------------------------------
require('direct.fs.path_ops')({ M = M, platform = platform, identity_key = identity_key })

-- Mutation
-- ---------------------------------------------------------------------------

local function is_exdev(err, code)
  return code == 'EXDEV'
    or code == 18
    or (type(err) == 'string' and (err:find('EXDEV', 1, true) ~= nil or err:find('Cross-device link', 1, true) ~= nil))
end

local function rename_case_only(src, dst)
  local source_path = require('direct.paths').strip_trailing_separator(src)
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
    local message = 'case-only rename failed ('
      .. tostring(err)
      .. '); source preserved at '
      .. temp
      .. '; restore to '
      .. src
      .. ' failed ('
      .. tostring(restore_err)
      .. ')'
    require('direct.ui').notify('direct: ' .. message, vim.log.levels.ERROR)
    return nil, message, code
  end
  return nil, err, code
end

-- rename(src, dst) -> true | nil, err, code. Placement is always atomic
-- no-replace. EXDEV is handled by an exclusive-temp copy path below.
function M.rename(src, dst)
  if type(src) ~= 'string' or src == '' or type(dst) ~= 'string' or dst == '' then return nil, 'invalid path' end
  local src_spelling = require('direct.paths').strip_trailing_separator(src)
  local dst_spelling = require('direct.paths').strip_trailing_separator(dst)
  local src_norm = require('direct.paths').canonical(src_spelling)
  local dst_norm = require('direct.paths').canonical(dst_spelling)
  if src_norm == dst_norm then
    if M.taken(src) then return true end
    return nil, 'source does not exist: ' .. tostring(src), 'ENOENT'
  end
  if M.same_entry(src, dst) then return rename_case_only(src, dst) end
  local ok, err, code = M.rename_noreplace(src, dst)
  if ok then return true end
  if not is_exdev(err, code) then return nil, err, code end
  return M.move_exdev(src, dst)
end

-- rename_noreplace(src, dst) -> true | nil, err. POSIX rename replaces an
-- occupied destination, and checking M.taken(dst) first leaves a TOCTOU window.
-- Use the native atomic exclusive-rename operation on each supported platform;
-- if unavailable, fail closed rather than placing onto a user path.
function M.rename_noreplace(src, dst, expected_source_identity)
  if type(src) ~= 'string' or src == '' or type(dst) ~= 'string' or dst == '' then return nil, 'invalid path' end
  if src:find('\0', 1, true) or dst:find('\0', 1, true) then return nil, 'invalid path: contains NUL' end
  src = require('direct.paths').strip_trailing_separator(src)
  dst = require('direct.paths').strip_trailing_separator(dst)
  if expected_source_identity ~= nil then
    local actual = identity_key(M.uv.fs_lstat(src), src)
    if expected_source_identity.inode == nil or actual ~= expected_source_identity.inode then
      return nil, 'source identity changed: ' .. src, 'ESTALE'
    end
  end
  return platform.rename_noreplace(src, dst, M.uv.os_uname().sysname)
end

-- copy_file(src, dst) -> true | nil, err, code (vim.uv.fs_copyfile preserves
-- mode by default).
function M.copy_file(src, dst)
  if type(src) ~= 'string' or type(dst) ~= 'string' then return nil, 'invalid path' end
  local ok, err, code = vim.uv.fs_copyfile(src, dst)
  if ok then return true end
  return nil, err, code
end

-- copy_file_exclusive refuses any existing destination atomically. Unlike
-- copy_file, it is suitable for user paths where an occupant must never be
-- overwritten.
function M.copy_file_exclusive(src, dst)
  if type(src) ~= 'string' or src == '' or type(dst) ~= 'string' or dst == '' then return nil, 'invalid path' end
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
  if not ok or lst == nil then return 'unreadable entry', nil end
  if lst.type == 'directory' then
    local scan, scan_err = vim.uv.fs_scandir(path)
    if scan == nil then return 'unreadable directory (' .. tostring(scan_err) .. ')', 'directory' end
    -- Drain the handle: luv closes it at the end of iteration.
    while vim.uv.fs_scandir_next(scan) ~= nil do
    end
    return nil, 'directory'
  end
  if lst.type == 'file' then return nil, 'file' end
  if lst.type == 'link' and opts ~= nil and opts.recreate_symlinks then return nil, 'link' end
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
  if ctx.require_complete then return 'cannot copy ' .. kind .. ': ' .. path end
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
    if uerr ~= nil then return nil, uerr end
    return true
  end

  local existed = M.taken(to)
  if existed and ctx.require_complete then return nil, 'destination exists: ' .. tostring(to) end
  local mok, merr
  if ctx.require_complete or ctx.exclusive then
    mok, merr = M.mkdir_exclusive(to)
  else
    mok, merr = M.mkdirp(to)
  end
  if not mok then return nil, merr end
  if not existed then
    ctx.created[#ctx.created + 1] = {
      path = to,
      dir = true,
      identity = identity_key(M.uv.fs_lstat(to), to),
    }
  end
  local names = M.list_dir(from)
  if not names then return nil, 'cannot list: ' .. tostring(from) end
  for _, name in ipairs(names) do
    local child_from = M.join(from, name)
    local child_to = M.join(to, name)
    local child_kind, itype = classify(child_from, ctx)
    if child_kind ~= nil then
      local uerr = uncopyable(ctx, child_from, child_kind)
      if uerr ~= nil then return nil, uerr end
    elseif itype == 'directory' then
      local cok, cerr = copy_dir(child_from, child_to, ctx)
      if not cok then return nil, cerr end
    elseif itype == 'link' and ctx.recreate_symlinks then
      local target, read_err = M.uv.fs_readlink(child_from)
      if not target then return nil, 'cannot read symlink: ' .. tostring(read_err) end
      local linked, link_err, link_code = platform.create_symlink(target, child_to, child_from)
      if not linked then return nil, tostring(link_err or link_code or 'cannot recreate symlink') end
      ctx.created[#ctx.created + 1] = {
        path = child_to,
        dir = false,
        identity = identity_key(M.uv.fs_lstat(child_to), child_to),
      }
    else
      -- A plain file. Recorded BEFORE the copy, so a half-written file is
      -- cleaned up too -- but only when the destination path was free: a path
      -- that was already taken belongs to whoever put it there, and a failure
      -- there (EISDIR when the source entry clashes with an existing
      -- destination directory, say) must not delete it.
      local child_taken = M.taken(child_to)
      if child_taken and ctx.require_complete then return nil, 'destination exists: ' .. tostring(child_to) end
      if not child_taken then ctx.created[#ctx.created + 1] = { path = child_to, dir = false } end
      local cok, cerr, ccode
      if ctx.require_complete or ctx.exclusive then
        cok, cerr, ccode = M.copy_file_exclusive(child_from, child_to)
      else
        cok, cerr, ccode = M.copy_file(child_from, child_to)
      end
      if not cok then
        if not child_taken and (ccode == 'EEXIST' or (type(cerr) == 'string' and cerr:find('EEXIST', 1, true))) then
          -- An exclusive copy lost a race; the occupant belongs to someone else.
          table.remove(ctx.created)
        elseif not child_taken then
          -- A failed exclusive copy may leave its partial file behind. Capture
          -- its inode so cleanup cannot unlink a replacement at this pathname.
          local entry = ctx.created[#ctx.created]
          entry.identity = identity_key(M.uv.fs_lstat(child_to), child_to)
        end
        return nil, cerr
      end
      if not child_taken then ctx.created[#ctx.created].identity = identity_key(M.uv.fs_lstat(child_to), child_to) end
    end
  end
  return true
end

-- prescan performs a deterministic depth-first walk before any writes. Complete
-- mode can therefore refuse unsupported entries without touching the
-- destination; the live copy walk still catches entries that appear later.
local function prescan(path, offender, ctx)
  local names = M.list_dir(path)
  if not names then return nil, 'cannot list: ' .. tostring(path) end
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
      if err ~= nil then return nil, err end
      if nested ~= nil then return nested end
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
  if not M.is_dir(src) then return nil, 'not a directory: ' .. tostring(src) end
  local ctx = {
    require_complete = opts ~= nil and opts.require_complete == true,
    recreate_symlinks = opts ~= nil and opts.recreate_symlinks == true,
    exclusive = opts ~= nil and opts.exclusive == true,
    skipped = {},
    created = {},
  }
  if ctx.require_complete then
    local offender, perr = prescan(src, {}, ctx)
    if perr ~= nil then return nil, perr end
    if offender ~= nil then return nil, 'cannot copy ' .. offender.kind .. ': ' .. offender.path end
    if M.taken(dst) then return nil, 'destination exists: ' .. tostring(dst) end
  end
  local cok, cerr = copy_dir(src, dst, ctx)
  if not cok then
    discard(ctx.created)
    return nil, cerr
  end
  if #ctx.skipped > 0 then return true, ctx.skipped, ctx.created end
  return true, nil, ctx.created
end

local function destination_parent(path)
  local trimmed = require('direct.paths').strip_trailing_separator(path)
  return M.dirname(trimmed)
end

local function allocate_private_dir(dst, tag)
  local parent = destination_parent(dst)
  for _ = 1, 100 do
    local candidate = temp_candidate(parent, tag)
    local ok, err, code = M.mkdir_exclusive(candidate, 448) -- private mode 0700
    if ok then return candidate, identity_key(M.uv.fs_lstat(candidate), candidate) end
    if not is_eexist(err, code) then return nil, err, code end
  end
  return nil, 'could not allocate a unique private temp directory'
end

local function cleanup_private_dir(path, identity)
  local ok, err = remove_dir_if_same(path, identity)
  if not ok then
    require('direct.ui').notify(
      'direct: temporary directory preserved at ' .. path .. ': ' .. tostring(err),
      vim.log.levels.ERROR
    )
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
      return nil, 'source or private copy changed before placement: ' .. tostring(compare_err or 'content mismatch')
    end
  end
  local placed, place_err, place_code = M.rename_noreplace(payload, dst, { inode = payload_identity })
  if not placed then
    discard(created or {})
    cleanup_private_dir(temp_dir, temp_identity)
    return nil, place_err, place_code
  end
  cleanup_private_dir(temp_dir, temp_identity)
  return true, skipped
end

local function report_partial_move(src, dst, err)
  require('direct.ui').notify(
    'direct: destination committed at '
      .. dst
      .. ' but source could not be removed at '
      .. src
      .. ': '
      .. tostring(err)
      .. '; both copies may remain',
    vim.log.levels.ERROR
  )
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
    if not target_a or not target_b then return nil, tostring(err_a or err_b or 'readlink failed') end
    return target_a == target_b
  end
  if a.type ~= 'directory' then return false end
  local initial_src, initial_dst = a, b
  local names_a, err_a = M.list_dir(src)
  local names_b, err_b = M.list_dir(dst)
  if not names_a or not names_b then return nil, tostring(err_a or err_b or 'cannot list directory') end
  if not vim.deep_equal(names_a, names_b) then return false end
  for _, name in ipairs(names_a) do
    local equal, err = same_tree(M.join(src, name), M.join(dst, name))
    if not equal then return equal, err end
  end
  local final_src, final_dst = M.uv.fs_lstat(src), M.uv.fs_lstat(dst)
  local function directory_stable(before, after)
    if not after or before.dev ~= after.dev or before.ino ~= after.ino or before.size ~= after.size then
      return false
    end
    for _, field in ipairs({ 'mtime', 'ctime' }) do
      local left, right = before[field] or {}, after[field] or {}
      if left.sec ~= right.sec or left.nsec ~= right.nsec then return false end
    end
    return true
  end
  if not directory_stable(initial_src, final_src) or not directory_stable(initial_dst, final_dst) then
    return false, 'directory changed while being verified'
  end
  return true
end

M.same_contents = same_tree

local function restore_quarantined_source(quarantine_dir, dir_identity, quarantine, src, dst, reason)
  local restored, restore_err = M.rename_noreplace(quarantine, src)
  if restored then
    cleanup_private_dir(quarantine_dir, dir_identity)
    report_partial_move(src, dst, reason)
    return true
  end
  require('direct.ui').notify(
    'direct: destination committed at '
      .. dst
      .. '; source could not be restored to '
      .. src
      .. ' ('
      .. tostring(restore_err)
      .. '); original source preserved at '
      .. quarantine
      .. ' ('
      .. tostring(reason)
      .. ')',
    vim.log.levels.ERROR
  )
  return true
end

local function remove_source_after_copy(src, dst, kind, original_identity)
  -- Capture the pathname with one atomic same-filesystem rename before verifying
  -- or deleting it. This prevents a new object placed at `src` after the copy
  -- from being removed by a later pathname-based unlink/rm_tree.
  local quarantine_dir, dir_identity, dir_err = allocate_private_dir(src, 'exdev-source')
  if not quarantine_dir then
    report_partial_move(src, dst, 'could not allocate source quarantine: ' .. tostring(dir_identity or dir_err))
    return true
  end
  local quarantine = M.join(quarantine_dir, 'source')
  local captured, capture_err = M.rename_noreplace(src, quarantine)
  if not captured then
    cleanup_private_dir(quarantine_dir, dir_identity)
    report_partial_move(src, dst, 'could not capture source for safe removal: ' .. tostring(capture_err))
    return true
  end

  local captured_identity = identity_key(M.uv.fs_lstat(quarantine), quarantine)
  if original_identity == nil or captured_identity ~= original_identity then
    return restore_quarantined_source(
      quarantine_dir,
      dir_identity,
      quarantine,
      src,
      dst,
      'source identity changed before removal'
    )
  end
  local equal, compare_err = same_tree(quarantine, dst)
  if not equal then
    return restore_quarantined_source(
      quarantine_dir,
      dir_identity,
      quarantine,
      src,
      dst,
      'source changed or could not be verified after copy: ' .. tostring(compare_err or 'content mismatch')
    )
  end

  local removed, remove_err
  if kind == 'directory' then
    removed, remove_err = M.rm_tree(quarantine)
  else
    removed, remove_err = M.rm_file(quarantine)
  end
  if not removed or M.taken(quarantine) then
    return restore_quarantined_source(
      quarantine_dir,
      dir_identity,
      quarantine,
      src,
      dst,
      'source removal failed: ' .. tostring(remove_err or 'source remains')
    )
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
      local partial_identity = identity_key(M.uv.fs_lstat(temp), temp)
      if partial_identity ~= nil then
        local cleanup_ok, cleanup_err = remove_file_if_same(temp, partial_identity)
        if not cleanup_ok then
          require('direct.ui').notify(
            'direct: failed copy temp preserved at ' .. temp .. ': ' .. tostring(cleanup_err),
            vim.log.levels.ERROR
          )
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
      require('direct.ui').notify(
        'direct: copy temp preserved at ' .. temp .. ': ' .. tostring(cleanup_err),
        vim.log.levels.ERROR
      )
    end
    cleanup_private_dir(temp_dir, temp_dir_identity)
    return nil, 'source or private copy changed before placement: ' .. tostring(compare_err or 'content mismatch')
  end
  local placed, place_err, place_code = M.rename_noreplace(temp, dst, temp_identity)
  if not placed then
    local cleanup_ok, cleanup_err = remove_file_if_same(temp, temp_identity.inode)
    if not cleanup_ok then
      require('direct.ui').notify(
        'direct: copy temp preserved at ' .. temp .. ': ' .. tostring(cleanup_err),
        vim.log.levels.ERROR
      )
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
    linked, link_err, link_code = platform.create_symlink(target, temp, src)
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
      require('direct.ui').notify(
        'direct: symlink temp preserved at ' .. temp .. ': ' .. tostring(cleanup_err),
        vim.log.levels.ERROR
      )
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
  src = require('direct.paths').strip_trailing_separator(src)
  dst = require('direct.paths').strip_trailing_separator(dst)
  local source = M.uv.fs_lstat(src)
  if not source then return nil, 'cannot stat source: ' .. tostring(src) end
  local source_identity = identity_key(source, src)
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

local function async_callback(callback, ...)
  local first, second, third = ...
  vim.schedule(function() callback(first, second, third) end)
end

local function same_tree_async_file(src, dst, callback)
  local uv = M.uv
  uv.fs_open(src, 'r', 0, function(open_src_err, src_fd)
    if open_src_err or not src_fd then
      return async_callback(callback, nil, 'cannot read source: ' .. tostring(open_src_err))
    end
    uv.fs_open(dst, 'r', 0, function(open_dst_err, dst_fd)
      if open_dst_err or not dst_fd then
        uv.fs_close(src_fd)
        return async_callback(callback, nil, 'cannot read destination: ' .. tostring(open_dst_err))
      end
      uv.fs_fstat(src_fd, function(stat_src_err, stat_src)
        uv.fs_fstat(dst_fd, function(stat_dst_err, stat_dst)
          if stat_src_err or stat_dst_err or not stat_src or not stat_dst then
            uv.fs_close(src_fd)
            uv.fs_close(dst_fd)
            return async_callback(callback, nil, tostring(stat_src_err or stat_dst_err or 'fstat failed'))
          end
          if stat_src.size ~= stat_dst.size then
            uv.fs_close(src_fd)
            uv.fs_close(dst_fd)
            return async_callback(callback, false)
          end
          local offset = 0
          local function finish(equal, reason)
            uv.fs_fstat(src_fd, function(after_src_err, after_src)
              uv.fs_fstat(dst_fd, function(after_dst_err, after_dst)
                local stable = after_src
                  and after_dst
                  and stat_src.size == after_src.size
                  and stat_dst.size == after_dst.size
                for _, field in ipairs({ 'mtime', 'ctime' }) do
                  local before_a, after_a = stat_src[field] or {}, after_src and after_src[field] or {}
                  local before_b, after_b = stat_dst[field] or {}, after_dst and after_dst[field] or {}
                  if
                    before_a.sec ~= after_a.sec
                    or before_a.nsec ~= after_a.nsec
                    or before_b.sec ~= after_b.sec
                    or before_b.nsec ~= after_b.nsec
                  then
                    stable = false
                  end
                end
                uv.fs_close(src_fd, function(close_src_err)
                  uv.fs_close(dst_fd, function(close_dst_err)
                    if equal and not stable then
                      return async_callback(callback, false, 'file changed while being verified')
                    end
                    if equal and (after_src_err or after_dst_err or close_src_err or close_dst_err) then
                      return async_callback(
                        callback,
                        nil,
                        tostring(after_src_err or after_dst_err or close_src_err or close_dst_err)
                      )
                    end
                    async_callback(callback, equal, reason)
                  end)
                end)
              end)
            end)
          end
          local function read_next()
            if offset >= stat_src.size then return finish(true) end
            local size = math.min(65536, stat_src.size - offset)
            uv.fs_read(src_fd, size, offset, function(read_src_err, bytes_src)
              if read_src_err or not bytes_src then
                return finish(nil, tostring(read_src_err or 'source read failed'))
              end
              uv.fs_read(dst_fd, size, offset, function(read_dst_err, bytes_dst)
                if read_dst_err or not bytes_dst then
                  return finish(nil, tostring(read_dst_err or 'destination read failed'))
                end
                if bytes_src ~= bytes_dst then return finish(false) end
                offset = offset + #bytes_src
                if #bytes_src == 0 then return finish(nil, 'file changed while being verified') end
                read_next()
              end)
            end)
          end
          read_next()
        end)
      end)
    end)
  end)
end

local function same_tree_async(src, dst, callback)
  local a, b = M.uv.fs_lstat(src), M.uv.fs_lstat(dst)
  if not a or not b then return async_callback(callback, nil, 'source or destination disappeared') end
  if a.type ~= b.type then return async_callback(callback, false) end
  if a.type == 'file' then return same_tree_async_file(src, dst, callback) end
  if a.type == 'link' then
    local target_a, err_a = M.uv.fs_readlink(src)
    local target_b, err_b = M.uv.fs_readlink(dst)
    if not target_a or not target_b then
      return async_callback(callback, nil, tostring(err_a or err_b or 'readlink failed'))
    end
    return async_callback(callback, target_a == target_b)
  end
  if a.type ~= 'directory' then return async_callback(callback, false) end

  local names_a, err_a = M.list_dir(src)
  local names_b, err_b = M.list_dir(dst)
  if not names_a or not names_b then
    return async_callback(callback, nil, tostring(err_a or err_b or 'cannot list directory'))
  end
  if not vim.deep_equal(names_a, names_b) then return async_callback(callback, false) end
  local index = 1
  local function next_entry()
    if index > #names_a then
      local final_a, final_b = M.uv.fs_lstat(src), M.uv.fs_lstat(dst)
      local function stable(before, after)
        if not after or before.dev ~= after.dev or before.ino ~= after.ino or before.size ~= after.size then
          return false
        end
        for _, field in ipairs({ 'mtime', 'ctime' }) do
          local left, right = before[field] or {}, after[field] or {}
          if left.sec ~= right.sec or left.nsec ~= right.nsec then return false end
        end
        return true
      end
      return async_callback(
        callback,
        stable(a, final_a) and stable(b, final_b),
        'directory changed while being verified'
      )
    end
    local name = names_a[index]
    index = index + 1
    same_tree_async(M.join(src, name), M.join(dst, name), function(equal, err)
      if equal ~= true then return callback(equal, err) end
      next_entry()
    end)
  end
  next_entry()
end

local function remove_tree_async(path, callback)
  local stat = M.uv.fs_lstat(path)
  if not stat then return async_callback(callback, nil, 'entry disappeared: ' .. path) end
  if stat.type ~= 'directory' then
    return M.uv.fs_unlink(path, function(err) async_callback(callback, err == nil, err and tostring(err) or nil) end)
  end
  local names, list_err = M.list_dir(path)
  if not names then return async_callback(callback, nil, tostring(list_err or 'cannot list directory')) end
  local index = 1
  local function remove_next()
    if index > #names then
      return M.uv.fs_rmdir(path, function(err) async_callback(callback, err == nil, err and tostring(err) or nil) end)
    end
    local child = M.join(path, names[index])
    index = index + 1
    remove_tree_async(child, function(ok, err)
      if not ok then return callback(nil, err) end
      remove_next()
    end)
  end
  remove_next()
end

local function restore_after_async_move(quarantine_dir, dir_identity, quarantine, src, dst, reason, callback)
  local restored, restore_err = M.rename_noreplace(quarantine, src)
  if restored then
    cleanup_private_dir(quarantine_dir, dir_identity)
    report_partial_move(src, dst, reason)
    return async_callback(callback, true, true)
  end
  require('direct.ui').notify(
    'direct: destination committed at '
      .. dst
      .. '; source could not be restored to '
      .. src
      .. ' ('
      .. tostring(restore_err)
      .. '); original source preserved at '
      .. quarantine
      .. ' ('
      .. tostring(reason)
      .. ')',
    vim.log.levels.ERROR
  )
  async_callback(callback, true, true)
end

local function remove_async_move_source(src, dst, original_identity, callback)
  local quarantine_dir, dir_identity, dir_err = allocate_private_dir(src, 'exdev-source')
  if not quarantine_dir then
    report_partial_move(src, dst, 'could not allocate source quarantine: ' .. tostring(dir_identity or dir_err))
    return async_callback(callback, true, true)
  end
  local quarantine = M.join(quarantine_dir, 'source')
  local captured, capture_err = M.rename_noreplace(src, quarantine)
  if not captured then
    cleanup_private_dir(quarantine_dir, dir_identity)
    report_partial_move(src, dst, 'could not capture source for safe removal: ' .. tostring(capture_err))
    return async_callback(callback, true, true)
  end
  if original_identity == nil or identity_key(M.uv.fs_lstat(quarantine), quarantine) ~= original_identity then
    return restore_after_async_move(
      quarantine_dir,
      dir_identity,
      quarantine,
      src,
      dst,
      'source identity changed before removal',
      callback
    )
  end
  same_tree_async(quarantine, dst, function(equal, compare_err)
    if not equal then
      return restore_after_async_move(
        quarantine_dir,
        dir_identity,
        quarantine,
        src,
        dst,
        'source changed or could not be verified after copy: ' .. tostring(compare_err or 'content mismatch'),
        callback
      )
    end
    remove_tree_async(quarantine, function(removed, remove_err)
      if not removed or M.taken(quarantine) then
        return restore_after_async_move(
          quarantine_dir,
          dir_identity,
          quarantine,
          src,
          dst,
          'source removal failed: ' .. tostring(remove_err or 'source remains'),
          callback
        )
      end
      cleanup_private_dir(quarantine_dir, dir_identity)
      async_callback(callback, true, false)
    end)
  end)
end

local function async_copy_tree_exclusive(src, dst, callback, progress)
  local original_identity = identity_key(M.uv.fs_lstat(src), src)
  if not original_identity then
    return async_callback(callback, false, nil, 'could not verify source directory identity')
  end
  local ctx = { require_complete = true, recreate_symlinks = true }
  local offender, prescan_err = prescan(src, {}, ctx)
  if prescan_err then return async_callback(callback, false, nil, prescan_err) end
  if offender then
    return async_callback(callback, false, nil, 'cannot copy ' .. offender.kind .. ': ' .. offender.path)
  end
  if M.taken(dst) then return async_callback(callback, false, nil, 'destination exists: ' .. tostring(dst)) end
  local temp_dir, temp_identity, alloc_err = allocate_private_dir(dst, 'move-tree')
  if not temp_dir then return async_callback(callback, false, nil, tostring(temp_identity or alloc_err)) end
  local payload = M.join(temp_dir, 'payload')
  local created, files, directories = {}, {}, { { src = src, dst = payload } }
  local copied_files, total_files = 0, 0
  local function fail(err)
    discard(created)
    cleanup_private_dir(temp_dir, temp_identity)
    async_callback(callback, false, nil, err)
  end
  local function add_directory(from, to)
    local made, mkdir_err = M.mkdir_exclusive(to)
    if not made then return nil, mkdir_err end
    created[#created + 1] = { path = to, dir = true, identity = identity_key(M.uv.fs_lstat(to), to) }
    local names, list_err = M.list_dir(from)
    if not names then return nil, 'cannot list: ' .. tostring(list_err or from) end
    for _, name in ipairs(names) do
      local child_src, child_dst = M.join(from, name), M.join(to, name)
      local kind, itype = classify(child_src, ctx)
      if kind then return nil, 'cannot copy ' .. kind .. ': ' .. child_src end
      if itype == 'directory' then
        directories[#directories + 1] = { src = child_src, dst = child_dst }
      elseif itype == 'link' then
        local target, read_err = M.uv.fs_readlink(child_src)
        if not target then return nil, 'cannot read symlink: ' .. tostring(read_err) end
        local linked, link_err = platform.create_symlink(target, child_dst, child_src)
        if not linked then return nil, tostring(link_err or 'cannot recreate symlink') end
        created[#created + 1] =
          { path = child_dst, dir = false, identity = identity_key(M.uv.fs_lstat(child_dst), child_dst) }
      else
        files[#files + 1] = { src = child_src, dst = child_dst }
      end
    end
    return true
  end
  local directory_index = 1
  local function make_directories()
    while directory_index <= #directories do
      local directory = directories[directory_index]
      directory_index = directory_index + 1
      local ok, err = add_directory(directory.src, directory.dst)
      if not ok then return fail(err) end
    end
    total_files = #files
    local file_index = 1
    local function copy_next_file()
      if file_index > #files then
        local payload_identity = created[1] and created[1].identity
        if not payload_identity then return fail('could not verify private copy tree identity') end
        return same_tree_async(src, payload, function(equal, verify_err)
          if not equal then
            return fail(
              'source or private copy changed before placement: ' .. tostring(verify_err or 'content mismatch')
            )
          end
          local placed, place_err = M.rename_noreplace(payload, dst, { inode = payload_identity })
          if not placed then return fail(place_err) end
          cleanup_private_dir(temp_dir, temp_identity)
          return remove_async_move_source(
            src,
            dst,
            original_identity,
            function(ok, partial, err) callback(ok, partial, err) end
          )
        end)
      end
      local file = files[file_index]
      file_index = file_index + 1
      if M.taken(file.dst) then return fail('destination exists: ' .. file.dst) end
      local entry = { path = file.dst, dir = false }
      created[#created + 1] = entry
      M.uv.fs_copyfile(file.src, file.dst, { excl = true }, function(copy_err)
        vim.schedule(function()
          if copy_err then
            if copy_err == 'EEXIST' then table.remove(created) end
            entry.identity = identity_key(M.uv.fs_lstat(file.dst), file.dst)
            return fail(tostring(copy_err))
          end
          entry.identity = identity_key(M.uv.fs_lstat(file.dst), file.dst)
          copied_files = copied_files + 1
          if progress then progress(copied_files, total_files, file.src, file.dst) end
          copy_next_file()
        end)
      end)
    end
    copy_next_file()
  end
  make_directories()
end

function M.rename_async(src, dst, callback, progress)
  if type(callback) ~= 'function' then return nil, 'rename_async requires a callback' end
  if type(src) ~= 'string' or src == '' or type(dst) ~= 'string' or dst == '' then
    async_callback(callback, false, nil, 'invalid path')
    return true
  end
  local paths = require('direct.paths')
  local src_norm = paths.canonical(paths.strip_trailing_separator(src))
  local dst_norm = paths.canonical(paths.strip_trailing_separator(dst))
  if src_norm == dst_norm then
    async_callback(
      callback,
      M.taken(src),
      M.taken(src),
      M.taken(src) and nil or ('source does not exist: ' .. tostring(src))
    )
    return true
  end
  if M.same_entry(src, dst) then
    local renamed, rename_err = M.rename(src, dst)
    async_callback(callback, renamed ~= nil, renamed, rename_err)
    return true
  end
  local moved, err, code = M.rename_noreplace(src, dst)
  if moved then
    async_callback(callback, true, true)
    return true
  end
  if not is_exdev(err, code) then
    async_callback(callback, false, nil, err, code)
    return true
  end

  src = require('direct.paths').strip_trailing_separator(src)
  dst = require('direct.paths').strip_trailing_separator(dst)
  local source = M.uv.fs_lstat(src)
  if not source then
    async_callback(callback, false, nil, 'cannot stat source: ' .. tostring(src))
    return true
  end
  if progress then progress('copying', src, dst) end
  if source.type == 'directory' then
    async_copy_tree_exclusive(
      src,
      dst,
      function(ok, _, copy_err) async_callback(callback, ok, ok and true or nil, copy_err) end,
      progress
    )
    return true
  end
  if source.type == 'link' then
    local result, move_err = M.move_exdev(src, dst)
    async_callback(callback, result ~= nil, result, move_err)
    return true
  end
  if source.type ~= 'file' then
    async_callback(callback, false, nil, 'cannot move unsupported source type ' .. tostring(source.type))
    return true
  end

  local source_identity = identity_key(source, src)
  local temp_dir, dir_identity, dir_err = allocate_private_dir(dst, 'move-file')
  if not temp_dir then
    async_callback(callback, false, nil, tostring(dir_identity or dir_err))
    return true
  end
  local temp = M.join(temp_dir, 'payload')
  M.uv.fs_copyfile(src, temp, { excl = true }, function(copy_err)
    vim.schedule(function()
      if copy_err then
        cleanup_private_dir(temp_dir, dir_identity)
        return async_callback(callback, false, nil, tostring(copy_err))
      end
      same_tree_async(src, temp, function(equal, verify_err)
        if not equal then
          local temp_identity = M.entry_identity(temp)
          if temp_identity then remove_file_if_same(temp, temp_identity.inode) end
          cleanup_private_dir(temp_dir, dir_identity)
          return async_callback(
            callback,
            false,
            nil,
            'source or private copy changed before placement: ' .. tostring(verify_err or 'content mismatch')
          )
        end
        local temp_identity = M.entry_identity(temp)
        local placed, place_err = M.rename_noreplace(temp, dst, temp_identity)
        if not placed then
          if temp_identity then remove_file_if_same(temp, temp_identity.inode) end
          cleanup_private_dir(temp_dir, dir_identity)
          return async_callback(callback, false, nil, place_err)
        end
        cleanup_private_dir(temp_dir, dir_identity)
        remove_async_move_source(
          src,
          dst,
          source_identity,
          function(ok, _, err2) async_callback(callback, ok, ok and true or nil, err2) end
        )
      end)
    end)
  end)
  return true
end

-- rm_file(path) -> true | nil, err, code.
function M.rm_file(path)
  if type(path) ~= 'string' then return nil, 'invalid path' end
  local ok, err, code = vim.uv.fs_unlink(path)
  if ok then return true end
  return nil, err, code
end

-- rm_tree(path) -> true | nil, err. vim.fs.rm returns nil on success, so
-- success is "did not raise".
function M.rm_tree(path)
  local ok, err = pcall(vim.fs.rm, path, { recursive = true, force = true })
  if not ok then return nil, tostring(err) end
  return true
end

-- mkdirp(path) -> true | nil, err. vim.fn.mkdir raises when a file occupies the
-- path, so it is pcall-guarded; a 0 return also signals failure. Non-string
-- input is rejected before any call: vim.fn.mkdir would otherwise coerce a
-- number to a directory name in the cwd and create a literal `v:null`
-- directory for a nil argument.
function M.mkdirp(path)
  if type(path) ~= 'string' then return nil, 'invalid path' end
  local ok, res = pcall(vim.fn.mkdir, path, 'p')
  if not ok then return nil, tostring(res) end
  if res == 0 then return nil, 'mkdir failed: ' .. tostring(path) end
  return true
end

-- mkdir_exclusive creates exactly one directory and never merges into an
-- existing destination. Internal directory setup should continue using mkdirp.
function M.mkdir_exclusive(path, mode)
  if type(path) ~= 'string' or path == '' then return nil, 'invalid path' end
  local ok, err, code = M.uv.fs_mkdir(path, mode or 493) -- default 0755, subject to umask
  if ok then return true end
  if is_eexist(err, code) then return nil, 'destination exists: ' .. tostring(path), 'EEXIST' end
  return nil, err, code
end

-- touch uses exclusive create (`wx`): a file appearing after a caller's
-- occupancy check is still never truncated.
function M.touch(path)
  if type(path) ~= 'string' or path == '' then return nil, 'invalid path' end
  local fd, err, code = M.uv.fs_open(path, 'wx', 420) -- 0644, subject to umask
  if not fd then
    if is_eexist(err, code) then return nil, 'destination exists: ' .. tostring(path), 'EEXIST' end
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
    local close_err_text = tostring(close_err or 'close failed')
    require('direct.ui').notify(
      'direct: created file preserved at ' .. path .. ' but close failed: ' .. close_err_text,
      vim.log.levels.ERROR
    )
    return nil, 'close failed; created file preserved at ' .. path .. ': ' .. close_err_text
  end
  return true
end

return M
