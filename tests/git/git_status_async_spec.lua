-- tests/git_status_async_spec.lua -- a slow status query never blocks listing.
local H = require('tests.support.harness')

local function git(root, ...)
  local args = { 'git', '-C', root }
  for _, part in ipairs({ ... }) do args[#args + 1] = part end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then error(result.stderr) end
end

local function init_repo(root)
  git(root, 'init', '-q')
  git(root, 'config', 'user.name', 'Direct Test')
  git(root, 'config', 'user.email', 'direct-test@example.invalid')
  H.mkfile(root, 'tracked.txt', { 'base' })
  git(root, 'add', '--all')
  git(root, 'commit', '-q', '-m', 'base')
end

local function message_count(text, needle)
  local count, start = 0, 1
  while true do
    local found = text:find(needle, start, true)
    if not found then return count end
    count, start = count + 1, found + #needle
  end
end

H.describe('asynchronous Git status', function()
  H.it('returns the listing before a hung status times out and warns only once', function()
    pcall(vim.cmd, '%bwipeout!')
    local sb = H.sandbox()
    local root = H.mkdir(sb.root, 'repo')
    init_repo(root)
    require('direct.config').setup({ git = { timeout_ms = 500 } })

    local real_system = vim.system
    local status_started, status_calls, kill_calls = false, 0, 0
    vim.system = function(argv, options, on_exit)
      local is_status = false
      for _, arg in ipairs(argv) do
        if arg == 'status' then is_status = true; break end
      end
      if is_status then
        status_started = true
        status_calls = status_calls + 1
        return {
          kill = function()
            kill_calls = kill_calls + 1
            return true
          end,
        }
      end
      return real_system(argv, options, on_exit)
    end

    H.capture_messages()
    local started = vim.uv.hrtime()
    local listing = require('direct').list(root)
    local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
    H.assert_not_nil(listing, 'listing succeeds while Git status is unresolved')
    H.assert_true(elapsed_ms < 500,
      string.format('listing returned before the 500ms status timeout (%.1fms)', elapsed_ms))
    H.assert_true(vim.tbl_contains(H.buf_lines(), 'tracked.txt'),
      'ordinary entries render immediately')

    H.assert_true(vim.wait(2000, function()
      return status_started and H.messages():find('Git status timed out', 1, true) ~= nil
    end), 'the timeout is reported after the listing appears')
    H.assert_eq(kill_calls, 1, 'the timed-out Git process is terminated')
    H.assert_eq(message_count(H.messages(), 'Git status unavailable'), 1,
      'the user is warned once for this repository')

    require('direct.buffer.buffer').refresh_git_status()
    H.assert_true(vim.wait(1000, function()
      return kill_calls == 2
    end), 'a second status request also reaches its timeout')
    H.assert_eq(message_count(H.messages(), 'Git status unavailable'), 1,
      'a later timeout does not repeat the warning')
    vim.system = real_system
  end)
end)
