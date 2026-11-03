-- Listing filenames use syntax groups; this module owns display highlight marks.

local M = {}

local namespace = vim.api.nvim_create_namespace('direct-listing-highlights')
local git_namespace = vim.api.nvim_create_namespace('direct-listing-git-status')

local default_highlights = {
  DirectFolderIcon = { link = 'Directory' },
  DirectFileIcon = { link = 'Normal' },
  DirectHiddenFolderIcon = { link = 'Comment' },
  DirectHiddenFileIcon = { link = 'Comment' },
  DirectGitAdded = { link = 'DiffAdd' },
  DirectGitDeleted = { link = 'DiffDelete' },
  DirectGitModified = { link = 'DiffChange' },
  DirectGitRenamed = { link = 'DirectGitModified' },
  DirectGitConflict = { link = 'ErrorMsg' },
  DirectGitIgnored = { link = 'Comment' },
  DirectGitStaged = { link = 'DirectGitAdded' },
  DirectGitDeletedFile = { link = 'ErrorMsg' },
  DirectGitDeletedDirectory = { link = 'ErrorMsg' },
}

local change_highlights = {
  added = 'DirectGitAdded',
  deleted = 'DirectGitDeleted',
  modified = 'DirectGitModified',
  renamed = 'DirectGitRenamed',
  conflict = 'DirectGitConflict',
  ignored = 'DirectGitIgnored',
}

local conflict_codes = {
  AA = true,
  DD = true,
  AU = true,
  UD = true,
  UA = true,
  DU = true,
  UU = true,
}

local function define_highlight_defaults()
  for group, definition in pairs(default_highlights) do
    vim.api.nvim_set_hl(0, group, vim.tbl_extend('force', { default = true }, definition))
  end
end

function M.git_status_highlight(status)
  return change_highlights[status]
end

local function status_chunks(status, symbols, conflicted)
  local function slot(key, highlight)
    local symbol = symbols[key]
    if type(symbol) ~= 'string' or symbol == '' then
      return { ' ', 'Normal' }
    end
    return { symbol, highlight }
  end

  if status == '!!' then
    return { slot('ignored', 'DirectGitIgnored'), { ' ', 'Normal' } }
  end

  local index, worktree = status:sub(1, 1), status:sub(2, 2)
  local conflict = conflicted
  if conflict == nil then conflict = conflict_codes[status] == true end

  local function change_for(code)
    local change
    if code == 'M' or code == 'U' then
      change = 'modified'
    elseif code == 'R' then
      change = 'renamed'
    elseif code == 'D' then
      change = 'deleted'
    else
      -- Neo-tree treats status codes without a special change symbol (including
      -- copied entries) as additions.
      change = 'added'
    end
    return change
  end

  if index == ' ' and worktree == ' ' then return {} end
  local first_code = index ~= ' ' and index or worktree
  local first_change = change_for(first_code)
  local second_change
  local second_symbol, second_highlight

  if conflict then
    second_symbol, second_highlight = 'conflict', 'DirectGitConflict'
  elseif index ~= ' ' and worktree == ' ' then
    second_symbol, second_highlight = 'staged', 'DirectGitStaged'
  elseif index ~= ' ' and worktree ~= ' ' then
    second_change = change_for(worktree)
  end

  return {
    slot(first_change, change_highlights[first_change]),
    second_change
      and slot(second_change, change_highlights[second_change])
      or (second_symbol and slot(second_symbol, second_highlight) or { ' ', 'Normal' }),
  }
end

function M.setup()
  define_highlight_defaults()
  local group = vim.api.nvim_create_augroup('direct_icon_highlight_defaults', {
    clear = true,
  })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = define_highlight_defaults,
    desc = 'direct: reapply default display highlight groups',
  })
end

-- render(bufnr, rows, options) clears stale display marks and reapplies the
-- Neo-tree-style right-aligned Git status component. Rows carry { row, depth,
-- status, deleted_kind }.
function M.render(bufnr, rows, options)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, git_namespace, 0, -1)
  options = options or {}
  local git_options = options.git or {}

  for _, item in ipairs(rows or {}) do
    local deleted_group = item.deleted_kind == 'directory'
      and 'DirectGitDeletedDirectory'
      or (item.deleted_kind == 'file' and 'DirectGitDeletedFile' or nil)
    if deleted_group and not (git_options.enabled ~= false and item.worktree_status) then
      local line = vim.api.nvim_buf_get_lines(bufnr, item.row, item.row + 1, false)[1] or ''
      vim.api.nvim_buf_set_extmark(bufnr, namespace, item.row, (item.depth or 0) * 2, {
        end_row = item.row,
        end_col = #line,
        hl_group = deleted_group,
        priority = 150,
      })
    end

    if git_options.enabled ~= false and item.worktree_status then
      local line = vim.api.nvim_buf_get_lines(bufnr, item.row, item.row + 1, false)[1] or ''
      vim.api.nvim_buf_set_extmark(bufnr, namespace, item.row, (item.depth or 0) * 2, {
        end_row = item.row,
        end_col = #line,
        hl_group = change_highlights[item.worktree_status],
        priority = 160,
      })
    end

    if git_options.enabled ~= false and git_options.show_symbols ~= false and item.status then
      local chunks = status_chunks(item.status, git_options.symbols or {}, item.conflict)
      if #chunks > 0 then
        local line = vim.api.nvim_buf_get_lines(bufnr, item.row, item.row + 1, false)[1] or ''
        vim.api.nvim_buf_set_extmark(bufnr, git_namespace, item.row, #line, {
          virt_text = chunks,
          virt_text_pos = 'eol_right_align',
          hl_mode = 'combine',
          priority = 120,
        })
      end
    end
  end
end

return M
