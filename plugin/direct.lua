-- plugin/direct.lua -- the command/autocmd surface, the netrw
-- neutralisation, the directory intercept and the deferred `-` mapping. Every
-- registration is idempotent (the harness sources this at every spec boundary).

-- Direct-buffer `BufWriteCmd` autocmds live in this augroup, created by
-- `direct.buffer`; do not reference the legacy Vimscript entry points.
local group = vim.api.nvim_create_augroup('direct', { clear = true })
local constants = require('direct.constants')
require('direct.highlight').setup()

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
    if vim.bo[args.buf].filetype == constants.FILETYPE then
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
  require('direct').list(args.args, { discard = args.bang })
end, { nargs = 1, bang = true, complete = 'dir', desc = 'direct: list a directory' })

vim.api.nvim_create_user_command('DirectListBuffer', function(args)
  require('direct').list_buffer({ discard = args.bang })
end, { nargs = 0, bang = true, desc = "direct: list the current buffer's directory" })

vim.api.nvim_create_user_command('DirectListCwd', function(args)
  require('direct').list_cwd({ discard = args.bang })
end, { nargs = 0, bang = true, desc = 'direct: list the current working directory' })

vim.api.nvim_create_user_command('DirectSync', function()
  local synced, err = require('direct').sync(function() end)
  if synced == nil and err ~= 'another direct operation is pending' then
    error(err or 'sync refused')
  end
end, { nargs = 0, desc = 'direct: sync the listing with the filesystem' })

vim.api.nvim_create_user_command('DirectFoldAll', function()
  require('direct').fold_all()
end, { nargs = 0, desc = 'direct: collapse all directories in the listing' })

vim.api.nvim_create_user_command('DirectUnfoldAll', function()
  require('direct').unfold_all()
end, { nargs = 0, desc = 'direct: recursively expand all directories in the listing' })

vim.api.nvim_create_user_command('DirectToggleHidden', function()
  require('direct').toggle_hidden()
end, { nargs = 0, desc = 'direct: toggle hidden entries in this listing' })

vim.api.nvim_create_user_command('DirectToggleGitStatus', function()
  require('direct').toggle_git_status()
end, { nargs = 0, desc = 'direct: show only entries with Git status' })

vim.api.nvim_create_user_command('DirectToggleGitIgnore', function()
  require('direct').toggle_gitignore()
end, { nargs = 0, desc = 'direct: toggle Git-ignore filtering in this listing' })

vim.api.nvim_create_user_command('DirectGitStatus', function(args)
  require('direct.git_commands').status(args.fargs)
end, {
  nargs = '*',
  complete = function(arg_lead, cmdline, cursor_pos)
    return require('direct.git_commands').complete_status(arg_lead, cmdline, cursor_pos)
  end,
  desc = 'direct: show Git status for a directory listing',
})

vim.api.nvim_create_user_command('DirectGitDiff', function(args)
  require('direct.git_commands').diff(args.fargs)
end, {
  nargs = '*',
  complete = function(arg_lead, cmdline, cursor_pos)
    return require('direct.git_commands').complete_diff(arg_lead, cmdline, cursor_pos)
  end,
  desc = 'direct: toggle a branch-relative Git diff filter',
})

vim.api.nvim_create_user_command('DirectNextChange', function()
  require('direct').next_change()
end, { nargs = 0, desc = 'direct: navigate to the next changed entry' })

vim.api.nvim_create_user_command('DirectPreviousChange', function()
  require('direct').previous_change()
end, { nargs = 0, desc = 'direct: navigate to the previous changed entry' })

vim.api.nvim_create_user_command('DirectNextFile', function()
  require('direct').next_file()
end, { nargs = 0, desc = 'direct: navigate to the next file' })

vim.api.nvim_create_user_command('DirectPreviousFile', function()
  require('direct').previous_file()
end, { nargs = 0, desc = 'direct: navigate to the previous file' })

vim.api.nvim_create_user_command('DirectUndo', function()
  require('direct').undo()
end, { nargs = 0, desc = 'direct: undo the last filesystem action' })

vim.api.nvim_create_user_command('DirectRedo', function()
  require('direct').redo()
end, { nargs = 0, desc = 'direct: redo the last undone action' })

vim.api.nvim_create_user_command('DirectHistory', function(args)
  if #args.fargs == 0 then
    require('direct.history.view').show()
  elseif args.fargs[1] == 'drop' and #args.fargs <= 2 then
    local which = args.fargs[2] or 'undo'
    local dropped, err = require('direct.history.history').drop_top(which)
    if not dropped and err then
      require('direct.ui').notify('direct: ' .. tostring(err), vim.log.levels.ERROR)
    end
  else
    require('direct.ui').notify('direct: usage: :DirectHistory [drop [undo|redo]]',
      vim.log.levels.ERROR)
  end
end, {
  nargs = '*',
  complete = function(arg_lead, cmdline, cursor_pos)
    return require('direct.history.history').complete_history(arg_lead, cmdline, cursor_pos)
  end,
  desc = 'direct: show or edit filesystem history',
})

vim.api.nvim_create_user_command('DirectHistoryReset', function()
  require('direct').reset_history()
end, { nargs = 0, desc = 'direct: back up and reset filesystem history' })

vim.api.nvim_create_user_command('DirectTrash', function(args)
  local api = require('direct')
  local operation = args.fargs[1]
  if not operation then
    api.trash_list()
  elseif operation == 'restore' and args.fargs[2] then
    api.trash_restore(args.fargs[2], args.fargs[3], args.bang)
  elseif operation == 'empty' then
    api.trash_empty(args.bang)
  else
    require('direct.ui').notify(
      'direct: usage: :DirectTrash [restore {id} [path] | empty]', vim.log.levels.ERROR)
  end
end, { nargs = '*', bang = true, desc = 'direct: list and manage trashed entries' })

vim.api.nvim_create_user_command('DirectYank', function(args)
  require('direct').yank(args.line1, args.line2)
end, { nargs = 0, range = true, desc = 'direct: yank the ranged entries' })

vim.api.nvim_create_user_command('DirectPaste', function(args)
  require('direct').paste(args.args)
end, { nargs = '?', complete = 'dir', desc = 'direct: paste the register' })

vim.api.nvim_create_user_command('DirectPasteAs', function(args)
  require('direct').paste_as(args.args)
end, { nargs = 1, complete = 'file', desc = 'direct: paste as a given name' })

vim.api.nvim_create_user_command('DirectRun', function(args)
  require('direct').run(args.args)
end, { nargs = '+', desc = 'direct: run a shell command for the current entry' })

vim.api.nvim_create_user_command('DirectGit', function(args)
  require('direct').git(args.args)
end, { nargs = '+', desc = 'direct: run a Git command and refresh status' })

vim.api.nvim_create_user_command('DirectGitRestore', function()
  require('direct').restore_git()
end, { nargs = 0, desc = 'direct: confirm and restore Git worktree changes' })

-- Under `nvim --headless -l` `v:vim_did_enter` is 1, so this installs the global
-- `-` immediately; a real startup defers to a one-shot VimEnter handler (config).
require('direct.config').install_deferred()
