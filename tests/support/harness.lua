-- tests/support/harness.lua -- zero-dependency test harness for direct.nvim.
-- Uses Neovim built-ins and Lua's standard library.
-- Provides registration, assertions, sandboxes, buffer/prompt helpers, and isolation.

-- `assert_eq(actual, expected[, msg])` is the default; `assert_buf_eq` takes
-- expected lines first because it reads the actual buffer named by its second arg.
--
-- Isolation model:
-- * Snapshot every global option at setup and restore it at every file/test
--   boundary; an allowlist would miss options a test mutates.
-- * Clear post-boot augroups/autocmds, including default-group `FileType` hooks.
--   Filetype machinery survives because it is part of the boot baseline.
-- * Forget plugin modules before re-sourcing the plugin so tests cannot retain
--   stale module tables. Set each file's XDG_DATA_HOME before that re-source.
--
-- The runner drives these boundaries through the private lifecycle hooks.

local M = {}

-- ---------------------------------------------------------------------------
-- Configuration and per-run state
-- ---------------------------------------------------------------------------

M._base = nil                 -- temp root for this run (realpath-resolved)
M._verbose = false            -- per-assert output when true
M._suites = {}                -- registered describe() blocks, for the current file
M._current = nil              -- describe() block currently open
M._sandboxes = {}             -- sandboxes created during the current test
M._file_home = nil            -- per-spec XDG_DATA_HOME temp dir
M._file_ui = nil              -- direct.ui captured before the per-file unload
M._option_snapshot = nil      -- every global option captured at setup()
M._boot_augroups = nil        -- augroups present at boot (protected baseline)
M._boot_autocmd_kinds = nil   -- autocmd identities present at boot (protected baseline)
M._assert_log = {}            -- per-test assert trace, only used with --verbose

-- setup() must run after the boot runtime files are sourced (tests/run.lua), so
-- the baseline it captures is the pristine post-boot state.
function M.setup(opts)
  opts = opts or {}
  M._base = opts.base
  M._verbose = opts.verbose or false

  -- Option baseline: every global option. Any option a spec mutates is restored
  -- at the next boundary, so no option can leak.
  M._option_snapshot = {}
  for name in pairs(vim.api.nvim_get_all_options_info()) do
    pcall(function() M._option_snapshot[name] = vim.o[name] end)
  end

  -- Autocmd baseline: every augroup and every autocmd identity registered by
  -- boot (internal groups, filetype machinery, and plugin/direct.lua's own
  -- autocmds). Anything that is not in this baseline is foreign state.
  M._boot_augroups = {}
  for _, name in ipairs(vim.fn.getcompletion('', 'augroup')) do
    M._boot_augroups[name] = true
  end
  M._boot_autocmd_kinds = {}
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    M._boot_autocmd_kinds[M._autocmd_kind(au)] = true
  end
end

-- Identity of an autocmd independent of the transient numeric id, so a plugin
-- that clears and re-registers its augroup on re-source still matches the
-- baseline. The command is part of the identity: without it, a spec autocmd
-- that merely reuses a boot group/event/pattern would match a baseline entry
-- and survive every boundary.
function M._autocmd_kind(au)
  return string.format('%s\0%s\0%s\0%s',
    au.group_name or '', au.event or '', au.pattern or '', au.command or '')
end

-- ---------------------------------------------------------------------------
-- Registry: describe / it
-- ---------------------------------------------------------------------------

