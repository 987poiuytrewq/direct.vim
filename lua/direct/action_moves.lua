-- Move-group planning and execution for interdependent filesystem renames.
-- The action facade is injected to keep action factories acyclic.
return function(M)
  -- ---------------------------------------------------------------------------
  -- Interlinked moves: staging, grouping, group reversal
  -- ---------------------------------------------------------------------------

  -- parent_dir(path) -> the directory the staging temp for `path` belongs in. The
  -- trailing slash of a directory line is stripped BEFORE the parent is taken
  -- `vim.fs.dirname('/ws/old/')` is '/ws/old', not '/ws' (measured on 0.12.5), so
  -- it cannot be used here. Every entry staged for one sync belongs to the sync
  -- root, so the temp spelling is exactly the `<root>/.direct-tmp-<n>` the save
  -- has always used -- and because the temp is created in the entry's OWN
  -- directory, the staging rename can never cross a filesystem.
  local function parent_dir(path)
    local trimmed = tostring(path):gsub('/+$', '')
    local dir = trimmed:match('^(.*)/[^/]*$')
    if dir == nil or dir == '' then
      return '/'
    end
    return dir
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
  -- `history.log` and `current_entry` keep using the original action, never a temp path.
  --
  -- This is the ONE staging mechanism: `Buffer:sync` applies a save through it and
  -- `M.Group` applies a group reversal through it, so the reversal of a swap gets
  -- exactly the protection the swap itself gets (the reported bug was that the
  -- reversal had none: it renamed a live name over a name whose contents had not
  -- been saved anywhere yet).
  function M.stage_moves(actions)
    actions = actions or {}
    local function move_key(path)
      return type(path) == 'string' and path:gsub('/+$', '') or path
    end
    local destinations, destinations_by_inode = {}, {}
    for _, act in ipairs(actions) do
      if act.name == 'mv' and act.dst ~= nil then
        local destination = move_key(act.dst)
        destinations[destination] = true
        local identity = M.fs.entry_identity(destination)
        if identity and identity.inode then
          local bucket = destinations_by_inode[identity.inode]
          if not bucket then
            bucket = {}
            destinations_by_inode[identity.inode] = bucket
          end
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
    local stage_sources, needed = {}, false
    for _, act in ipairs(actions) do
      if act.name == 'mv' and act.src ~= nil and shares_destination(act.src) then
        stage_sources[move_key(act.src)] = true
        needed = true
      end
    end
    if not needed then
      return nil
    end
    local overrides, temps, identities = {}, {}, {}
    for _, act in ipairs(actions) do
      if act.name == 'mv' and act.src ~= nil and stage_sources[move_key(act.src)]
        and overrides[act.src] == nil then
        local tmp = M.first_free_temp(parent_dir(act.src))
        local identity = M.fs.entry_identity(act.src)
        local ok, err = M.fs.rename(act.src, tmp)
        if not ok then
          -- return the temps accumulated so far ALONGSIDE the error
          -- (and the partial overrides that name each temp's original path), so
          -- the caller can report -- and, where it must, restore -- each entry
          -- that is now parked at a temp path instead of returning the error
          -- alone and orphaning them silently.
          return nil, err, temps, overrides, identities
        end
        overrides[act.src] = tmp
        identities[act.src] = identity
        temps[#temps + 1] = tmp
      end
    end
    return { overrides = overrides, temps = temps, identities = identities }
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
      return type(path) == 'string' and path:gsub('/+$', '') or path
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
