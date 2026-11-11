-- Sync writes keep the editor responsive while a cross-device tree is copied.
local H = require('tests.support.harness')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

H.describe('asynchronous sync', function()
  H.it(':write returns while a cross-device directory copy is pending', function()
    clean_buffers()
    local pending = require('direct.pending')
    local fs = require('direct.fs')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkdir(root, 'old/nested')
    H.mkfile(root, 'old/nested/item.txt', { 'payload' })
    local source, destination = root .. '/old', root .. '/new'
    require('direct').list(root)
    H.set_direct_rows(0, { 'new/' })

    local real_rename = fs.rename_noreplace
    local rename_calls = {}
    local restore_rename = H.stub(fs, 'rename_noreplace', function(from, to, identity)
      rename_calls[#rename_calls + 1] = { from, to }
      if vim.fs.normalize(from) == source and vim.fs.normalize(to) == destination then
        return nil, 'EXDEV: simulated second filesystem', 'EXDEV'
      end
      return real_rename(from, to, identity)
    end)
    local real_copyfile = fs.uv.fs_copyfile
    local copy_deferred
    local restore_copy = H.stub(fs.uv, 'fs_copyfile', function(from, to, flags, callback)
      copy_deferred = function()
        return real_copyfile(from, to, flags, callback)
      end
      return true
    end)

    H.capture_messages()
    local wrote, write_err = pcall(vim.cmd, 'write')
    H.assert_true(wrote, 'write starts the asynchronous sync: ' .. tostring(write_err))
    H.assert_true(pending.is_pending(), 'the save owns the Direct pending-operation guard')
    H.assert_true(fs.exists(source), 'the original directory remains while copying')
    H.assert_false(fs.exists(destination), 'the destination is not committed early')
    H.assert_true(vim.wait(2000, function() return copy_deferred ~= nil end),
      'the background action reaches the pending copy')
    H.assert_not_nil(copy_deferred, 'the large copy was dispatched asynchronously: '
      .. vim.inspect(rename_calls))
    H.assert_notified('copying ' .. source .. ' to ' .. destination
      .. ' across filesystems', vim.log.levels.INFO)

    H.assert_nil(require('direct').sync(), 'a second DirectSync is refused while pending')
    H.assert_true(pending.is_pending(), 'the refusal does not release the save lock')

    copy_deferred()
    H.assert_true(vim.wait(5000, function() return not pending.is_pending() end),
      'the sync releases the pending guard after copy and history commit')
    restore_copy()
    restore_rename()

    H.assert_false(fs.exists(source), 'the verified source tree is removed')
    H.assert_fs_eq(destination, { 'nested/', 'nested/item.txt' },
      'the directory tree is committed intact')
    H.assert_false(vim.bo.modified, 'the listing is marked clean after completion')
    H.assert_eq(vim.fn.readfile(vim.fs.joinpath(sb.data_home,
      'direct/history/undo.log'))[2],
      require('tests.support.history_fixtures').move(source .. '/', destination .. '/'),
      'the move is undoable after the asynchronous commit')
  end)
end)
