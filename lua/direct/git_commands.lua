-- Git view commands target the current Direct listing or open/reuse another one.
local M = {}

local ui = require('direct.ui')
local paths = require('direct.paths')

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

local function current_listing_root()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= require('direct.constants').FILETYPE then return nil end
  return require('direct.buffer.buffer').root_for_buffer(bufnr)
end

local function is_absolute(path)
  return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil or path:match('^[/\\][/\\]') ~= nil
end

local function command_root(directory)
  local base = current_listing_root() or vim.fn.getcwd()
  if type(directory) ~= 'string' or directory == '' then return base end
  if is_absolute(directory) then return paths.root(directory) end
  return paths.root(vim.fs.joinpath(base, directory))
end

local function open_listing(directory)
  local api = require('direct')
  if directory == nil and current_listing_root() then return api end
  local listed, err = api.list(command_root(directory))
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

local function completion_tokens(arg_lead, cmdline, cursor_pos)
  local line = tostring(cmdline or '')
  local before = line:sub(1, cursor_pos or #line)
  if arg_lead ~= '' and before:sub(-#arg_lead) == arg_lead then before = before:sub(1, #before - #arg_lead) end
  local previous = before:match('(%S+)%s*$')
  return previous
end

local function option_value(args, key)
  for index, token in ipairs(args) do
    local value = token:match('^%-%-' .. key .. '=(.*)$')
    if value ~= nil then return value end
    if token == '--' .. key then return args[index + 1] end
  end
end

local function directory_completions(arg_lead, cmdline, cursor_pos)
  local previous = completion_tokens(arg_lead, cmdline, cursor_pos)
  local inline = arg_lead:match('^%-%-dir=(.*)$')
  local lead = inline or arg_lead
  if previous ~= '--dir' and inline == nil then return {} end

  local base = command_root(nil)
  local separator = paths.directory_separator()
  local normalized_lead = lead:gsub('\\', '/')
  local directory_part = normalized_lead:match('^(.*)/[^/]*$') or ''
  local name_prefix = normalized_lead:match('([^/]*)$') or ''
  local parent = directory_part == '' and base
    or (is_absolute(directory_part) and paths.root(directory_part) or paths.root(vim.fs.joinpath(base, directory_part)))
  local scan = vim.uv.fs_scandir(parent)
  if not scan then return {} end

  local result = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then break end
    if kind == 'directory' and name:sub(1, #name_prefix) == name_prefix then
      local candidate = directory_part == '' and name or (directory_part .. '/' .. name)
      candidate = candidate .. separator
      if inline then candidate = '--dir=' .. candidate end
      result[#result + 1] = candidate
    end
  end
  table.sort(result)
  return result
end

local function ref_completions(arg_lead, cmdline, cursor_pos)
  local previous = completion_tokens(arg_lead, cmdline, cursor_pos)
  local inline = arg_lead:match('^%-%-ref=(.*)$')
  local prefix = inline or arg_lead
  if previous ~= '--ref' and inline == nil then return {} end

  local line = tostring(cmdline or ''):sub(1, cursor_pos or #tostring(cmdline or ''))
  local args = vim.split(line, '%s+', { trimempty = true })
  local root = command_root(option_value(args, 'dir'))
  local timeout = require('direct.config').options.git.timeout_ms
  local ok, process = pcall(
    vim.system,
    { 'git', '-C', root, 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes', 'refs/tags' },
    { text = true }
  )
  if not ok or not process then return {} end
  local waited, result = pcall(function() return process:wait(timeout) end)
  if not waited or not result or result.code ~= 0 then return {} end

  local completions, seen = {}, {}
  for ref in (result.stdout or ''):gmatch('[^\r\n]+') do
    if ref:sub(1, #prefix) == prefix and not seen[ref] then
      seen[ref] = true
      completions[#completions + 1] = inline and ('--ref=' .. ref) or ref
    end
  end
  table.sort(completions)
  return completions
end

local function complete(arg_lead, cmdline, cursor_pos, allowed)
  local lead = tostring(arg_lead or '')
  if lead:match('^%-%-dir=') or completion_tokens(lead, cmdline, cursor_pos) == '--dir' then
    return directory_completions(lead, cmdline, cursor_pos)
  end
  if allowed.ref and (lead:match('^%-%-ref=') or completion_tokens(lead, cmdline, cursor_pos) == '--ref') then
    return ref_completions(lead, cmdline, cursor_pos)
  end
  if lead:sub(1, 2) == '--' or lead == '' then
    local options = {}
    if allowed.ref then options[#options + 1] = '--ref' end
    if allowed.dir then options[#options + 1] = '--dir' end
    if allowed.include_uncommitted then options[#options + 1] = '--include-uncommitted' end
    return vim.tbl_filter(function(option) return option:sub(1, #lead) == lead end, options)
  end
  return {}
end

function M.complete_status(arg_lead, cmdline, cursor_pos) return complete(arg_lead, cmdline, cursor_pos, { dir = true }) end

function M.complete_diff(arg_lead, cmdline, cursor_pos)
  return complete(arg_lead, cmdline, cursor_pos, {
    ref = true,
    dir = true,
    include_uncommitted = true,
  })
end

return M
