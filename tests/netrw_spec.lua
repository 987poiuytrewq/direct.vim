-- tests/netrw_spec.lua -- netrw neutralisation (R2 fix, spec 7 B12 / T-028).
--
-- netrw is NOT loaded under `nvim --headless -l` (no runtimepath plugins), so
-- this file sources `plugin/netrwPlugin.vim` itself and pins the three clauses
-- of T-028 / AC12:
--
--   1. after sourcing, netrw's `FileExplorer` group really does install a
--      `BufEnter` autocmd; firing `VimEnter` explicitly (under `-l` `VimEnter`
--      never fires on its own, spec 11.1) leaves ZERO `FileExplorer` `BufEnter`
--      autocmds -- synchronously, via our handler's clear, and again after the
--      tick-deferred clear the handler schedules;
--   2. `:edit <dir>` then yields `filetype=direct` with the correct listing
--      (not a netrw buffer);
--   3. the CLI ordering -- `BufEnter` firing *before* `VimEnter`, while netrw is
--      still loaded -- is still captured by the intercept registered at load,
--      and a non-direct directory buffer is converted (reviewer B1: a dead
--      predicate cannot satisfy this);
--   4. the repo-before-`$VIMRUNTIME` order, including a `FileExplorer` group
--      registered *after* our `VimEnter` handler inside the same batch, is
--      neutralised once startup completes.
--
-- netrw guards on `g:loaded_netrwPlugin`, so each `it` resets it (and clears the
-- group) before re-sourcing.
--
-- Since B12 now also clears on the next event-loop tick (`vim.schedule`), an
-- assertion that `count == 0` after firing `VimEnter` must let that tick run
-- first (`settle_netrw`) -- otherwise the assertion would depend on whether the
-- synchronous clear happened to suffice.

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

H.describe('netrw neutralisation (R2 / T-028)', function()
  H.it('netrw installs FileExplorer BufEnter autocmds and VimEnter removes them (R2/T-028)', function()
    clean_buffers()
    load_netrw()

    H.assert_true(vim.fn.exists('#FileExplorer') > 0, 'netrw created the FileExplorer group')
    H.assert_true(fileexplorer_bufenter_count() > 0, 'netrw installed a BufEnter autocmd')

    vim.api.nvim_exec_autocmds('VimEnter', {})

    H.assert_eq(settle_netrw(), 0, 'the VimEnter handler cleared them all')
  end)

  H.it(':edit {dir} after neutralisation is a direct buffer with the correct listing (R2/T-028)', function()
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

  H.it('a BufEnter before VimEnter (CLI startup) is captured while netrw is loaded (R2/T-028)', function()
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

  H.it('a non-direct directory buffer is converted by the intercept (reviewer B1) (R2/T-028)', function()
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

  H.it('repo before $VIMRUNTIME: FileExplorer registered after our VimEnter handler is still cleared (R2/T-028/AC12)', function()
    clean_buffers()

    -- AC12 says "after our VimEnter handler there are zero `#FileExplorer`
    -- `BufEnter` autocmds". With the repo BEFORE $VIMRUNTIME that handler runs
    -- before netrw's plugin file, so the group can still appear (or reappear)
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
