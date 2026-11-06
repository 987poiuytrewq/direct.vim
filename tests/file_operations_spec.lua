local H = require('tests.support.harness')
local operations = require('direct.file_operations')
local buffer = require('direct.buffer')
local pending = require('direct.pending')

-- How long to wait for asynchronous work (an LSP round trip, a deferred sync)
-- to finish. vim.wait returns as soon as the condition holds, so this only
-- bounds a real failure. Slow CI runners, Windows in particular, can take
-- more than a few hundred milliseconds.
local ASYNC_WAIT_MS = 3000

local function with_clients(clients, fn)
  local get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function() return clients end
  local ok, err = xpcall(fn, debug.traceback)
  vim.lsp.get_clients = get_clients
  if not ok then error(err) end
end

local function client(id, capabilities, root, request)
  return {
    id = id,
    server_capabilities = { workspace = {
      fileOperations = capabilities,
    } },
    workspace_folders = root and {
      { name = root, uri = vim.uri_from_fname(root) },
    } or nil,
    request = request,
    notify = function() end,
  }
end

H.describe('LSP file operations', function()
  H.it('requires a file-operation capability and selects detached workspace clients', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local detached = client(9, { didCreate = true }, root)
    local unsupported = client(2, nil, root)
    with_clients({ unsupported, detached }, function()
      local selected = operations.clients('didCreateFiles', { root .. '/new.txt' })
      H.assert_eq(#selected, 1)
      H.assert_eq(selected[1].client.id, 9)
    end)
  end)

  H.it('scopes every request and notification to workspace paths and complete rename pairs', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local outside = H.mkdir(sb.root, 'outside')
    local requested, notifications = {}, {}
    local opted = client(10, {
      willRename = true, didCreate = true, didDelete = true, didRename = true,
    }, root, function(_, method, params, callback)
      requested[#requested + 1] = { method, vim.deepcopy(params) }
      callback(nil, nil)
      return true, 1
    end)
    opted.notify = function(_, method, params)
      notifications[#notifications + 1] = { method, vim.deepcopy(params) }
    end
    local inside_old, inside_new = root .. '/before.txt', root .. '/after.txt'
    local outside_path = outside .. '/outside.txt'
    with_clients({ opted }, function()
      operations.will_rename({
        { oldUri = vim.uri_from_fname(inside_old), newUri = vim.uri_from_fname(inside_new) },
        { oldUri = vim.uri_from_fname(inside_old), newUri = vim.uri_from_fname(outside_path) },
      }, function() end)
      operations.notify('didCreateFiles', { root .. '/created.txt', outside_path })
      operations.notify('didDeleteFiles', { root .. '/deleted.txt', outside_path })
      operations.notify('didRenameFiles', nil, {
        { src = inside_old, dst = inside_new },
        { src = inside_old, dst = outside_path },
      })
    end)

    local outside_uri = vim.uri_from_fname(outside_path)
    H.assert_eq(requested[1][2].files, {
      { oldUri = vim.uri_from_fname(inside_old), newUri = vim.uri_from_fname(inside_new) },
    }, 'willRename omits outside paths and cross-workspace pairs')
    H.assert_eq(#notifications, 3)
    H.assert_eq(notifications[1][2].files,
      { { uri = vim.uri_from_fname(root .. '/created.txt') } })
    H.assert_eq(notifications[2][2].files,
      { { uri = vim.uri_from_fname(root .. '/deleted.txt') } })
    H.assert_eq(notifications[3][2].files, {
      { oldUri = vim.uri_from_fname(inside_old), newUri = vim.uri_from_fname(inside_new) },
    }, 'didRename omits the entire cross-workspace pair')
    for _, entry in ipairs(requested[1][2].files) do
      H.assert_false(entry.oldUri == outside_uri or entry.newUri == outside_uri)
    end
    for _, notification in ipairs(notifications) do
      for _, entry in ipairs(notification[2].files) do
        H.assert_false(entry.uri == outside_uri or entry.oldUri == outside_uri
          or entry.newUri == outside_uri)
      end
    end
  end)

  H.it('honors file/folder filters and sends canonical file URIs', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local got
    local opted = client(1, {
      didCreate = { filters = {
        { scheme = 'file', pattern = { glob = '**/*.txt', matches = 'file' } },
      } },
    }, root, nil)
    opted.notify = function(_, method, params) got = { method, params } end
    with_clients({ opted }, function()
      operations.notify('didCreateFiles', { root .. '/nested/a.txt', root .. '/nested/b.lua' })
    end)
    H.assert_eq(got[1], 'workspace/didCreateFiles')
    H.assert_eq(got[2].files, { { uri = vim.uri_from_fname(root .. '/nested/a.txt') } })
  end)

  H.it('uses logical folder kinds for didCreate folder filters', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local got
    local opted = client(1, {
      didCreate = { filters = {
        { scheme = 'file', pattern = { glob = '**', matches = 'folder' } },
      } },
    }, root)
    opted.notify = function(_, method, params) got = { method, params } end
    with_clients({ opted }, function()
      operations.emit_actions({
        require('direct.action').Touch(root .. '/file.txt'),
        require('direct.action').MakeDirectory(root .. '/directory'),
      }, { [1] = true, [2] = true })
    end)
    H.assert_eq(got[1], 'workspace/didCreateFiles')
    H.assert_eq(got[2].files, { { uri = vim.uri_from_fname(root .. '/directory') } })
  end)

  H.it('honors dynamic-registration filters when Neovim exposes them', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local dynamic = client(6, nil, root)
    dynamic.dynamic_capabilities = {
      get = function(_, method)
        if method == 'workspace/didCreateFiles' then
          return { {
            method = method,
            registerOptions = { filters = {
              { scheme = 'file', pattern = { glob = '**/*.lua', matches = 'file' } },
            } },
          } }
        end
        return nil
      end,
    }
    with_clients({ dynamic }, function()
      local selected = operations.clients('workspace/didCreateFiles', {
        root .. '/nested/one.txt', root .. '/nested/two.lua',
      })
      H.assert_eq(#selected, 1)
      H.assert_eq(selected[1].paths,
        { vim.fs.normalize(root .. '/nested/two.lua') })
    end)
  end)

  H.it('treats explicitly empty dynamic filters as matching no request or event', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local requests, notifications = 0, 0
    local dynamic = client(7, nil, root, function() requests = requests + 1; return true, 1 end)
    dynamic.dynamic_capabilities = {
      get = function(_, method)
        if method == 'workspace/willRenameFiles' or method == 'workspace/didCreateFiles' then
          return { { method = method, registerOptions = { filters = {} } } }
        end
      end,
    }
    dynamic.notify = function() notifications = notifications + 1 end
    local result
    with_clients({ dynamic }, function()
      operations.will_rename({ { oldUri = vim.uri_from_fname(root .. '/before.txt'),
        newUri = vim.uri_from_fname(root .. '/after.txt') } }, function(ok) result = ok end)
      operations.notify('didCreateFiles', { root .. '/new.txt' })
    end)
    H.assert_true(result, 'no eligible willRename client is a successful empty response')
    H.assert_eq(requests, 0, 'an empty willRename filter starts no request')
    H.assert_eq(notifications, 0, 'an empty didCreate filter sends no event')
  end)

  H.it('leaves dynamic registrations without filter information unrestricted', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local requests, notifications = 0, 0
    local dynamic = client(8, nil, root, function(_, _, _, callback)
      requests = requests + 1
      callback(nil, nil)
      return true, 1
    end)
    dynamic.dynamic_capabilities = {
      get = function(_, method)
        if method == 'workspace/willRenameFiles' then
          return { { method = method, registerOptions = {} } }
        elseif method == 'workspace/didCreateFiles' then
          return { { method = method } }
        end
      end,
    }
    dynamic.notify = function() notifications = notifications + 1 end
    local result
    with_clients({ dynamic }, function()
      operations.will_rename({ { oldUri = vim.uri_from_fname(root .. '/before.txt'),
        newUri = vim.uri_from_fname(root .. '/after.txt') } }, function(ok) result = ok end)
      operations.notify('didCreateFiles', { root .. '/new.txt' })
    end)
    H.assert_true(result, 'an absent filters property keeps the registration unrestricted')
    H.assert_eq(requests, 1, 'the unrestricted willRename registration receives a request')
    H.assert_eq(notifications, 1, 'the unrestricted didCreate registration receives an event')
  end)

  H.it('requests willRename asynchronously, applies edits in client order, ignores null and warns on errors/timeouts', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local order, warnings = {}, {}
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function(edit)
      order[#order + 1] = edit.client
      return true
    end
    local a = client(8, { willRename = true }, root, function(_, _, _, callback)
      vim.schedule(function() callback(nil, { client = 8 }) end)
      return true, 1
    end)
    local b = client(3, { willRename = true }, root, function(_, _, _, callback)
      vim.schedule(function() callback(nil, { client = 3 }) end)
      return true, 2
    end)
    local silent = client(4, { willRename = true }, root, function(_, _, _, callback)
      vim.schedule(function() callback(nil, vim.NIL) end)
      return true, 3
    end)
    local broken = client(5, { willRename = true }, root, function(_, _, _, callback)
      vim.schedule(function() callback({ code = -1, message = 'failed' }, nil) end)
      return true, 4
    end)
    local timeout = client(6, { willRename = true }, root, function() return true, 5 end)
    local finished
    with_clients({ a, b, silent, broken, timeout }, function()
      operations._timeout_ms = 15
      operations.will_rename({ { oldUri = vim.uri_from_fname(root .. '/a'),
        newUri = vim.uri_from_fname(root .. '/b') } }, function(ok, failed)
        finished = { ok, failed }
      end, function(message) warnings[#warnings + 1] = message end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return finished ~= nil end, 5))
      operations._timeout_ms = nil
    end)
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_eq(order, { 3, 8 })
    H.assert_true(finished[1])
    H.assert_true(#warnings >= 2)
  end)

  H.it('stops before a filesystem callback if applying a returned edit fails', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function() error('apply failed') end
    local opted = client(1, { willRename = true }, root, function(_, _, _, callback)
      vim.schedule(function() callback(nil, { changes = {} }) end)
      return true, 1
    end)
    local result
    with_clients({ opted }, function()
      operations.will_rename({ { oldUri = vim.uri_from_fname(root .. '/a'),
        newUri = vim.uri_from_fname(root .. '/b') } }, function(ok, err)
        result = { ok, err }
      end)
      H.assert_true(vim.wait(200, function() return result ~= nil end, 5))
    end)
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_false(result[1])
    H.assert_true(result[2]:find('apply failed', 1, true) ~= nil)
  end)

  H.it('keeps :write nonblocking, then renames and sends didRenameFiles', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'contents')
    local note = H.mkfile(sb.root, 'note.txt', 'before')
    vim.cmd('edit ' .. vim.fn.fnameescape(note))
    local note_buf = vim.api.nvim_get_current_buf()
    local requested, notifications = {}, {}
    local unsupported_calls = 0
    package.loaded['direct.buffer'] = buffer
    package.loaded['direct'] = nil
    require('direct')
    local opted = client(12, { willRename = true, didRename = true }, sb.root,
      function(_, method, params, callback)
        requested[#requested + 1] = { method, params }
        vim.schedule(function()
          callback(nil, { changes = {
            [vim.uri_from_fname(note)] = { {
              range = { start = { line = 0, character = 0 },
                ['end'] = { line = 0, character = 6 } },
              newText = 'updated',
            } },
          } })
        end)
        return true, 1
      end)
    opted.notify = function(_, method, params)
      notifications[#notifications + 1] = { method, params }
    end
    local unsupported = client(13, nil, sb.root)
    unsupported.request = function() unsupported_calls = unsupported_calls + 1 end
    unsupported.notify = function() unsupported_calls = unsupported_calls + 1 end
    with_clients({ opted, unsupported }, function()
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      vim.cmd('write')
      H.assert_true(listing ~= nil)
      H.assert_true(pending.is_pending())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function()
        return vim.uv.fs_stat(root .. '/after.txt') ~= nil and not pending.is_pending()
      end, 5))
    end)
    H.assert_eq(#requested, 1)
    H.assert_eq(requested[1][1], 'workspace/willRenameFiles')
    H.assert_eq(requested[1][2].files[1].oldUri, vim.uri_from_fname(root .. '/before.txt'))
    H.assert_eq(#notifications, 1)
    H.assert_eq(notifications[1][1], 'workspace/didRenameFiles')
    H.assert_eq(notifications[1][2].files[1], {
      oldUri = vim.uri_from_fname(root .. '/before.txt'),
      newUri = vim.uri_from_fname(root .. '/after.txt'),
    })
    H.assert_eq(unsupported_calls, 0)
    H.assert_eq(vim.api.nvim_buf_get_lines(note_buf, 0, -1, false), { 'updated' })
  end)

  H.it('does not block a rename on request timeout and clears the guard', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'contents')
    local notifications = 0
    local opted = client(1, { willRename = true, didRename = true }, root,
      function() return true, 1 end)
    opted.notify = function(_, method) if method == 'workspace/didRenameFiles' then
      notifications = notifications + 1 end end
    local notify, saved_notify = vim.notify, vim.notify
    vim.notify = function(message)
      if tostring(message):find('timed out', 1, true) then notify = message end
    end
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function() return true end
    with_clients({ opted }, function()
      operations._timeout_ms = 15
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function()
        return vim.uv.fs_stat(root .. '/after.txt') ~= nil and not pending.is_pending()
      end, 5))
      operations._timeout_ms = nil
    end)
    vim.lsp.util.apply_workspace_edit = apply
    vim.notify = saved_notify
    H.assert_eq(notify, 'direct: Could not check with the language server before renaming '
      .. '(client 1): request timed out after 15 ms')
    H.assert_eq(notifications, 1)
  end)

  H.it('aborts the filesystem rename and clears pending after edit application failure', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'contents')
    local notifications = 0
    local opted = client(1, { willRename = true, didRename = true }, root,
      function(_, _, _, callback)
        vim.schedule(function() callback(nil, { changes = {} }) end)
        return true, 1
      end)
    opted.notify = function() notifications = notifications + 1 end
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function() error('forced apply failure') end
    with_clients({ opted }, function()
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
    end)
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_true(vim.uv.fs_stat(root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(root .. '/after.txt'))
    H.assert_eq(notifications, 0)
  end)

  H.it('warns and clears the pending guard after a malformed WorkspaceEdit', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'contents')
    local warnings = {}
    local opted = client(1, { willRename = true, didRename = true }, root,
      function(_, _, _, callback)
        vim.schedule(function() callback(nil, { documentChanges = 17 }) end)
        return true, 1
      end)
    opted.notify = function() error('Direct must refuse the rename') end
    local saved_notify = vim.notify
    vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
    with_clients({ opted }, function()
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5),
        'malformed response must release Direct pending guard')
    end)
    vim.notify = saved_notify
    H.assert_true(vim.uv.fs_stat(root .. '/before.txt') ~= nil,
      'Direct source remains in place after rejecting the malformed edit')
    H.assert_nil(vim.uv.fs_stat(root .. '/after.txt'), 'Direct rename is refused')
    H.assert_true(vim.bo.modified, 'the listing remains modified so the user can retry')
    H.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { 'after.txt' },
      'the user-edited listing is preserved')
    H.assert_true(#warnings > 0, 'malformed WorkspaceEdit is reported')
    H.assert_true(table.concat(warnings, '\n'):find('check with the language server', 1, true) ~= nil
      or table.concat(warnings, '\n'):find('workspace edit', 1, true) ~= nil,
      'warning identifies the failed WorkspaceEdit')
  end)

  H.it('detects a silently skipped WorkspaceEdit rename into an occupied destination', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'direct source')
    H.mkdir(sb.root, 'side')
    H.mkfile(sb.root, 'side/lsp-source.txt', 'workspace edit source')
    H.mkfile(sb.root, 'side/lsp-destination.txt', 'occupied workspace edit destination')
    local opted = client(1, { willRename = true, didRename = true }, sb.root,
      function(_, _, _, callback)
        vim.schedule(function()
          callback(nil, { documentChanges = { {
            kind = 'rename', oldUri = vim.uri_from_fname(sb.root .. '/side/lsp-source.txt'),
            newUri = vim.uri_from_fname(sb.root .. '/side/lsp-destination.txt'),
          } } })
        end)
        return true, 1
      end)
    with_clients({ opted }, function()
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'renamed.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
    end)
    H.assert_eq(vim.fn.readfile(sb.root .. '/side/lsp-source.txt'), { 'workspace edit source' })
    H.assert_eq(vim.fn.readfile(sb.root .. '/side/lsp-destination.txt'),
      { 'occupied workspace edit destination' })
    H.assert_eq(vim.fn.readfile(root .. '/before.txt'), { 'direct source' })
    H.assert_nil(vim.uv.fs_stat(root .. '/renamed.txt'))
  end)

  H.it('does not proceed when an annotated WorkspaceEdit is declined', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'direct source')
    local side = H.mkdir(sb.root, 'side')
    H.mkfile(side, 'note.txt', 'original')
    local opted = client(1, { willRename = true, didRename = true }, sb.root,
      function(_, _, _, callback)
        vim.schedule(function()
          callback(nil, {
            changes = { [vim.uri_from_fname(side .. '/note.txt')] = { {
              range = { start = { line = 0, character = 0 },
                ['end'] = { line = 0, character = 8 } },
              newText = 'declined', annotationId = 'confirm',
            } } },
            changeAnnotations = { confirm = { label = 'Confirm this edit',
              needsConfirmation = true } },
          })
        end)
        return true, 1
      end)
    local confirm = vim.fn.confirm
    vim.fn.confirm = function() return 2 end
    with_clients({ opted }, function()
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'renamed.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
    end)
    vim.fn.confirm = confirm
    H.assert_true(vim.uv.fs_stat(root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(root .. '/renamed.txt'))
    H.assert_eq(vim.fn.readfile(side .. '/note.txt'), { 'original' })
  end)

  H.it('rejects yank while willRename is pending without changing the register', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local first = H.mkfile(root, 'first.txt', 'first')
    local second = H.mkfile(root, 'second.txt', 'second')
    package.loaded['direct'] = nil
    local direct = require('direct')
    local register = require('direct.register')
    H.assert_true(register.yank({ first }))
    local prior = register.content()
    local listing = buffer.list(root)
    local row
    for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if line == 'second.txt' then row = i; break end
    end
    H.assert_true(row ~= nil)
    local direct_pending = require('direct.pending')
    local began = direct_pending.begin('willRenameFiles')
    H.assert_true(began)
    local result = direct.yank(row, row)
    H.assert_nil(result)
    H.assert_eq(register.content(), prior)
    direct_pending.finish()
    H.assert_false(direct_pending.is_pending())
    H.assert_eq(vim.uv.fs_stat(second) ~= nil, true)
    H.assert_true(listing ~= nil)
  end)

  H.it('preflights and reports history rename undo/redo through LSP exactly once', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local source = H.mkfile(root, 'before.txt', 'contents')
    local destination = root .. '/after.txt'
    local requested, notifications, edits = {}, {}, {}
    local opted = client(2, { willRename = true, didRename = true }, root,
      function(_, method, params, callback)
        requested[#requested + 1] = { method, vim.deepcopy(params) }
        local workspace_path = root .. '/server-edit-' .. #requested
        vim.schedule(function()
          callback(nil, { documentChanges = { {
            kind = 'create', uri = vim.uri_from_fname(workspace_path),
          } } })
        end)
        return true, #requested
      end)
    opted.notify = function(_, method, params)
      notifications[#notifications + 1] = { method, vim.deepcopy(params) }
    end
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function(edit)
      edits[#edits + 1] = edit
      return apply(edit, 'utf-16')
    end
    local history, action, fs = require('direct.history'), require('direct.action'), require('direct.fs')
    with_clients({ opted }, function()
      H.assert_true(fs.rename(source, destination))
      H.assert_true(history.log(action.Move(source, destination)))
      local done
      history.undo_async(function(result) done = result end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return done ~= nil end, 5))
      H.assert_true(fs.stat(source) ~= nil)
      H.assert_nil(fs.stat(destination))
      H.assert_true(fs.stat(root .. '/server-edit-1') ~= nil)
      done = nil
      history.redo_async(function(result) done = result end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return done ~= nil end, 5))
      H.assert_nil(fs.stat(source))
      H.assert_true(fs.stat(destination) ~= nil)
      H.assert_true(fs.stat(root .. '/server-edit-2') ~= nil)
    end)
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_eq(#requested, 2)
    H.assert_eq(requested[1][1], 'workspace/willRenameFiles')
    H.assert_eq(requested[1][2].files[1], {
      oldUri = vim.uri_from_fname(destination), newUri = vim.uri_from_fname(source),
    })
    H.assert_eq(requested[2][2].files[1], {
      oldUri = vim.uri_from_fname(source), newUri = vim.uri_from_fname(destination),
    })
    H.assert_eq(#notifications, 2)
    H.assert_eq(#edits, 2)
    H.assert_eq(notifications[1][1], 'workspace/didRenameFiles')
    H.assert_eq(notifications[2][1], 'workspace/didRenameFiles')
  end)

  H.it('proceeds with history rename after willRename request error or timeout', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local source, destination = root .. '/before.txt', root .. '/after.txt'
    local requested, notifications, warnings = 0, 0, {}
    local opted = client(3, { willRename = true, didRename = true }, root,
      function(_, _, _, callback)
        requested = requested + 1
        if requested == 1 then
          vim.schedule(function()
            callback({ code = -1, message = 'test request failure' }, nil)
          end)
        end
        return true, requested
      end)
    opted.notify = function(_, method)
      if method == 'workspace/didRenameFiles' then notifications = notifications + 1 end
    end
    local saved_notify = vim.notify
    vim.notify = function(message)
      warnings[#warnings + 1] = tostring(message)
    end
    local history, action, fs = require('direct.history'), require('direct.action'), require('direct.fs')
    local file_operations = require('direct.file_operations')
    local original_timeout = file_operations._timeout_ms
    with_clients({ opted }, function()
      H.assert_true(fs.touch(source))
      H.assert_true(fs.rename(source, destination))
      H.assert_true(history.log(action.Move(source, destination)))
      file_operations._timeout_ms = 15
      local done
      history.undo_async(function(result, err) done = { result, err } end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return done ~= nil end, 5))
      H.assert_true(done[1] ~= nil, tostring(done[2]))
      H.assert_true(fs.stat(source) ~= nil)
      H.assert_false(history.pending.is_pending(), 'undo must release the history guard')
      done = nil
      history.redo_async(function(result, err) done = { result, err } end)
      H.assert_eq(requested, 2, 'redo must send a second willRename request')
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not history.pending.is_pending() end, 5),
        'history guard should clear after the willRename timeout')
      H.assert_true(done ~= nil, table.concat(warnings, '\n'))
      H.assert_true(done[1] ~= nil, tostring(done[2]))
      H.assert_true(fs.stat(destination) ~= nil)
    end)
    file_operations._timeout_ms = original_timeout
    vim.notify = saved_notify
    H.assert_eq(requested, 2)
    H.assert_eq(notifications, 2)
    H.assert_true(#warnings >= 2)
    H.assert_true(table.concat(warnings, '\n'):find('test request failure', 1, true) ~= nil)
    H.assert_true(table.concat(warnings, '\n'):find('timed out', 1, true) ~= nil)
  end)

  H.it('refuses history reversal when a server resource edit silently cannot rename', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local source, destination = root .. '/before.txt', root .. '/after.txt'
    local side = H.mkdir(root, 'side')
    H.mkfile(side, 'source.txt', 'server source')
    H.mkfile(side, 'occupied.txt', 'server target')
    local notifications = 0
    local opted = client(5, { willRename = true, didRename = true }, root,
      function(_, _, _, callback)
        vim.schedule(function()
          callback(nil, { documentChanges = { {
            kind = 'rename', oldUri = vim.uri_from_fname(side .. '/source.txt'),
            newUri = vim.uri_from_fname(side .. '/occupied.txt'),
          } } })
        end)
        return true, 1
      end)
    opted.notify = function() notifications = notifications + 1 end
    local history, action, fs = require('direct.history'), require('direct.action'), require('direct.fs')
    with_clients({ opted }, function()
      H.mkfile(root, 'before.txt', 'direct contents')
      H.assert_true(fs.rename(source, destination))
      H.assert_true(history.log(action.Move(source, destination)))
      local done
      history.undo_async(function(result, err) done = { result, err } end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return done ~= nil end, 5))
      H.assert_nil(done[1])
      H.assert_true(tostring(done[2]):find('destination is occupied', 1, true) ~= nil)
      H.assert_false(history.pending.is_pending())
      H.assert_nil(fs.stat(source))
      H.assert_true(fs.stat(destination) ~= nil)
      H.assert_eq(notifications, 0)
    end)
    H.assert_eq(vim.fn.readfile(side .. '/source.txt'), { 'server source' })
    H.assert_eq(vim.fn.readfile(side .. '/occupied.txt'), { 'server target' })
  end)

  H.it('revalidates and refuses if the direct sync plan changes while pending', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'contents')
    local respond
    local opted = client(1, { willRename = true, didRename = true }, root,
      function(_, _, _, callback)
        respond = callback
        return true, 1
      end)
    local notifications = 0
    opted.notify = function() notifications = notifications + 1 end
    with_clients({ opted }, function()
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'other.txt' })
      vim.schedule(function() respond(nil, nil) end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
    end)
    H.assert_true(vim.uv.fs_stat(root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(root .. '/after.txt'))
    H.assert_nil(vim.uv.fs_stat(root .. '/other.txt'))
    H.assert_eq(notifications, 0)
  end)

  H.it('cancels pending rename safely when its listing buffer is wiped', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'before.txt', 'contents')
    local respond
    local opted = client(1, { willRename = true, didRename = true }, root,
      function(_, _, _, callback)
        respond = callback
        return true, 1
      end)
    with_clients({ opted }, function()
      local listing = buffer.list(root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      local bufnr = vim.api.nvim_get_current_buf()
      H.assert_true(pending.is_pending())
      vim.api.nvim_buf_delete(bufnr, { force = true })
      H.assert_false(pending.is_pending())
      vim.schedule(function() respond(nil, nil) end)
      vim.wait(100, function() return false end, 5)
    end)
    H.assert_true(vim.uv.fs_stat(root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(root .. '/after.txt'))
  end)

  H.it('does not apply a late WorkspaceEdit after its listing buffer is wiped', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local direct_root = H.mkdir(root, 'direct')
    H.mkfile(direct_root, 'before.txt', 'contents')
    local note = H.mkfile(root, 'note.txt', 'original')
    local respond, canceled = nil, 0
    local opted = client(1, { willRename = true, didRename = true }, root,
      function(_, _, _, callback)
        respond = callback
        return true, 19
      end)
    opted.cancel_request = function(_, request_id)
      H.assert_eq(request_id, 19)
      canceled = canceled + 1
      return true
    end
    with_clients({ opted }, function()
      local listing = buffer.list(direct_root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      local bufnr = vim.api.nvim_get_current_buf()
      H.assert_true(pending.is_pending())
      vim.api.nvim_buf_delete(bufnr, { force = true })
      H.assert_false(pending.is_pending())
      vim.schedule(function()
        respond(nil, { changes = { [vim.uri_from_fname(note)] = { {
          range = { start = { line = 0, character = 0 },
            ['end'] = { line = 0, character = 8 } },
          newText = 'mutated',
        } } } })
      end)
      vim.wait(100, function() return false end, 5)
    end)
    H.assert_eq(canceled, 1, 'wiping the listing cancels its outstanding request')
    H.assert_eq(vim.fn.readfile(note), { 'original' }, 'late WorkspaceEdit is ignored')
    H.assert_true(vim.uv.fs_stat(direct_root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(direct_root .. '/after.txt'), 'Direct rename is not executed')
  end)

  H.it('refuses CreateFile overwrite of an existing directory before Direct rename', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local direct_root = H.mkdir(root, 'direct')
    H.mkfile(direct_root, 'before.txt', 'contents')
    local directory = H.mkdir(root, 'existing-directory')
    local warnings, applications = {}, 0
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function(...)
      applications = applications + 1
      return apply(...)
    end
    local opted = client(1, { willRename = true }, root,
      function(_, _, _, callback)
        vim.schedule(function()
          callback(nil, { documentChanges = { {
            kind = 'create', uri = vim.uri_from_fname(directory),
            options = { overwrite = true },
          } } })
        end)
        return true, 1
      end)
    local saved_notify = vim.notify
    vim.notify = function(message, level)
      warnings[#warnings + 1] = { tostring(message), level }
    end
    with_clients({ opted }, function()
      local listing = buffer.list(direct_root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
    end)
    vim.notify = saved_notify
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_eq(applications, 0, 'the conflicting CreateFile is rejected before edit application')
    H.assert_true(vim.uv.fs_stat(direct_root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(direct_root .. '/after.txt'), 'Direct rename is aborted')
    H.assert_eq(vim.uv.fs_stat(directory).type, 'directory')
    H.assert_true(#warnings > 0, 'a CreateFile conflict is reported')
    H.assert_true(table.concat(vim.tbl_map(function(item) return item[1] end, warnings), '\n')
      :find('CreateFile', 1, true) ~= nil)
  end)

  H.it('aborts Direct rename when CreateFile overwrite silently leaves a non-empty file unchanged', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local direct_root = H.mkdir(root, 'direct')
    H.mkfile(direct_root, 'before.txt', 'contents')
    local existing = H.mkfile(root, 'existing.txt', 'keep this data')
    local warnings = {}
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function() return nil end
    local opted = client(1, { willRename = true }, root,
      function(_, _, _, callback)
        vim.schedule(function()
          callback(nil, { documentChanges = { {
            kind = 'create', uri = vim.uri_from_fname(existing),
            options = { overwrite = true },
          } } })
        end)
        return true, 1
      end)
    local saved_notify = vim.notify
    vim.notify = function(message, level)
      warnings[#warnings + 1] = { tostring(message), level }
    end
    with_clients({ opted }, function()
      local listing = buffer.list(direct_root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
    end)
    vim.notify = saved_notify
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_eq(vim.fn.readfile(existing), { 'keep this data' },
      'the silent no-op leaves the existing data intact')
    H.assert_true(vim.uv.fs_stat(direct_root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(direct_root .. '/after.txt'), 'Direct rename is aborted')
    H.assert_true(#warnings > 0, 'the failed overwrite postcondition is reported')
    H.assert_true(table.concat(vim.tbl_map(function(item) return item[1] end, warnings), '\n')
      :find('postcondition', 1, true) ~= nil)
  end)

  H.it('fails closed before applying CreateFile overwrite to an already-empty file', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local direct_root = H.mkdir(root, 'direct')
    H.mkfile(direct_root, 'before.txt', 'contents')
    local existing = H.mkfile(root, 'empty.txt', nil)
    local empty = assert(io.open(existing, 'w'))
    empty:close()
    local warnings, applications = {}, 0
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function(...)
      applications = applications + 1
      return apply(...)
    end
    local opted = client(1, { willRename = true }, root,
      function(_, _, _, callback)
        vim.schedule(function()
          callback(nil, { documentChanges = { {
            kind = 'create', uri = vim.uri_from_fname(existing),
            options = { overwrite = true },
          } } })
        end)
        return true, 1
      end)
    local saved_notify = vim.notify
    vim.notify = function(message, level)
      warnings[#warnings + 1] = { tostring(message), level }
    end
    with_clients({ opted }, function()
      local listing = buffer.list(direct_root)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'after.txt' })
      vim.bo.modified = true
      H.assert_true(listing:sync())
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
    end)
    vim.notify = saved_notify
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_eq(applications, 0, 'an unverifiable overwrite is rejected before application')
    H.assert_true(vim.uv.fs_stat(direct_root .. '/before.txt') ~= nil)
    H.assert_nil(vim.uv.fs_stat(direct_root .. '/after.txt'), 'Direct rename is aborted')
    H.assert_true(table.concat(vim.tbl_map(function(item) return item[1] end, warnings), '\n')
      :find('cannot be verified', 1, true) ~= nil, 'the verification limitation is reported')
  end)

  H.it('verifies CreateFile success, ignoreIfExists no-op, and overwrite', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local direct_root = H.mkdir(root, 'direct')
    H.mkfile(direct_root, 'before.txt', 'contents')
    H.mkfile(root, 'created.txt', 'old')
    H.mkfile(root, 'both-options.txt', 'old')
    H.mkdir(root, 'existing-directory')
    local response = 0
    local opted = client(1, { willRename = true }, root,
      function(_, _, _, callback)
        response = response + 1
        local changes
        if response == 1 then
          changes = { { kind = 'create', uri = vim.uri_from_fname(root .. '/new.txt') } }
        elseif response == 2 then
          changes = { { kind = 'create', uri = vim.uri_from_fname(root .. '/existing-directory'),
            options = { ignoreIfExists = true } } }
        elseif response == 3 then
          changes = { { kind = 'create', uri = vim.uri_from_fname(root .. '/created.txt'),
            options = { overwrite = true } } }
        else
          changes = { { kind = 'create', uri = vim.uri_from_fname(root .. '/both-options.txt'),
            options = { overwrite = true, ignoreIfExists = true } } }
        end
        vim.schedule(function() callback(nil, { documentChanges = changes }) end)
        return true, response
      end)
    with_clients({ opted }, function()
      local listing = buffer.list(direct_root)
      local function rename_to(name)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { name })
        vim.bo.modified = true
        local synced, sync_err = listing:sync()
        H.assert_true(synced == true, tostring(sync_err) .. '\n' .. H.messages())
        H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
      end
      rename_to('first.txt')
      H.assert_eq(vim.uv.fs_stat(root .. '/new.txt').type, 'file')
      rename_to('second.txt')
      H.assert_eq(vim.uv.fs_stat(root .. '/existing-directory').type, 'directory')
      rename_to('third.txt')
      H.assert_eq(vim.uv.fs_stat(root .. '/created.txt').type, 'file')
      H.assert_eq(vim.fn.readfile(root .. '/created.txt'), {}, 'overwrite truncates existing file')
      rename_to('fourth.txt')
      H.assert_eq(vim.fn.readfile(root .. '/both-options.txt'), {},
        'overwrite takes precedence over ignoreIfExists')
    end)
    H.assert_eq(response, 4)
    H.assert_true(vim.uv.fs_stat(direct_root .. '/fourth.txt') ~= nil)
  end)

  H.it('rejects missing DeleteFile unless ignoreIfNotExists makes it a no-op', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local direct_root = H.mkdir(root, 'direct')
    H.mkfile(direct_root, 'before.txt', 'contents')
    local response, applications = 0, 0
    local apply = vim.lsp.util.apply_workspace_edit
    vim.lsp.util.apply_workspace_edit = function(...)
      applications = applications + 1
      return apply(...)
    end
    local opted = client(1, { willRename = true }, root,
      function(_, _, _, callback)
        response = response + 1
        local options = response == 1 and { ignoreIfNotExists = false }
          or { ignoreIfNotExists = true }
        vim.schedule(function()
          callback(nil, { documentChanges = { {
            kind = 'delete', uri = vim.uri_from_fname(root .. '/missing-' .. response),
            options = options,
          } } })
        end)
        return true, response
      end)
    with_clients({ opted }, function()
      local listing = buffer.list(direct_root)
      local function rename_to(name)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { name })
        vim.bo.modified = true
        H.assert_true(listing:sync())
        H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return not pending.is_pending() end, 5))
      end
      rename_to('rejected.txt')
      H.assert_true(vim.uv.fs_stat(direct_root .. '/before.txt') ~= nil,
        'a missing DeleteFile without ignoreIfNotExists aborts Direct rename')
      H.assert_nil(vim.uv.fs_stat(direct_root .. '/rejected.txt'))
      H.assert_eq(applications, 0, 'the invalid WorkspaceEdit is rejected before application')

      rename_to('accepted.txt')
      H.assert_true(vim.uv.fs_stat(direct_root .. '/accepted.txt') ~= nil,
        'ignoreIfNotExists accepts the missing DeleteFile as a no-op')
      H.assert_nil(vim.uv.fs_stat(direct_root .. '/before.txt'))
      H.assert_eq(applications, 1)
    end)
    vim.lsp.util.apply_workspace_edit = apply
    H.assert_eq(response, 2)
  end)

  H.it('continues to delete existing files, recursive directories, and symlinks', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkfile(root, 'regular.txt', 'regular')
    local directory = H.mkdir(root, 'directory')
    H.mkfile(directory, 'nested.txt', 'nested')
    local target = H.mkfile(root, 'symlink-target.txt', 'target')
    local link = root .. '/symlink.txt'
    H.assert_true(H.symlink(target, link) == true, 'symlink fixture is available')
    local opted = client(1, { willRename = true }, root,
      function(_, _, _, callback)
        vim.schedule(function()
          callback(nil, { documentChanges = {
            { kind = 'delete', uri = vim.uri_from_fname(root .. '/regular.txt') },
            { kind = 'delete', uri = vim.uri_from_fname(directory), options = { recursive = true } },
            { kind = 'delete', uri = vim.uri_from_fname(link) },
          } })
        end)
        return true, 1
      end)
    local result
    with_clients({ opted }, function()
      operations.will_rename({ { oldUri = vim.uri_from_fname(root .. '/before.txt'),
        newUri = vim.uri_from_fname(root .. '/after.txt') } }, function(ok, err)
        result = { ok, err }
      end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return result ~= nil end, 5))
    end)
    H.assert_true(result[1], tostring(result[2]))
    H.assert_nil(vim.uv.fs_lstat(root .. '/regular.txt'))
    H.assert_nil(vim.uv.fs_lstat(directory))
    H.assert_nil(vim.uv.fs_lstat(link))
    H.assert_eq(vim.fn.readfile(target), { 'target' }, 'deleting a symlink preserves its target')
  end)

  H.it('groups only successful logical sync effects, without exposing support paths', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local calls = {}
    local opted = client(7, {
      didCreate = true, didDelete = true, didRename = true,
    }, root)
    opted.notify = function(_, method, params)
      calls[#calls + 1] = { method, params }
    end
    local action = require('direct.action')
    local register_root = H.mkdir(sb.root, 'register-content')
    H.mkfile(register_root, 'copied.txt', 'copied')
    local target_root = H.mkdir(root, 'target')
    local paste = action.Paste(register_root, target_root,
      { 'copied.txt' }, { 'new-copy.txt' })
    paste.renames = { { src = 'copied.txt', dst = 'new-copy.txt' } }
    local unpaste = action.Unpaste(target_root, register_root,
      { 'new-copy.txt' }, { 'copied.txt' })
    unpaste._completed_renames = { { src = 'new-copy.txt', dst = 'copied.txt' } }
    with_clients({ opted }, function()
      operations.emit_actions({
        action.Touch(root .. '/new.txt'),
        action.MakeDirectory(root .. '/new-dir'),
        action.Remove(root .. '/deleted.txt', root .. '/trash/item'),
        action.Move(root .. '/old.txt', root .. '/renamed.txt'),
      }, { [1] = true, [2] = true, [3] = false, [4] = true })
      operations.emit_actions({ paste })
      operations.emit_actions({ unpaste })
    end)
    H.assert_eq(#calls, 4)
    H.assert_eq(calls[1][1], 'workspace/didCreateFiles')
    H.assert_eq(calls[1][2].files, {
      { uri = vim.uri_from_fname(root .. '/new.txt') },
      { uri = vim.uri_from_fname(root .. '/new-dir') },
    })
    H.assert_eq(calls[2][1], 'workspace/didRenameFiles')
    H.assert_eq(calls[2][2].files, { {
      oldUri = vim.uri_from_fname(root .. '/old.txt'),
      newUri = vim.uri_from_fname(root .. '/renamed.txt'),
    } })
    H.assert_eq(calls[3][1], 'workspace/didCreateFiles')
    H.assert_eq(calls[3][2].files, {
      { uri = vim.uri_from_fname(target_root .. '/new-copy.txt') },
    })
    H.assert_eq(calls[4][1], 'workspace/didDeleteFiles')
    H.assert_eq(calls[4][2].files, {
      { uri = vim.uri_from_fname(target_root .. '/new-copy.txt') },
    })
  end)

  H.it('emits logical events for successful history undo and redo', function()
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    local path = H.mkfile(root, 'item.txt', 'history')
    local calls = {}
    local opted = client(4, { didCreate = true, didDelete = true }, root)
    opted.notify = function(_, method, params)
      calls[#calls + 1] = { method, params }
    end
    local fs = require('direct.fs')
    local action = require('direct.action')
    local history = require('direct.history')
    with_clients({ opted }, function()
      H.assert_true(history.log(action.Touch(path)))
      local done
      history.undo_async(function(result) done = result end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return done ~= nil end, 5))
      H.assert_nil(fs.stat(path))
      H.assert_eq(calls[1][1], 'workspace/didDeleteFiles')
      done = nil
      history.redo_async(function(result) done = result end)
      H.assert_true(vim.wait(ASYNC_WAIT_MS, function() return done ~= nil end, 5))
      H.assert_true(fs.stat(path) ~= nil)
    end)
    H.assert_eq(calls[2][1], 'workspace/didCreateFiles')
    H.assert_eq(calls[1][2].files, { { uri = vim.uri_from_fname(path) } })
    H.assert_eq(calls[2][2].files, { { uri = vim.uri_from_fname(path) } })
  end)
end)
