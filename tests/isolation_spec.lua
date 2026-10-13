-- tests/isolation_spec.lua -- self-test for the harness isolation guarantees
-- (reviewer B1 autocmds, B2 options).
--
-- This file proves the *within-file* half (one `it` cannot leak into the next)
-- and deliberately leaves foreign state behind in its final spec so
-- tests/zzz_isolation_observer_spec.lua -- which sorts last and runs after this
-- file -- can prove the *cross-file* half.

local H = require('tests.support.harness')

local WITHIN_AUGROUP = 'direct_probe_within'
local CROSS_AUGROUP = 'direct_probe_cross'

-- Count autocmds anywhere whose command carries `marker`, independent of their
-- augroup (nvim_get_autocmds errors on a missing group, so a global scan is the
-- robust way to assert "none remain").
local function count_probe_autocmds(marker)
  local found = 0
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    if (au.command or ''):find(marker, 1, true) then
      found = found + 1
    end
  end
  return found
end

H.describe('isolation: autocmd within a file', function()
  H.it('registers a foreign augroup and autocmd', function()
    vim.api.nvim_create_augroup(WITHIN_AUGROUP, { clear = true })
    vim.api.nvim_create_autocmd('BufEnter', {
      group = WITHIN_AUGROUP,
      pattern = '*',
      command = 'let g:direct_probe_within = 1',
    })
    H.assert_eq(vim.fn.exists('#' .. WITHIN_AUGROUP), 1,
      'foreign augroup is visible in its own spec')
    H.assert_eq(count_probe_autocmds('direct_probe_within'), 1,
      'foreign autocmd is registered')
  end)

  H.it('the next spec sees no foreign autocmd', function()
    H.assert_eq(vim.fn.exists('#' .. WITHIN_AUGROUP), 0,
      'foreign augroup cleared before the next spec')
    H.assert_eq(count_probe_autocmds('direct_probe_within'), 0,
      'foreign autocmd cleared before the next spec')
  end)
end)

H.describe('isolation: option within a file', function()
  H.it('mutates ignorecase with with_option and raw', function()
    H.assert_false(vim.o.ignorecase, 'ignorecase starts at the -l default (false)')
    H.with_option('ignorecase', true, function()
      H.assert_true(vim.o.ignorecase, 'with_option applies the value inside fn')
    end)
    H.assert_false(vim.o.ignorecase, 'with_option restores the value after fn')
    vim.o.ignorecase = true
    H.assert_true(vim.o.ignorecase, 'raw mutation applied')
  end)

  H.it('the next spec sees ignorecase restored', function()
    H.assert_false(vim.o.ignorecase, 'ignorecase restored before the next spec')
  end)
end)

-- Registered last: the state left here must be cleaned at the *file* boundary
-- and is checked by the observer spec that runs after this file.
H.describe('isolation: cross-file probe', function()
  H.it('leaves foreign autocmd and option state for the next spec file', function()
    vim.api.nvim_create_augroup(CROSS_AUGROUP, { clear = true })
    vim.api.nvim_create_autocmd('BufEnter', {
      group = CROSS_AUGROUP,
      pattern = '*',
      command = 'let g:direct_probe_cross = 1',
    })
    vim.o.ignorecase = true
    H.assert_eq(vim.fn.exists('#' .. CROSS_AUGROUP), 1, 'cross-file augroup registered')
    H.assert_true(vim.o.ignorecase, 'cross-file option mutation applied')
  end)
end)

-- B1-1: a default-group FileType autocmd must not survive the file boundary.
-- The BufEnter probes above cannot catch the removed `event == 'FileType'`
-- exemption because they never register a FileType handler.
H.describe('isolation: default-group FileType probe', function()
  H.it('leaves a default-group FileType autocmd for the next spec file', function()
    vim.api.nvim_create_autocmd('FileType', {
      pattern = '*',
      command = 'let g:direct_probe_default_ft = 1',
    })
    H.assert_eq(count_probe_autocmds('direct_probe_default_ft'), 1,
      'default-group FileType autocmd registered')
  end)
end)

-- T-002 (reviewer B3): `filetype plugin on` must actually work under `-l`, and
-- the filetype machinery must survive the harness's per-boundary autocmd/option
-- reset. An ftplugin in a temp rtp dir bumps `g:direct_probe_ft_count`; the
-- observer spec (which sorts last, after this file's boundary) re-triggers it
-- from the dir left in `g:direct_probe_ft_rtp`. If the machinery were dead --
-- filetype plugins off, or its FileType handler cleared as "foreign" -- the
-- buffer-local mapping assertions elsewhere would pass vacuously, and the
-- observer would fail here instead.
--
-- The probe dir is created under the run temp root (`H._base`, removed at the
-- end of the run) and deliberately not registered as a sandbox, because it must
-- outlive this file's boundary.
H.describe('isolation: filetype machinery probe', function()
  H.it('sources an ftplugin from a temp rtp dir when filetype is set', function()
    local dir = vim.uv.fs_mkdtemp(vim.fs.joinpath(H._base, 'ftprobe-XXXXXX'))
    H.assert_not_nil(dir, 'created a temp rtp dir under the run root')
    vim.fn.mkdir(vim.fs.joinpath(dir, 'ftplugin'), 'p')
    vim.fn.writefile({
      "vim.g.direct_probe_ft_count = (vim.g.direct_probe_ft_count or 0) + 1",
    }, vim.fs.joinpath(dir, 'ftplugin', 'directprobe.lua'))
    vim.g.direct_probe_ft_rtp = dir

    vim.opt.runtimepath:prepend(dir)
    vim.g.direct_probe_ft_count = nil
    vim.cmd('enew')
    vim.bo.filetype = 'directprobe'

    H.assert_eq(vim.g.direct_probe_ft_count, 1,
      'ftplugin from the temp rtp dir loaded when filetype was set')
  end)
end)

-- B8-1: with_env must restore a variable that was unset before the call,
-- including when fn raises. `saved[name] = nil` never created a key, so the
-- restore loop skipped it and the value leaked.
H.describe('isolation: with_env restores unset variables', function()
  local UNSET_ON_RETURN = 'DIRECT_PROBE_UNSET_RETURN'
  local UNSET_ON_RAISE = 'DIRECT_PROBE_UNSET_RAISE'

  H.it('unsets a previously-unset variable after a normal return', function()
    vim.env[UNSET_ON_RETURN] = nil
    H.assert_nil(vim.env[UNSET_ON_RETURN], 'precondition: variable starts unset')
    H.with_env({ [UNSET_ON_RETURN] = 'leaked-value' }, function()
      H.assert_eq(vim.env[UNSET_ON_RETURN], 'leaked-value', 'value visible inside fn')
    end)
    H.assert_nil(vim.env[UNSET_ON_RETURN], 'previously-unset variable is unset again')
  end)

  H.it('unsets a previously-unset variable after fn raises', function()
    vim.env[UNSET_ON_RAISE] = nil
    H.assert_nil(vim.env[UNSET_ON_RAISE], 'precondition: variable starts unset')
    H.assert_error(function()
      H.with_env({ [UNSET_ON_RAISE] = 'leaked-value' }, function()
        error('boom')
      end)
    end, 'boom')
    H.assert_nil(vim.env[UNSET_ON_RAISE], 'previously-unset variable is unset after a raise')
  end)
end)
