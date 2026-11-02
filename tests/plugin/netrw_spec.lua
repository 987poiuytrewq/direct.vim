-- tests/netrw_spec.lua -- netrw interception and startup ordering.
-- `-l` skips runtimepath plugins, so this test sources netrw explicitly.

-- 1. Sourcing netrw registers `FileExplorer`'s `BufEnter`; fire `VimEnter`
--    explicitly because `-l` does not fire it, then wait for the scheduled clear.
-- 2. Verify `:edit <dir>` yields a direct listing rather than a netrw buffer.
-- 3. Exercise CLI order: `BufEnter` occurs before `VimEnter` while netrw is loaded.
-- 4. Put the repository before `$VIMRUNTIME` so netrw can register after our
--    handler in the same startup batch; the deferred clear must still remove it.
--
-- Each test resets netrw's loaded guard and clears the group before re-sourcing.

local H = require('tests.support.harness')

local function clean_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

-- fileexplorer_bufenter_count() -> the number of FileExplorer BufEnter
-- autocmds, or 0 when the group does not exist. nvim_get_autocmds raises on a
-- missing group, hence the exists() guard.
local function fileexplorer_bufenter_count()
  if vim.fn.exists('#FileExplorer') == 0 then
    return 0
  end
  local n = 0
  for _ in ipairs(vim.api.nvim_get_autocmds({ group = 'FileExplorer', event = 'BufEnter' })) do
    n = n + 1
  end
  return n
end

-- load_netrw() -> (re-)source netrwPlugin.vim with its loaded-guard cleared.
local function load_netrw()
  pcall(vim.api.nvim_clear_autocmds, { group = 'FileExplorer' })
  vim.g.loaded_netrwPlugin = nil
  vim.g.loaded_netrw = nil
  vim.cmd('runtime! plugin/netrwPlugin.vim')
end

-- settle_netrw([timeout_ms]) -> the FileExplorer BufEnter count after letting
-- the event loop run for one tick.
--
-- plugin/direct.lua clears netrw synchronously in its `VimEnter` handler and
-- again on the next event-loop tick (`vim.schedule`). Under `-l` nothing runs
-- that tick on its own, so a spec must pump the main loop before asserting
-- `count == 0`; otherwise the assertion only covers the synchronous clear.
--
-- The wait uses an always-false condition deliberately: a count-based condition
-- would return immediately -- and vacuously -- whenever the synchronous clear
-- already zeroed the group, without ever giving the scheduled clear a chance to
-- run. `vim.wait` processes the main loop, so the `vim.schedule` callback runs
-- inside it.
local function settle_netrw(timeout_ms)
  vim.wait(timeout_ms or 50, function() return false end)
  return fileexplorer_bufenter_count()
end

local function enter_buffer_named(path)
  vim.cmd('enew')
  vim.api.nvim_buf_set_name(0, path)
end

H.describe('netrw neutralisation', function()
  H.it('netrw installs FileExplorer BufEnter autocmds and VimEnter removes them', function()
    clean_buffers()
    load_netrw()

    H.assert_true(vim.fn.exists('#FileExplorer') > 0, 'netrw created the FileExplorer group')
    H.assert_true(fileexplorer_bufenter_count() > 0, 'netrw installed a BufEnter autocmd')

    vim.api.nvim_exec_autocmds('VimEnter', {})

    H.assert_eq(settle_netrw(), 0, 'the VimEnter handler cleared them all')
  end)

  H.it(':edit {dir} after neutralisation is a direct buffer with the correct listing', function()
    clean_buffers()
    local sb = H.sandbox()
    local dir = H.mkdir(sb.root, 'dir')
    H.mkdir(dir, 'sub')
    H.mkfile(dir, 'a.txt', { 'a' })

    load_netrw()
    vim.api.nvim_exec_autocmds('VimEnter', {})
    H.assert_eq(settle_netrw(), 0, 'netrw is neutralised before the edit')

    vim.cmd('edit ' .. vim.fn.fnameescape(dir))

    H.assert_eq(vim.bo.filetype, 'direct', ':edit <dir> is a direct buffer, not netrw')
    H.assert_buf_eq({ 'sub/', 'a.txt' })
  end)

  H.it('a BufEnter before VimEnter (CLI startup) is captured while netrw is loaded', function()
    clean_buffers()
    local sb = H.sandbox()
    local dir = H.mkdir(sb.root, 'clidir')
    H.mkfile(dir, 'c.txt', { 'c' })

    load_netrw()
    H.assert_true(fileexplorer_bufenter_count() > 0, 'netrw is loaded and active')

    enter_buffer_named(dir)
    vim.api.nvim_exec_autocmds('BufEnter', {})

    H.assert_eq(vim.bo.filetype, 'direct', 'the intercept won the CLI ordering (BufEnter first)')
    H.assert_buf_eq({ 'c.txt' })
  end)

  H.it('a non-direct directory buffer is converted by the intercept', function()
    clean_buffers()
    local sb = H.sandbox()
    local dir = H.mkdir(sb.root, 'plaindir')
    H.mkfile(dir, 'd.txt', { 'd' })

    load_netrw()
    vim.api.nvim_exec_autocmds('VimEnter', {})
    H.assert_eq(settle_netrw(), 0, 'netrw is neutralised')

    enter_buffer_named(dir)
    H.assert_true(vim.bo.filetype ~= 'direct', 'sanity: not a direct buffer before BufEnter')

    vim.api.nvim_exec_autocmds('BufEnter', {})

    H.assert_eq(vim.bo.filetype, 'direct', 'the intercept converted the non-direct buffer')
    H.assert_buf_eq({ 'd.txt' })
  end)

  H.it('repo before $VIMRUNTIME: FileExplorer registered after our VimEnter handler is still cleared', function()
    clean_buffers()

    -- Expect no `#FileExplorer` `BufEnter` autocmds after our VimEnter handler.
    -- With the repo before `$VIMRUNTIME`, our handler runs before netrw's plugin,
    -- so the group can appear again after the synchronous clear.
    -- after the synchronous clear. Reproduce both halves of that order:
    --
    --   (a) netrw's plugin file sourced after our plugin (the rtp order);
    load_netrw()
    H.assert_true(fileexplorer_bufenter_count() > 0,
      'netrw installed its BufEnter autocmd after our plugin was sourced')

    --   (b) netrw's plugin file sourced again *inside the VimEnter batch*, after
    --       our handler has already run. This is what a plugin manager's own
    --       VimEnter loader (or any rtp entry after ours) does; a clear that
    --       only runs synchronously inside our handler misses it. Re-sourcing
    --       the real netrw plugin keeps the simulation honest: it re-creates
    --       `FileExplorer` exactly as netrw does.
    local late = vim.api.nvim_create_augroup('netrw_late_source', { clear = true })
    vim.api.nvim_create_autocmd('VimEnter', {
      group = late,
      once = true,
      callback = load_netrw,
    })

    vim.api.nvim_exec_autocmds('VimEnter', {})
    H.assert_eq(fileexplorer_bufenter_count(), 1,
      'sanity: the late source re-registered FileExplorer after the synchronous clear')

    -- The tick-deferred clear is what removes it; the count must be 0 once
    -- startup completes (i.e. after that scheduled callback has run).
    H.assert_eq(settle_netrw(), 0,
      'zero FileExplorer BufEnter autocmds once startup completes')
  end)
end)
