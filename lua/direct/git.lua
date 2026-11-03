-- lua/direct/git.lua -- Git status and native Git-ignore snapshots.

local M = {}

local status_priority = {
  M = 1,
  D = 2,
  A = 3,
  R = 4,
  C = 4,
  U = 5,
}

local function normalize(path)
  local value = vim.fs.normalize(path)
  if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
    value = value:gsub('\\', '/')
  end
  if value:match('^%a:/$') then return value end
  value = value:gsub('/+$', '')
  return value == '' and '/' or value
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

local function add_path(paths, path, status)
  local key = normalize(path)
  paths[key] = merge_status(paths[key], status)
end

local function add_with_parent_directories(paths, root, relative, status)
  local path = normalize(root .. '/' .. relative)
  add_path(paths, path, status)
  local parent = path:match('^(.*)/[^/]+$')
  while parent do
    add_path(paths, parent, status)
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
    '--untracked-files=all' })
  if not output then return nil end

  local fields = nul_fields(output)
  local paths, deleted = {}, {}
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
        add_with_parent_directories(paths, repo_root, relative, status)
        if xy:find('D', 1, true) then
          add_deleted(deleted, repo_root, relative)
        end
      end
    end
  end
  return { root = repo_root, paths = paths, deleted = deleted }
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
        if entry.kind == 'directory' then name = name .. '/' end
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

local function absolute(root, path)
  if path:sub(1, 1) == '/' or path:match('^%a:[/\\]') then
    return normalize(path)
  end
  return normalize(vim.fs.joinpath(root, path))
end

local function read_file(path)
  local file = io.open(path, 'rb')
  if not file then return nil, 'cannot read Git ignore source: ' .. path end
  local contents, err = file:read('*a')
  file:close()
  if contents == nil then return nil, err end
  return contents
end

local function read_optional_file(path)
  local contents, err = read_file(path)
  if contents ~= nil then return contents, nil, false end
  local _, stat_err = vim.uv.fs_stat(path)
  if stat_err and (stat_err:find('ENOENT', 1, true)
    or stat_err:find('ENOTDIR', 1, true)) then
    return nil, nil, true
  end
  return nil, err
end

local function optional_file_fingerprint(path)
  local contents, err, missing = read_optional_file(path)
  if contents == nil and not missing then return nil, err end
  if missing then return 'missing\0' end
  return 'present\0' .. contents .. '\0'
end

local function default_global_excludes()
  local config_home = vim.env.XDG_CONFIG_HOME
  if type(config_home) ~= 'string' or config_home == '' then
    local home = vim.env.HOME
    if type(home) ~= 'string' or home == '' then home = vim.fn.expand('~') end
    if type(home) ~= 'string' or home == '' or home == '~' then
      return nil, 'Git default global excludes path cannot be determined'
    end
    config_home = vim.fs.joinpath(home, '.config')
  end
  return vim.fs.joinpath(config_home, 'git', 'ignore')
end

local function effective_global_excludes(repo_root, configured_path)
  local configured = vim.trim(configured_path or '')
  if configured == '' then return default_global_excludes() end
  if configured:sub(1, 1) ~= '/' and not configured:match('^%a:[/\\]') then
    configured = vim.fs.joinpath(repo_root, configured)
  end
  return vim.fs.normalize(configured)
end

