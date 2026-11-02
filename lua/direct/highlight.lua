-- Listing filenames use syntax groups; this module owns display highlight marks.

local M = {}

local namespace = vim.api.nvim_create_namespace('direct-listing-highlights')
local gutter_namespace = vim.api.nvim_create_namespace('direct-listing-git-gutter')

local default_links = {
  DirectFolderIcon = 'Directory',
  DirectFileIcon = 'Normal',
  DirectHiddenFolderIcon = 'Comment',
  DirectHiddenFileIcon = 'Comment',
  DirectGitAddedIcon = 'DiffAdd',
  DirectGitAdded = 'DiffAdd',
  DirectGitModifiedIcon = 'DiffChange',
  DirectGitModified = 'DiffChange',
  DirectGitRenamedIcon = 'DiffChange',
  DirectGitRenamed = 'DiffChange',
  DirectGitConflictedIcon = 'ErrorMsg',
  DirectGitConflicted = 'ErrorMsg',
}

local function define_highlight_defaults()
  for group, target in pairs(default_links) do
    vim.api.nvim_set_hl(0, group, { default = true, link = target })
  end
end

function M.setup()
  define_highlight_defaults()
  local group = vim.api.nvim_create_augroup('direct_icon_highlight_defaults', {
    clear = true,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = define_highlight_defaults,
    desc = 'direct: reapply default display highlight links',
  })
end

-- render(bufnr, rows, options) clears stale Git marks and reapplies the selected
-- display layers. `rows` is an ordered array of { row, depth, status }.
function M.render(bufnr, rows, options)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, gutter_namespace, 0, -1)
  options = options or {}
  local git_options = options.git or {}
  if git_options.enabled == false then return end
  local display = git_options.display or 'both'
  local statuses = git_options.statuses or {}

  for _, item in ipairs(rows or {}) do
    local settings = item.status and statuses[item.status]
    if settings then
      local line = vim.api.nvim_buf_get_lines(bufnr, item.row, item.row + 1, false)[1] or ''
      if (display == 'text' or display == 'both') and settings.text_hl then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, item.row, (item.depth or 0) * 2, {
          end_row = item.row,
          end_col = #line,
          hl_group = settings.text_hl,
          priority = 120,
        })
      end
      if settings.gutter then
        vim.api.nvim_buf_set_extmark(bufnr, gutter_namespace, item.row, 0, {
          sign_text = settings.gutter.symbol,
          sign_hl_group = settings.gutter.highlight,
          priority = 120,
        })
      end
    end
  end
end

return M
