-- tests/health_spec.lua -- checks the health report's version and data directory.

local H = require('tests.support.harness')

H.describe('health: :checkhealth direct', function()
  H.it('reports the Neovim version floor and the resolved data directory', function()
    local paths = require('direct.paths')

    vim.cmd('checkhealth direct')

    local buf = vim.api.nvim_get_current_buf()
    H.assert_eq(vim.api.nvim_buf_get_name(buf), 'health://',
      'checkhealth focuses the health report buffer')
    H.assert_eq(vim.bo[buf].filetype, 'checkhealth', 'and marks it as a health buffer')

    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    H.assert_true(text:find('Neovim', 1, true) ~= nil, 'the report names Neovim')
    H.assert_true(text:find('(>= 0.11.7 required)', 1, true) ~= nil,
      'the report states the 0.11.7 floor')
    H.assert_true(text:find('OK', 1, true) ~= nil, 'the version check is OK on this runtime')
    H.assert_true(text:find('data directory: ' .. paths.data_home(), 1, true) ~= nil,
      'the report names the resolved data directory')
    H.assert_true(text:find('data directory is writable:', 1, true) ~= nil,
      'the report checks that Direct can write its data directory')
    H.assert_true(text:find('Git:', 1, true) ~= nil, 'the report includes Git availability/version')
    H.assert_true(text:find('undo.log: not initialized (fresh)', 1, true) ~= nil,
      'the report classifies fresh history')
    H.assert_true(text:find('recovery journal: none', 1, true) ~= nil,
      'the report checks for interrupted transactions')
    H.assert_true(text:find('trash size: 0 bytes', 1, true) ~= nil,
      'the report includes the trash size')
    H.assert_true(text:find('nvim-web-devicons:', 1, true) ~= nil,
      'the report notes optional icon-provider availability')
    H.assert_true(text:find('icons enabled:', 1, true) ~= nil,
      'the report includes current icon settings')
  end)

  H.it('reports damaged history without resetting it and flags a valid journal for recovery', function()
    local sb = H.sandbox()
    local history_dir = vim.fs.joinpath(sb.data_home, 'direct/history')
    vim.fn.mkdir(history_dir, 'p')
    local undo_path = vim.fs.joinpath(history_dir, 'undo.log')
    local malformed = '{"format":"direct-history","version":1}\nnot-json\n'
    H.assert_true(require('direct.log').write_raw_atomic(undo_path, malformed),
      'write a damaged history fixture')
    local transaction = require('direct.history.transaction')
    local journal = vim.json.encode({
      format = transaction.FORMAT,
      version = transaction.VERSION,
      kind = 'stacks',
      undo = { transaction.HEADER },
      redo = { transaction.HEADER },
    }) .. '\n'
    H.assert_true(require('direct.log').write_raw_atomic(
      vim.fs.joinpath(history_dir, 'transaction.json'), journal), 'write a valid transaction')

    vim.cmd('checkhealth direct')

    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    H.assert_true(text:find('undo.log: preserved because damaged or unrecognized', 1, true) ~= nil,
      'damaged history is reported as preserved')
    H.assert_true(text:find('unfinished transaction requires recovery', 1, true) ~= nil,
      'a parseable pending journal is reported as recovery-needed')
    H.assert_eq(require('direct.log').read_raw(undo_path), malformed,
      'health inspection leaves damaged history byte-for-byte')
  end)

  H.it('reports when the Git executable is unavailable', function()
    local real_executable = vim.fn.executable
    vim.fn.executable = function(name)
      if name == 'git' then return 0 end
      return real_executable(name)
    end

    vim.cmd('checkhealth direct')

    vim.fn.executable = real_executable
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    H.assert_true(text:find('Git executable is unavailable', 1, true) ~= nil,
      'health warns when Git is missing')
  end)

  H.it('reports a data-directory write failure and skips history inspection', function()
    local real_open = vim.uv.fs_open
    vim.uv.fs_open = function(path, flags, mode, callback)
      if tostring(path):find('.health-write-', 1, true) then
        if callback then
          callback('forced write probe failure')
          return
        end
        return nil, 'forced write probe failure'
      end
      return real_open(path, flags, mode, callback)
    end

    vim.cmd('checkhealth direct')

    vim.uv.fs_open = real_open
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    H.assert_true(text:find('data directory is not writable', 1, true) ~= nil,
      'write probe failure is reported')
    H.assert_true(text:find('history checks skipped because the data directory is not writable',
      1, true) ~= nil, 'history checks do not create data files after failed write probe')
  end)
end)
