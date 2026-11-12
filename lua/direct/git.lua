-- lua/direct/git.lua -- Git status and native Git-ignore snapshots.

local M = {}
local paths = require('direct.paths')
local ignore_snapshot_cache = {}
local ignore_snapshot_cache_order = {}
local ignore_snapshot_cache_limit = 8
local ignore_timeout_warnings = {}

local status_priority = {
  ['!'] = -1,
  M = 1,
  D = 2,
  A = 3,
  R = 4,
  C = 4,
  U = 5,
}

local function normalize(path) return paths.canonical(path) end

local function start(args, stdin)
  local ok, process = pcall(vim.system, args, { text = false, stdin = stdin })
  if not ok then return nil, tostring(process), -1 end
  return process
end

local function finish(process, timeout_ms)
  local ok, result = pcall(function() return process:wait(timeout_ms) end)
  if not ok then return nil, tostring(result), -1 end
  if timeout_ms and result.code == 124 then return nil, 'git command timed out after ' .. timeout_ms .. ' ms', 124 end
  if result.code ~= 0 then
    local stderr = result.stderr and result.stderr:gsub('%s+$', '') or ''
    return nil, stderr ~= '' and stderr or 'git command failed', result.code, stderr
  end
  return result.stdout or '', nil, result.code
end

local function run(args, stdin, timeout_ms)
  local process, err, code = start(args, stdin)
  if not process then return nil, err, code end
  return finish(process, timeout_ms)
end

-- Start every independent command before waiting for any one of them. Waiting
-- remains synchronous for callers, but the child processes overlap instead of
-- paying their startup and scan times serially.
local function run_parallel(commands, timeout_ms)
  local processes, start_errors = {}, {}
  for index, spec in ipairs(commands) do
    local process, err, code = start(spec.args, spec.stdin)
    processes[index] = process
    if not process then start_errors[index] = { err, code } end
  end

  local outputs, errors = {}, start_errors
  for index, process in ipairs(processes) do
    if process then
      local output, err, code, stderr = finish(process, timeout_ms)
      if output then
        outputs[index] = output
      elseif not errors[index] then
        errors[index] = { err, code, stderr }
      end
    end
  end

  for index = 1, #commands do
    local failure = errors[index]
    if failure then return nil, failure[1], failure[2], failure[3] end
  end
  return outputs
end

local function command(args, stdin, timeout_ms) return run(vim.list_extend({ 'git' }, args), stdin, timeout_ms) end

local function commands_parallel(args_list, timeout_ms)
  local commands = {}
  for index, args in ipairs(args_list) do
    commands[index] = { args = vim.list_extend({ 'git' }, args) }
  end
  return run_parallel(commands, timeout_ms)
end

-- Returns false when path is outside Git, or the repository root when it is.
-- Repository-scoped commands must not run until this check succeeds.
local function discover_repo(path, timeout_ms)
  if vim.fn.executable('git') ~= 1 then return nil, 'Git executable is unavailable' end
  local output, err = command({ '-C', path, 'rev-parse', '--show-toplevel' }, nil, timeout_ms)
  if not output then
    local lower = tostring(err):lower()
    if lower:find('not a git repository', 1, true) or lower:find('must be run in a work tree', 1, true) then
      return false
    end
    return nil, err
  end
  return normalize(output:gsub('[\r\n]+$', ''))
end

