-- plugin/direct.lua -- the command/autocmd surface: nine commands, the netrw
-- neutralisation, the directory intercept and the deferred `-` mapping. Every
-- registration is idempotent (the harness sources this at every spec boundary).

-- Direct-buffer `BufWriteCmd` autocmds live in this augroup, created by
-- `direct.buffer`; do not reference the legacy Vimscript entry points.
local group = vim.api.nvim_create_augroup('direct', { clear = true })

-- netrw neutralisation runs at three points: clear the `FileExplorer` group at
-- load (pcall, when it already exists), again synchronously on `VimEnter`, and
-- once more on the next event-loop tick. The tick-deferred clear is credited
-- only with a group registered AFTER our handler inside the same `VimEnter`
-- batch, not with runtimepath order -- the synchronous clear already leaves zero
-- `FileExplorer` autocmds either way. Residual limit, not assumed away: netrw
-- sourced on a later tick/event re-registers the group after this clear has run.
--
-- `nvim_get_autocmds` raises on a missing group, so the `exists()` guard is
-- required. Clearing also removes netrw's own `VimEnter` handler (what stops
-- s:LocalBrowse on startup); the group itself survives, so a later netrw source
-- can re-register into it.
local function clear_netrw()
  if vim.fn.exists('#FileExplorer') > 0 then
    pcall(vim.api.nvim_clear_autocmds, { group = 'FileExplorer' })
  end
end

clear_netrw()

-- Registered at LOAD, not VimEnter: for `nvim <dir>/` BufEnter fires before
-- VimEnter. The predicate needs a name that resolves to a directory and
-- `filetype ~= 'direct'`; the filetype guard stops it re-triggering on direct
-- buffers, whose name IS a directory.
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

-- Independent of `config.install_deferred()`: netrw's own `VimEnter` handler
-- lives in FileExplorer and is removed by this clear.
vim.api.nvim_create_autocmd('VimEnter', {
  group = group,
  pattern = '*',
  desc = 'direct: neutralise netrw once more on VimEnter',
  callback = function()
    clear_netrw()
    vim.schedule(clear_netrw)
  end,
})

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

-- Under `nvim --headless -l` `v:vim_did_enter` is 1, so this installs the global
-- `-` immediately; a real startup defers to a one-shot VimEnter handler (config).
require('direct.config').install_deferred()
