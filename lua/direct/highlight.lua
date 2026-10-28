-- Listing filenames do not receive custom extmark highlights.

local M = {}

local namespace = vim.api.nvim_create_namespace('direct-listing-highlights')

-- Clear stale marks on render; filename marks are not applied.
function M.render(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

return M