-- Fingerprint every .gitignore below the worktree plus Git's per-repository
-- exclude file, configured global excludes file, and the effective core ignore
-- configuration. Including nested repositories' files is conservative: a
-- change may cause an unnecessary re-list, but can never weaken sync safety.
local function ignore_fingerprint(repo_root)
  local config, config_err, config_code = command({ '-C', repo_root, 'config',
    '--show-origin', '--get-regexp', '^core\\.' })
  if not config and config_code ~= 1 then return nil, config_err end
  local global_path, global_err, global_code = command({ '-C', repo_root,
    'config', '--path', '--get', 'core.excludesFile' })
  if not global_path and global_code ~= 1 then return nil, global_err end
  local exclude_path, exclude_err = command({ '-C', repo_root, 'rev-parse',
    '--git-path', 'info/exclude' })
  if not exclude_path then return nil, exclude_err end
  exclude_path = absolute(repo_root, exclude_path:gsub('[\r\n]+$', ''))
  local files, nested_repos, pending = {}, {}, { repo_root }
  while #pending > 0 do
    local dir = table.remove(pending)
    local scan, scan_err = vim.uv.fs_scandir(dir)
    if not scan then return nil, scan_err or ('cannot scan ' .. dir) end
    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if name == nil then break end
      local path = vim.fs.joinpath(dir, name)
      if kind == 'directory' and name ~= '.git' then
        pending[#pending + 1] = path
      elseif name == '.git' then
        if dir ~= repo_root then nested_repos[#nested_repos + 1] = dir end
      elseif name == '.gitignore' then
        files[#files + 1] = path
      end
    end
  end
  table.sort(files)
  local parts = { config or '', '\0' }
  local effective_global, effective_err = effective_global_excludes(repo_root, global_path)
  if not effective_global then return nil, effective_err end
  local sources = { exclude_path, effective_global }
  table.sort(sources)
  for _, path in ipairs(sources) do
    local fingerprint, err = optional_file_fingerprint(path)
    if not fingerprint then return nil, err end
    parts[#parts + 1] = path .. '\0' .. fingerprint
  end
  for _, path in ipairs(files) do
    local contents, err = read_file(path)
    if not contents then return nil, err end
    parts[#parts + 1] = path .. '\0' .. contents .. '\0'
  end
  table.sort(nested_repos)
  for _, nested_root in ipairs(nested_repos) do
    local nested_config, nested_config_err, nested_config_code = command({ '-C', nested_root,
      'config', '--show-origin', '--get-regexp', '^core\\.' })
    if not nested_config and nested_config_code ~= 1 then return nil, nested_config_err end
    local nested_global, nested_global_err, nested_global_code = command({ '-C', nested_root,
      'config', '--path', '--get', 'core.excludesFile' })
    if not nested_global and nested_global_code ~= 1 then return nil, nested_global_err end
    local nested_effective_global, nested_global_path_err = effective_global_excludes(
      nested_root, nested_global)
    if not nested_effective_global then return nil, nested_global_path_err end
    local nested_exclude, nested_exclude_err = command({ '-C', nested_root,
      'rev-parse', '--git-path', 'info/exclude' })
    if not nested_exclude then return nil, nested_exclude_err end
    nested_exclude = absolute(nested_root, nested_exclude:gsub('[\r\n]+$', ''))
    local exclude_fingerprint, read_err = optional_file_fingerprint(nested_exclude)
    if not exclude_fingerprint then return nil, read_err end
    local nested_tracked, nested_tracked_err = command({ '-C', nested_root,
      'ls-files', '--cached', '-z' })
    if not nested_tracked then return nil, nested_tracked_err end
    parts[#parts + 1] = nested_root .. '\0' .. (nested_config or '') .. '\0'
      .. nested_exclude .. '\0' .. exclude_fingerprint
      .. 'tracked\0' .. nested_tracked .. '\0'
    local global_fingerprint, global_read_err = optional_file_fingerprint(nested_effective_global)
    if not global_fingerprint then return nil, global_read_err end
    parts[#parts + 1] = nested_effective_global .. '\0' .. global_fingerprint
  end
  return vim.fn.sha256(table.concat(parts))
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

-- ignore_snapshot(path) returns nil,nil outside a repository; an error is
-- distinct from that case so an enabled filter never silently guesses.
function M.ignore_snapshot(path)
  local repo_root, repo_err = discover_repo(path)
  if repo_root == false then return nil end
  if not repo_root then return nil, repo_err end
  local fingerprint, fingerprint_err = ignore_fingerprint(repo_root)
  if not fingerprint then return nil, fingerprint_err end
  local tracked_output, tracked_err = command({ '-C', repo_root, 'ls-files',
    '--cached', '-z' })
  if not tracked_output then return nil, tracked_err end
  -- Index membership affects whether an ignored path is still visible. Include
  -- the exact cached path list in the snapshot identity so a later force-add
  -- cannot turn a list-time hidden path into a deletion source.
  fingerprint = vim.fn.sha256(fingerprint .. '\0' .. tracked_output)
  local tracked = {}
  for _, relative in ipairs(nul_fields(tracked_output)) do
    tracked[relative] = true
    local parent = relative:match('^(.*)/[^/]+$')
    while parent do
      tracked[parent] = true
      parent = parent:match('^(.*)/[^/]+$')
    end
  end
  local prefix, prefix_err = command({ '-C', path, 'rev-parse', '--show-prefix' })
  if not prefix then return nil, prefix_err end
  prefix = prefix:gsub('[\r\n]+$', ''):gsub('/+$', '')
  if prefix ~= '' then prefix = prefix .. '/' end
  return {
    root = repo_root,
    fingerprint = fingerprint,
    tracked = tracked,
    scope_path = normalize(path),
    repo_prefix = prefix,
  }
end

function M.ignore_snapshot_matches(snapshot, path, checked)
  -- A missing snapshot is meaningful when filtering was enabled: it records
  -- that the listed directory was not in a repository. Re-discover from that
  -- directory so a newly-created (or newly-removed) repository is detected.
  path = path or (snapshot and snapshot.root)
  if not path then return nil, 'Git ignore snapshot path is unavailable' end
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
  local current = checked[repo_root]
  local err
  if not current then
    current, err = M.ignore_snapshot(repo_root)
    if not current then return nil, err or 'Git repository is no longer available' end
    checked[repo_root] = current
  end
  if current.root ~= snapshot.root or current.fingerprint ~= snapshot.fingerprint then
    return false, 'Git ignore rules changed or tracked paths changed; re-list this directory'
  end
  return true
end

-- ignored_paths(snapshot, absolute_paths) delegates all pattern semantics to
-- git check-ignore. Tracked paths are not returned by check-ignore (no
-- --no-index); tracked directory ancestors are also explicitly retained.
function M.ignored_paths(snapshot, paths)
  if not snapshot or #paths == 0 then return {} end
  local relative, rel_to_absolute = {}, {}
  local scope_path = normalize(snapshot.scope_path or snapshot.root)
  local prefix = scope_path:gsub('/+$', '') .. '/'
  for _, path in ipairs(paths) do
    local normalized = normalize(path)
    if normalized:sub(1, #prefix) == prefix then
      local name = (snapshot.repo_prefix or '') .. normalized:sub(#prefix + 1)
      relative[#relative + 1] = name
      rel_to_absolute[name] = normalized
    end
  end
  if #relative == 0 then return {} end
  local output, err, code, stderr = command({ '-C', snapshot.root, 'check-ignore', '-z',
    '--stdin' }, table.concat(relative, '\0') .. '\0')
  if not output and (code ~= 1 or (stderr ~= nil and stderr ~= '')) then
    return nil, err
  end
  local ignored = {}
  for _, field in ipairs(nul_fields(output or '')) do
    ignored[field] = true
  end
  local result = {}
  for relative_name, path in pairs(rel_to_absolute) do
    if ignored[relative_name] and not snapshot.tracked[relative_name] then
      result[#result + 1] = path
    end
  end
  return result
end

function M.status_for(snapshot, path)
  if not snapshot or type(path) ~= 'string' then return nil end
  return snapshot.paths[normalize(path)]
end

return M
