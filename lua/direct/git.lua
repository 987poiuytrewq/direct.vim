-- lua/direct/git.lua -- Git status snapshots for display-only listing metadata.

local M = {}

local status_priority = {
  modified = 1,
  added = 2,
  renamed = 3,
  conflicted = 4,
}

local function normalize(path)
  local value = vim.fs.normalize(path):gsub('\\', '/')
  if value:match('^%a:/$') then return value end
  value = value:gsub('/+$', '')
  return value == '' and '/' or value
end

local function run(args)
  local ok, result = pcall(function()
    return vim.system(args, { text = false }):wait()
  end)
  if not ok then return nil, tostring(result) end
  if result.code ~= 0 then
    return nil, result.stderr and result.stderr:gsub('%s+$', '') or 'git command failed'
  end
  return result.stdout or ''
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

local function classify(xy)
  if xy:find('U', 1, true) or xy == 'AA' or xy == 'DD' then
    return 'conflicted'
  end
  if xy:find('R', 1, true) then return 'renamed' end
  if xy == '??' or xy:find('A', 1, true) then return 'added' end
  if xy:find('M', 1, true) or xy:find('T', 1, true)
    or xy:find('C', 1, true) then
    return 'modified'
  end
  return nil
end

local function add_path(paths, path, status)
  local key = normalize(path)
  local previous = paths[key]
  if not previous or status_priority[status] > status_priority[previous] then
    paths[key] = status
  end
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

-- read(root) -> { root = repository root, paths = absolute path -> status }
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
  local paths = {}
  local index = 1
  while index <= #fields do
    local record = fields[index]
    index = index + 1
    if #record >= 4 then
      local xy = record:sub(1, 2)
      local relative = record:sub(4)
      local status = classify(xy)
      if status and relative ~= '' then
        -- In -z output, a rename record is followed by the original path; the
        -- first path is the destination and is the one present in the listing.
        if xy:find('R', 1, true) or xy:find('C', 1, true) then
          index = index + 1
        end
        add_with_parent_directories(paths, repo_root, relative, status)
      end
    end
  end
  return { root = repo_root, paths = paths }
end

function M.status_for(snapshot, path)
  if not snapshot or type(path) ~= 'string' then return nil end
  return snapshot.paths[normalize(path)]
end

return M
