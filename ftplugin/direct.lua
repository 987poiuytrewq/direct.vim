-- ftplugin/direct.lua -- installs configured buffer-local mappings into the
-- current buffer. `map_default_keys` controls defaults; explicit per-action
-- mappings and <Plug> entry points remain available when defaults are off.

-- Only installs mappings. Under `nvim --headless -l` this file loads only because
-- the harness ran `filetype plugin on`; with filetype plugins off it never loads.
local config = require('direct.config')

config.install_buffer_mappings(0)

-- Remove only mappings still owned by this ftplugin when the buffer leaves the
-- direct filetype. Preserve a hook installed by an earlier ftplugin.
local undo = "lua require('direct.config').clear_buffer_mappings(0)"
local previous = vim.b.undo_ftplugin
if type(previous) == 'string' and previous ~= '' then
  if not previous:find(undo, 1, true) then
    vim.b.undo_ftplugin = previous .. ' | ' .. undo
  end
else
  vim.b.undo_ftplugin = undo
end
