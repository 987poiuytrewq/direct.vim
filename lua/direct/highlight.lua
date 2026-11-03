-- Listing filenames use syntax groups; this module owns display highlight marks.

local M = {}

local namespace = vim.api.nvim_create_namespace('direct-listing-highlights')
local git_namespace = vim.api.nvim_create_namespace('direct-listing-git-status')

local default_highlights = {
  DirectFolderIcon = { link = 'Directory' },
  DirectFileIcon = { link = 'Normal' },
  DirectHiddenFolderIcon = { link = 'Comment' },
  DirectHiddenFileIcon = { link = 'Comment' },
  DirectGitAdded = { fg = '#5faf5f' },
  DirectGitDeleted = { fg = '#ff5900' },
  DirectGitModified = { fg = '#d7af5f' },
  DirectGitRenamed = { link = 'DirectGitModified' },
  DirectGitConflict = { fg = '#ff8700', italic = true, bold = true },
  DirectGitIgnored = { fg = '#626262' },
  DirectGitUntracked = { fg = '#ff8700', italic = true },
  DirectGitStaged = { link = 'DirectGitAdded' },
  DirectGitUnstaged = { link = 'DirectGitConflict' },
  DirectGitDeletedFile = { link = 'ErrorMsg' },
  DirectGitDeletedDirectory = { link = 'ErrorMsg' },
}

local change_highlights = {
  added = 'DirectGitAdded',
  deleted = 'DirectGitDeleted',
  modified = 'DirectGitModified',
  renamed = 'DirectGitRenamed',
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

local function status_chunks(status, symbols, conflicted)
  local chunks = {}
  local function append(key, highlight)
    local symbol = symbols[key]
    if type(symbol) ~= 'string' or symbol == '' then return end
    if vim.fn.strchars(symbol) == 1 then symbol = symbol .. ' ' end
    chunks[#chunks + 1] = { symbol, highlight }
  end

  -- Direct's Git snapshot normalizes porcelain `??` to `_A` (a space and A).
  if status == ' A' then
    append('untracked', 'DirectGitUntracked')
    return chunks
  end
  if status == '!!' then
    append('ignored', 'DirectGitIgnored')
    return chunks
  end

  local index, worktree = status:sub(1, 1), status:sub(2, 2)
  local conflict = conflicted
  if conflict == nil then conflict = conflict_codes[status] == true end
  local stage, stage_highlight
  if worktree == ' ' then
    stage, stage_highlight = 'staged', 'DirectGitStaged'
  elseif index == ' ' then
    stage, stage_highlight = 'unstaged', 'DirectGitUnstaged'
  elseif conflict then
    stage, stage_highlight = 'conflict', 'DirectGitConflict'
  end

  local function append_change(code)
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
    append(change, change_highlights[change])
  end

  if index ~= ' ' then append_change(index) end
  if not conflict and worktree ~= ' ' then append_change(worktree) end

  -- Show the staged/unstaged marker for a single-column change. For a mixed
  -- two-column change, the two change symbols already convey both states.
  if (#chunks < 2 or conflict) and stage then append(stage, stage_highlight) end
  return chunks
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
    if deleted_group then
      local line = vim.api.nvim_buf_get_lines(bufnr, item.row, item.row + 1, false)[1] or ''
      vim.api.nvim_buf_set_extmark(bufnr, namespace, item.row, (item.depth or 0) * 2, {
        end_row = item.row,
        end_col = #line,
        hl_group = deleted_group,
        priority = 150,
      })
    end

    if git_options.enabled ~= false and item.status then
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
