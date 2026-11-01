-- Content-proof Unpaste protocol: validate, capture, verify, then delete only Q.
local H = require('tests.support.harness')
local action = require('direct.action')
local fs = require('direct.fs')
local log = require('direct.log')
local paths = require('direct.paths')
local register = require('direct.register')
local history = require('direct.history')
local ui = require('direct.ui')

local function history_paths(sb)
  local dir = vim.fs.joinpath(sb.data_home, 'direct/history')
  return vim.fs.joinpath(dir, 'undo.log'), vim.fs.joinpath(dir, 'redo.log')
end

local function paste_one_file(sb, name)
  local source = H.mkfile(sb.root, name, { 'REGISTER-' .. name })
  H.assert_true(register.yank({ source }) == true, 'register source')
  local content = register.content()
  local dest = H.mkdir(sb.root, 'dest')
  H.assert_eq(register.paste(dest), dest .. '/' .. name, 'paste source')
  return source, content, dest, dest .. '/' .. name
end

H.describe('content-proof Unpaste', function()
  H.it('U1 removes unchanged files and trees only after all capture checks pass', function()
    local sb = H.sandbox()
    local file = H.mkfile(sb.root, 'file.txt', { 'FILE' })
    local tree = H.mkdir(sb.root, 'tree')
    H.mkfile(tree, 'child.txt', { 'CHILD' })
    H.assert_true(register.yank({ file, tree }) == true, 'register file and tree')
    local content = register.content()
    local dest = H.mkdir(sb.root, 'dest')
    register.paste(dest)
    H.assert_fs_eq(dest, { 'file.txt', 'tree/', 'tree/child.txt' }, 'paste fixture')

    H.assert_true(history.undo() ~= nil, 'unchanged paste is safely undone')

    H.assert_fs_eq(dest, {}, 'captured copies were deleted')
    H.assert_fs_eq(content, { 'file.txt', 'tree/', 'tree/child.txt' },
      'register copy remains untouched')
    H.assert_eq(vim.fn.glob(dest .. '/.direct-unpaste-*'), '', 'no quarantine remains')
    local undo_path, redo_path = history_paths(sb)
    H.assert_eq(vim.fn.readfile(undo_path), { history.HEADER }, 'undo source was drained')
    H.assert_eq(#vim.fn.readfile(redo_path), 2, 'inverse was appended after full success')
  end)

  H.it('U2 refuses an edited file and preserves the undo source record', function()
    local sb = H.sandbox()
    local _, _, dest, pasted = paste_one_file(sb, 'file.txt')
    vim.fn.writefile({ 'EDITED' }, pasted)
    local undo_path = history_paths(sb)
    local before = log.read_raw(undo_path)
    local contents_before = H.fs_snapshot(dest)

    H.capture_messages()
    H.assert_nil(history.undo(), 'edited content refuses Unpaste')

    H.assert_eq(log.read_raw(undo_path), before, 'source history bytes are restored')
    H.assert_eq(H.fs_snapshot(dest), contents_before, 'edited file remains unchanged')
    H.assert_eq(vim.fn.readfile(pasted), { 'EDITED' }, 'edited bytes remain')
    H.assert_eq(vim.fn.glob(dest .. '/.direct-unpaste-*'), '', 'no capture was attempted')
  end)

  H.it('U3 refuses added, deleted, or changed directory children before deleting any entry', function()
    for _, mutation in ipairs({ 'add', 'delete', 'change' }) do
      local sb = H.sandbox()
      local tree = H.mkdir(sb.root, 'tree')
      H.mkfile(tree, 'child.txt', { 'CHILD' })
      H.assert_true(register.yank({ tree }) == true, 'register tree: ' .. mutation)
      local dest = H.mkdir(sb.root, 'dest')
      register.paste(dest)
      local pasted = dest .. '/tree'
      if mutation == 'add' then
        H.mkfile(pasted, 'added.txt', { 'ADDED' })
      elseif mutation == 'delete' then
        vim.uv.fs_unlink(pasted .. '/child.txt')
      else
        vim.fn.writefile({ 'CHANGED' }, pasted .. '/child.txt')
      end
      local before = H.fs_snapshot(dest)

      H.assert_nil(history.undo(), mutation .. ' child change refuses the whole operation')
      H.assert_eq(H.fs_snapshot(dest), before, mutation .. ' directory remains intact')
      H.assert_eq(vim.fn.glob(dest .. '/.direct-unpaste-*'), '',
        mutation .. ' is rejected before capture')
    end
  end)

  H.it('U4 refuses a different-content same-name replacement', function()
    local sb = H.sandbox()
    local _, _, dest, pasted = paste_one_file(sb, 'same.txt')
    vim.uv.fs_unlink(pasted)
    H.mkfile(dest, 'same.txt', { 'REPLACEMENT' })
    local undo_path = history_paths(sb)
    local before = log.read_raw(undo_path)

    H.assert_nil(history.undo(), 'different same-name replacement is not deleted')

    H.assert_eq(vim.fn.readfile(pasted), { 'REPLACEMENT' }, 'replacement survives')
    H.assert_eq(log.read_raw(undo_path), before, 'history source is preserved')
  end)

  H.it('U5 compares symlink targets without following outside targets', function()
    local sb = H.sandbox()
    local outside_a = H.mkfile(sb.root, 'outside-a.txt', { 'A' })
    local outside_b = H.mkfile(sb.root, 'outside-b.txt', { 'B' })
    local reg_root = paths.ensure_data_dir('register')
    local reg = H.mkdir(reg_root, 'symlink-fixture')
    H.assert_true(vim.uv.fs_symlink(outside_a, reg .. '/link') == true,
      'register symlink created')
    vim.fn.writefile({ reg }, paths.join(reg_root, 'content'))
    local dest = H.mkdir(sb.root, 'dest')
    local pasted = dest .. '/link'
    H.assert_true(vim.uv.fs_symlink(outside_b, pasted) == true,
      'same-name symlink replacement points elsewhere')
    local record = action.Paste(reg, dest, { 'link' }, { 'link' })
    H.assert_true(history.log(record) == true, 'paste record fixture')
    local undo_path = history_paths(sb)
    local before = log.read_raw(undo_path)

    H.assert_nil(history.undo(), 'different link target refuses Unpaste')

    H.assert_eq(vim.uv.fs_readlink(pasted), outside_b, 'replacement symlink is untouched')
    H.assert_eq(vim.fn.readfile(outside_a), { 'A' }, 'register target is never followed')
    H.assert_eq(vim.fn.readfile(outside_b), { 'B' }, 'replacement target is never followed')
    H.assert_eq(log.read_raw(undo_path), before, 'history source is preserved')
  end)

  H.it('U6 unreadable content refuses before capture or deletion', function()
    local sb = H.sandbox()
    local _, _, dest, pasted = paste_one_file(sb, 'file.txt')
    local undo_path = history_paths(sb)
    local before = log.read_raw(undo_path)
    local original = fs.same_contents
    local restore = H.stub(fs, 'same_contents', function(a, b)
      if a == pasted then return nil, 'forced unreadable subtree' end
      return original(a, b)
    end)

    H.assert_nil(history.undo(), 'unreadable comparison refuses Unpaste')
    restore()

    H.assert_eq(vim.fn.readfile(pasted), { 'REGISTER-file.txt' }, 'target remains')
    H.assert_eq(log.read_raw(undo_path), before, 'history source remains')
    H.assert_eq(vim.fn.glob(dest .. '/.direct-unpaste-*'), '', 'no quarantine exists')
  end)

  H.it('a raised Phase B comparison error restores captured P without losing history', function()
    local sb = H.sandbox()
    local _, _, dest, pasted = paste_one_file(sb, 'file.txt')
    local undo_path = history_paths(sb)
    local history_before = log.read_raw(undo_path)
    local original, calls = fs.same_contents, 0
    local restore = H.stub(fs, 'same_contents', function(a, b)
      calls = calls + 1
      if calls == 2 then error('forced comparison exception') end
      return original(a, b)
    end)

    H.assert_nil(history.undo(), 'raised comparison error refuses Unpaste')
    restore()

    H.assert_eq(calls, 2, 'Phase A passed, Phase B comparison raised')
    H.assert_eq(vim.fn.readfile(pasted), { 'REGISTER-file.txt' },
      'captured entry was restored to P')
    H.assert_eq(vim.fn.glob(dest .. '/.direct-unpaste-*'), '', 'Q was restored')
    H.assert_eq(log.read_raw(undo_path), history_before, 'source record remains')
  end)

  H.it('U7 a mismatch in one item prevents deletion of every item', function()
    local sb = H.sandbox()
    local a = H.mkfile(sb.root, 'a.txt', { 'A' })
    local b = H.mkfile(sb.root, 'b.txt', { 'B' })
    H.assert_true(register.yank({ a, b }) == true, 'register both files')
    local dest = H.mkdir(sb.root, 'dest')
    register.paste(dest)
    vim.fn.writefile({ 'EDITED-B' }, dest .. '/b.txt')
    local before = H.fs_snapshot(dest)
    local undo_path = history_paths(sb)
    local history_before = log.read_raw(undo_path)

    H.assert_nil(history.undo(), 'one mismatched item refuses the whole set')

    H.assert_eq(H.fs_snapshot(dest), before, 'neither destination was deleted')
    H.assert_eq(log.read_raw(undo_path), history_before, 'source history is preserved')
    H.assert_eq(vim.fn.glob(dest .. '/.direct-unpaste-*'), '', 'Phase A made no Q paths')
  end)

  H.it('U8 a new object at P after capture is untouched while only Q is deleted', function()
    local sb = H.sandbox()
    local _, _, dest, pasted = paste_one_file(sb, 'file.txt')
    local real = fs.rename_noreplace
    local injected = false
    local restore = H.stub(fs, 'rename_noreplace', function(src, target, expected)
      local moved, err, code = real(src, target, expected)
      if moved and src == pasted and target:find('/.direct-unpaste-', 1, true)
        and not injected then
        injected = true
        H.mkfile(dest, 'file.txt', { 'NEW P OBJECT' })
      end
      return moved, err, code
    end)

    H.assert_true(history.undo() ~= nil, 'captured paste is undone')
    restore()

    H.assert_true(injected, 'new P object was created after capture')
    H.assert_eq(vim.fn.readfile(pasted), { 'NEW P OBJECT' }, 'new P object survives')
    H.assert_eq(vim.fn.glob(dest .. '/.direct-unpaste-*'), '', 'only captured Q was deleted')
  end)

  H.it('U9 a post-capture mismatch stays in Q when P is reoccupied', function()
    local sb = H.sandbox()
    local _, _, dest, pasted = paste_one_file(sb, 'file.txt')
    local undo_path = history_paths(sb)
    local history_before = log.read_raw(undo_path)
    local quarantine, injected = nil, false
    local real = fs.rename_noreplace
    local restore = H.stub(fs, 'rename_noreplace', function(src, target, expected)
      local moved, err, code = real(src, target, expected)
      if moved and src == pasted and target:find('/.direct-unpaste-', 1, true)
        and not injected then
        injected, quarantine = true, target
        vim.fn.writefile({ 'CHANGED AFTER CAPTURE' }, target)
        H.mkfile(dest, 'file.txt', { 'NEW P OBJECT' })
      end
      return moved, err, code
    end)
    H.capture_messages()
    local result = history.undo()
    restore()

    H.assert_nil(result, 'post-capture content mismatch refuses Unpaste')
    H.assert_true(injected, 'captured object was changed and P was reoccupied')
    H.assert_eq(vim.fn.readfile(pasted), { 'NEW P OBJECT' }, 'new P object remains')
    H.assert_eq(vim.fn.readfile(quarantine), { 'CHANGED AFTER CAPTURE' },
      'captured Q is preserved for recovery')
    H.assert_eq(log.read_raw(undo_path), history_before, 'history source is retained')
    H.assert_notified(quarantine, vim.log.levels.ERROR)
  end)

  H.it('U10 a Phase B failure reports every Q that cannot be restored', function()
    local sb = H.sandbox()
    local a = H.mkfile(sb.root, 'a.txt', { 'A' })
    local b = H.mkfile(sb.root, 'b.txt', { 'B' })
    H.assert_true(register.yank({ a, b }) == true, 'register both files')
    local dest = H.mkdir(sb.root, 'dest')
    register.paste(dest)
    local pasted_a, pasted_b = dest .. '/a.txt', dest .. '/b.txt'
    local real = fs.rename_noreplace
    local q_for_a, blocked = nil, false
    local restore = H.stub(fs, 'rename_noreplace', function(src, target, expected)
      if src == pasted_b and target:find('/.direct-unpaste-', 1, true) then
        return nil, 'forced Phase B failure'
      end
      if src == pasted_a and target:find('/.direct-unpaste-', 1, true) then
        local moved, err, code = real(src, target, expected)
        if moved then
          q_for_a = target
          H.mkfile(dest, 'a.txt', { 'NEW P OBJECT' })
        end
        return moved, err, code
      end
      local restored, err, code = real(src, target, expected)
      if src == q_for_a and target == pasted_a and not restored then
        blocked = true
      end
      return restored, err, code
    end)
    H.capture_messages()
    local result = history.undo()
    restore()

    H.assert_nil(result, 'Phase B failure refuses the operation')
    H.assert_true(blocked, 'rollback was blocked by a new object at P')
    H.assert_true(fs.taken(q_for_a), 'captured Q remains for recovery')
    H.assert_eq(vim.fn.readfile(pasted_a), { 'NEW P OBJECT' }, 'new P object is untouched')
    H.assert_eq(vim.fn.readfile(pasted_b), { 'B' },
      'uncaptured second entry remains untouched')
    H.assert_notified(q_for_a, vim.log.levels.ERROR)
  end)

  H.it('U11 a raised Phase C deletion failure preserves and reports every remaining Q', function()
    local sb = H.sandbox()
    local a = H.mkfile(sb.root, 'a.txt', { 'A' })
    local b = H.mkfile(sb.root, 'b.txt', { 'B' })
    H.assert_true(register.yank({ a, b }) == true, 'register both files')
    local dest = H.mkdir(sb.root, 'dest')
    register.paste(dest)
    local real_rm = fs.rm_file
    local first_q
    local restore = H.stub(fs, 'rm_file', function(path)
      if path:find('/.direct-unpaste-', 1, true) then
        if first_q == nil then
          first_q = path
          error('forced Phase C deletion exception')
        end
      end
      return real_rm(path)
    end)
    H.capture_messages()

    H.assert_nil(history.undo(), 'Phase C deletion failure refuses Unpaste')
    restore()

    H.assert_true(first_q ~= nil, 'first Q deletion was attempted')
    H.assert_true(fs.taken(first_q), 'failed Q is preserved')
    local quarantines = vim.fn.glob(dest .. '/.direct-unpaste-*', false, true)
    H.assert_eq(#quarantines, 2, 'both captured Q paths are preserved')
    H.assert_notified(first_q, vim.log.levels.ERROR)
    for _, quarantine in ipairs(quarantines) do
      H.assert_notified(quarantine, vim.log.levels.ERROR)
    end
    H.assert_eq(vim.fn.glob(dest .. '/a.txt'), '', 'original P names remain vacated')
    H.assert_eq(vim.fn.glob(dest .. '/b.txt'), '', 'all sources were captured before delete')
  end)

  H.it('U12 identical-byte replacement is indistinguishable and documents the residual', function()
    local sb = H.sandbox()
    local _, _, _, pasted = paste_one_file(sb, 'file.txt')
    vim.uv.fs_unlink(pasted)
    H.mkfile(vim.fs.dirname(pasted), vim.fs.basename(pasted), { 'REGISTER-file.txt' })

    H.assert_true(history.undo() ~= nil,
      'identical-byte replacement matches the register and can be removed')
    H.assert_nil(vim.uv.fs_lstat(pasted), 'the indistinguishable replacement was deleted')
  end)

  H.it('U13 a missing or re-yanked register refuses Unpaste', function()
    for _, mode in ipairs({ 'missing', 're-yanked' }) do
      local sb = H.sandbox()
      local _, _, _, pasted = paste_one_file(sb, 'file.txt')
      local content_path = vim.fs.joinpath(sb.data_home, 'direct/register/content')
      if mode == 'missing' then
        vim.uv.fs_unlink(content_path)
      else
        local other = H.mkdir(sb.data_home, 'other-register')
        H.mkfile(other, 'file.txt', { 'DIFFERENT REGISTER' })
        vim.fn.writefile({ other }, content_path)
      end
      local undo_path = history_paths(sb)
      local before = log.read_raw(undo_path)

      H.assert_nil(history.undo(), mode .. ' register refuses Unpaste')
      H.assert_eq(vim.fn.readfile(pasted), { 'REGISTER-file.txt' },
        mode .. ' register leaves the pasted target')
      H.assert_eq(log.read_raw(undo_path), before, mode .. ' register preserves history')
    end
  end)
end)
