-- Buffer row identity, extmarks, and display rendering.
local M = {}

local states = {}
local namespace = vim.api.nvim_create_namespace('direct-listing-rows')
local ICON_NAMESPACE = 'direct-listing-icons'
local FOLDER_ICON_CLOSED = '\u{f024b}'
local FOLDER_ICON_OPEN = '\u{f0770}'
local FILE_ICON = '\u{f0214}'
local icon_namespace
local function next_id(state)
  state.next_id = (state.next_id or 0) + 1
  return state.next_id
end

local fs = require('direct.fs')
local listing = require('direct.buffer_listing')
local git = require('direct.git')

local function path_identity(path)
  return fs.path_identity(path, fs.stat(path))
end

local function set_row_mark(bufnr, row, id)
  vim.api.nvim_buf_set_extmark(bufnr, namespace, row, 0, {
    id = id,
    right_gravity = true,
    invalidate = true,
    undo_restore = true,
  })
end

local function row_id_at(bufnr, row)
  local state = states[bufnr]
  if not state then return nil end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace,
      { row, 0 }, { row, -1 }, { details = true })) do
    if mark[2] == row and not (mark[4] and mark[4].invalid) then
      return mark[1]
    end
  end
  return nil
end

local function refresh_display_ids(bufnr, state)
  local display_ids = {}
  for row = 0, vim.api.nvim_buf_line_count(bufnr) - 1 do
    local id = row_id_at(bufnr, row)
    if id then display_ids[#display_ids + 1] = id end
  end
  state.display_ids = display_ids
end

local function row_path(root, record, line)
  if not record then return nil end
  if record.kind == 'root' then
    return listing.entry_path(root, line)
  end
  return record.path
end

local function current_row_record(bufnr, row)
  local state = states[bufnr]
  local id = row_id_at(bufnr, row)
  return state and id and state.rows[id] or nil
end

-- is_dir_line(line) -> true for a directory entry. The trailing slash is the
-- convention: a directory is never distinguished from a file by a
-- filesystem stat here.
local function is_dir_line(line)
  return type(line) == 'string' and line:sub(-1) == '/'
end

-- Refresh display-only icons. When either kind is enabled, every row gets an
-- icon slot: rows whose icon is disabled receive a two-cell spacer so names
-- remain aligned. Buffer text and row identities are never changed here.
local function refresh_icons(bufnr, state)
  local options = require('direct.config').options
  local show_folders = options.show_folder_icons == true
  local show_files = options.show_file_icons == true
  if options.git.enabled and state.git_status == nil then
    state.git_status = git.read(state.root) or false
  end
  local git_snapshot = state.git_status
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  state.icon_line_count = line_count
  if not show_folders and not show_files then
    local existing = icon_namespace
      or vim.api.nvim_get_namespaces()[ICON_NAMESPACE]
    if existing then vim.api.nvim_buf_clear_namespace(bufnr, existing, 0, -1) end
    return
  end
  if not icon_namespace then
    icon_namespace = vim.api.nvim_create_namespace(ICON_NAMESPACE)
  end
  vim.api.nvim_buf_clear_namespace(bufnr, icon_namespace, 0, -1)
  for row = 0, line_count - 1 do
    local id = row_id_at(bufnr, row)
    local rec = id and state.rows[id]
    if rec then
      local is_folder = is_dir_line(rec.name)
      local enabled = is_folder and show_folders or (not is_folder and show_files)
      local glyph = '  '
      local group = 'Normal'
      local hidden = rec.name:sub(1, 1) == '.'
      local base_glyph
      local base_group
      if enabled and is_folder then
        base_glyph = state.expanded[id] and FOLDER_ICON_OPEN or FOLDER_ICON_CLOSED
        base_group = hidden and 'DirectHiddenFolderIcon' or 'DirectFolderIcon'
      elseif enabled then
        base_glyph = FILE_ICON
        base_group = hidden and 'DirectHiddenFileIcon' or 'DirectFileIcon'
      end
      if enabled then
        glyph, group = base_glyph, base_group
        local status = options.git.enabled and git_snapshot
          and git.status_for(git_snapshot, rec.path)
        local settings = status and options.git.statuses[status]
        if settings and (options.git.display == 'icon' or options.git.display == 'both') then
          group = settings.icon_hl or group
          if type(settings.icon) == 'string' then
            glyph = settings.icon
          elseif type(settings.icon) == 'table' then
            local variant = is_folder
              and (state.expanded[id] and 'folder_open' or 'folder') or 'file'
            glyph = settings.icon[variant] or settings.icon[is_folder and 'folder' or 'file']
              or glyph
          end
        end
      end
      vim.api.nvim_buf_set_extmark(bufnr, icon_namespace, row,
        (rec.depth or 0) * 2, {
          virt_text = { { glyph .. (enabled and ' ' or ''), group } },
          virt_text_pos = 'inline',
          right_gravity = false,
          hl_mode = 'combine',
        })
    end
  end
end

-- dirs_then_name(lines) -> a copy ordered directories first, each group sorted
-- ascending by byte-wise comparison. A directory line carries its
-- trailing '/', so the two groups never interleave.
local function dirs_then_name(lines)
  local dirs, files = {}, {}
  for _, line in ipairs(lines or {}) do
    if is_dir_line(line) then
      dirs[#dirs + 1] = line
    else
      files[#files + 1] = line
    end
  end
  table.sort(dirs)
  table.sort(files)
  local out = {}
  for _, line in ipairs(dirs) do
    out[#out + 1] = line
  end
  for _, line in ipairs(files) do
    out[#out + 1] = line
  end
  return out
end

local function recorded_row_text(rec)
  local name = rec.name
  if is_dir_line(name) then name = name:gsub('/+$', '') .. '/' end
  return string.rep('  ', rec.depth or 0) .. name
end

local function visible_row_for_id(bufnr, state, id)
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, id, {})
  if #mark == 0 then return nil end
  local row = mark[1] + 1
  return state.display_ids[row] == id and row or nil
end

local function remove_expanded_subtree(bufnr, state, parent_id)
  local expansion = state.expanded[parent_id]
  if not expansion then return end
  state.expanded[parent_id] = nil
  for _, child in ipairs(expansion.children or {}) do
    remove_expanded_subtree(bufnr, state, child.id)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, child.id)
    state.rows[child.id] = nil
  end
end

M.states = states
M.namespace = namespace
M.state_for_test = function(bufnr) return states[bufnr] end
M.next_id = next_id
M.set_row_mark = set_row_mark
M.row_id_at = row_id_at
M.refresh_display_ids = refresh_display_ids
M.row_path = row_path
M.current_row_record = current_row_record
M.is_dir_line = is_dir_line
M.refresh_icons = refresh_icons
M.dirs_then_name = dirs_then_name
M.recorded_row_text = recorded_row_text
M.visible_row_for_id = visible_row_for_id
M.remove_expanded_subtree = remove_expanded_subtree
M.record_identity = function(rec)
  if not rec then return nil end
  return rec.identity or path_identity(rec.path)
end

return M
