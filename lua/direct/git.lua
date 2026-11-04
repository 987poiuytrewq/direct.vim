-- lua/direct/git.lua -- Git status and native Git-ignore snapshots.

local M = {}
local paths = require('direct.paths')

local status_priority = {
  ['!'] = -1,
  M = 1,
  D = 2,
  A = 3,
  R = 4,
  C = 4,
  U = 5,
}

local function normalize(path)
  return paths.canonical(path)
end

local function run(args, stdin)
  local ok, result = pcall(function()
    return vim.system(args, { text = false, stdin = stdin }):wait()
  end)
  if not ok then return nil, tostring(result), -1 end
  if result.code ~= 0 then
    local stderr = result.stderr and result.stderr:gsub('%s+$', '') or ''
    return nil, stderr ~= '' and stderr or 'git command failed', result.code, stderr
  end
  return result.stdout or '', nil, result.code
end

local function command(args, stdin)
  return run(vim.list_extend({ 'git' }, args), stdin)
end

local function nul_fields(output)
  local fields, start = {}, 1
  while start <= #output do
    local stop = output:find('\0', start, true)
    if not stop then break end
    fields[#fields + 1] = output:sub(start, stop - 1)
    start = stop + 1
  end
  return fields
end

local function normalize_status(xy)
  if xy == '??' then return ' A' end
  return (xy:gsub('T', 'M'))
end

local function status_priority_for(code)
  return status_priority[code] or 0
end

local function is_unmerged(xy)
  return xy:find('U', 1, true) ~= nil or xy == 'AA' or xy == 'DD'
end

local function merge_status(previous, incoming)
  if not previous then return incoming end
  local merged = {}
  for column = 1, 2 do
    local old, new = previous:sub(column, column), incoming:sub(column, column)
    merged[column] = status_priority_for(new) > status_priority_for(old) and new or old
  end
  return table.concat(merged)
end

local function path_is_missing(path)
  local ok, stat = pcall(vim.uv.fs_lstat, path)
  return ok and stat == nil
end

local function add_deleted(deleted, root, relative)
  local path = normalize(root .. '/' .. relative)
  local function add(path, kind)
    if not path_is_missing(path) then return end
    if not deleted[path] then deleted[path] = { kind = kind } end
  end

  add(path, 'file')
  local parent = path:match('^(.*)/[^/]+$')
  while parent do
    add(parent, 'directory')
    if parent == root or parent == '/' then break end
    parent = parent:match('^(.*)/[^/]+$')
  end
end

local function add_path(paths, conflicts, path, status, conflicted)
  local key = normalize(path)
  paths[key] = merge_status(paths[key], status)
  if conflicted then conflicts[key] = true end
end

local function add_with_parent_directories(paths, conflicts, root, relative, status, conflicted)
  local path = normalize(root .. '/' .. relative)
  add_path(paths, conflicts, path, status, conflicted)
  local parent = path:match('^(.*)/[^/]+$')
  while parent do
    add_path(paths, conflicts, parent, status, conflicted)
    if parent == root or parent == '/' then break end
    parent = parent:match('^(.*)/[^/]+$')
  end
end

-- read(root) -> { root = repository root, paths = absolute path -> porcelain XY }
-- or nil when Git is unavailable / root is not in a repository. One status
-- query covers the repository; directory status is aggregated from descendants.
function M.read(root)
  if type(root) ~= 'string' or root == '' then return nil end
  local root_output = run({ 'git', '-C', root, 'rev-parse', '--show-toplevel' })
  if not root_output then return nil end
  local repo_root = normalize(root_output:gsub('[\r\n]+$', ''))
  local output = run({ 'git', '-C', repo_root, 'status', '--porcelain=v1', '-z',
    '--untracked-files=all', '--ignored=matching' })
  if not output then return nil end

  local fields = nul_fields(output)
  local paths, conflicts, deleted = {}, {}, {}
  local index = 1
  while index <= #fields do
    local record = fields[index]
    index = index + 1
    if #record >= 4 then
      local xy = record:sub(1, 2)
      local relative = record:sub(4)
      local status = normalize_status(xy)
      if status ~= '  ' and relative ~= '' then
        -- In -z output, a rename record is followed by the original path; the
        -- first path is the destination and is the one present in the listing.
        if xy:find('R', 1, true) or xy:find('C', 1, true) then
          index = index + 1
        end
        add_with_parent_directories(paths, conflicts, repo_root, relative, status,
          is_unmerged(xy))
        if xy:find('D', 1, true) then
          add_deleted(deleted, repo_root, relative)
        end
      end
    end
  end
  return { root = repo_root, paths = paths, conflicts = conflicts, deleted = deleted }
end

-- deleted_children(snapshot, directory) returns absent tracked entries directly
-- below directory. Missing parent directories are included in `snapshot.deleted`
-- so callers can display and expand a deleted subtree without touching disk.
function M.deleted_children(snapshot, directory)
  if not snapshot or type(snapshot.deleted) ~= 'table' then return {} end
  directory = normalize(directory)
  local prefix = directory == '/' and '/' or (directory .. '/')
  local result = {}
  for path, entry in pairs(snapshot.deleted) do
    if path:sub(1, #prefix) == prefix and path_is_missing(path) then
      local name = path:sub(#prefix + 1)
      if name ~= '' and not name:find('/', 1, true) then
        if entry.kind == 'directory' then
          name = name .. require('direct.paths').directory_separator()
        end
        result[#result + 1] = {
          name = name,
          path = path,
          kind = entry.kind,
        }
      end
    end
  end
  table.sort(result, function(a, b)
    if a.kind ~= b.kind then return a.kind == 'directory' end
    return a.name < b.name
  end)
  return result
end

local function discover_repo(path)
  if vim.fn.executable('git') ~= 1 then return nil, 'Git executable is unavailable' end
  local output, err = command({ '-C', path, 'rev-parse', '--show-toplevel' })
  if not output then
    local lower = tostring(err):lower()
    if lower:find('not a git repository', 1, true)
      or lower:find('must be run in a work tree', 1, true) then
      return false
    end
    return nil, err
  end
  return normalize(output:gsub('[\r\n]+$', ''))
end

local function add_tracked_path(tracked, relative)
  relative = relative:gsub('/+$', '')
  if relative == '' then return end
  tracked[relative] = true
  local parent = relative:match('^(.*)/[^/]+$')
  while parent do
    tracked[parent] = true
    parent = parent:match('^(.*)/[^/]+$')
  end
end

local function path_set(output)
  local result = {}
  for _, path in ipairs(nul_fields(output or '')) do
    path = path:gsub('/+$', '')
    if path ~= '' then result[path] = true end
  end
  return result
end

local function ls_files_args(repo_root, options, prefix)
  local args = { '-C', repo_root, 'ls-files' }
  vim.list_extend(args, options)
  vim.list_extend(args, { '--full-name' })
  if prefix and prefix ~= '' then
    vim.list_extend(args, { '--', ':(literal)' .. prefix:gsub('/+$', '') })
  end
  return args
end

local function read_ignore_state(repo_root, prefix)
  local tracked_output, tracked_err = command(ls_files_args(repo_root,
    { '--cached', '-z' }, prefix))
  if not tracked_output then return nil, tracked_err end
  local ignored_output, ignored_err = command(ls_files_args(repo_root,
    { '--others', '--ignored', '--exclude-standard', '--directory', '-z' }, prefix))
  if not ignored_output then return nil, ignored_err end

  local tracked, tracked_exact = {}, path_set(tracked_output)
  for relative in pairs(tracked_exact) do add_tracked_path(tracked, relative) end
  return { tracked = tracked, tracked_exact = tracked_exact, ignored = path_set(ignored_output) }
end

local function nested_repo_roots(repo_root, scope_path)
  local roots, pending = {}, { scope_path or repo_root }
  while #pending > 0 do
    local dir = table.remove(pending)
    if dir ~= repo_root and vim.uv.fs_lstat(vim.fs.joinpath(dir, '.git')) then
      roots[#roots + 1] = normalize(dir)
    else
      local scan, scan_err = vim.uv.fs_scandir(dir)
      if not scan then return nil, scan_err or ('cannot scan ' .. dir) end
      while true do
        local name, kind = vim.uv.fs_scandir_next(scan)
        if name == nil then break end
        if kind == 'directory' and name ~= '.git' then
          pending[#pending + 1] = vim.fs.joinpath(dir, name)
        end
      end
    end
  end
  table.sort(roots)
  return roots
end

local function capture_repo_snapshot(repo_root, scope_path, prefix, seen)
  if seen[repo_root] then
    return nil, 'nested Git repository cycle detected'
  end
  scope_path = normalize(scope_path or repo_root)
  seen[repo_root] = true
  local state, state_err = read_ignore_state(repo_root, prefix)
  if not state then return nil, state_err end
  local snapshot = {
    root = repo_root,
    scope_path = normalize(scope_path or repo_root),
    repo_prefix = prefix or '',
    tracked = state.tracked,
    tracked_exact = state.tracked_exact,
    ignored = state.ignored,
    nested = {},
  }

  local roots, roots_err = nested_repo_roots(repo_root, scope_path)
  if not roots then return nil, roots_err end
  for _, nested_root in ipairs(roots) do
    local nested_prefix, prefix_err = command({ '-C', nested_root,
      'rev-parse', '--show-prefix' })
    if not nested_prefix then return nil, prefix_err end
    nested_prefix = nested_prefix:gsub('[\r\n]+$', ''):gsub('/+$', '')
    if nested_prefix ~= '' then nested_prefix = nested_prefix .. '/' end
    local nested, nested_err = capture_repo_snapshot(nested_root, nested_root,
      nested_prefix, seen)
    if not nested then return nil, nested_err end
    snapshot.nested[nested_root] = nested
  end
  seen[repo_root] = nil
  return snapshot
end

-- ignore_snapshot(path) returns nil,nil outside a repository; an error is
-- distinct from that case so an enabled filter never silently guesses. The
-- snapshot records Git's effective ignored and tracked path decisions instead
-- of hashing every ignore source in the worktree.
function M.ignore_snapshot(path)
  local repo_root, repo_err = discover_repo(path)
  if repo_root == false then return nil end
  if not repo_root then return nil, repo_err end
  local prefix, prefix_err = command({ '-C', path, 'rev-parse', '--show-prefix' })
  if not prefix then return nil, prefix_err end
  prefix = prefix:gsub('[\r\n]+$', ''):gsub('/+$', '')
  if prefix ~= '' then prefix = prefix .. '/' end
  return capture_repo_snapshot(repo_root, path, prefix, {})
end

function M.record_ignore_candidates(snapshot, scope_path, names)
  if not snapshot then return end
  local scope = normalize(scope_path):gsub('/+$', '') .. '/'
  local candidates = {}
  for _, name in ipairs(names or {}) do
    local path = normalize(vim.fs.joinpath(scope_path, name))
    if path:sub(1, #scope) == scope then
      candidates[(snapshot.repo_prefix or '') .. path:sub(#scope + 1)] = true
    end
  end
  snapshot.candidates = candidates
end

-- A live ignore context is sufficient for a one-off descendant scan. It avoids
-- building a second list-time snapshot when the scan encounters a nested repo.
function M.ignore_context(path)
  local repo_root, repo_err = discover_repo(path)
  if repo_root == false then return nil end
  if not repo_root then return nil, repo_err end
  local prefix, prefix_err = command({ '-C', path, 'rev-parse', '--show-prefix' })
  if not prefix then return nil, prefix_err end
  prefix = prefix:gsub('[\r\n]+$', ''):gsub('/+$', '')
  if prefix ~= '' then prefix = prefix .. '/' end
  return {
    root = repo_root,
    scope_path = normalize(path),
    repo_prefix = prefix,
  }
end

local function in_scope(path, prefix)
  if prefix == '' then return true end
  prefix = prefix:gsub('/+$', '')
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. '/'
end

local function same_scoped_paths(previous, current, prefix)
  for path in pairs(previous or {}) do
    if in_scope(path, prefix) and not current[path] then return false end
  end
  for path in pairs(current or {}) do
    if in_scope(path, prefix) and not previous[path] then return false end
  end
  return true
end

local function current_repo_state(repo_root, prefix, scope_path, checked)
  local key = repo_root .. '\0' .. (prefix or '')
  local current = checked[key]
  if current then return current end
  local state, err = read_ignore_state(repo_root, prefix)
  if not state then return nil, err end
  local roots, roots_err = nested_repo_roots(repo_root, scope_path)
  if not roots then return nil, roots_err end
  state.nested_roots = roots
  checked[key] = state
  return state
end

local function matches_snapshot(snapshot, checked)
  local prefix = snapshot.repo_prefix or ''
  local current, err = current_repo_state(snapshot.root, prefix,
    snapshot.scope_path, checked)
  if not current then return nil, err end
  local ignored_changed = false
  if snapshot.candidates then
    for path in pairs(snapshot.candidates) do
      if (snapshot.ignored[path] == true) ~= (current.ignored[path] == true) then
        ignored_changed = true
        break
      end
    end
  else
    ignored_changed = not same_scoped_paths(snapshot.ignored, current.ignored, prefix)
  end
  if not same_scoped_paths(snapshot.tracked_exact, current.tracked_exact, prefix)
    or ignored_changed then
    return false, 'Git ignore rules changed or tracked paths changed; re-list this directory'
  end

  local previous_roots = {}
  for root in pairs(snapshot.nested or {}) do previous_roots[root] = true end
  local current_roots = {}
  for _, root in ipairs(current.nested_roots or {}) do current_roots[root] = true end
  for root in pairs(previous_roots) do
    if not current_roots[root] then
      return false, 'Git repository context changed; re-list this directory'
    end
  end
  for root in pairs(current_roots) do
    if not previous_roots[root] then
      return false, 'Git repository context changed; re-list this directory'
    end
  end
  for root, nested_snapshot in pairs(snapshot.nested or {}) do
    local matches, nested_err = matches_snapshot(nested_snapshot, checked)
    if matches ~= true then return matches, nested_err end
  end
  return true
end

function M.ignore_snapshot_matches(snapshot, path, checked)
  -- A missing snapshot is meaningful when filtering was enabled: it records
  -- that the listed directory was not in a repository. Re-discover from that
  -- directory so a newly-created (or newly-removed) repository is detected.
  path = path or (snapshot and snapshot.scope_path)
  if not path then return nil, 'Git ignore snapshot path is unavailable' end
  -- Expanded directories can be moved or removed by a successful sync while
  -- retaining their original list-time snapshot. If they were outside Git,
  -- the now-missing path cannot have gained repository context; accept it.
  -- A Git-backed snapshot still requires a live path so repository changes fail
  -- closed as usual.
  if not snapshot then
    local stat, stat_err = vim.uv.fs_stat(path)
    if not stat and stat_err and (stat_err:find('ENOENT', 1, true)
      or stat_err:find('ENOTDIR', 1, true)) then
      return true
    end
  end
  local repo_root, discover_err = discover_repo(path)
  if repo_root == false then
    if snapshot then
      return false, 'Git repository context changed; re-list this directory'
    end
    return true
  end
  if not repo_root then return nil, discover_err end
  if not snapshot then
    return false, 'Git repository context changed; re-list this directory'
  end
  if repo_root ~= snapshot.root then
    return false, 'Git repository context changed; re-list this directory'
  end
  checked = checked or {}
  return matches_snapshot(snapshot, checked)
end

local function inventory_for(snapshot, cache)
  if cache then
    local prefix = snapshot.repo_prefix or ''
    local key = snapshot.root .. '\0' .. prefix
    local state = cache[key]
    if state then return state.ignored, state.tracked end
    local output, err = command(ls_files_args(snapshot.root,
      { '--others', '--ignored', '--exclude-standard', '--directory', '-z' }, prefix))
    if not output then return nil, nil, err end
    state = { ignored = path_set(output) }
    cache[key] = state
    return state.ignored
  end
  return snapshot.ignored or {}, snapshot.tracked or {}
end

-- ignored_paths(snapshot, absolute_paths[, cache]) matches candidates against
-- Git's native ignored-path inventory. A supplied cache is fresh and shared by
-- a live descendant walk; otherwise the list-time inventory is used.
function M.ignored_paths(snapshot, paths, cache)
  if not snapshot or #paths == 0 then return {} end
  local ignored, tracked, err = inventory_for(snapshot, cache)
  if not ignored then return nil, err end
  local scope_path = normalize(snapshot.scope_path or snapshot.root)
  local prefix = scope_path:gsub('/+$', '') .. '/'
  local result = {}
  for _, path in ipairs(paths) do
    local normalized = normalize(path)
    if normalized:sub(1, #prefix) == prefix then
      local relative = (snapshot.repo_prefix or '') .. normalized:sub(#prefix + 1)
      if ignored[relative] and not (tracked and tracked[relative]) then
        result[#result + 1] = normalized
      end
    end
  end
  return result
end

function M.status_for(snapshot, path)
  if not snapshot or type(path) ~= 'string' then return nil end
  local key = normalize(path)
  return snapshot.paths[key], snapshot.conflicts and snapshot.conflicts[key] == true or false
end

-- first_status_for returns the category used by the leftmost status symbol:
-- porcelain's index (X) column when set, otherwise its worktree (Y) column.
function M.first_status_for(snapshot, path)
  local status = M.status_for(snapshot, path)
  if not status then return nil end
  if status == '!!' then return 'ignored' end
  local code = status:sub(1, 1)
  if code == ' ' then code = status:sub(2, 2) end
  if code == ' ' then return nil end
  if code == 'A' or code == 'C' then return 'added' end
  if code == 'M' or code == 'T' or code == 'U' then return 'modified' end
  if code == 'D' then return 'deleted' end
  if code == 'R' then return 'renamed' end
  return nil
end

return M
