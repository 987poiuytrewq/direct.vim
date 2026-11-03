-- Listing filenames use syntax groups; this module owns display highlight marks.

local M = {}

local namespace = vim.api.nvim_create_namespace('direct-listing-highlights')
local gutter_namespace = vim.api.nvim_create_namespace('direct-listing-git-gutter')
local saved_signcolumn = {}

local default_links = {
  DirectFolderIcon = 'Directory',
  DirectFileIcon = 'Normal',
  DirectHiddenFolderIcon = 'Comment',
  DirectHiddenFileIcon = 'Comment',
  DirectGitAddedGutter = 'DiffAdd',
  DirectGitModifiedGutter = 'DiffChange',
  DirectGitConflictedGutter = 'ErrorMsg',
  DirectGitDeletedGutter = 'DiffDelete',
  DirectGitDeletedFile = 'ErrorMsg',
  DirectGitDeletedDirectory = 'ErrorMsg',
}

local status_highlights = {
  A = 'DirectGitAddedGutter',
  M = 'DirectGitModifiedGutter',
  D = 'DirectGitDeletedGutter',
  R = 'DirectGitModifiedGutter',
  C = 'DirectGitModifiedGutter',
  U = 'DirectGitConflictedGutter',
}

local function two_column_value(value)
  if value == 'no' then return nil end
  if value == 'number' then return 'auto:2' end
  if value == 'auto' then return 'auto:2' end
  if value == 'yes' then return 'yes:2' end
  local count = value:match('^auto:(%d+)$') or value:match('^yes:(%d+)$')
  if count then
    if tonumber(count) < 2 then
      return value:sub(1, 4) == 'auto' and 'auto:2' or 'yes:2'
    end
    return nil
  end
  local _, maximum = value:match('^auto:(%d+)%-(%d+)$')
  if maximum and tonumber(maximum) < 2 then return 'auto:2' end
  return nil
end

local function ensure_signcolumn(win)
  local current = vim.wo[win].signcolumn
  local previous = saved_signcolumn[win]
  if previous and previous.applied == current then return end
  saved_signcolumn[win] = nil
  local replacement = two_column_value(current)
  if replacement then
    saved_signcolumn[win] = { original = current, applied = replacement }
    vim.wo[win].signcolumn = replacement
  end
end

local function restore_signcolumn(win)
  local previous = saved_signcolumn[win]
  saved_signcolumn[win] = nil
  if not previous or not vim.api.nvim_win_is_valid(win) then return end
  if vim.wo[win].signcolumn == previous.applied then
    vim.wo[win].signcolumn = previous.original
  end
end

local function ensure_signcolumn_for_buffer(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then ensure_signcolumn(win) end
  end
end

local function restore_signcolumn_for_buffer(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then restore_signcolumn(win) end
  end
end

local function needs_git_gutter()
  if vim.bo.filetype ~= 'direct' then return false end
  local config = package.loaded['direct.config']
  return not config or config.options.git.enabled ~= false
end

local function define_highlight_defaults()
  for group, target in pairs(default_links) do
    vim.api.nvim_set_hl(0, group, { default = true, link = target })
  end
end

function M.setup()
  define_highlight_defaults()
  local sign_group = vim.api.nvim_create_augroup('direct_git_signcolumn', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = sign_group,
    callback = function()
      if needs_git_gutter() then ensure_signcolumn(vim.api.nvim_get_current_win()) end
    end,
    desc = 'direct: reserve two sign cells for Git status',
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    group = sign_group,
    callback = function() restore_signcolumn(vim.api.nvim_get_current_win()) end,
    desc = 'direct: restore the window signcolumn after leaving a listing',
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = sign_group,
    callback = function(args) saved_signcolumn[tonumber(args.match)] = nil end,
    desc = 'direct: release saved signcolumn state for a closed window',
  })
  local group = vim.api.nvim_create_augroup('direct_icon_highlight_defaults', {
    clear = true,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = define_highlight_defaults,
    desc = 'direct: reapply default display highlight links',
  })
end

-- render(bufnr, rows, options) clears stale display marks and reapplies the
-- Git status gutter. `rows` is an ordered array of { row, depth, status }.
function M.render(bufnr, rows, options)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, gutter_namespace, 0, -1)
  options = options or {}
  local git_options = options.git or {}
  for _, item in ipairs(rows or {}) do
    local deleted_group = item.deleted_kind == 'directory'
      and 'DirectGitDeletedDirectory'
      or (item.deleted_kind == 'file' and 'DirectGitDeletedFile' or nil)
    if deleted_group then
      local line = vim.api.nvim_buf_get_lines(bufnr, item.row, item.row + 1, false)[1] or ''
      vim.api.nvim_buf_set_extmark(bufnr, namespace, item.row, (item.depth or 0) * 2, {
        end_row = item.row,
        end_col = #line,
        hl_group = deleted_group,
        priority = 150,
      })
    end
  end
  if git_options.enabled == false then
    restore_signcolumn_for_buffer(bufnr)
    return
  end
  ensure_signcolumn_for_buffer(bufnr)
  local gutter = git_options.gutter or { index = '|', worktree = '|' }

  for _, item in ipairs(rows or {}) do
    if item.status then
      for column, key in ipairs({ 'index', 'worktree' }) do
        local code = item.status:sub(column, column)
        vim.api.nvim_buf_set_extmark(bufnr, gutter_namespace, item.row, 0, {
          sign_text = code == ' ' and ' ' or gutter[key],
          sign_hl_group = status_highlights[code] or 'Normal',
          priority = 120 - column,
        })
      end
    end
  end
end

return M
