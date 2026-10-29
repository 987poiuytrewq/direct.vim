-- Assertions run after a normal Neovim startup with the plugin on runtimepath.
local function run()
  if vim.env.DIRECT_LIVE_MAP_DEFAULT_KEYS == 'false' then
    local function has_lhs(maps, lhs)
      for _, mapping in ipairs(maps) do
        if mapping.lhs == lhs then return true end
      end
      return false
    end
    assert(vim.bo.filetype == 'direct', 'directory startup was not intercepted with mappings off')
    assert(not has_lhs(vim.api.nvim_get_keymap('n'), '-'),
      'map_default_keys=false left the global - mapping installed')
    assert(not has_lhs(vim.api.nvim_buf_get_keymap(0, 'n'), '-'),
      'map_default_keys=false left a buffer-local - mapping installed')
    return 'LIVE_STARTUP_OPTOUT_OK'
  end

  local root = assert(vim.uv.fs_realpath(vim.env.DIRECT_LIVE_WORKSPACE),
    'workspace path is required and must resolve')
  local file = vim.fs.joinpath(root, 'alpha.txt')
  local child = vim.fs.joinpath(root, 'sub')

  local function lines()
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  local function feed(lhs)
    local keys = vim.api.nvim_replace_termcodes(lhs, true, false, true)
    vim.api.nvim_feedkeys(keys, 'xt', false)
  end

  assert(vim.bo.filetype == 'direct', 'CLI directory startup was not intercepted')
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(root),
    'startup listing is not attached to the requested directory: '
      .. vim.inspect(vim.api.nvim_buf_get_name(0)) .. ' != ' .. vim.inspect(root))
  assert(vim.deep_equal(lines(), { 'sub/', 'alpha.txt' }),
    'startup listing contents differ: ' .. vim.inspect(lines()))

  -- Exercise the buffer-local Enter mapping to open a file, then the global
  -- `-` mapping to list that file's directory.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed('<CR>')
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(file),
    '<CR> did not open the selected file')
  assert(vim.bo.filetype ~= 'direct', 'opening a file left it in a direct buffer')
  feed('-')
  assert(vim.bo.filetype == 'direct', 'global - did not list the file directory')
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(root),
    'global - listed the wrong directory')

  -- Enter a child directory and use the buffer-local `-` override to return.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed('<CR>')
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(child),
    '<CR> did not open the selected directory')
  feed('-')
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(root),
    'buffer-local - did not navigate to the parent directory')

  -- Exercise the user-facing write path rather than calling Buffer:sync().
  local rows = lines()
  rows[#rows + 1] = 'created.txt'
  vim.api.nvim_buf_set_lines(0, 0, -1, false, rows)
  vim.cmd('write')
  assert(vim.uv.fs_stat(vim.fs.joinpath(root, 'created.txt')) ~= nil,
    ':write did not create the new entry')
  assert(not vim.bo.modified, 'successful :write left the listing modified')
  return 'LIVE_STARTUP_OK'
end

local ok, result = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write('LIVE_STARTUP_FAIL\n' .. tostring(result) .. '\n')
  vim.cmd('cquit 1')
end
io.stdout:write(result .. '\n')
vim.cmd('qa!')
