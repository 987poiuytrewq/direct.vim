-- tests/run.lua -- zero-dependency harness entry point for direct.nvim.
--
-- Usage:
--   nvim --headless -l tests/run.lua              # run every tests/*_spec.lua
--   nvim --headless -l tests/run.lua sync         # only specs whose name matches "sync"
--   nvim --headless -l tests/run.lua --verbose    # per-assert output
--   nvim --headless -l tests/run.lua --print-tmp  # also print the temp root
--
-- Boot notes (spec section 11.1), all re-measured on nvim 0.12.5:
--   * `nvim --headless -l` does NOT load user config or plugins from
--     runtimepath, so the repo root is prepended and the runtime files are
--     sourced explicitly below.
--   * Under `-l`, Neovim boots with `filetype plugin:OFF`. `filetype plugin
--     on` is therefore mandatory or `ftplugin/direct.lua` would never load and
--     every buffer-local mapping assertion would be vacuously true.
--   * Under `-l`, `v:vim_did_enter == 1` already when this script starts and
--     `VimEnter` is never fired by the runtime. Specs that depend on `VimEnter`
--     must call `nvim_exec_autocmds('VimEnter', {})` explicitly.
--   * `vim.fs.realpath` does not exist on the target runtime; the temp root is
--     created with `vim.uv.fs_mkdtemp` and resolved with `vim.uv.fs_realpath`.
--   * A boot-scoped XDG_DATA_HOME is set *before* the plugin is sourced
--     (reviewer B3), so the first load resolves against a temp dir rather than
--     the user's real data dir; every later spec is re-pointed by the harness.
--
-- Isolation (spec section 11.1): specs/`it` blocks may freely mutate any global
-- *option* -- the harness snapshots every option at setup() and restores it at
-- every file and test boundary (reviewer B2). They may also register any
-- augroup/autocmd, in any group; every augroup/autocmd not present at boot is
-- cleared at every boundary, except the filetype machinery (reviewer B1). Scope
-- a single-assertion change with `with_option(name, value, fn)` or
-- `with_env(vars, fn)`.

-- Repo root from this script's own path: <root>/tests/run.lua -> <root>.
local this_file = debug.getinfo(1, 'S').source:gsub('^@', '')
local this_abs = vim.fn.fnamemodify(this_file, ':p')
local tests_dir = vim.fs.dirname(this_abs)
local root = vim.fs.dirname(tests_dir)

-- Boot step 1: prepend the repo root.
vim.opt.runtimepath:prepend(root)

-- Boot step 2: create the run temp root and point XDG_DATA_HOME at a boot home
-- BEFORE the plugin is sourced (reviewer B3). The root is realpath-resolved
-- immediately so glob and fs_realpath agree for every fixture derived from it.
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
for _, value in ipairs(arg or {}) do
  if value == '--verbose' or value == '-v' then
    verbose = true
  elseif value == '--print-tmp' then
    print_tmp = true
  elseif value:sub(1, 2) == '--' then
    -- Unknown flag: ignored so future options do not break older invocations.
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
  -- Capture the pristine post-boot option/autocmd baseline now that the runtime
  -- files are sourced and `filetype plugin on` has run. Inside main() so a
  -- baseline failure still runs the temp-root cleanup below.
  H.setup({ base = base, verbose = verbose })

  io.write(string.format('== direct tests ==\nrepo: %s\n', root))
  if print_tmp or verbose then
    -- Opt-in: the temp root differs on every run (reviewer B6), so it must not
    -- appear in the default output that the determinism gate compares.
    io.write(string.format('tmp:  %s\n', base))
  end
  if #specs == 0 then
    io.write('no specs matched\n')
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
