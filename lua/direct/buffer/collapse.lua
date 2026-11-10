-- Project filtered directory chains as a single editable path row.
return function(deps)
  local paths = deps.paths
  local fs = deps.fs
  local entry_path = deps.entry_path
  local list_with_snapshot = deps.list_with_snapshot
  local filter_git_status_lines = deps.filter_git_status_lines
  local get_directory_snapshot = deps.get_directory_snapshot
  local apply_snapshot = deps.apply_snapshot
  local is_dir_line = deps.is_dir_line
  local dirs_then_name = deps.dirs_then_name

  return function(root, lines, options)
    local rendered, components_by_line, snapshots = {}, {}, {}

    local function children_for(directory)
      local children, snapshot, err
      if options.capture then
        children, snapshot, err = list_with_snapshot(directory, options.show_hidden, options.respect_gitignore)
        if not children then return nil, err end
        snapshots[#snapshots + 1] = snapshot
      else
        snapshot = get_directory_snapshot(options.state, directory)
        if snapshot then
          local physical
          physical, err = fs.read_dir_lines(directory)
          if not physical then return nil, err end
          children, err = apply_snapshot(directory, physical, snapshot)
          if not children then return nil, err end
        else
          -- A newly appeared directory has no saved filter context. Inspect it
          -- only so sync can reject the external change safely.
          children, snapshot, err = list_with_snapshot(directory, options.show_hidden, options.respect_gitignore)
          if not children then return nil, err end
        end
      end
      if options.status_only then children = filter_git_status_lines(directory, children, options.git_status) end
      return children
    end

    local function render_chain(path, entry_name, components, deleted)
      local name = paths.strip_directory_marker(entry_name)
      local is_directory = is_dir_line(entry_name)
      local next_components = vim.deepcopy(components)
      next_components[#next_components + 1] = {
        name = name,
        directory = is_directory,
      }
      local function append_current()
        local line = table.concat(vim.tbl_map(function(item) return item.name end, next_components), '/')
        if is_directory then line = paths.mark_directory(line) end
        rendered[#rendered + 1] = line
        components_by_line[line] = next_components
        return true
      end
      if not is_directory or deleted then return append_current() end

      local directory = paths.strip_trailing_separator(path)
      local children, err = children_for(directory)
      if not children then
        if options.capture then return append_current() end
        return nil, err
      end
      if #children == 1 then
        local child = children[1]
        return render_chain(entry_path(directory, child), child, next_components, false)
      end
      return append_current()
    end

    for _, line in ipairs(lines or {}) do
      local path = entry_path(root, line)
      local deleted = options.deleted_paths and options.deleted_paths[vim.fs.normalize(path)] ~= nil
      local ok, err = render_chain(path, line, {}, deleted)
      if not ok then return nil, nil, nil, err end
    end

    local ordered = dirs_then_name(rendered)
    local components = {}
    for index, line in ipairs(ordered) do
      components[index] = components_by_line[line]
    end
    return ordered, components, snapshots
  end
end
