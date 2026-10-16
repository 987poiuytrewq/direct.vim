-- tests/zzz_isolation_observer_spec.lua -- last-sorted cross-file isolation check.

local H = require('tests.support.harness')

local function count_probe_autocmds(marker)
  local found = 0
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    if (au.command or ''):find(marker, 1, true) then
      found = found + 1
    end
  end
  return found
end

H.describe('isolation: cross-file', function()
  H.it('sees no foreign augroup from the previous spec file', function()
    H.assert_eq(vim.fn.exists('#direct_probe_cross'), 0,
      'foreign augroup cleared at the file boundary')
    H.assert_eq(count_probe_autocmds('direct_probe_cross'), 0,
      'foreign autocmd cleared at the file boundary')
  end)

  H.it('sees ignorecase restored from the previous spec file', function()
    H.assert_false(vim.o.ignorecase,
      'leaked ignorecase restored at the file boundary')
  end)

  H.it('sees no default-group FileType autocmd from the previous spec file', function()
    H.assert_eq(count_probe_autocmds('direct_probe_default_ft'), 0,
      'default-group FileType autocmd cleared at the file boundary')
  end)

  H.it('sees the filetype machinery preserved', function()
    H.assert_eq(vim.fn.exists('#filetypeplugin'), 1,
      'filetypeplugin augroup preserved across the autocmd reset')
  end)

  -- The machinery must still *work*, not merely exist: isolation_spec.lua left a
  -- temp rtp dir with an ftplugin in `g:direct_probe_ft_rtp`, and re-triggering
  -- FileType here -- one file boundary later -- must still source it.
  H.it('still sources an ftplugin from a temp rtp dir after the file boundary', function()
    local dir = vim.g.direct_probe_ft_rtp
    H.assert_not_nil(dir, 'isolation_spec left the probe rtp dir')

    vim.opt.runtimepath:prepend(dir)
    vim.g.direct_probe_ft_count = nil
    vim.cmd('enew')
    vim.bo.filetype = 'directprobe'

    H.assert_eq(vim.g.direct_probe_ft_count, 1,
      'ftplugin still loads after the file boundary (filetype machinery alive)')
  end)
end)
