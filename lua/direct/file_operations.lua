-- LSP workspace file-operation requests/notifications. Keep this independent of
-- buffers: workspace clients are not necessarily attached to the `acwrite` view.
local M = {}
local paths = require('direct.paths')

M._timeout_ms = 1200

local methods = {
  willRenameFiles = 'workspace/willRenameFiles',
  didCreateFiles = 'workspace/didCreateFiles',
  didRenameFiles = 'workspace/didRenameFiles',
  didDeleteFiles = 'workspace/didDeleteFiles',
}

local function canonical(path)
  if type(path) ~= 'string' then return nil end
  return paths.canonical(vim.fn.fnamemodify(path, ':p'))
end

local function under(path, root)
  path, root = canonical(path), canonical(root)
  if not path or not root then return false end
  root = root:gsub('/+$', '')
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

local function workspace_roots(client)
  local roots = {}
  for _, folder in ipairs(client.workspace_folders or {}) do
    if type(folder.uri) == 'string' then
      local ok, path = pcall(vim.uri_to_fname, folder.uri)
      if ok and path then roots[#roots + 1] = path end
    end
  end
  -- Workspace folders are the authoritative coverage when present. root_dir is
  -- only the compatibility fallback for clients that do not expose folders.
  if #roots == 0 and type(client.root_dir) == 'string' then roots[#roots + 1] = client.root_dir end
  return roots
end

local function workspace_paths(client, paths)
  local roots = workspace_roots(client)
  local result = {}
  for _, path in ipairs(paths) do
    for _, root in ipairs(roots) do
      if under(path, root) then
        result[#result + 1] = path
        break
      end
    end
  end
  return result
end

local function operation_field(method) return (method:match('([^/]+)$') or ''):gsub('Files$', '') end

local function supports(client, method)
  local field = operation_field(method)
  local workspace = client.server_capabilities and client.server_capabilities.workspace
  local operations = workspace and workspace.fileOperations
  local static = operations and operations[field]
  if static ~= nil and static ~= false then return true end
  local dynamic = client.dynamic_capabilities
  if dynamic and type(dynamic.get) == 'function' then
    local ok, registrations = pcall(dynamic.get, dynamic, method)
    if ok and type(registrations) == 'table' and next(registrations) ~= nil then return true end
  end
  return false
end

local function path_kind(path, kinds)
  if kinds and kinds[canonical(path)] then return kinds[canonical(path)] end
  local stat = vim.uv.fs_lstat(path)
  if not stat then return 'file' end
  return stat.type == 'directory' and 'folder' or 'file'
end

local function glob_match(glob, path, root)
  if type(glob) ~= 'string' or glob == '' then return true end
  local relative = path
  if root and under(path, root) then relative = path:sub(#canonical(root):gsub('/+$', '') + 2) end
  local ok, matcher = pcall(vim.glob.to_lpeg, glob)
  if not ok or not matcher then return false end
  return matcher:match(relative) ~= nil or matcher:match(path) ~= nil
end

local function filter_matches(filter, path, roots, kinds)
  if type(filter) ~= 'table' then return true end
  if filter.scheme and filter.scheme ~= 'file' then return false end
  local kind = path_kind(path, kinds)
  local pattern = filter.pattern
  if type(pattern) ~= 'table' then return true end
  if pattern.matches and pattern.matches ~= kind then return false end
  local glob = pattern.glob
  if not glob then return true end
  for _, root in ipairs(roots) do
    if glob_match(glob, path, root) then return true end
  end
  return glob_match(glob, path, nil)
end

local function filters_for(client, method)
  local field = operation_field(method)
  local operations = client.server_capabilities
    and client.server_capabilities.workspace
    and client.server_capabilities.workspace.fileOperations
  local capability = operations and operations[field]
  if type(capability) == 'table' and type(capability.filters) == 'table' then return capability.filters end
  -- Dynamic file-operation registrations are available through
  -- dynamic_capabilities:get on current Neovim; older clients may expose the
  -- registration table directly.
  local registrations
  local dynamic = client.dynamic_capabilities
  if dynamic and type(dynamic.get) == 'function' then
    local ok, result = pcall(dynamic.get, dynamic, method)
    if ok and type(result) == 'table' then registrations = result end
  end
  registrations = registrations or client.registrations
  if type(registrations) == 'table' then
    local result, has_filters = {}, false
    for _, registration in pairs(registrations) do
      local options = type(registration) == 'table' and registration.registerOptions
      if
        type(registration) == 'table'
        and registration.method == method
        and type(options) == 'table'
        and type(options.filters) == 'table'
      then
        -- An explicitly empty array denies every path; only missing filter
        -- information falls through to the protocol's unrestricted behavior.
        has_filters = true
        for _, filter in ipairs(options.filters) do
          result[#result + 1] = filter
        end
      end
    end
    if has_filters then return result end
  end
  return nil
end

local function filter_paths(client, method, paths, kinds)
  local roots = workspace_roots(client)
  local filters = filters_for(client, method)
  local result = {}
  for _, path in ipairs(paths) do
    local matches = filters == nil
    for _, filter in ipairs(filters or {}) do
      if filter_matches(filter, path, roots, kinds) then
        matches = true
        break
      end
    end
    if matches then result[#result + 1] = canonical(path) end
  end
  return result
end

local function client_list()
  if type(vim.lsp.get_clients) == 'function' then
    local ok, clients = pcall(vim.lsp.get_clients)
    if ok and type(clients) == 'table' then return clients end
  end
  return {}
end

function M.clients(method, paths, kinds)
  local full_paths = {}
  for _, path in ipairs(paths or {}) do
    local full = canonical(path)
    if full then full_paths[#full_paths + 1] = full end
  end
  local selected = {}
  for _, client in ipairs(client_list()) do
    if supports(client, method) then
      local scoped = workspace_paths(client, full_paths)
      if #scoped > 0 then
        local filtered = filter_paths(client, method, scoped, kinds)
        if #filtered > 0 then
          selected[#selected + 1] = {
            client = client,
            paths = filtered,
            workspace_paths = scoped,
          }
        end
      end
    end
  end
  table.sort(selected, function(a, b) return (a.client.id or 0) < (b.client.id or 0) end)
  return selected
end

function M.notify(kind, paths, pairs, kinds)
  local method = methods[kind]
  if not method then return end
  local entries = {}
  for _, path in ipairs(paths or {}) do
    entries[#entries + 1] = canonical(path)
  end
  local involved = {}
  for _, path in ipairs(paths or {}) do
    involved[#involved + 1] = path
  end
  for _, pair in ipairs(pairs or {}) do
    involved[#involved + 1] = pair.src
    involved[#involved + 1] = pair.dst
  end
  for _, selected in ipairs(M.clients(method, involved, kinds)) do
    local allowed = {}
    local filterset = {}
    for _, path in ipairs(selected.paths) do
      filterset[path] = true
    end
    local workspace_set = {}
    for _, path in ipairs(selected.workspace_paths) do
      workspace_set[path] = true
    end
    if kind == 'didRenameFiles' then
      for _, pair in ipairs(pairs or {}) do
        local src, dst = canonical(pair.src), canonical(pair.dst)
        if workspace_set[src] and workspace_set[dst] and (filterset[src] or filterset[dst]) then
          allowed[#allowed + 1] = {
            oldUri = vim.uri_from_fname(canonical(pair.src)),
            newUri = vim.uri_from_fname(canonical(pair.dst)),
          }
        end
      end
    else
      for _, path in ipairs(entries) do
        if filterset[canonical(path)] then allowed[#allowed + 1] = { uri = vim.uri_from_fname(canonical(path)) } end
      end
    end
    if #allowed > 0 and type(selected.client.notify) == 'function' then
      local params = { files = allowed }
      local ok, err = pcall(selected.client.notify, selected.client, method, params)
      if not ok then
        require('direct.ui').report_error(
          'notify the language server about ' .. operation_field(method),
          err,
          vim.log.levels.WARN
        )
      end
    end
  end
end

local function resource_paths(edit)
  local seen = {}
  for _, change in ipairs(edit and edit.documentChanges or {}) do
    if type(change) == 'table' and change.kind then
      if change.kind == 'rename' then
        for _, uri in ipairs({ change.oldUri, change.newUri }) do
          local ok, path = pcall(vim.uri_to_fname, uri)
          if ok and path then seen[canonical(path)] = true end
        end
      elseif change.uri then
        local ok, path = pcall(vim.uri_to_fname, change.uri)
        if ok and path then seen[canonical(path)] = true end
      end
    end
  end
  return seen
end

-- Neovim's apply_workspace_edit intentionally has no success return value.
-- Its rename helper can skip work and CreateFile silently ignores io.open('w')
-- failures. Model expected resource state before applying and verify it after,
-- rather than treating pcall(true, nil) as success. For an existing non-empty
-- CreateFile overwrite, verify truncation to zero bytes. If the file is already
-- empty, the API offers no reliable way to distinguish a successful overwrite
-- from a silent no-op, so fail closed during preflight.
local function resource_expectations(edit)
  local states, sizes, verify_sizes, expected = {}, {}, {}, {}
  local function state(path)
    path = canonical(path)
    if states[path] == nil then
      local stat = vim.uv.fs_lstat(path)
      states[path] = stat and stat.type or false
      sizes[path] = stat and stat.size or false
    end
    return states[path]
  end
  local function remember(path)
    path = canonical(path)
    expected[path] = {
      type = states[path],
      size = verify_sizes[path] and sizes[path] or nil,
    }
  end
  for index, change in ipairs(edit and edit.documentChanges or {}) do
    if type(change) == 'table' then
      if change.kind == 'rename' then
        local old_ok, old_path = pcall(vim.uri_to_fname, change.oldUri)
        local new_ok, new_path = pcall(vim.uri_to_fname, change.newUri)
        if not old_ok or not new_ok then return nil, ('documentChanges[%d] has an invalid rename URI'):format(index) end
        old_path, new_path = canonical(old_path), canonical(new_path)
        local options = change.options or {}
        if old_path ~= new_path then
          local old_type, new_type = state(old_path), state(new_path)
          if old_type == false then
            return nil, ('documentChanges[%d] rename source is missing: %s'):format(index, old_path)
          end
          if new_type ~= false then
            -- util.rename skips occupied targets unless overwrite is set. Even
            -- when ignoreIfExists was requested, an unapplied edit must not be
            -- mistaken for approval to continue with Direct's own rename.
            if options.overwrite and options.ignoreIfExists then
              return nil,
                ('documentChanges[%d] rename has conflicting overwrite and ignoreIfExists options'):format(index)
            end
            if not options.overwrite or options.ignoreIfExists then
              return nil, ('documentChanges[%d] rename destination is occupied: %s'):format(index, new_path)
            end
          end
          local old_size, old_verify_size = sizes[old_path], verify_sizes[old_path]
          states[old_path], states[new_path] = false, old_type
          sizes[old_path], sizes[new_path] = false, old_size
          verify_sizes[old_path], verify_sizes[new_path] = nil, old_verify_size
          remember(old_path)
          remember(new_path)
        end
      elseif change.kind == 'create' or change.kind == 'delete' then
        local ok, path = pcall(vim.uri_to_fname, change.uri)
        if not ok then return nil, ('documentChanges[%d] has an invalid resource URI'):format(index) end
        path = canonical(path)
        if change.kind == 'create' then
          local options = change.options or {}
          local current = state(path)
          if current ~= false then
            -- LSP/Neovim semantics give overwrite precedence when both flags
            -- are present; ignoreIfExists applies only without overwrite.
            if options.overwrite then
              if current ~= 'file' then
                return nil, ('documentChanges[%d] CreateFile overwrite target is not a file: %s'):format(index, path)
              end
              if sizes[path] == 0 then
                return nil,
                  ('documentChanges[%d] CreateFile overwrite of an already-empty file cannot be verified with Neovim apply_workspace_edit: %s'):format(
                    index,
                    path
                  )
              end
              states[path] = 'file'
              sizes[path], verify_sizes[path] = 0, true
              remember(path)
            elseif options.ignoreIfExists then
              -- Protocol-defined no-op: preserve the existing entry's actual
              -- type and verify that it remains unchanged after application.
              remember(path)
            else
              return nil, ('documentChanges[%d] CreateFile target already exists: %s'):format(index, path)
            end
          else
            states[path] = 'file'
            sizes[path] = 0
            remember(path)
          end
        elseif change.kind == 'delete' then
          local options = change.options or {}
          local current = state(path)
          if current == false and options.ignoreIfNotExists ~= true then
            return nil, ('documentChanges[%d] DeleteFile target does not exist: %s'):format(index, path)
          end
          if current ~= false then
            states[path], sizes[path], verify_sizes[path] = false, false, nil
          end
          -- A missing target with ignoreIfNotExists is a successful no-op; keep
          -- its absent state as a postcondition just like a successful delete.
          remember(path)
        end
      end
    end
  end
  return function()
    for path, expectation in pairs(expected) do
      local stat = vim.uv.fs_lstat(path)
      local actual_type = stat and stat.type or false
      if actual_type ~= expectation.type then
        return nil,
          ('resource operation postcondition failed for %s (expected %s, got %s)'):format(
            path,
            tostring(expectation.type),
            tostring(actual_type)
          )
      end
      if expectation.size ~= nil and (not stat or stat.size ~= expectation.size) then
        return nil,
          ('resource operation postcondition failed for %s (expected file size %d, got %s)'):format(
            path,
            expectation.size,
            tostring(stat and stat.size or 'missing')
          )
      end
    end
    return true
  end
end

local function stale_document_edit(edit)
  for index, change in ipairs(edit and edit.documentChanges or {}) do
    local document = type(change) == 'table' and change.textDocument
    local version = document and document.version
    if document and version ~= nil and version ~= vim.NIL and version > 0 and not (index and index > 1) then
      local ok, bufnr = pcall(vim.uri_to_bufnr, document.uri)
      local current = ok and vim.lsp.util.buf_versions[bufnr] or nil
      if type(current) == 'number' and current > version then
        return ('documentChanges[%d] is stale (buffer version %d exceeds edit version %d)'):format(
          index,
          current,
          version
        )
      end
    end
  end
end

-- Neovim's apply_text_edits prompts through vim.fn.confirm but returns no
-- indication that the user declined. Confirm annotated text-edit groups before
-- calling apply_workspace_edit, then clear those flags on a copy so Neovim does
-- not prompt a second time. This uses the public LSP changeAnnotations fields
-- and leaves the process-wide vim.fn.confirm untouched.
local function confirm_workspace_edit(edit)
  local groups = {}
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if type(change) == 'table' and not change.kind then groups[#groups + 1] = change.edits or {} end
    end
  else
    for _, edits in pairs(edit.changes or {}) do
      groups[#groups + 1] = edits
    end
  end

  local annotations = edit.changeAnnotations or {}
  local approved = {}
  for _, edits in ipairs(groups) do
    local confirmations = {}
    for _, text_edit in ipairs(edits) do
      local id = text_edit.annotationId
      if id ~= nil then
        local annotation = annotations[id]
        if type(annotation) ~= 'table' then
          return nil, 'annotated WorkspaceEdit is missing change annotation: ' .. tostring(id)
        end
        if annotation.needsConfirmation then confirmations[id] = (confirmations[id] or 0) + 1 end
      end
    end

    if next(confirmations) then
      local message = { 'Apply all changes?' }
      for id, count in pairs(confirmations) do
        local annotation = annotations[id]
        message[#message + 1] = annotation.label
          .. (annotation.description and (': ' .. annotation.description) or '')
          .. (count > 1 and string.format(' (%d)', count) or '')
      end
      if vim.fn.confirm(table.concat(message, '\n'), '&Yes\n&No', 1, 'Question') ~= 1 then
        return false, 'WorkspaceEdit changes were not confirmed'
      end
      for id in pairs(confirmations) do
        approved[id] = true
      end
    end
  end

  if next(approved) == nil then return edit end
  local confirmed_edit = vim.deepcopy(edit)
  for id in pairs(approved) do
    confirmed_edit.changeAnnotations[id].needsConfirmation = false
  end
  return confirmed_edit
end

function M.will_rename(files, callback, warn, is_active)
  local paths = {}
  for _, file in ipairs(files or {}) do
    paths[#paths + 1] = vim.uri_to_fname(file.oldUri)
    paths[#paths + 1] = vim.uri_to_fname(file.newUri)
  end
  local selected_clients = M.clients(methods.willRenameFiles, paths)
  local clients = {}
  for _, selected in ipairs(selected_clients) do
    local filterset, workspace_set, client_files = {}, {}, {}
    for _, path in ipairs(selected.paths) do
      filterset[canonical(path)] = true
    end
    for _, path in ipairs(selected.workspace_paths) do
      workspace_set[canonical(path)] = true
    end
    for _, file in ipairs(files or {}) do
      local ok_src, src = pcall(vim.uri_to_fname, file.oldUri)
      local ok_dst, dst = pcall(vim.uri_to_fname, file.newUri)
      local src_path, dst_path = ok_src and canonical(src), ok_dst and canonical(dst)
      if
        src_path
        and dst_path
        and workspace_set[src_path]
        and workspace_set[dst_path]
        and (filterset[src_path] or filterset[dst_path])
      then
        client_files[#client_files + 1] = file
      end
    end
    if #client_files > 0 then clients[#clients + 1] = { client = selected.client, files = client_files } end
  end
  if #clients == 0 then
    callback(true, {})
    return false
  end
  local pending, responses = #clients, {}
  local settled = false
  local cancelled = false
  local requests = {}
  local function cancel_requests()
    for _, request in pairs(requests) do
      if request.id ~= nil and type(request.client.cancel_request) == 'function' then
        pcall(request.client.cancel_request, request.client, request.id)
      end
    end
    requests = {}
  end
  local function cancel()
    if settled or cancelled then return false end
    cancelled, settled = true, true
    cancel_requests()
    return true
  end
  local function active() return not cancelled and (not is_active or is_active()) end
  local function deliver(ok, value)
    if settled or not active() then
      if not settled then cancel() end
      return false
    end
    settled = true
    cancel_requests()
    callback(ok, value)
    return true
  end
  local function warning(client, reason)
    local client_id = tostring(client and client.id or 'unknown')
    local message = require('direct.ui').error_message(
      'check with the language server before renaming (client ' .. client_id .. ')',
      reason
    )
    if warn then
      pcall(warn, message)
    else
      pcall(require('direct.ui').notify, message, vim.log.levels.WARN)
    end
  end
  local function finish()
    if settled or pending > 0 then return end
    if not active() then
      cancel()
      return
    end
    local processing_client
    local ok, outcome, value = xpcall(function()
      table.sort(responses, function(a, b) return (a.client.id or 0) < (b.client.id or 0) end)
      local suppressed = {}
      for _, response in ipairs(responses) do
        processing_client = response.client
        if not active() then
          cancel()
          return nil
        end
        if response.edit ~= nil then
          local verify, preflight_err = resource_expectations(response.edit)
          if not verify then return false, tostring(preflight_err) end
          local stale_err = stale_document_edit(response.edit)
          if stale_err then return false, tostring(stale_err) end
          local edit, confirm_err = confirm_workspace_edit(response.edit)
          if edit == false then return false, confirm_err end
          if edit == nil then return false, confirm_err end
          local applied, result = pcall(function()
            if not active() then
              cancel()
              return nil
            end
            return vim.lsp.util.apply_workspace_edit(edit, response.client.offset_encoding or 'utf-16')
          end)
          if settled then return nil end
          if not applied then return false, tostring(result) end
          if result == false then return false, 'workspace edit application failed' end
          local verified, verify_err = verify()
          if not verified then return false, tostring(verify_err) end
          for path in pairs(resource_paths(response.edit)) do
            suppressed[path] = true
          end
        end
      end
      return true, suppressed
    end, debug.traceback)
    if not ok then
      warning(processing_client, outcome)
      deliver(false, tostring(outcome))
    elseif outcome ~= nil then
      if not outcome then warning(processing_client, value) end
      deliver(outcome, value)
    end
  end
  local function complete(index, err, edit)
    local response = responses[index]
    if not response or response.done then return end
    response.done = true
    requests[index] = nil
    if err then warning(response.client, err.message or err) end
    if edit ~= nil and edit ~= vim.NIL then responses[index].edit = edit end
    pending = pending - 1
    finish()
  end
  for index, selected in ipairs(clients) do
    local response = { client = selected.client }
    responses[index] = response
    local client = selected.client
    requests[index] = { client = client }
    if type(client.request) ~= 'function' then
      complete(index, 'client has no request method')
    else
      local ok, started, request_id = pcall(
        client.request,
        client,
        methods.willRenameFiles,
        { files = vim.deepcopy(selected.files) },
        function(err, edit) complete(index, err, edit) end
      )
      if ok and started ~= false and started ~= nil then
        local request = requests[index]
        if request and not response.done and not settled then request.id = request_id end
      end
      if not ok or started == false or started == nil then
        complete(index, ok and (request_id or 'request was not started') or started)
      else
        vim.defer_fn(function()
          if response.done or settled then return end
          if request_id ~= nil and type(client.cancel_request) == 'function' then
            pcall(client.cancel_request, client, request_id)
            requests[index] = nil
          end
          complete(index, 'request timed out after ' .. tostring(M._timeout_ms) .. ' ms')
        end, M._timeout_ms or 1200)
      end
    end
  end
  return cancel
end

local function notify_safely(...)
  local ok, err = pcall(M.notify, ...)
  if not ok then
    pcall(
      require('direct.ui').report_error,
      'send file-operation notifications to language servers',
      err,
      vim.log.levels.WARN
    )
  end
end

function M.emit_actions(actions, applied, suppressed)
  local creates, deletes, renames = {}, {}, {}
  local kinds = {}
  local function mark(path, kind)
    if path and kind then kinds[canonical(path)] = kind end
  end
  local function add(action)
    if action.name == 'g' then
      local completed = action._completed_actions or action.actions or {}
      for _, member in ipairs(completed) do
        add(member)
      end
    elseif action.name == 'touch' or action.name == 'mkdir' then
      creates[#creates + 1] = action.dst
      mark(action.dst, action.name == 'mkdir' and 'folder' or 'file')
    elseif action.name == 'rm' or action.name == 'rmdir' then
      deletes[#deletes + 1] = action.src
      mark(action.src, action.name == 'rmdir' and 'folder' or 'file')
    elseif action.name == 'mv' then
      renames[#renames + 1] = { src = action.src, dst = action.dst }
      local stat = require('direct.fs').stat(action.dst) or require('direct.fs').stat(action.src)
      mark(action.src, stat and stat.type == 'directory' and 'folder' or 'file')
      mark(action.dst, stat and stat.type == 'directory' and 'folder' or 'file')
    elseif action.name == 'rs' or action.name == 'rsdir' then
      creates[#creates + 1] = action.dst
      mark(action.dst, action.name == 'rsdir' and 'folder' or 'file')
    elseif action.name == 'p' then
      for _, pair in ipairs(action.renames or {}) do
        local path = require('direct.fs').join(action.dst, pair.dst)
        creates[#creates + 1] = path
        local source = require('direct.fs').join(action.src, pair.src)
        local stat = require('direct.fs').stat(source)
        mark(path, stat and stat.type == 'directory' and 'folder' or 'file')
      end
    elseif action.name == 'up' then
      local completed = action._completed_renames or action.renames or {}
      for _, pair in ipairs(completed) do
        local path = require('direct.fs').join(action.src, pair.src)
        deletes[#deletes + 1] = path
        local source = require('direct.fs').join(action.dst, pair.dst)
        local stat = require('direct.fs').stat(source)
        mark(path, stat and stat.type == 'directory' and 'folder' or 'file')
      end
    end
  end
  for index, action in ipairs(actions or {}) do
    local partial = action._completed_actions and #action._completed_actions > 0
      or action._completed_renames and #action._completed_renames > 0
    if applied == nil or applied[index] or partial then add(action) end
  end
  local function keep(path) return not (suppressed and suppressed[canonical(path)]) end
  local function filter(list)
    local result = {}
    for _, path in ipairs(list) do
      if keep(path) then result[#result + 1] = path end
    end
    return result
  end
  creates, deletes = filter(creates), filter(deletes)
  local filtered_renames = {}
  for _, pair in ipairs(renames) do
    if not (suppressed and suppressed[canonical(pair.src)] and suppressed[canonical(pair.dst)]) then
      filtered_renames[#filtered_renames + 1] = pair
    end
  end
  renames = filtered_renames
  if #creates > 0 then notify_safely('didCreateFiles', creates, nil, kinds) end
  if #deletes > 0 then notify_safely('didDeleteFiles', deletes, nil, kinds) end
  if #renames > 0 then notify_safely('didRenameFiles', nil, renames, kinds) end
end

return M