local function nul_fields(output)
  local fields, field_start = {}, 1
  while field_start <= #output do
    local stop = output:find('\0', field_start, true)
    if not stop then break end
    fields[#fields + 1] = output:sub(field_start, stop - 1)
    field_start = stop + 1
  end
  return fields
end

local function trimmed_output(output) return (output or ''):gsub('[\r\n]+$', '') end

local function default_compare_ref(repo_root)
  local remote_head = command({ '-C', repo_root, 'symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD' })
  local remote_ref = remote_head and trimmed_output(remote_head) or nil
  if remote_ref and remote_ref ~= '' then
    local _, _, code = command({
      '-C',
      repo_root,
      'rev-parse',
      '--verify',
      '--quiet',
      '--end-of-options',
      remote_ref .. '^{commit}',
    })
    if code == 0 then return remote_ref end
  end

  for _, branch in ipairs({ 'main', 'master' }) do
    local _, _, code = command({ '-C', repo_root, 'show-ref', '--verify', '--quiet', 'refs/heads/' .. branch })
    if code == 0 then return branch end
  end
  return nil, 'cannot determine the default branch (origin/HEAD, main, or master)'
end

local function resolve_commit(repo_root, ref)
  local output, err = command({ '-C', repo_root, 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' })
  if not output then return nil, err end
  return trimmed_output(output)
end

-- compare_snapshot(root[, ref]) returns the committed paths changed between
-- the target ref's merge base with HEAD and HEAD. Working-tree/index changes
-- are deliberately excluded, matching a pull-request file list.
function M.compare_snapshot(root, ref, options)
  if type(root) ~= 'string' or root == '' then return nil, 'repository path is required' end
  if vim.fn.executable('git') ~= 1 then return nil, 'Git executable is unavailable' end
  if options ~= nil and type(options) ~= 'table' then return nil, 'Git diff options must be a table' end
  options = options or {}
  local include_uncommitted = options.include_uncommitted == true
  if ref ~= nil and (type(ref) ~= 'string' or ref:find('\0', 1, true)) then
    return nil, 'Git ref must be a non-empty string'
  end

  local repo_output, repo_err = command({ '-C', root, 'rev-parse', '--show-toplevel' })
  if not repo_output then return nil, repo_err end
  local repo_root = normalize(trimmed_output(repo_output))

  if ref == nil or vim.trim(ref) == '' then
    local default_ref, default_err = default_compare_ref(repo_root)
    if not default_ref then return nil, default_err end
    ref = default_ref
  end
  local target, target_err = resolve_commit(repo_root, ref)
  if not target then return nil, 'cannot resolve Git ref ' .. ref .. ': ' .. tostring(target_err) end
  local head, head_err = resolve_commit(repo_root, 'HEAD')
  if not head then return nil, 'cannot resolve HEAD: ' .. tostring(head_err) end

  local base_output, base_err = command({ '-C', repo_root, 'merge-base', target, head })
  if not base_output then return nil, 'Git ref ' .. ref .. ' has no merge base with HEAD: ' .. tostring(base_err) end
  local base = trimmed_output(base_output)
  local output, diff_err =
    command({ '-C', repo_root, 'diff', '--no-ext-diff', '--name-status', '-z', '-M', base, head, '--' })
  if not output then return nil, 'cannot diff against ' .. ref .. ': ' .. tostring(diff_err) end

  local fields, entries, index = nul_fields(output), {}, 1
  while index <= #fields do
    local status = fields[index]
    index = index + 1
    local code = status:sub(1, 1)
    local old_path, relative
    if code == 'R' or code == 'C' then
      old_path, relative = fields[index], fields[index + 1]
      index = index + 2
    else
      relative = fields[index]
      index = index + 1
    end
    if relative and relative ~= '' then
      entries[#entries + 1] = {
        path = relative,
        old_path = old_path,
        status = code,
      }
    end
  end

  local uncommitted_deleted = {}
  if include_uncommitted then
    local status_output, status_err =
      command({ '--no-optional-locks', '-C', repo_root, 'status', '--porcelain=v1', '-z', '--untracked-files=all' })
    if not status_output then return nil, 'cannot read uncommitted Git changes: ' .. tostring(status_err) end
    local committed_paths = {}
    for _, entry in ipairs(entries) do
      committed_paths[entry.path] = true
    end
    local function add_uncommitted_deleted(relative)
      local path = normalize(vim.fs.joinpath(repo_root, relative))
      uncommitted_deleted[path] = { kind = 'file' }
      local parent = path:match('^(.*)/[^/]+$')
      while parent do
        uncommitted_deleted[parent] = { kind = 'directory' }
        if parent == repo_root or parent == '/' then break end
        parent = parent:match('^(.*)/[^/]+$')
      end
    end
    local status_fields, status_index = nul_fields(status_output), 1
    while status_index <= #status_fields do
      local record = status_fields[status_index]
      status_index = status_index + 1
      if #record >= 4 then
        local xy, relative = record:sub(1, 2), record:sub(4)
        local old_path
        local code
        if xy == '??' then
          code = 'A'
        elseif xy:find('R', 1, true) then
          code = 'R'
          old_path = status_fields[status_index]
          status_index = status_index + 1
        elseif xy:find('C', 1, true) then
          code = 'C'
          old_path = status_fields[status_index]
          status_index = status_index + 1
        elseif xy:find('A', 1, true) then
          code = 'A'
        elseif xy:find('D', 1, true) then
          code = 'D'
        elseif xy:find('T', 1, true) then
          code = 'T'
        elseif xy:find('M', 1, true) then
          code = 'M'
        elseif xy:find('U', 1, true) then
          code = 'U'
        end
        if code and relative ~= '' then
          if not committed_paths[relative] then
            entries[#entries + 1] = {
              path = relative,
              old_path = old_path,
              status = code,
              uncommitted = true,
            }
            committed_paths[relative] = true
          end
          if code == 'D' then add_uncommitted_deleted(relative) end
          if code == 'R' and old_path then add_uncommitted_deleted(old_path) end
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.path == b.path then return a.status < b.status end
    return a.path < b.path
  end)
  local diff_paths, deleted = {}, {}
  local function add_diff_path(path, status)
    path = normalize(path)
    local previous = diff_paths[path]
    if previous and previous ~= status then
      diff_paths[path] = 'M'
    else
      diff_paths[path] = status
    end
  end
  for _, entry in ipairs(entries) do
    local path = normalize(vim.fs.joinpath(repo_root, entry.path))
    add_diff_path(path, entry.status)
    if entry.status == 'D' then deleted[path] = { kind = 'file' } end
    local parent = path:match('^(.*)/[^/]+$')
    while parent do
      add_diff_path(parent, entry.status)
      if entry.status == 'D' then deleted[parent] = { kind = 'directory' } end
      if parent == repo_root or parent == '/' then break end
      parent = parent:match('^(.*)/[^/]+$')
    end
  end
  for path, entry in pairs(uncommitted_deleted) do
    deleted[path] = entry
  end
  return {
    root = repo_root,
    ref = ref,
    target = target,
    base = base,
    head = head,
    entries = entries,
    paths = diff_paths,
    deleted = deleted,
    force_deleted = true,
    include_uncommitted = include_uncommitted,
  }
end

local function normalize_status(xy)
  if xy == '??' then return ' A' end
  return (xy:gsub('T', 'M'))
end

local function status_priority_for(code) return status_priority[code] or 0 end

local function is_unmerged(xy) return xy:find('U', 1, true) ~= nil or xy == 'AA' or xy == 'DD' end

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
  local function add(candidate, kind)
    if not path_is_missing(candidate) then return end
    if not deleted[candidate] then deleted[candidate] = { kind = kind } end
  end

  add(path, 'file')
  local parent = path:match('^(.*)/[^/]+$')
  while parent do
    add(parent, 'directory')
    if parent == root or parent == '/' then break end
    parent = parent:match('^(.*)/[^/]+$')
  end
end

local function add_path(path_statuses, conflicts, path, status, conflicted)
  local key = normalize(path)
  path_statuses[key] = merge_status(path_statuses[key], status)
  if conflicted then conflicts[key] = true end
end

local function add_with_parent_directories(path_statuses, conflicts, root, relative, status, conflicted)
  local path = normalize(root .. '/' .. relative)
  add_path(path_statuses, conflicts, path, status, conflicted)
  local parent = path:match('^(.*)/[^/]+$')
  while parent do
    add_path(path_statuses, conflicts, parent, status, conflicted)
    if parent == root or parent == '/' then break end
    parent = parent:match('^(.*)/[^/]+$')
  end
end

local function parse_status(repo_root, output, include_ignored)
  local fields = nul_fields(output)
  local statuses, conflicts, deleted = {}, {}, {}
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
        if xy:find('R', 1, true) or xy:find('C', 1, true) then index = index + 1 end
        if include_ignored or status ~= '!!' then
          add_with_parent_directories(statuses, conflicts, repo_root, relative, status, is_unmerged(xy))
        end
        if xy:find('D', 1, true) then add_deleted(deleted, repo_root, relative) end
      end
    end
  end
  return { root = repo_root, paths = statuses, conflicts = conflicts, deleted = deleted }
end

-- read(root) -> { root = repository root, paths = absolute path -> porcelain XY }
-- or nil when Git is unavailable / root is not in a repository. One status
-- query covers the repository; directory status is aggregated from descendants.
function M.read(root)
  if type(root) ~= 'string' or root == '' then return nil end
  local repo_root = discover_repo(root)
  if not repo_root or repo_root == false then return nil end
  local output =
    run({ 'git', '-C', repo_root, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignored=matching' })
  if not output then return nil end

  return parse_status(repo_root, output, true)
end

-- read_async(root, timeout_ms, callback) starts Git in the background. The
-- callback receives snapshot, error, timed_out; snapshot is false outside a
-- repository or when Git fails. The timeout covers discovery and status.
function M.read_async(root, timeout_ms, callback)
  if type(callback) ~= 'function' then return nil, 'callback is required' end
  if type(root) ~= 'string' or root == '' then
    callback(false, 'invalid Git root', false)
    return nil
  end
  timeout_ms = tonumber(timeout_ms) or 1000
  timeout_ms = math.max(1, math.floor(timeout_ms))

  local finished, process, timer = false, nil, nil
  local function complete_read(snapshot, err, timed_out)
    if finished then return end
    finished = true
    if timer then
      timer:stop()
      if not timer:is_closing() then timer:close() end
      timer = nil
    end
    callback(snapshot, err, timed_out == true)
  end

  local function cancel()
    if finished then return false end
    finished = true
    if timer then
      timer:stop()
      if not timer:is_closing() then timer:close() end
      timer = nil
    end
    local running = process
    if running then pcall(running.kill, running, 15) end
    return true
  end

  timer = vim.uv.new_timer()
  timer:start(timeout_ms, 0, function()
    vim.schedule(function()
      if finished then return end
      local running = process
      if running then pcall(running.kill, running, 15) end
      complete_read(false, 'Git status timed out after ' .. timeout_ms .. ' ms', true)
    end)
  end)

  local function spawn(args, on_result)
    local ok, child = pcall(vim.system, args, { text = false }, function(result)
      vim.schedule(function()
        if finished then return end
        on_result(result)
      end)
    end)
    if not ok or not child then
      complete_read(false, tostring(child or 'could not start Git'), false)
      return false
    end
    process = child
    return true
  end

  spawn({ 'git', '-C', root, 'rev-parse', '--show-toplevel' }, function(result)
    if result.code ~= 0 then
      local err = result.stderr and result.stderr:gsub('%s+$', '') or 'git command failed'
      local lower = err:lower()
      if lower:find('not a git repository', 1, true) or lower:find('must be run in a work tree', 1, true) then
        complete_read(false, nil, false)
      else
        complete_read(false, err, false)
      end
      return
    end
    local repo_root = normalize((result.stdout or ''):gsub('[\r\n]+$', ''))
    process = nil
    spawn({
      'git',
      '--no-optional-locks',
      '-C',
      repo_root,
      'status',
      '--porcelain=v1',
      '-z',
      '--untracked-files=all',
      '--ignored=matching',
    }, function(status_result)
      if status_result.code ~= 0 then
        local err = status_result.stderr and status_result.stderr:gsub('%s+$', '') or 'git status failed'
        complete_read(false, err, false)
        return
      end
      complete_read(parse_status(repo_root, status_result.stdout or '', true), nil, false)
    end)
  end)
  return cancel
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
    if path:sub(1, #prefix) == prefix and (snapshot.force_deleted == true or path_is_missing(path)) then
      local name = path:sub(#prefix + 1)
      if name ~= '' and not name:find('/', 1, true) then
        if entry.kind == 'directory' then name = name .. require('direct.paths').directory_separator() end
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

-- worktree_changes(root, path, directory) -> the absolute tracked paths whose
-- unstaged worktree changes a restore would discard. Untracked files are not
-- included because `git restore --worktree` does not remove them.
function M.worktree_changes(root, path, directory)
  local repo_root, repo_err = discover_repo(root)
  if repo_root == false then return nil, 'path is not in a Git repository' end
  if not repo_root then return nil, repo_err end
  local output, status_err = command({ '-C', repo_root, 'status', '--porcelain=v1', '-z', '--untracked-files=all' })
  if not output then return nil, status_err end

  path = normalize(path)
  local prefix = path == '/' and '/' or (path .. '/')
  local function covers(candidate) return candidate == path or (directory and candidate:sub(1, #prefix) == prefix) end

  local fields, changes, seen = nul_fields(output), {}, {}
  local index = 1
  while index <= #fields do
    local record = fields[index]
    index = index + 1
    if #record >= 4 then
      local xy, relative = record:sub(1, 2), record:sub(4)
      if xy:find('R', 1, true) or xy:find('C', 1, true) then index = index + 1 end
      -- Column two is the worktree state. `??` is untracked, not a change that
      -- restore --worktree can discard; staged-only changes have a blank second
      -- column and likewise remain untouched.
      if xy ~= '??' and xy:sub(2, 2) ~= ' ' and relative ~= '' then
        local absolute = normalize(vim.fs.joinpath(repo_root, relative))
        if covers(absolute) and not seen[absolute] then
          seen[absolute] = true
          changes[#changes + 1] = absolute
        end
      end
    end
  end
  table.sort(changes)
  return changes
end

function M.worktree_restore_command(root)
  local repo_root, repo_err = discover_repo(root)
  if repo_root == false then return nil, 'path is not in a Git repository' end
  if not repo_root then return nil, repo_err end
  local version = run({ 'git', '-C', root, '--version' })
  local major, minor
  if type(version) == 'string' then
    major, minor = version:match('git version (%d+)%.(%d+)')
  end
  major, minor = tonumber(major), tonumber(minor)
  if major and (major > 2 or (major == 2 and minor >= 23)) then
    return 'git --literal-pathspecs restore --worktree -- {}'
  end
  return 'git --literal-pathspecs checkout -- {}'
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

local function path_set_directories(output)
  local result = {}
  for _, path in ipairs(nul_fields(output or '')) do
    if path:sub(-1) == '/' then result[path:gsub('/+$', '')] = true end
  end
  return result
end

local function stat_signature(path)
  local stat = vim.uv.fs_lstat(path)
  if not stat then return false end
  local mtime = stat.mtime or {}
  local ctime = stat.ctime or {}
  return table.concat({
    tostring(stat.dev),
    tostring(stat.ino),
    tostring(stat.mode),
    tostring(stat.size),
    tostring(mtime.sec),
    tostring(mtime.nsec),
    tostring(ctime.sec),
    tostring(ctime.nsec),
  }, ':')
end

local function is_absolute(path) return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil end

local function fingerprint_path(context, path)
  if context and type(path) == 'string' and path ~= '' then
    path = normalize(path)
    context.fingerprint[path] = stat_signature(path)
  end
end

local function fingerprint_matches(fingerprint)
  for path, signature in pairs(fingerprint or {}) do
    if stat_signature(path) ~= signature then return false end
  end
  return true
end

local function cache_touch(key)
  for index, existing in ipairs(ignore_snapshot_cache_order) do
    if existing == key then
      table.remove(ignore_snapshot_cache_order, index)
      break
    end
  end
  ignore_snapshot_cache_order[#ignore_snapshot_cache_order + 1] = key
end

local function cache_remove(key)
  ignore_snapshot_cache[key] = nil
  for index, existing in ipairs(ignore_snapshot_cache_order) do
    if existing == key then
      table.remove(ignore_snapshot_cache_order, index)
      break
    end
  end
end

local function cache_store(key, entry)
  ignore_snapshot_cache[key] = entry
  cache_touch(key)
  while #ignore_snapshot_cache_order > ignore_snapshot_cache_limit do
    local oldest = table.remove(ignore_snapshot_cache_order, 1)
    ignore_snapshot_cache[oldest] = nil
  end
end

local function cache_invalidate_all()
  ignore_snapshot_cache = {}
  ignore_snapshot_cache_order = {}
end

local function git_environment()
  return {
    HOME = vim.env.HOME,
    XDG_CONFIG_HOME = vim.env.XDG_CONFIG_HOME,
    GIT_CONFIG_GLOBAL = vim.env.GIT_CONFIG_GLOBAL,
    GIT_CONFIG_SYSTEM = vim.env.GIT_CONFIG_SYSTEM,
    GIT_CONFIG_NOSYSTEM = vim.env.GIT_CONFIG_NOSYSTEM,
    GIT_DIR = vim.env.GIT_DIR,
    GIT_WORK_TREE = vim.env.GIT_WORK_TREE,
    GIT_CEILING_DIRECTORIES = vim.env.GIT_CEILING_DIRECTORIES,
    GIT_DISCOVERY_ACROSS_FILESYSTEM = vim.env.GIT_DISCOVERY_ACROSS_FILESYSTEM,
  }
end

local function repo_git_dirs(repo_root)
  local marker = vim.fs.joinpath(repo_root, '.git')
  local stat = vim.uv.fs_lstat(marker)
  if not stat then return nil end
  if stat.type == 'directory' then return marker, marker end
  local ok, lines = pcall(vim.fn.readfile, marker)
  local target = ok and lines[1] and lines[1]:match('^gitdir:%s*(.-)%s*$')
  if not target then return nil end
  local git_dir = is_absolute(target) and target or vim.fs.joinpath(repo_root, target)
  git_dir = normalize(git_dir)
  local common_dir = git_dir
  local common_path = vim.fs.joinpath(git_dir, 'commondir')
  local common_ok, common_lines = pcall(vim.fn.readfile, common_path)
  local common_target = common_ok and common_lines[1]
  if common_target and common_target ~= '' then
    common_dir = normalize(is_absolute(common_target) and common_target or vim.fs.joinpath(git_dir, common_target))
  end
  return git_dir, common_dir
end

local function fingerprint_repo(repo_root, context)
  local marker = vim.fs.joinpath(repo_root, '.git')
  fingerprint_path(context, marker)
  local git_dir, common_dir = repo_git_dirs(repo_root)
  if not git_dir then return end
  fingerprint_path(context, git_dir)
  fingerprint_path(context, vim.fs.joinpath(git_dir, 'commondir'))
  fingerprint_path(context, vim.fs.joinpath(common_dir, 'config'))
  fingerprint_path(context, vim.fs.joinpath(git_dir, 'config.worktree'))
  fingerprint_path(context, vim.fs.joinpath(git_dir, 'index'))
  fingerprint_path(context, vim.fs.joinpath(common_dir, 'info', 'exclude'))

  local home = vim.env.HOME
  local xdg = vim.env.XDG_CONFIG_HOME
  fingerprint_path(context, vim.env.GIT_CONFIG_GLOBAL)
  fingerprint_path(context, vim.env.GIT_CONFIG_SYSTEM)
  fingerprint_path(context, home and vim.fs.joinpath(home, '.gitconfig'))
  fingerprint_path(context, home and vim.fs.joinpath(home, '.config', 'git', 'config'))
  fingerprint_path(context, home and vim.fs.joinpath(home, '.config', 'git', 'ignore'))
  fingerprint_path(context, xdg and vim.fs.joinpath(xdg, 'git', 'config'))
  fingerprint_path(context, xdg and vim.fs.joinpath(xdg, 'git', 'ignore'))
  if not vim.env.GIT_CONFIG_SYSTEM then fingerprint_path(context, '/etc/gitconfig') end
end

local function fingerprint_scope_ancestors(repo_root, scope_path, context)
  local root, scope = normalize(repo_root), normalize(scope_path)
  local relative = ''
  if scope ~= root then
    local prefix = root:gsub('/+$', '') .. '/'
    if scope:sub(1, #prefix) ~= prefix then return end
    relative = scope:sub(#prefix + 1)
  end
  local current = root
  fingerprint_path(context, current)
  fingerprint_path(context, vim.fs.joinpath(current, '.gitignore'))
  for component in relative:gmatch('[^/]+') do
    current = vim.fs.joinpath(current, component)
    fingerprint_path(context, current)
    fingerprint_path(context, vim.fs.joinpath(current, '.git'))
    fingerprint_path(context, vim.fs.joinpath(current, '.gitignore'))
  end
end

local function fingerprint_configured_excludes(repo_root, context, timeout_ms)
  local output, err, code =
    command({ '-C', repo_root, 'config', '--path', '--get', 'core.excludesfile' }, nil, timeout_ms)
  if not output then
    if code == 1 then return true end
    return nil, err
  end
  local path = trimmed_output(output)
  if path ~= '' then
    if not is_absolute(path) then path = vim.fs.joinpath(repo_root, path) end
    fingerprint_path(context, path)
  end
  return true
end

local function ignore_timeout_ms()
  local config = require('direct.config')
  return config.options.git.timeout_ms
end

local function timeout_message(err, timeout_ms)
  if tostring(err):find('timed out', 1, true) then
    return 'Git-ignore query timed out after ' .. tostring(timeout_ms) .. ' ms'
  end
  return err
end

function M.is_timeout(err) return type(err) == 'string' and err:find('timed out', 1, true) ~= nil end

function M.warn_ignore_timeout(path, err)
  if not M.is_timeout(err) then return end
  path = normalize(path or '')
  local warning_key, current = path, path
  while current and current ~= '' do
    if vim.uv.fs_lstat(vim.fs.joinpath(current, '.git')) then
      warning_key = normalize(current)
      break
    end
    local parent = vim.fs.dirname(current)
    if parent == current then break end
    current = parent
  end
  if ignore_timeout_warnings[warning_key] then return end
  ignore_timeout_warnings[warning_key] = true
  require('direct.ui').notify(
    'direct: Git-ignore filtering timed out; listing without Git-ignore filtering: '
      .. path
      .. ' ('
      .. tostring(err)
      .. ')',
    vim.log.levels.WARN
  )
end

local function ls_files_args(scope_path, options)
  local args = { '-C', scope_path, 'ls-files' }
  vim.list_extend(args, options)
  vim.list_extend(args, { '--full-name' })
  return args
end

local function parse_index(output)
  local tracked_exact, gitlinks = {}, {}
  for _, record in ipairs(nul_fields(output or '')) do
    local metadata, path = record:match('^([^\t]*)\t(.*)$')
    if path and path ~= '' then
      tracked_exact[path] = true
      if metadata:match('^160000%s') then gitlinks[path] = true end
    end
  end
  return tracked_exact, gitlinks
end

local function ignore_state_from_outputs(index_output, ignored_output, untracked_output)
  local tracked_exact, gitlinks = parse_index(index_output)
  local tracked = {}
  for relative in pairs(tracked_exact) do
    add_tracked_path(tracked, relative)
  end
  return {
    tracked = tracked,
    tracked_exact = tracked_exact,
    ignored = path_set(ignored_output),
    untracked = path_set(untracked_output),
    untracked_dirs = path_set_directories(untracked_output),
    gitlinks = gitlinks,
  }
end

local function read_ignore_state(repo_root, prefix, scope_path, timeout_ms)
  scope_path = scope_path or vim.fs.joinpath(repo_root, prefix or '')
  local outputs, err = commands_parallel({
    ls_files_args(scope_path, { '--stage', '-z' }),
    ls_files_args(scope_path, { '--others', '--ignored', '--exclude-standard', '--directory', '-z' }),
    ls_files_args(scope_path, { '--others', '--exclude-standard', '--directory', '-z' }),
  }, timeout_ms)
  if not outputs then return nil, err end
  return ignore_state_from_outputs(outputs[1], outputs[2], outputs[3])
end

local function relative_to_repo(repo_root, path)
  path, repo_root = normalize(path), normalize(repo_root)
  if path == repo_root then return '' end
  local prefix = repo_root:gsub('/+$', '') .. '/'
  if path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1):gsub('/+$', '')
end

local function nested_repo_roots(repo_root, scope_path, state, context)
  local roots, pending = {}, { scope_path or repo_root }
  if next(state.untracked_dirs or {}) then context.cacheable = false end
  for relative in pairs(state.untracked or {}) do
    if relative:find('/', 1, true) then
      context.cacheable = false
      break
    end
  end
  local root_set = {}
  local unreadable = context.unreadable
  local function add_root(path)
    path = normalize(path)
    if path ~= repo_root and not root_set[path] then
      roots[#roots + 1] = path
      root_set[path] = true
    end
  end

  for relative in pairs(state.gitlinks or {}) do
    local path = normalize(vim.fs.joinpath(repo_root, relative))
    if vim.uv.fs_lstat(vim.fs.joinpath(path, '.git')) then add_root(path) end
  end

  while #pending > 0 do
    local dir = table.remove(pending)
    dir = normalize(dir)
    fingerprint_path(context, dir)
    local ignore_file = vim.fs.joinpath(dir, '.gitignore')
    fingerprint_path(context, ignore_file)
    if dir ~= repo_root and vim.uv.fs_lstat(vim.fs.joinpath(dir, '.git')) then
      add_root(dir)
    else
      local scan, scan_err = vim.uv.fs_scandir(dir)
      if not scan then
        unreadable[#unreadable + 1] = dir .. ': ' .. tostring(scan_err or 'cannot read directory')
      else
        while true do
          local name, kind = vim.uv.fs_scandir_next(scan)
          if name == nil then break end
          if kind == 'directory' and name ~= '.git' then
            local child = normalize(vim.fs.joinpath(dir, name))
            fingerprint_path(context, child)
            fingerprint_path(context, vim.fs.joinpath(child, '.git'))
            fingerprint_path(context, vim.fs.joinpath(child, '.gitignore'))
            local relative = relative_to_repo(repo_root, child)
            if vim.uv.fs_lstat(vim.fs.joinpath(child, '.git')) then
              add_root(child)
            elseif relative and state.tracked[relative] then
              pending[#pending + 1] = child
            end
          end
        end
      end
    end
  end
  table.sort(roots)
  table.sort(unreadable)
  return roots, unreadable
end

local function capture_repo_snapshot(repo_root, scope_path, prefix, seen, initial_state, context, timeout_ms)
  if seen[repo_root] then return nil, 'nested Git repository cycle detected' end
  scope_path = normalize(scope_path or repo_root)
  seen[repo_root] = true
  local state, state_err = initial_state, nil
  if not state then
    state, state_err = read_ignore_state(repo_root, prefix, scope_path, timeout_ms)
  end
  if not state then return nil, state_err end
  fingerprint_repo(repo_root, context)
  fingerprint_scope_ancestors(repo_root, scope_path, context)
  local excludes_ok, excludes_err = fingerprint_configured_excludes(repo_root, context, timeout_ms)
  if not excludes_ok then return nil, excludes_err end
  local snapshot = {
    root = repo_root,
    scope_path = normalize(scope_path or repo_root),
    repo_prefix = prefix or '',
    tracked = state.tracked,
    tracked_exact = state.tracked_exact,
    ignored = state.ignored,
    untracked = state.untracked,
    nested = {},
  }

  local roots = nested_repo_roots(repo_root, scope_path, state, context)
  snapshot.nested_roots = roots
  for _, nested_root in ipairs(roots) do
    local nested_repo, nested_repo_err = discover_repo(nested_root, timeout_ms)
    if nested_repo == false then return nil, 'nested Git repository context changed; re-list this directory' end
    if not nested_repo then return nil, nested_repo_err end
    if nested_repo ~= repo_root then
      if nested_repo ~= nested_root then return nil, 'nested Git repository root changed; re-list this directory' end
      local nested_prefix, prefix_err = command({ '-C', nested_root, 'rev-parse', '--show-prefix' }, nil, timeout_ms)
      if not nested_prefix then return nil, prefix_err end
      nested_prefix = nested_prefix:gsub('[\r\n]+$', ''):gsub('/+$', '')
      if nested_prefix ~= '' then nested_prefix = nested_prefix .. '/' end
      local nested, nested_err =
        capture_repo_snapshot(nested_root, nested_root, nested_prefix, seen, nil, context, timeout_ms)
      if not nested then return nil, nested_err end
      snapshot.nested[nested_root] = nested
    end
  end
  snapshot._fingerprint = context.fingerprint
  seen[repo_root] = nil
  return snapshot
end

-- ignore_snapshot(path) returns nil,nil outside a repository; an error is
-- distinct from that case so an enabled filter never silently guesses. The
-- snapshot records Git's effective ignored and tracked path decisions instead
-- of hashing every ignore source in the worktree.
function M.ignore_snapshot(path)
  local timeout_ms = ignore_timeout_ms()
  local cache_key = normalize(path)
  local cached = ignore_snapshot_cache[cache_key]
  if cached and vim.deep_equal(cached.environment, git_environment()) and fingerprint_matches(cached.fingerprint) then
    cache_touch(cache_key)
    return vim.deepcopy(cached.snapshot)
  end
  if cached then cache_remove(cache_key) end

  -- Probe repository membership first. Outside Git, do not run prefix or
  -- inventory queries; those are only meaningful after this succeeds.
  local repo_root, repo_err = discover_repo(path, timeout_ms)
  if repo_root == false then return nil end
  if not repo_root then return nil, timeout_message(repo_err, timeout_ms) end
  -- Once the repository guard succeeds, prefix discovery and both inventories
  -- are independent. Running ls-files from the requested scope preserves Git's
  -- subtree semantics without waiting for the prefix to build a pathspec.
  local outputs, snapshot_err = commands_parallel({
    { '-C', path, 'rev-parse', '--show-prefix' },
    ls_files_args(path, { '--stage', '-z' }),
    ls_files_args(path, { '--others', '--ignored', '--exclude-standard', '--directory', '-z' }),
    ls_files_args(path, { '--others', '--exclude-standard', '--directory', '-z' }),
  }, timeout_ms)
  if not outputs then return nil, timeout_message(snapshot_err, timeout_ms) end
  local prefix = outputs[1]:gsub('[\r\n]+$', ''):gsub('/+$', '')
  if prefix ~= '' then prefix = prefix .. '/' end
  local state = ignore_state_from_outputs(outputs[2], outputs[3], outputs[4])
  local context = { fingerprint = {}, unreadable = {}, cacheable = true }
  local snapshot, capture_err = capture_repo_snapshot(repo_root, path, prefix, {}, state, context, timeout_ms)
  if not snapshot then return nil, timeout_message(capture_err, timeout_ms) end
  snapshot.unreadable = context.unreadable
  local function set_cacheable(item)
    item.cacheable = context.cacheable
    item._environment = git_environment()
    for _, nested in pairs(item.nested or {}) do
      set_cacheable(nested)
    end
  end
  set_cacheable(snapshot)
  if context.cacheable then
    local function cache_tree(item)
      cache_store(normalize(item.scope_path), {
        snapshot = vim.deepcopy(item),
        fingerprint = context.fingerprint,
        environment = git_environment(),
      })
      for _, nested in pairs(item.nested or {}) do
        cache_tree(nested)
      end
    end
    cache_tree(snapshot)
  end
  return snapshot
end

function M.record_ignore_candidates(snapshot, scope_path, names)
  if not snapshot then return end
  local scope = normalize(scope_path):gsub('/+$', '') .. '/'
  local candidates = {}
  for _, name in ipairs(names or {}) do
    local path = normalize(vim.fs.joinpath(scope_path, name))
    if path:sub(1, #scope) == scope then candidates[(snapshot.repo_prefix or '') .. path:sub(#scope + 1)] = true end
  end
  snapshot.candidates = candidates
end

-- A live ignore context is sufficient for a one-off descendant scan. It avoids
-- building a second list-time snapshot when the scan encounters a nested repo.
function M.ignore_context(path)
  local timeout_ms = ignore_timeout_ms()
  local repo_root, repo_err = discover_repo(path, timeout_ms)
  if repo_root == false then return nil end
  if not repo_root then return nil, timeout_message(repo_err, timeout_ms) end
  local prefix, prefix_err = command({ '-C', path, 'rev-parse', '--show-prefix' }, nil, timeout_ms)
  if not prefix then return nil, timeout_message(prefix_err, timeout_ms) end
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
  local cached_snapshot = ignore_snapshot_cache[normalize(scope_path)]
  if
    cached_snapshot
    and vim.deep_equal(cached_snapshot.environment, git_environment())
    and fingerprint_matches(cached_snapshot.fingerprint)
  then
    cache_touch(normalize(scope_path))
    local snapshot = cached_snapshot.snapshot
    if snapshot.root == repo_root and (snapshot.repo_prefix or '') == (prefix or '') then
      current = {
        tracked = snapshot.tracked,
        tracked_exact = snapshot.tracked_exact,
        ignored = snapshot.ignored,
        nested_roots = snapshot.nested_roots or {},
      }
      checked[key] = current
      return current
    end
  end

  local timeout_ms = ignore_timeout_ms()
  local live_root, repo_err = discover_repo(scope_path, timeout_ms)
  if live_root == false then return nil, 'Git repository context changed; re-list this directory' end
  if not live_root then return nil, timeout_message(repo_err, timeout_ms) end
  if live_root ~= repo_root then return nil, 'Git repository context changed; re-list this directory' end
  local state, err = read_ignore_state(repo_root, prefix, scope_path, timeout_ms)
  if not state then return nil, timeout_message(err, timeout_ms) end
  local context = { fingerprint = {}, unreadable = {} }
  local roots = nested_repo_roots(repo_root, scope_path, state, context)
  state.nested_roots = roots
  checked[key] = state
  return state
end

local function matches_snapshot(snapshot, checked)
  local prefix = snapshot.repo_prefix or ''
  local current, err
  if
    snapshot.cacheable
    and snapshot._fingerprint
    and vim.deep_equal(snapshot._environment, git_environment())
    and fingerprint_matches(snapshot._fingerprint)
  then
    current = {
      tracked = snapshot.tracked,
      tracked_exact = snapshot.tracked_exact,
      ignored = snapshot.ignored,
      nested_roots = snapshot.nested_roots or {},
    }
  else
    current, err = current_repo_state(snapshot.root, prefix, snapshot.scope_path, checked)
  end
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
  if not same_scoped_paths(snapshot.tracked_exact, current.tracked_exact, prefix) or ignored_changed then
    return false, 'Git ignore rules changed or tracked paths changed; re-list this directory'
  end

  local previous_roots = {}
  for root in pairs(snapshot.nested or {}) do
    previous_roots[root] = true
  end
  local current_roots = {}
  for _, root in ipairs(current.nested_roots or {}) do
    current_roots[root] = true
  end
  for root in pairs(previous_roots) do
    if not current_roots[root] then return false, 'Git repository context changed; re-list this directory' end
  end
  for root in pairs(current_roots) do
    if not previous_roots[root] then return false, 'Git repository context changed; re-list this directory' end
  end
  for _, nested_snapshot in pairs(snapshot.nested or {}) do
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
  if
    snapshot
    and snapshot.cacheable
    and snapshot._fingerprint
    and vim.deep_equal(snapshot._environment, git_environment())
    and fingerprint_matches(snapshot._fingerprint)
  then
    return matches_snapshot(snapshot, checked or {})
  end
  -- Expanded directories can be moved or removed by a successful sync while
  -- retaining their original list-time snapshot. If they were outside Git,
  -- the now-missing path cannot have gained repository context; accept it.
  -- A Git-backed snapshot still requires a live path so repository changes fail
  -- closed as usual.
  if not snapshot then
    local stat, stat_err = vim.uv.fs_stat(path)
    if not stat and stat_err and (stat_err:find('ENOENT', 1, true) or stat_err:find('ENOTDIR', 1, true)) then
      return true
    end
  end
  local repo_root, discover_err = discover_repo(path)
  if repo_root == false then
    if snapshot then return false, 'Git repository context changed; re-list this directory' end
    return true
  end
  if not repo_root then return nil, discover_err end
  if not snapshot then return false, 'Git repository context changed; re-list this directory' end
  if repo_root ~= snapshot.root then return false, 'Git repository context changed; re-list this directory' end
  checked = checked or {}
  local matches, err = matches_snapshot(snapshot, checked)
  if M.is_timeout(err) then cache_invalidate_all() end
  return matches, err
end

local function inventory_for(snapshot, cache)
  if cache then
    local prefix = snapshot.repo_prefix or ''
    local key = snapshot.root .. '\0' .. prefix
    local state = cache[key]
    if state then return state.ignored, state.tracked end
    local scope_path = snapshot.scope_path or snapshot.root
    local timeout_ms = ignore_timeout_ms()
    local repo_root, repo_err = discover_repo(scope_path, timeout_ms)
    if repo_root == false then return nil, nil, 'Git repository context changed; re-list this directory' end
    if not repo_root then return nil, nil, timeout_message(repo_err, timeout_ms) end
    if repo_root ~= snapshot.root then return nil, nil, 'Git repository context changed; re-list this directory' end
    local output, err = command(
      ls_files_args(scope_path, { '--others', '--ignored', '--exclude-standard', '--directory', '-z' }),
      nil,
      timeout_ms
    )
    if not output then return nil, nil, timeout_message(err, timeout_ms) end
    state = { ignored = path_set(output) }
    cache[key] = state
    return state.ignored
  end
  return snapshot.ignored or {}, snapshot.tracked or {}
end

-- ignored_paths(snapshot, absolute_paths[, cache]) matches candidates against
-- Git's native ignored-path inventory. A supplied cache is fresh and shared by
-- a live descendant walk; otherwise the list-time inventory is used.
function M.ignored_paths(snapshot, candidate_paths, cache)
  if not snapshot or #candidate_paths == 0 then return {} end
  local ignored, tracked, err = inventory_for(snapshot, cache)
  if not ignored then
    if M.is_timeout(err) then cache_invalidate_all() end
    return nil, err
  end
  local scope_path = normalize(snapshot.scope_path or snapshot.root)
  local prefix = scope_path:gsub('/+$', '') .. '/'
  local result = {}
  for _, path in ipairs(candidate_paths) do
    local normalized = normalize(path)
    if normalized:sub(1, #prefix) == prefix then
      local relative = (snapshot.repo_prefix or '') .. normalized:sub(#prefix + 1)
      if ignored[relative] and not (tracked and tracked[relative]) then result[#result + 1] = normalized end
    end
  end
  return result
end

-- Check new or moved-to paths against the current ignore rules. Unlike
-- ignored_paths(), this handles destinations that do not exist yet and hence
-- are absent from `ls-files --ignored` inventories.
function M.ignored_candidates(snapshot, candidates)
  if not snapshot or type(candidates) ~= 'table' or #candidates == 0 then return {} end
  local inventory_matches, inventory_err = M.ignored_paths(snapshot, candidates)
  if not inventory_matches then return nil, inventory_err end
  local ignored_by_path, result_paths = {}, {}
  for _, path in ipairs(inventory_matches) do
    local key = normalize(path)
    ignored_by_path[key] = true
    result_paths[#result_paths + 1] = path
  end

  local input, absolute_by_relative = {}, {}
  for _, path in ipairs(candidates) do
    local relative = relative_to_repo(snapshot.root, path)
    if
      relative
      and relative ~= ''
      and not ignored_by_path[normalize(path)]
      and not (snapshot.tracked and snapshot.tracked[relative])
    then
      relative = relative:gsub('\\', '/')
      if path:sub(-1) == '/' or path:sub(-1) == '\\' then relative = relative .. '/' end
      if not absolute_by_relative[relative] then
        input[#input + 1] = relative
        absolute_by_relative[relative] = normalize(path)
        absolute_by_relative[relative:gsub('/+$', '')] = normalize(path)
      end
    end
  end
  if #input == 0 then return result_paths end

  local timeout_ms = ignore_timeout_ms()
  local process, start_err = start(
    { 'git', '-C', snapshot.root, 'check-ignore', '--no-index', '-z', '--stdin' },
    table.concat(input, '\0') .. '\0'
  )
  if not process then return nil, start_err end
  local ok, result = pcall(function() return process:wait(timeout_ms) end)
  if not ok then return nil, tostring(result) end
  if result.code == 124 then
    cache_invalidate_all()
    return nil, 'Git-ignore query timed out after ' .. timeout_ms .. ' ms'
  end
  if result.code == 1 then
    table.sort(result_paths)
    return result_paths
  end
  if result.code ~= 0 then
    local err = result.stderr and result.stderr:gsub('%s+$', '') or ''
    return nil, err ~= '' and err or 'git check-ignore failed'
  end

  local matched, seen = path_set(result.stdout), ignored_by_path
  for relative in pairs(matched) do
    local absolute = absolute_by_relative[relative]
    if absolute and not seen[normalize(absolute)] then
      result_paths[#result_paths + 1] = absolute
      seen[normalize(absolute)] = true
    end
  end
  table.sort(result_paths)
  return result_paths
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
