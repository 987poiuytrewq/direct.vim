-- lua/direct/folding.lua -- direct-buffer fold commands and tree traversal.

local M = {}

function M.install_mappings(bufnr, buffer)
  local maps = {
    { '<LeftMouse>', function() return M._handle_mouse_click(buffer) end,
      'Toggle a direct directory from its folder icon' },
    { '<2-LeftMouse>', function() return M._handle_double_click(buffer) end,
      'Open the direct entry under the double-click' },
    { 'zo', function() return buffer.expand() end,
      'Expand one direct directory level' },
    { 'za', function() return buffer.toggle() end,
      'Toggle direct directory expansion' },
    { 'zc', function() return buffer.collapse() end,
      'Collapse direct directory rows' },
    { 'zO', function() return M.expand_recursive(buffer) end,
      'Recursively expand direct directories' },
    { 'zA', function() return M.toggle_recursive(buffer) end,
      'Recursively toggle direct directories' },
    { 'zC', function() return buffer.collapse() end,
      'Recursively collapse direct directories' },
    { 'zR', function() return M.expand_all(buffer) end,
      'Expand all direct directories' },
    { 'zM', function() return M.collapse_all(buffer) end,
      'Collapse all direct directories' },
  }
  for _, map in ipairs(maps) do
    vim.keymap.set('n', map[1], map[2], {
      buffer = bufnr,
      silent = true,
      desc = map[3],
    })
  end
end