function M.describe(name, fn)
  local suite = { name = name, tests = {} }
  M._suites[#M._suites + 1] = suite
  local previous = M._current
  M._current = suite
  fn()
  M._current = previous
end

function M.it(name, fn)
  assert(M._current, 'it() called outside describe()')
  M._current.tests[#M._current.tests + 1] = { name = name, fn = fn }
end

function M.reset_registry()
  M._suites = {}
  M._current = nil
end

-- ---------------------------------------------------------------------------
-- Verbose per-assert tracing (verbose = per-assert output)
-- ---------------------------------------------------------------------------

local function trace(line)
  if M._verbose then
    M._assert_log[#M._assert_log + 1] = '      ' .. line
  end
end

-- ---------------------------------------------------------------------------
-- Assertions (raise on failure; the runner turns the raise into a FAIL line)
-- ---------------------------------------------------------------------------

function M.fail(msg)
  trace('FAIL ' .. (msg or 'assertion failed'))
  error(msg or 'assertion failed', 0)
end

local function pass(label, msg)
  trace('ok   ' .. label .. (msg and (': ' .. msg) or ''))
end

local function format_mismatch(label, actual, expected)
  return string.format('%s\n  expected: %s\n  actual:   %s',
    label, vim.inspect(expected), vim.inspect(actual))
end

function M.assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass('assert_eq', msg)
  else
    M.fail(msg and (msg .. '\n' .. format_mismatch('assert_eq failed', actual, expected))
      or format_mismatch('assert_eq failed', actual, expected))
  end
end

function M.assert_true(value, msg)
  if value == true then
    pass('assert_true', msg)
  else
    M.fail((msg or 'assert_true failed') .. ': expected true, got ' .. vim.inspect(value))
  end
end

function M.assert_false(value, msg)
  if value == false then
    pass('assert_false', msg)
  else
    M.fail((msg or 'assert_false failed') .. ': expected false, got ' .. vim.inspect(value))
  end
end

function M.assert_nil(value, msg)
  if value == nil then
    pass('assert_nil', msg)
  else
    M.fail((msg or 'assert_nil failed') .. ': expected nil, got ' .. vim.inspect(value))
  end
end

function M.assert_not_nil(value, msg)
  if value ~= nil then
    pass('assert_not_nil', msg)
  else
    M.fail((msg or 'assert_not_nil failed') .. ': expected a value, got nil')
  end
end

function M.assert_error(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then
    M.fail(msg or 'assert_error: expected an error, got none')
  end
  err = tostring(err)
  if pattern and not err:find(pattern, 1, true) then
    M.fail(string.format('assert_error: error %q did not contain %q', err, pattern))
  end
  pass('assert_error', msg)
  return err
end

-- ---------------------------------------------------------------------------
-- Sandbox and filesystem helpers
-- ---------------------------------------------------------------------------

local function mkdtemp(prefix)
  local template = vim.fs.joinpath(M._base, prefix .. '-XXXXXX')
  local created = vim.uv.fs_mkdtemp(template)
  if not created then
    M.fail('could not create temp dir from template ' .. template)
  end
  return vim.uv.fs_realpath(created) or created
end

-- sandbox() -> { root = <tmpdir>, data_home = <tmp>/data }
-- Also points XDG_DATA_HOME at the sandbox so `direct.paths` resolves inside it.
-- Removed automatically after the current test.
function M.sandbox()
  local root = mkdtemp('direct-sandbox')
  local data_home = vim.fs.joinpath(root, 'data')
  vim.fn.mkdir(data_home, 'p')
  vim.env.XDG_DATA_HOME = data_home
  M._sandboxes[#M._sandboxes + 1] = root
  return { root = root, data_home = data_home }
end

local function to_lines(contents)
  if contents == nil then return {} end
  if type(contents) == 'table' then return contents end
  if type(contents) == 'string' then
    return vim.split(contents, '\n', { plain = true })
  end
  M.fail('mkfile contents must be a string, a list, or nil')
end

function M.mkfile(root, rel, contents)
  local path = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(to_lines(contents), path)
  return path
end

function M.mkdir(root, rel)
  local path = vim.fs.joinpath(root, rel)
  vim.fn.mkdir(path, 'p')
  return path
end

function M.ls(root)
  local names = {}
  for name in vim.fs.dir(root) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.exists(root, rel)
  return vim.uv.fs_stat(vim.fs.joinpath(root, rel)) ~= nil
end

function M.inode_of(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.ino
end

-- fs_snapshot(root) -> sorted list of "<relative path>" with type markers:
--   directory -> trailing "/", symlink -> trailing "@", file -> no marker.
-- Symlinks are leaves (not followed), so the snapshot cannot loop.
function M.fs_snapshot(root)
  local out = {}
  local function walk(rel)
    local dir = rel == '' and root or vim.fs.joinpath(root, rel)
    local entries = {}
    for name, typ in vim.fs.dir(dir) do
      entries[#entries + 1] = { name = name, typ = typ }
    end
    table.sort(entries, function(a, b) return a.name < b.name end)
    for _, e in ipairs(entries) do
      local child = rel == '' and e.name or (rel .. '/' .. e.name)
      if e.typ == 'directory' then
        out[#out + 1] = child .. '/'
        walk(child)
      elseif e.typ == 'link' then
        out[#out + 1] = child .. '@'
      else
        out[#out + 1] = child
      end
    end
  end
  walk('')
  table.sort(out)
  return out
end

function M.assert_fs_eq(root, expected)
  local actual = M.fs_snapshot(root)
  local want = vim.deepcopy(expected)
  table.sort(want)
  if not vim.deep_equal(actual, want) then
    M.fail(format_mismatch('fs_snapshot mismatch for ' .. root, actual, want))
  end
end

-- ---------------------------------------------------------------------------
-- Buffer oracle
-- ---------------------------------------------------------------------------

function M.buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)
end

-- assert_buf_eq(expected, bufnr): expected lines first (matching the documented
-- assert_buf_eq(lines) form); bufnr defaults to the current buffer.
function M.assert_buf_eq(expected, bufnr)
  local actual = M.buf_lines(bufnr)
  if vim.deep_equal(actual, expected) then
    pass('assert_buf_eq', nil)
  else
    M.fail(format_mismatch('buffer mismatch', actual, expected))
  end
end

-- ---------------------------------------------------------------------------
-- Stubbing
-- ---------------------------------------------------------------------------

-- stub(mod, name, fn) -> restore()
-- Swaps a field on a module table; call restore() to put the old value back.
function M.stub(mod, name, fn)
  local had = rawget(mod, name) ~= nil
  local old = rawget(mod, name)
  rawset(mod, name, fn)
  return function()
    if had then
      rawset(mod, name, old)
    else
      rawset(mod, name, nil)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Message oracle
-- ---------------------------------------------------------------------------

function M.messages()
  return vim.api.nvim_exec2('messages', { output = true }).output or ''
end

-- capture_messages() clears the message history and returns a handle with
-- :messages() and :assert(pattern[, level]) so a test can assert only on what
-- it itself triggered.
function M.capture_messages()
  vim.cmd('messages clear')
  local handle = {}
  function handle.messages()
    return M.messages()
  end
  function handle.assert(_, pattern, level)
    M.assert_notified(pattern, level)
  end
  return handle
end

-- assert_notified(pattern[, level]) checks the current :messages history.
-- `level` is accepted for API symmetry; under `-l` the headless message store
-- records text without a level marker, so the level is not asserted on.
function M.assert_notified(pattern, level)
  local text = M.messages()
  if not text:find(pattern, 1, true) then
    M.fail(string.format('expected notification containing %q; messages:\n%s',
      pattern, text))
  end
  pass('assert_notified', nil)
  return level
end

-- ---------------------------------------------------------------------------
-- Prompt / environment / option seams
-- ---------------------------------------------------------------------------

-- with_prompt(fn, answers) replaces require('direct.ui').prompt for the
-- duration of fn. `answers` is either a list (consumed in order) or a function
-- used verbatim as the prompt implementation.
--
-- A stale ui table can make a stub miss and reach the real vim.fn.input, which
-- aborts `-l` before the runner reports a result. Guard both failure paths:
-- * Require stubs to target the ui table captured by this file before unload.
-- * Replace vim.fn.input with a raising stub while the prompt seam is active.
function M.with_prompt(fn, answers)
  local ui = require('direct.ui')
  if M._file_ui ~= nil and ui ~= M._file_ui then
    error('with_prompt: stale direct.ui module -- the spec captured a '
      .. 'different ui table before the modules were unloaded, so stubbing the '
      .. 'fresh table would miss and the real vim.fn.input could abort the run. '
      .. 'Stub the captured table with H.stub(ui, "prompt", ...) instead, or '
      .. 'require direct.* only inside the spec body.', 0)
  end
  local responder
  if type(answers) == 'function' then
    responder = answers
  else
    local queue = vim.deepcopy(answers or {})
    responder = function()
      if #queue == 0 then return nil end
      return table.remove(queue, 1)
    end
  end
  local restore_prompt = M.stub(ui, 'prompt', responder)
  local restore_input = M.stub(vim.fn, 'input', function()
    error('with_prompt: vim.fn.input reached under -l -- the prompt seam was '
      .. 'bypassed (stale ui table?); refusing to truncate the run', 0)
  end)
  local ok, err = xpcall(fn, debug.traceback)
  restore_input()
  restore_prompt()
  if not ok then
    error(err, 0)
  end
end

-- with_env(vars, fn): temporarily overwrites the named environment variables,
-- runs fn, and restores every one even if fn raises. Presence is tracked
-- explicitly: a variable that was unset before the call must be unset again
-- afterwards; `nil` cannot be stored as a table key.
function M.with_env(vars, fn)
  local saved = {}
  for name in pairs(vars) do
    saved[name] = { present = vim.env[name] ~= nil, value = vim.env[name] }
  end
  for name, value in pairs(vars) do
    vim.env[name] = value
  end
  local ok, err = xpcall(fn, debug.traceback)
  for name, prev in pairs(saved) do
    vim.env[name] = prev.present and prev.value or nil
  end
  if not ok then
    error(err, 0)
  end
end

-- with_option(name, value, fn): scoped global option change; the previous value
-- is restored even if fn raises.
function M.with_option(name, value, fn)
  local saved = vim.o[name]
  vim.o[name] = value
  local ok, err = xpcall(fn, debug.traceback)
  pcall(function() vim.o[name] = saved end)
  if not ok then
    error(err, 0)
  end
end

-- with_cwd(dir, fn) scopes the window cwd and restores it even if fn raises.
-- Action descriptions are CWD-relative, so tests need this scoped seam.
function M.with_cwd(dir, fn)
  local old = vim.fn.getcwd()
  pcall(vim.cmd, 'lcd ' .. vim.fn.fnameescape(dir))
  local ok, err = xpcall(fn, debug.traceback)
  pcall(vim.cmd, 'lcd ' .. vim.fn.fnameescape(old))
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Per-spec and per-test isolation (driven by tests/run.lua)
-- ---------------------------------------------------------------------------

local function wipe_buffers()
  pcall(vim.cmd, '%bwipeout!')
end

-- The filetype machinery belongs to `filetype plugin on` and must outlive the
-- per-spec autocmd reset. It does so by boot-baseline membership alone: the
-- machinery is registered before setup() captures `_boot_augroups` /
-- `_boot_autocmd_kinds`. An earlier version also exempted every `FileType`
-- autocmd by event, which kept a spec's own default-group FileType handler
-- alive forever; that blanket exemption is gone.

-- Remove every augroup/autocmd created since the boot baseline. Foreign state
-- registered by one test can never leak into a later one.
local function clear_foreign_autocmds()
  if not M._boot_augroups then return end
  for _, name in ipairs(vim.fn.getcompletion('', 'augroup')) do
    if name ~= 'END' and not M._boot_augroups[name] then
      pcall(vim.api.nvim_del_augroup_by_name, name)
    end
  end
  for _, au in ipairs(vim.api.nvim_get_autocmds({})) do
    if not M._boot_autocmd_kinds[M._autocmd_kind(au)] then
      pcall(vim.api.nvim_del_autocmd, au.id)
    end
  end
end

-- Clear foreign autocmds, then re-source plugin/direct.lua so its own autocmds
-- are re-registered after the reset.
local function reset_runtime()
  clear_foreign_autocmds()
  pcall(vim.cmd, 'runtime! plugin/direct.lua')
end

local function reset_options()
  if not M._option_snapshot then return end
  for name, value in pairs(M._option_snapshot) do
    pcall(function() vim.o[name] = value end)
  end
end

local function forget_direct_modules()
  local keys = {}
  for k in pairs(package.loaded) do
    if k == 'direct' or k:match('^direct%.') then
      keys[#keys + 1] = k
    end
  end
  for _, k in ipairs(keys) do
    package.loaded[k] = nil
  end
end

function M._begin_file()
  wipe_buffers()
  -- remember the ui table this file captured at load time (if any) before
  -- forgetting the direct.* modules. `with_prompt` stubs the freshly-required
  -- table, so if the two differ the spec's consumer modules hold a stale table
  -- and the stub would silently miss (the real vim.fn.input path).
  M._file_ui = package.loaded['direct.ui']
  forget_direct_modules()                 -- unload before the re-source
  reset_options()
  M._file_home = mkdtemp('direct-spec')
  vim.env.XDG_DATA_HOME = M._file_home    -- home before the re-source
  reset_runtime()
end

function M._end_file()
  if M._file_home then
    pcall(vim.fs.rm, M._file_home, { recursive = true, force = true })
    M._file_home = nil
  end
  wipe_buffers()
  reset_options()
  reset_runtime()
  -- Forgetting the direct.* modules AFTER the re-source means the next file's
  -- `_begin_file` captures `_file_ui` from this file's chunk, not a table a
  -- previous file left in `package.loaded`. Otherwise `with_prompt` can compare
  -- against a stale table and falsely report that the stub failed.
  forget_direct_modules()
end

function M._begin_test()
  M._sandboxes = {}
  if M._file_home then
    vim.env.XDG_DATA_HOME = M._file_home
  end
  reset_options()
  -- Within-file isolation: clear foreign autocmds but keep the plugin's own
  -- (re-registered at the file boundary), so re-sourcing is not needed here.
  clear_foreign_autocmds()
end

function M._end_test()
  for _, dir in ipairs(M._sandboxes) do
    pcall(vim.fs.rm, dir, { recursive = true, force = true })
  end
  M._sandboxes = {}
  if M._file_home then
    vim.env.XDG_DATA_HOME = M._file_home
  end
end

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------

-- run_all() executes every registered describe()/it() with per-spec and
-- per-test isolation and returns a report:
--   { text, suites, specs, passed, failed }
-- _begin_file / _end_file are wrapped so a cleanup failure is reported instead
-- of aborting the whole test file.
function M.run_all()
  local lines = {}
  local total_passed, total_failed, total_specs = 0, 0, 0

  local begin_ok, begin_err = xpcall(M._begin_file, debug.traceback)
  if not begin_ok then
    total_failed = total_failed + 1
    lines[#lines + 1] = string.format('  FAIL <setup> :: _begin_file\n%s', begin_err)
  else
    for _, suite in ipairs(M._suites) do
      local passed, failed = 0, 0
      for _, test in ipairs(suite.tests) do
        total_specs = total_specs + 1
        M._begin_test()
        M._assert_log = {}
        local ok, err = xpcall(test.fn, debug.traceback)
        -- Contain a throwing teardown: report it against this spec instead of
        -- aborting the remaining tests in the file.
        local end_ok, end_err = xpcall(M._end_test, debug.traceback)
        if not end_ok then
          if ok then
            ok, err = false, 'teardown failed:\n' .. tostring(end_err)
          else
            err = tostring(err) .. '\nteardown also failed:\n' .. tostring(end_err)
          end
        end
        if ok then
          passed = passed + 1
          lines[#lines + 1] = string.format('  ok   %s :: %s', suite.name, test.name)
        else
          failed = failed + 1
          lines[#lines + 1] = string.format('  FAIL %s :: %s\n%s', suite.name, test.name, err)
        end
        if M._verbose and #M._assert_log > 0 then
          lines[#lines + 1] = table.concat(M._assert_log, '\n')
        end
      end
      total_passed = total_passed + passed
      total_failed = total_failed + failed
      lines[#lines + 1] = string.format('%s: %d spec, %d passed, %d failed',
        suite.name, passed + failed, passed, failed)
    end
  end

  local end_ok, end_err = xpcall(M._end_file, debug.traceback)
  if not end_ok then
    total_failed = total_failed + 1
    lines[#lines + 1] = string.format('  FAIL <teardown> :: _end_file\n%s', end_err)
  end

  return {
    text = table.concat(lines, '\n') .. '\n',
    suites = #M._suites,
    specs = total_specs,
    passed = total_passed,
    failed = total_failed,
  }
end

return M
