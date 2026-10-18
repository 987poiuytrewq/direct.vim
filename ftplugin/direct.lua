-- ftplugin/direct.lua -- installs the nine buffer-local mappings into the current
-- buffer when `map_default_keys` is true. The table itself lives in
-- `direct.config` so setup() can clear and restore already-open buffers.

-- Only installs mappings. Under `nvim --headless -l` this file loads only because
-- the harness ran `filetype plugin on`; with filetype plugins off it never loads.
local config = require('direct.config')

if not config.options.map_default_keys then
  return
end

config.install_buffer_mappings(0)
