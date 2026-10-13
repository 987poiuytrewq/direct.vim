-- ftplugin/direct.lua -- buffer-local mappings for filetype=direct (T-026).
--
-- The nine mappings installed by the retired `ftplugin/direct.vim`, rebuilt on
-- `<Cmd>` (never a `:` command that would leave visual mode / re-trigger
-- mappings) and installed only when `map_default_keys` is true (section 6).
-- The table lives in `direct.config` (P2, Greptile PR #1) so setup() can clear
-- and restore these maps in ALREADY-open direct buffers; this file only asks
-- config to install them into the current buffer.
--
-- Only installs mappings: no commands, no autocmds. Reachable under
-- `nvim --headless -l` only because the harness ran `filetype plugin on`
-- (T-002, reviewer B3) -- with filetype plugins off this file never loads and an
-- assertion here would be vacuously green.

local config = require('direct.config')

if not config.options.map_default_keys then
  return
end

config.install_buffer_mappings(0)