-- Toggle only when the click lands on the rendered folder glyph. The icon is
-- inline virtual text immediately before the directory name; screenpos()'s
-- curscol includes that virtual text, while col is the underlying text column.
function M._handle_mouse_click(buffer, mouse)
  mouse = mouse or vim.fn.getmousepos()
  local winid = mouse.winid
  if not winid or winid == 0 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local target_buf = vim.api.nvim_win_get_buf(winid)
  local context = buffer._folding_context(target_buf)
  local rec = context and mouse.line and mouse.line > 0
    and context.get_row_record(mouse.line) or nil
  local is_icon_click = false
  if rec and context.is_directory(rec)
    and require('direct.config').options.show_folder_icons == true then
    local text_col = (rec.depth or 0) * 2 + 1
    local ok, icon_pos = pcall(vim.fn.screenpos, winid, mouse.line, text_col)
    if ok and icon_pos and icon_pos.row == mouse.screenrow
      and icon_pos.col and icon_pos.curscol then
      -- The icon slot appends one alignment space after the glyph.
      local glyph_width = icon_pos.curscol - icon_pos.col - 1
      is_icon_click = glyph_width > 0
        and mouse.screencol >= icon_pos.col
        and mouse.screencol < icon_pos.col + glyph_width
    end
  end

  -- A buffer-local mouse mapping replaces Neovim's default click action, so
  -- retain its normal-mode cursor placement for clicks that are not on an icon.
  if vim.api.nvim_get_current_win() ~= winid then
    vim.api.nvim_set_current_win(winid)
  end
  if mouse.line and mouse.line > 0 then
    local line = vim.api.nvim_buf_get_lines(target_buf, mouse.line - 1, mouse.line, false)[1]
    if line then
      local col = math.max(0, math.min((mouse.column or 1) - 1, #line))
      vim.api.nvim_win_set_cursor(winid, { mouse.line, col })
    end
  end

  if not is_icon_click then return end
  return vim.api.nvim_win_call(winid, function()
    local attached = buffer.restore()
    if context.is_expanded(rec.id) then
      return attached:collapse(mouse.line)
    end
    return attached:expand(mouse.line)
  end)
end

-- Open the entry at the double-click position using the same path and identity
-- validation as the normal <CR> action.
function M._handle_double_click(buffer, mouse)
  mouse = mouse or vim.fn.getmousepos()
  local winid = mouse.winid
  if not winid or winid == 0 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local target_buf = vim.api.nvim_win_get_buf(winid)
  local context = buffer._folding_context(target_buf)
  if not context or not mouse.line or mouse.line < 1
    or not context.get_row_record(mouse.line) then
    return
  end

  if vim.api.nvim_get_current_win() ~= winid then
    vim.api.nvim_set_current_win(winid)
  end
  local line = vim.api.nvim_buf_get_lines(target_buf, mouse.line - 1, mouse.line, false)[1]
  if not line then return end
  local col = math.max(0, math.min((mouse.column or 1) - 1, #line))
  vim.api.nvim_win_set_cursor(winid, { mouse.line, col })
  return vim.api.nvim_win_call(winid, function()
    return require('direct').open()
  end)
end

local function expand_tree(buffer, context, start_ids)
  local configured_depth = require('direct.config').options.max_recursive_expand_depth
  local max_depth = configured_depth == false and math.huge or configured_depth
  local stack, ancestors = {}, {}
  for index = #start_ids, 1, -1 do
    stack[#stack + 1] = { id = start_ids[index], depth = 1 }
  end

  while #stack > 0 do
    local task = table.remove(stack)
    if task.exit then
      ancestors[task.key] = nil
    else
      local rec = context.get_record(task.id)
      if rec and context.is_directory(rec) then
        local identity = context.identity_for_record(rec)
        local key = identity and (identity.inode and ('inode:' .. identity.inode)
          or ('path:' .. identity.path)) or ('id:' .. tostring(rec.id))
        if not ancestors[key] then
          ancestors[key] = true
          local row = context.visible_row_for_id(task.id)
          if row then
            local ok, err = buffer:expand(row)
            if ok == nil then return nil, err end
            if context.is_expanded(task.id) and task.depth < max_depth then
              stack[#stack + 1] = { exit = true, key = key }
              local children = context.get_expanded_children(task.id)
              for index = #children, 1, -1 do
                local child = children[index]
                if context.is_directory(child) then
                  stack[#stack + 1] = { id = child.id, depth = task.depth + 1 }
                end
              end
            else
              ancestors[key] = nil
            end
          else
            ancestors[key] = nil
          end
        end
      end
    end
  end
  return true
end

local function get_context(buffer, bufnr)
  local context = buffer._folding_context(bufnr)
  if not context then
    return nil, 'directory state is unavailable'
  end
  return context
end

function M.expand_at(buffer, row, context)
  local rec = context.get_row_record(row)
  if not rec then return nil, 'row identity is unavailable' end
  if not context.is_directory(rec) then return false end
  return expand_tree(buffer, context, { rec.id })
end

function M.expand_recursive(buffer)
  local bufnr = vim.api.nvim_get_current_buf()
  local context, err = get_context(buffer, bufnr)
  if not context then return nil, err end
  return M.expand_at(buffer.restore(), vim.api.nvim_win_get_cursor(0)[1], context)
end

function M.toggle_recursive(buffer)
  local bufnr = vim.api.nvim_get_current_buf()
  local context, err = get_context(buffer, bufnr)
  if not context then return nil, err end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rec = context.get_row_record(row)
  if rec and context.is_expanded(rec.id) then
    return buffer.collapse()
  end
  return M.expand_at(buffer.restore(), row, context)
end

function M.expand_all(buffer)
  local bufnr = vim.api.nvim_get_current_buf()
  local context, err = get_context(buffer, bufnr)
  if not context then return nil, err end
  local starts = context.get_root_directory_ids()
  return expand_tree(buffer.restore(), context, starts)
end

function M.collapse_all(buffer)
  local bufnr = vim.api.nvim_get_current_buf()
  local context, err = get_context(buffer, bufnr)
  if not context then return nil, err end
  local first_error
  local attached = buffer.restore()
  for _, id in ipairs(context.get_root_directory_ids()) do
    if context.is_expanded(id) then
      local row = context.visible_row_for_id(id)
      if row then
        local ok, collapse_err = attached:collapse(row)
        if not ok and first_error == nil then first_error = collapse_err end
      end
    end
  end
  if first_error then return false, first_error end
  return true
end

return M
