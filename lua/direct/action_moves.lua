-- Move-group planning and execution for interdependent filesystem renames.
-- The action facade is injected to keep action factories acyclic.
return function(M)
  -- ---------------------------------------------------------------------------
  -- Interlinked moves: staging, grouping, group reversal
  -- ---------------------------------------------------------------------------

  -- parent_dir(path) -> the directory the staging temp for `path` belongs in. The
  -- trailing filesystem separator of a directory path is stripped BEFORE the
  -- parent is taken
  -- `vim.fs.dirname('/ws/old/')` is '/ws/old', not '/ws' (measured on 0.12.5), so
  -- it cannot be used here. Every entry staged for one sync belongs to the sync
  -- root, so the temp spelling is exactly the `<root>/.direct-tmp-<n>` the save
  -- has always used -- and because the temp is created in the entry's OWN
  -- directory, the staging rename can never cross a filesystem.
  local function parent_dir(path)
    local trimmed = M.paths.strip_trailing_separator(tostring(path))
    return M.paths.dirname(trimmed)
  end

  -- first_free_temp(dir) -> the first free `<dir>/.direct-tmp-<n>`.
  function M.first_free_temp(dir)
    local n = 1
    local candidate = M.fs.join(dir, '.direct-tmp-' .. n)
    while M.fs.taken(candidate) do
      n = n + 1
      candidate = M.fs.join(dir, '.direct-tmp-' .. n)
    end
    return candidate
  end

  -- stage_moves(actions) -> { overrides = { src -> tmp }, temps = { tmp },
  -- identities = { src -> identity } } when a
  -- rename `dst` is also some action's `src` (a swap, a chain or a rotation), else
  -- nil. Only `mv` actions participate. A staging rename failure returns
  -- `nil, err, temps, overrides, identities`, where `temps` are the entries
  -- ALREADY renamed to temp paths and `identities` records the staged inodes. The
  -- caller must verify identity and restore only with no-replace, or report any
  -- stranded path instead of deleting it.
  -- The caller executes each Move from `overrides[src]` when present, while
  -- history records keep the original action paths, never staging temps.
  --
  -- Journaled execution and the standalone Group executor share this plan.
  function M.stage_moves(actions)
    local steps, staging_count = M.plan_move_steps(actions)
    if not steps then return nil, staging_count end
    if staging_count == 0 then return nil end
    local overrides, temps, identities = {}, {}, {}
    for index = 1, staging_count do
      local step = steps[index]
      local ok, err = M.fs.rename(step.src, step.dst)
      if not ok then
        return nil, err, temps, overrides, identities
      end
      overrides[step.src] = step.dst
      identities[step.src] = step.identity
      temps[#temps + 1] = step.dst
    end
    return { overrides = overrides, temps = temps, identities = identities }
  end

  -- plan_move_steps(actions) produces the exact staging and final rename sequence
  -- without changing the filesystem. History persists this plan before executing
  -- a group, so restart recovery never has to guess staging names.
  function M.plan_move_steps(actions)
    actions = actions or {}
    local move_key = function(path)
      return type(path) == 'string' and M.paths.strip_trailing_separator(path) or path
    end
    local destinations, destinations_by_inode = {}, {}
    for _, act in ipairs(actions) do
      if act.name == 'mv' and act.dst ~= nil then
        local destination = move_key(act.dst)
        destinations[destination] = true
        local identity = M.fs.entry_identity(destination)
        if identity and identity.inode then
          local bucket = destinations_by_inode[identity.inode] or {}
          destinations_by_inode[identity.inode] = bucket
          bucket[#bucket + 1] = destination
        end
      end
    end

    local function shares_destination(path)
      path = move_key(path)
      if destinations[path] then return true end
      local identity = M.fs.entry_identity(path)
      local bucket = identity and identity.inode and destinations_by_inode[identity.inode]
      for _, destination in ipairs(bucket or {}) do
        if M.fs.same_entry(path, destination) then return true end
      end
      return false
    end

    local stage_sources = {}
    for _, act in ipairs(actions) do
      if act.name == 'mv' and act.src ~= nil and shares_destination(act.src) then
        stage_sources[move_key(act.src)] = true
      end
    end

    local overrides, staged_identities, reserved = {}, {}, {}
    local stages = {}
    for _, act in ipairs(actions) do
      if act.name == 'mv' and act.src ~= nil and stage_sources[move_key(act.src)]
        and overrides[act.src] == nil then
        local parent = parent_dir(act.src)
        local tmp = M.first_free_temp(parent)
        while reserved[tmp] do
          local suffix = tonumber(tmp:match('%.direct%-tmp%-(%d+)$')) or 0
          tmp = M.fs.join(parent, '.direct-tmp-' .. (suffix + 1))
        end
        reserved[tmp] = true
        local identity, stat = M.fs.entry_identity(act.src)
        if not stat or not identity or not identity.inode then
          return nil, 'cannot identify grouped move source: ' .. tostring(act.src)
        end
        overrides[act.src] = tmp
        staged_identities[act.src] = identity
        stages[#stages + 1] = {
          src = act.src, dst = tmp,
          identity = { path = M.paths.canonical(act.src), inode = identity.inode },
        }
      end
    end

    local steps = {}
    for _, stage in ipairs(stages) do steps[#steps + 1] = stage end
    for _, act in ipairs(actions) do
      if act.name ~= 'mv' or type(act.src) ~= 'string'
        or type(act.dst) ~= 'string' then
        return nil, 'grouped move plan contains a non-move action'
      end
      local src = overrides[act.src] or act.src
      local identity = staged_identities[act.src]
        or M.fs.entry_identity(act.src)
      if not identity or not identity.inode then
        return nil, 'cannot identify grouped move source: ' .. tostring(act.src)
      end
      steps[#steps + 1] = {
        src = src, dst = act.dst,
        identity = { path = M.paths.canonical(src), inode = identity.inode },
      }
    end
    return steps, #stages
  end

  -- move_groups(actions) -> an ordered partition of the action list into the
  -- groups history records together. Two `mv` actions belong together when one's
  -- `dst` is the other's `src` (transitively): that link is exactly what makes a
  -- one-action-at-a-time rename unsafe, because the destination of one move still
  -- has to be read by another. Every other action -- a Touch, a
  -- MakeDirectory, a Remove, a Paste/Unpaste, or a `mv` sharing no name with
  -- another -- is its own single-action group.
  --
  -- What the UI can produce and what it therefore groups: a two-file swap (a
  -- 2-cycle), an N-way rotation (a cycle of length > 2, from permuting the
  -- equal-length listing), and an open chain (a -> b ->..., when the permutation
  -- consumes a fresh name at its tail). Two moves that share no name stay two
  -- entries. In a RENAME plan the `src` names are distinct and the `dst` names are
  -- distinct (the duplicate check runs first), so a shared name links at most two
  -- moves and the components are paths and cycles.
  --
  -- Returns { { <index>,... },... }: groups in ascending first-index order
  -- every action index exactly once, a group of one being an independent action.
  function M.move_groups(actions)
    actions = actions or {}
    local function move_key(path)
      return type(path) == 'string' and M.paths.strip_trailing_separator(path) or path
    end
    local parent = {}
    for i = 1, #actions do
      parent[i] = i
    end
    local function root(i)
      while parent[i] ~= i do
        parent[i] = parent[parent[i]]
        i = parent[i]
      end
      return i
    end
    local at_path, at_inode = {}, {}
    for i, act in ipairs(actions) do
      local paths = {}
      if type(act.src) == 'string' then
        paths[#paths + 1] = act.src
      end
      if type(act.dst) == 'string' then
        paths[#paths + 1] = act.dst
      end
      if act.name == 'mv' then
        for _, path in ipairs(paths) do
          path = move_key(path)
          local exact = at_path[path]
          for _, previous in ipairs(exact or {}) do
            local a, b = root(previous), root(i)
            if a ~= b then parent[b] = a end
          end
          local identity = M.fs.entry_identity(path)
          local bucket = identity and identity.inode and at_inode[identity.inode]
          for _, previous in ipairs(bucket or {}) do
            if M.fs.same_entry(path, previous.path) then
              local a, b = root(previous.index), root(i)
              if a ~= b then parent[b] = a end
            end
          end
          if not exact then
            exact = {}
            at_path[path] = exact
          end
          exact[#exact + 1] = i
          if identity and identity.inode then
            local inode_entries = at_inode[identity.inode]
            if not inode_entries then
              inode_entries = {}
              at_inode[identity.inode] = inode_entries
            end
            inode_entries[#inode_entries + 1] = { path = path, index = i }
          end
        end
      end
    end
    local groups, at_root = {}, {}
    for i = 1, #actions do
      local r = root(i)
      if at_root[r] == nil then
        at_root[r] = {}
        groups[#groups + 1] = at_root[r]
      end
      at_root[r][#at_root[r] + 1] = i
    end
    return groups
  end

  -- Group(actions) -- the interlinked `mv` actions of one sync, recorded and
  -- reversed as ONE history entry. `do` reuses `M.stage_moves`, so a group
  -- reversal is staged exactly like the save that created it. A staging failure
  -- attempts to unwind landed staging renames with atomic no-replace operations.
  -- This prevents overwriting a destination created concurrently. If restoration
  -- is unsafe or unsupported, the entry stays at its reported temp path and the
  -- history entry is retained for retry after manual recovery.
  --
  -- The name `g` never collides with an action name: every other serialized line
  -- starts with the name of a single-entry action. `describe` joins the member
  -- descriptions, so `summarize` still emits ONE summary per undo press.
  function M.Group(actions)
    local self = { name = 'g', _kind = 'g', actions = actions }
    local function report_temps(staging)
      for _, tmp in ipairs(staging ~= nil and staging.temps or {}) do
        if M.fs.taken(tmp) then
          M.ui.notify('direct: a failed move left the staged entry ' .. tmp,
            vim.log.levels.ERROR)
        end
      end
    end
    self._execute = function()
      local members = self.actions or {}
      self._completed_actions = {}
      local staging, stage_err, stage_temps, stage_overrides, stage_identities =
        M.stage_moves(members)
      if staging == nil and stage_err ~= nil then
        -- Restore only to an unoccupied original path with atomic no-replace
        -- rename. If that fails, leave and report the temp entry; retry only after
        -- manual recovery. The history entry remains available for that retry.
        local overrides = stage_overrides or {}
        local identities = stage_identities or {}
        local reported = {}
        for _, act in ipairs(members) do
          local tmp = act.src ~= nil and overrides[act.src] or nil
          if tmp ~= nil and M.fs.taken(tmp) then
            local expected = identities[act.src]
            local rok, rerr = M.fs.rename_noreplace(tmp, act.src, expected)
            if not rok then
              reported[tmp] = true
              local occupied = M.fs.taken(act.src)
              local cause = occupied and 'destination is occupied' or tostring(rerr)
              M.ui.notify('direct: could not restore staged entry ' .. tmp
                .. ' to ' .. tostring(act.src) .. ' (' .. cause
                .. '); temp preserved; manual recovery required before retry',
                vim.log.levels.ERROR)
            end
          end
        end
        for _, tmp in ipairs(stage_temps or {}) do
          if M.fs.taken(tmp) and not reported[tmp] then
            M.ui.notify('direct: a failed rename left the staged entry ' .. tmp,
              vim.log.levels.ERROR)
          end
        end
        return nil, 'could not stage renames: ' .. tostring(stage_err)
      end
      for _, act in ipairs(members) do
        local exec = act
        if staging ~= nil and act.name == 'mv'
          and staging.overrides[act.src] ~= nil then
          exec = M.Move(staging.overrides[act.src], act.dst)
        end
        local ok, res, err = pcall(M.execute, exec)
        if not ok then
          report_temps(staging)
          return nil, tostring(res)
        end
        if res == nil then
          report_temps(staging)
          return nil, err ~= nil and tostring(err) or 'action failed'
        end
        self._completed_actions[#self._completed_actions + 1] = act
      end
      return true
    end
    self['do'] = function() return M.execute(self) end
    function self.describe()
      local parts = {}
      for _, member in ipairs(self.actions or {}) do
        parts[#parts + 1] = M.describe_action(member)
      end
      return table.concat(parts, ', ')
    end
    return self
  end

  -- ---------------------------------------------------------------------------
end
