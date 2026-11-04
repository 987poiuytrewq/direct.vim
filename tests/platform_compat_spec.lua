-- platform_compat_spec.lua -- native and configured path separator behavior.

local H = require('tests.support.harness')
local buffer = require('direct.buffer')
local fs = require('direct.fs')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

H.describe('platform path compatibility', function()
  H.it('renders directory rows with the native separator and uses native paths', function()
    clean_buffers()
    local separator = package.config:sub(1, 1)
    require('direct.config').setup({
      map_default_keys = false,
      directory_separator = separator,
      git = { enabled = false },
    })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkdir(root, 'existing')

    buffer.list(root)

    H.assert_buf_eq({ 'existing' .. separator })
    H.assert_eq(buffer.entry_path(root, 'existing' .. separator),
      vim.fs.joinpath(root, 'existing') .. separator,
      'the rendered marker maps to a native filesystem path')
  end)

  H.it('supports a configured marker for nested creates without leaking it into paths', function()
    clean_buffers()
    local native = package.config:sub(1, 1)
    local marker = native == '/' and '\\' or '/'
    require('direct.config').setup({
      map_default_keys = false,
      directory_separator = marker,
      git = { enabled = false },
    })
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'workspace')
    H.mkdir(root, 'existing')
    local listing = buffer.list(root)

    H.assert_buf_eq({ 'existing' .. marker })
    H.assert_eq(buffer.entry_path(root, 'existing' .. marker),
      vim.fs.joinpath(root, 'existing') .. native)

    vim.api.nvim_buf_set_lines(0, -1, -1, false, {
      'created' .. marker,
      'nested' .. marker,
      'nested' .. marker .. 'child.txt',
    })
    H.assert_true(listing:sync() == true, 'configured directory rows sync successfully')
    H.assert_true(fs.is_dir(vim.fs.joinpath(root, 'created')))
    H.assert_true(fs.is_file(vim.fs.joinpath(root, 'nested', 'child.txt')))
    H.assert_not_nil(buffer._component_reason('bad' .. marker .. 'name'),
      'the configured row separator is reserved inside entry names')
  end)

  H.it('uses atomic no-replace moves on the current platform', function()
    local sb = H.sandbox()
    local source = H.mkfile(sb.root, 'source.txt', 'source')
    local destination = vim.fs.joinpath(sb.root, 'destination.txt')
    H.assert_true(fs.rename_noreplace(source, destination), 'free destination is committed')
    H.assert_false(fs.exists(source), 'source was moved')
    H.assert_eq(vim.fn.readfile(destination), { 'source' })

    local second_source = H.mkfile(sb.root, 'second.txt', 'second')
    H.assert_true(fs.rename_noreplace(second_source, destination) == nil,
      'occupied destination is refused')
    H.assert_true(fs.exists(second_source), 'refused source remains in place')
    H.assert_eq(vim.fn.readfile(destination), { 'source' },
      'refused move leaves the existing destination intact')
  end)
end)
