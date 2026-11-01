-- Listing filenames use syntax groups; this module owns icon highlight defaults.

local M = {}

local namespace = vim.api.nvim_create_namespace('direct-listing-highlights')

local icon_highlights = {
  DirectFolderIcon = 'Directory',
  DirectFileIcon = 'Normal',
  DirectHiddenFolderIcon = 'Comment',
  DirectHiddenFileIcon = 'Comment',
}

local function define_icon_highlight_defaults()
  for group, target in pairs(icon_highlights) do
    vim.api.nvim_set_hl(0, group, { default = true, link = target })
  end
end

function M.setup()
  define_icon_highlight_defaults()
  local group = vim.api.nvim_create_augroup('direct_icon_highlight_defaults', {
    clear = true,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = define_icon_highlight_defaults,
    desc = 'direct: reapply default icon highlight links',
  })
end

-- Clear stale marks on render; filename marks are not applied.
function M.render(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

return M
