-- Commands that open/reuse a Direct listing before showing a Git filter.
local M = {}

local ui = require('direct.ui')

local function usage(command, reason)
  local message = 'usage: ' .. command
  if reason then message = message .. ' (' .. reason .. ')' end
  ui.notify('direct: ' .. message, vim.log.levels.ERROR)
  return nil, message
end

local function parse(args, allowed)
  local result, seen = {}, {}
  local index = 1
  while index <= #args do
    local token = args[index]
    if token == '--include-uncommitted' and allowed.include_uncommitted then
      if seen.include_uncommitted then return nil, 'duplicate --include-uncommitted option' end
      result.include_uncommitted = true
      seen.include_uncommitted = true
      index = index + 1
    else
      local key, inline = token:match('^%-%-(%a[%w%-]*)=(.*)$')
      if not key then key = token:match('^%-%-(%a[%w%-]*)$') end
      if key ~= 'ref' and key ~= 'dir' then return nil, 'unknown option ' .. tostring(token) end
      if not allowed[key] then return nil, 'option --' .. key .. ' is not supported' end
      if seen[key] then return nil, 'duplicate --' .. key .. ' option' end
      local value = inline
      if value == nil then
        index = index + 1
        value = args[index]
      end
      if type(value) ~= 'string' or value == '' then return nil, 'missing value for --' .. key end
      result[key] = value
      seen[key] = true
      index = index + 1
    end
  end
  return result
end

local function open_listing(directory)
  local api = require('direct')
  local listed, err = api.list(directory or vim.fn.getcwd())
  if not listed then return nil, err end
  return api
end

function M.status(args)
  local options, err = parse(args or {}, {
    dir = true,
  })
  if not options then return usage(':DirectGitStatus [--dir {dir}]', err) end
  local api, list_err = open_listing(options.dir)
  if not api then return nil, list_err end
  return api.show_git_status()
end

function M.diff(args)
  local options, err = parse(args or {}, {
    ref = true,
    dir = true,
    include_uncommitted = true,
  })
  if not options then return usage(':DirectGitDiff [--ref {ref}] [--dir {dir}] [--include-uncommitted]', err) end
  local api, list_err = open_listing(options.dir)
  if not api then return nil, list_err end
  return api.git_diff(options.ref, options.include_uncommitted)
end

return M
