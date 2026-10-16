-- plugin/direct.lua -- commands, mappings, autocmds (spec section 6 / T-025).
--
-- Responsibility (spec section 5): register the nine user commands with the
-- exact flags of the retired Vimscript entry point, neutralise netrw
-- (B12/D7/R2), install the `BufEnter` directory intercept (D7), and hand the
-- global-mapping timing to `direct.config` (D10).
--
-- Loaded by `runtime! plugin/direct.lua` from the harness at boot and at every
-- spec boundary, so every registration below is idempotent: the `direct`
-- augroup is recreated with `clear = true` and `nvim_create_user_command`
-- replaces an existing definition of the same name.
--
-- B12 netrw neutralisation:
--   1. at load, clear the `FileExplorer` group if it already exists (pcall);
--   2. again on `VimEnter`, synchronously, and then once more on the next
--      event-loop tick (`vim.schedule`), so the group is also removed when
--      netrw's plugin file is sourced *after* our handler inside the same
--      `VimEnter` batch;
--   3. register the `BufEnter` intercept at load -- not at `VimEnter` -- so
--      `nvim <dir>/`, where `BufEnter` fires *before* `VimEnter`, is captured.
-- The deferred clear in (2) is credited only with what the synchronous clear
-- cannot see: a `FileExplorer` group registered *after* our handler inside the
-- same `VimEnter` batch. It is not about runtimepath order -- the synchronous
-- clear already leaves zero `FileExplorer` autocmds in both ordinary rtp
-- orders, and netrw's own `VimEnter` handler does not re-register the group.
-- See `clear_netrw` below for the residual limit (netrw sourced on a later
-- tick or later event than that tick).
-- Intercept predicate: the buffer has a name that resolves to an existing
-- directory (`fs.is_dir`) AND `&filetype !=# 'direct'`. There is deliberately no
-- "has no name" clause (unsatisfiable/dead, reviewer B1), and the filetype guard
-- stops the intercept re-triggering on direct buffers (whose name *is* a dir).
--
-- This module defines commands and autocmds only; every behaviour lives behind
-- `require('direct').<api>`.

-- Direct-buffer `BufWriteCmd` autocmds are created by `direct.buffer`
-- (`set_options`), in this augroup. Do not reference the legacy Vimscript
-- entry points here: the Lua facade is the only surface.

local group = vim.api.nvim_create_augroup('direct', { clear = true })

-- clear_netrw(): remove every autocmd in netrw's `FileExplorer` group. Idempotent
-- and safe when the group is absent -- `nvim_get_autocmds` raises on a missing
-- group, so the `exists()` guard is required. Clearing the group also removes
-- netrw's own `VimEnter` handler, which is what stops `s:LocalBrowse` running on
-- startup. The augroup itself survives the clear, so a later netrw source can
-- re-register into it (see the `VimEnter` handler below).
local function clear_netrw()
  if vim.fn.exists('#FileExplorer') > 0 then
    pcall(vim.api.nvim_clear_autocmds, { group = 'FileExplorer' })
  end
end

-- B12 step 1: clear netrw's FileExplorer group at load if it is already there
-- (the repo-after-$VIMRUNTIME order, where netrw's plugin file ran first).
clear_netrw()

-- B12 step 3: the directory intercept, registered at load.
vim.api.nvim_create_autocmd('BufEnter', {
  group = group,
  pattern = '*',
  desc = 'direct: open a directory buffer as a direct listing',
  callback = function(args)
    local name = vim.api.nvim_buf_get_name(args.buf)
    if name == '' then
      return
    end
    if vim.bo[args.buf].filetype == 'direct' then
      return
    end
    if require('direct.fs').is_dir(name) then
      require('direct').list(name)
    end
  end,
})

-- B12 step 2: clear netrw's group again on `VimEnter`, and once more on the
-- next event-loop tick. The synchronous clear handles the order where netrw's
-- plugin file ran before ours; the tick-deferred clear removes a `FileExplorer`
-- group that is registered *after* our handler inside the same `VimEnter` batch
-- (a plugin manager's own `VimEnter` loader). That in-batch case is the only
-- thing the deferred clear is credited with: the synchronous clear already
-- leaves zero `FileExplorer` autocmds in both ordinary runtimepath orders
-- (measured), and netrw's `VimEnter` handler does not re-register the group, so
-- the deferred clear is not what makes this order-independent.
--
-- Residual limit (stated, not assumed away): netrw sourced on a *later*
-- event-loop tick or a later event than that tick (for example a `User
-- VeryLazy` handler, or a manual `:packadd netrw` after startup) registers
-- `FileExplorer` again *after* this clear has run. Nothing in this plugin is
-- invoked by those events, so the neutralisation would have to be re-run then;
-- in such a layout netrw must be loaded before/at `VimEnter`.
--
-- `config.install_deferred()` (D10) must also run before this handler would
-- matter, but the two orderings are independent (netrw's own `VimEnter` lives in
-- FileExplorer and is removed by this clear).
vim.api.nvim_create_autocmd('VimEnter', {
  group = group,
  pattern = '*',
  desc = 'direct: neutralise netrw once more on VimEnter',
  callback = function()
    clear_netrw()
    vim.schedule(clear_netrw)
  end,
})

-- The nine commands (section 6), with the retired Vimscript flags:
--   :DirectList       -nargs=1 -complete=dir
--   :DirectListBuffer (none)
--   :DirectListCwd    (none)
--   :DirectSync       (none)
--   :DirectUndo       (none)
--   :DirectRedo       (none)
--   :DirectYank       -range
--   :DirectPaste      -nargs=? -complete=dir
--   :DirectPasteAs    -nargs=1 -complete=file
vim.api.nvim_create_user_command('DirectList', function(args)
  require('direct').list(args.args)
end, { nargs = 1, complete = 'dir', desc = 'direct: list a directory' })

vim.api.nvim_create_user_command('DirectListBuffer', function()
  require('direct').list_buffer()
end, { nargs = 0, desc = "direct: list the current buffer's directory" })

vim.api.nvim_create_user_command('DirectListCwd', function()
  require('direct').list_cwd()
end, { nargs = 0, desc = 'direct: list the current working directory' })

vim.api.nvim_create_user_command('DirectSync', function()
  require('direct').sync()
end, { nargs = 0, desc = 'direct: sync the listing with the filesystem' })

vim.api.nvim_create_user_command('DirectUndo', function()
  require('direct').undo()
end, { nargs = 0, desc = 'direct: undo the last filesystem action' })

vim.api.nvim_create_user_command('DirectRedo', function()
  require('direct').redo()
end, { nargs = 0, desc = 'direct: redo the last undone action' })

vim.api.nvim_create_user_command('DirectYank', function(args)
  require('direct').yank(args.line1, args.line2)
end, { nargs = 0, range = true, desc = 'direct: yank the ranged entries' })

vim.api.nvim_create_user_command('DirectPaste', function(args)
  require('direct').paste(args.args)
end, { nargs = '?', complete = 'dir', desc = 'direct: paste the register' })

vim.api.nvim_create_user_command('DirectPasteAs', function(args)
  require('direct').paste_as(args.args)
end, { nargs = 1, complete = 'file', desc = 'direct: paste as a given name' })

-- B12 step 2 + D10 deferred install. Under `nvim --headless -l`
-- `v:vim_did_enter == 1`, so this installs the global `-` mapping immediately;
-- in a real startup it defers to a one-shot `VimEnter` handler (config).
require('direct.config').install_deferred()
