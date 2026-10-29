-- tests/run.lua -- zero-dependency harness entry point for direct.nvim.

-- Usage:
--   nvim --headless -l tests/run.lua              # run every tests/*_spec.lua
--   nvim --headless -l tests/run.lua sync         # filter spec filenames
--   nvim --headless -l tests/run.lua --verbose    # per-assert output
--   nvim --headless -l tests/run.lua --print-tmp  # print the temp root
--
-- Boot behavior verified on Neovim 0.12.5:
-- * `-l` loads neither user config nor runtimepath plugins, so the repo root is
--   prepended and plugin/runtime files are sourced explicitly.
-- * Filetype plugins are off; enable them before capturing the harness baseline
--   or buffer-local mapping assertions would be vacuous.
-- * `v:vim_did_enter` is already true and `VimEnter` does not fire under `-l`,
--   so tests that depend on it dispatch the event explicitly.
-- * `vim.fs.realpath` is unavailable; resolve the temporary root with `vim.uv`.
-- * Set a boot-scoped XDG_DATA_HOME before sourcing the plugin, then redirect it
--   per test file so the first load never touches the user's data directory.
--
-- Isolation: each test may mutate global options or register autocmds. Snapshot
-- every option and restore it at file/test boundaries; clear post-boot autocmds
-- while preserving the boot filetype machinery. Use `with_option`/`with_env` for
-- a single scoped assertion.

-- Repo root from this script's own path: <root>/tests/run.lua -> <root>.
local this_file = debug.getinfo(1, 'S').source:gsub('^@', '')
local this_abs = vim.fn.fnamemodify(this_file, ':p')
local tests_dir = vim.fs.dirname(this_abs)
local root = vim.fs.dirname(tests_dir)

-- Boot step 1: prepend the repo root.
vim.opt.runtimepath:prepend(root)

-- Boot step 2: create a temp root and set XDG_DATA_HOME before sourcing the
-- plugin. Resolve it immediately so fixtures use a consistent real path.
local os_tmp = vim.uv.os_tmpdir() or vim.env.TMPDIR or '/tmp'
local created = vim.uv.fs_mkdtemp(vim.fs.joinpath(os_tmp, 'direct-tests-XXXXXX'))
if not created then
  error('could not create temp root under ' .. os_tmp)
end
local base = vim.uv.fs_realpath(created) or created
local boot_home = vim.fs.joinpath(base, 'boot-home')
vim.fn.mkdir(boot_home, 'p')
vim.env.XDG_DATA_HOME = boot_home

-- Boot step 3: source the runtime files ourselves.
vim.cmd('runtime! plugin/direct.lua ftplugin/direct.lua syntax/direct.vim')

-- Boot step 4: enable filetype plugins (OFF under `-l`).
vim.cmd('filetype plugin on')

-- Make `require('direct')` (lua/) and `require('tests.support.harness')`
-- (repo root) resolvable regardless of runtimepath synchronisation timing.
package.path = table.concat({
  root .. '/?.lua',
  root .. '/?/init.lua',
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  package.path,
}, ';')

local H = require('tests.support.harness')

-- ---------------------------------------------------------------------------
-- Arguments: flags (--verbose, --print-tmp) and name filters.
-- ---------------------------------------------------------------------------

local verbose = false
local print_tmp = false
local filters = {}
local argument_error
for _, value in ipairs(arg or {}) do
  if value == '--verbose' or value == '-v' then
    verbose = true
  elseif value == '--print-tmp' then
    print_tmp = true
  elseif value:sub(1, 2) == '--' then
    argument_error = 'unknown option: ' .. value
  else
    filters[#filters + 1] = value
  end
end

local function matches_filters(name)
  if #filters == 0 then return true end
  for _, filter in ipairs(filters) do
    if name:find(filter, 1, true) then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Spec discovery: tests/*_spec.lua, sorted for determinism.
-- ---------------------------------------------------------------------------

local specs = {}
for name, kind in vim.fs.dir(tests_dir) do
  if kind == 'file' and name:match('_spec%.lua$') and matches_filters(name) then
    specs[#specs + 1] = { name = name, path = vim.fs.joinpath(tests_dir, name) }
  end
end
table.sort(specs, function(a, b) return a.name < b.name end)

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

local function main()
  if argument_error then
    io.stderr:write(argument_error .. '\n')
    return false
  end

  if #specs == 0 then
    io.stderr:write('no specs matched the requested filter(s)\n')
    return false
  end

  -- Capture the pristine post-boot option/autocmd baseline now that the runtime
  -- files are sourced and `filetype plugin on` has run. Inside main() so a
  -- baseline failure still runs the temp-root cleanup below.
  H.setup({ base = base, verbose = verbose })

  io.write(string.format('== direct tests ==\nrepo: %s\n', root))
  if print_tmp or verbose then
    -- Keep random temp paths out of default output so runs remain comparable.
    io.write(string.format('tmp:  %s\n', base))
  end
  local total_specs, total_passed, total_failed = 0, 0, 0
  for _, spec in ipairs(specs) do
    H.reset_registry()
    local loaded, load_err = xpcall(function()
      local chunk, compile_err = loadfile(spec.path)
      if not chunk then error(compile_err) end
      chunk()
    end, debug.traceback)

    if not loaded then
      io.write(string.format('FAIL %s (load error)\n%s\n', spec.name, load_err))
      total_failed = total_failed + 1
    else
      local ran, report = xpcall(H.run_all, debug.traceback)
      if not ran then
        io.write(string.format('FAIL %s (harness error)\n%s\n', spec.name, report))
        total_failed = total_failed + 1
      else
        io.write(string.format('-- %s\n%s', spec.name, report.text))
        total_specs = total_specs + report.specs
        total_passed = total_passed + report.passed
        total_failed = total_failed + report.failed
      end
    end
  end

  io.write(string.format('RUN: %d spec(s), %d passed, %d failed\n',
    total_specs, total_passed, total_failed))
  return total_failed == 0
end

local ok, result = xpcall(main, debug.traceback)

-- Boot cleanup: remove the run temp root (and every sandbox under it).
if base then
  pcall(vim.fs.rm, base, { recursive = true, force = true })
end

if not ok then
  io.stderr:write('harness error:\n' .. tostring(result) .. '\n')
end

local exit_code = (ok and result) and 0 or 1
io.stdout:flush()
io.stderr:flush()
os.exit(exit_code)
