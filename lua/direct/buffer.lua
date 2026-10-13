-- lua/direct/buffer.lua -- buffer model, listing, sync (spec section 5 / B1-B5,
-- B8, B11-B13, D2-D4, D8b, D11, D14, D17; T-018..T-023).
--
-- Responsibility: attach/create a direct buffer, list a directory into it,
-- classify and apply a sync, open an entry, expose the ranged paths.
--
-- Contracts implemented here:
--   * B3 attach: reuse an existing buffer only when a buffer's STORED name
--     denotes the same directory as root -- path identity via `fs.same_path`
--     (ino+dev), never `==` and never `vim.fn.bufnr` (which pattern-matches the
--     unresolved `bufname()` spelling). `paths.root()` absolutises the input;
--     the comparison is spelling-independent, so a root under a symlinked
--     prefix reuses the one buffer instead of creating a duplicate (B9).
--   * B1/B13 listing: `fs.read_dir_lines` (symlink resolution, broken/
--     non-regular omission, dirs-then-files, byte-wise sorting) with the
--     `&wildignore` ignore set built with `glob(path, true, true, true)`
--     (`nosuf` second, `alllinks` fourth) and compared through `same_path`.
--   * B2 current entry: captured from the PRE-ATTACH current buffer name; the
--     cursor is restored from it with `same_path` after every listing.
--   * B4/B5 sync: duplicate -> AMBIGUOUS, ADD/DELETE/RENAME, D17 ordering,
--     delete auto-yank, per-action error capture, history only for successes,
--     always re-list, one joined summary (B15), one failure summary.
--   * B11/D3 rename clobber guard: swap/chain renames stage to
--     `<root>/.direct-tmp-<n>` first. `current_entry` is never a temp path.
--     A staging rename that FAILS returns the temps already staged alongside
--     the error, and the caller reports each orphan path, so a `.direct-tmp-*`
--     left behind by a failed staging rename is never silent (T-023/B1).
--   * D4/OQ7 ambiguous: notify the reason and both sides, change nothing, write
--     no history, do NOT re-list, leave the buffer modified.
--   * B8/D8b open: trailing `/` opens a new direct listing, otherwise `:edit`
--     (D14: `fnameescape` + `vim.cmd`, never a raw path interpolated into a
--     command). The previous direct buffer is wiped only when it is no longer
--     current (the observable property; no `E937` claim).
--   * P2-NB2 (T-023 data-integrity): a path carrying the serialization
--     FIELD_SEPARATOR ('\t') or any other control character cannot round-trip
--     through the `NAME\tfield...` history framing, so the sync boundary
--     REFUSES it before any action or history write. `action.path_reason` is
--     the shared guard and `action.serialize` re-checks it on every field, so
--     no other caller can emit an unrepresentable line either (B2).
--     Re-framing the log was
--     rejected: the on-disk format is shared with the D18 history version gate,
--     and changing it would invalidate the marker contract. A `' '` (space) is
--     NOT refused here: the single-action framing is tab-delimited, so a space
--     in a path is safe (the ' ' ENTRY_SEPARATOR only matters for `p`/`up`
--     multi-actions, which the sync boundary never builds).
--
-- This module never calls `vim.fn.input` directly (it goes through `ui`), so it
-- is headless-safe and satisfies the T-023 GREP gate.

local M = {}

-- Module tables are captured once so tests can stub `fs.rename`,
-- `history.log`, `register.yank`, `ui.notify`, ... on the very tables the
-- code below resolves through.
local fs = require('direct.fs')
local paths = require('direct.paths')
local action_mod = require('direct.action')
local history = require('direct.history')
local register = require('direct.register')
local ui = require('direct.ui')

local Buffer = {}
Buffer.__index = Buffer

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- is_dir_line(line) -> true for a directory entry. The trailing slash is the
-- convention (B1/B4): a directory is never distinguished from a file by a
-- filesystem stat here.
local function is_dir_line(line)
  return type(line) == 'string' and line:sub(-1) == '/'
end

-- dirs_then_name(lines) -> a copy ordered directories first, each group sorted
-- ascending by byte-wise comparison (B4/D17). A directory line carries its
-- trailing '/', so the two groups never interleave.
local function dirs_then_name(lines)
  local dirs, files = {}, {}
  for _, line in ipairs(lines or {}) do
    if is_dir_line(line) then
      dirs[#dirs + 1] = line
    else
      files[#files + 1] = line
    end
  end
  table.sort(dirs)
  table.sort(files)
  local out = {}
  for _, line in ipairs(dirs) do
    out[#out + 1] = line
  end
  for _, line in ipairs(files) do
    out[#out + 1] = line
  end
  return out
end

-- entry_path(root, line) -> the absolute entry a buffer line denotes. The
-- spelling is `root .. '/' .. line`, so a directory line keeps its trailing '/'
-- (Python `os.path.join` parity): the delete auto-yank path and the trash
-- digest are therefore the trailing-slash string, exactly as in the Python
-- version. The only root that already ends in a separator is '/'.
function M.entry_path(root, line)
  if type(root) ~= 'string' or type(line) ~= 'string' then
    return root
  end
  if root:sub(-1) == '/' then
    return root .. line
  end
  return root .. '/' .. line
end

-- current_entry([name]) -> `name` when it names an existing filesystem entry,
-- else nil (B2). Defaults to the current buffer's stored name: the buffer name
-- `nvim_buf_get_name` returns (the resolved spelling). `same_path` makes the
-- spelling irrelevant, so no `bufname('%')` accessor is needed.
function M.current_entry(name)
  if name == nil then
    name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  end
  if type(name) ~= 'string' or name == '' then
    return nil
  end
  if fs.stat(name) then
    return name
  end
  return nil
end

-- ignore_set(root) -> the B13 ignore set: the union of
-- `glob(root .. '/' .. pattern, true, true, true)` over the comma-separated,
-- trimmed, non-empty `&wildignore` patterns, or nil when there are none. The
-- four glob arguments are {expr}, {nosuf}, {list}, {alllinks}: `nosuf` must be
-- passed or 'suffixes'/'wildmenu' would fabricate matches, `{list}` makes the
-- result an array, and `{alllinks}` follows symlinks while globbing. The
-- comparison itself is `same_path` (B13/D6 hardening), which is correct for
-- every root spelling.
function M.ignore_set(root)
  local wildignore = vim.o.wildignore or ''
  if wildignore == '' then
    return nil
  end
  local set = {}
  for pattern in wildignore:gmatch('[^,]+') do
    pattern = vim.trim(pattern)
    if pattern ~= '' then
      local matches = vim.fn.glob(M.entry_path(root, pattern), true, true, true)
      if type(matches) == 'table' then
        for _, match in ipairs(matches) do
          set[#set + 1] = match
        end
      end
    end
  end
  if #set == 0 then
    return nil
  end
  return set
end

-- read(root) -> the B1 listing lines, or nil, err when root is not readable.
function M.read(root)
  return fs.read_dir_lines(root, M.ignore_set(root))
end

-- ---------------------------------------------------------------------------
-- B4 classification
-- ---------------------------------------------------------------------------

-- classify(actual, expected) -> a plan:
--   { kind = 'ADD', added = <lines, dirs-then-name> }
--   { kind = 'DELETE', removed = <lines, dirs-then-name> }
--   { kind = 'RENAME', moves = { { src = <expected line>, dst = <actual line> } } }
--   { kind = 'AMBIGUOUS', reason = 'duplicate' | 'mixed' }
-- The duplicate check is FIRST (R7/OQ3): the Python version collapsed
-- duplicates through set() diffs, and a duplicated line in a RENAME-shaped edit
-- produced a self-move.
function M.classify(actual, expected)
  actual = actual or {}
  expected = expected or {}

  local seen = {}
  for _, line in ipairs(actual) do
    if seen[line] then
      return { kind = 'AMBIGUOUS', reason = 'duplicate' }
    end
    seen[line] = true
  end

  local actual_set, expected_set = {}, {}
  for _, line in ipairs(actual) do
    actual_set[line] = true
  end
  for _, line in ipairs(expected) do
    expected_set[line] = true
  end
  local function subset(x, y)
    for key in pairs(x) do
      if not y[key] then
        return false
      end
    end
    return true
  end

  if #actual > #expected and subset(expected_set, actual_set) then
    local added = {}
    for _, line in ipairs(actual) do
      if not expected_set[line] then
        added[#added + 1] = line
      end
    end
    return { kind = 'ADD', added = dirs_then_name(added) }
  end

  if #actual < #expected and subset(actual_set, expected_set) then
    local removed = {}
    for _, line in ipairs(expected) do
      if not actual_set[line] then
        removed[#removed + 1] = line
      end
    end
    return { kind = 'DELETE', removed = dirs_then_name(removed) }
  end

  if #actual == #expected then
    local moves = {}
    for i = 1, #actual do
      if actual[i] ~= expected[i] then
        moves[#moves + 1] = { src = expected[i], dst = actual[i] }
      end
    end
    return { kind = 'RENAME', moves = moves }
  end

  return { kind = 'AMBIGUOUS', reason = 'mixed' }
end

-- ---------------------------------------------------------------------------
-- P2-NB2: the sync-boundary framing guard
-- ---------------------------------------------------------------------------

-- unsafe_path_reason(path) -> the shared `action.path_reason` (P2-NB2/B2): nil
-- when `path` can round-trip through the `NAME\tfield...` history framing, else
-- a short reason. A tab IS the field separator, so it would split one path into
-- two fields; any other control character (a newline included) cannot survive
-- `vim.fn.writefile`'s line handling either. A space is legal here: only the
-- `p`/`up` name lists use the ' ' ENTRY_SEPARATOR, and the sync classification
-- never builds those. This boundary keeps its own early refusal for the user;
-- `action.serialize` applies the SAME shared guard to every emitted field, so a
-- path outside the sync path can never bypass it.
local function unsafe_path_reason(path)
  return action_mod.path_reason(path)
end

-- first_unsafe(root, lines) -> { path, reason } for the first line whose path
-- is unrepresentable, else nil. Both the edited lines and the on-disk listing
-- are checked: either side can be an OS-chosen name.
local function first_unsafe(root, lines)
  for _, line in ipairs(lines) do
    local path = M.entry_path(root, line)
    local reason = unsafe_path_reason(path)
    if reason ~= nil then
      return { path = path, reason = reason }
    end
  end
  return nil
end

-- ambiguous_message(plan, actual, expected) names the reason and both sides of
-- the comparison (B4/B5/D4) so the user can see what desynced.
local function ambiguous_message(plan, actual, expected)
  return string.format(
    'Ambiguous buffer content (%s). '
      .. 'You must only add, remove or rename in each edit.'
      .. '\nactual:   %s\nexpected: %s',
    plan.reason, table.concat(actual, ', '), table.concat(expected, ', '))
end

-- ---------------------------------------------------------------------------
-- B11/D3 rename staging
-- ---------------------------------------------------------------------------

-- first_free_temp(root) -> the first free `<root>/.direct-tmp-<n>` (same
-- directory, so staging a rename can never cross a filesystem).
local function first_free_temp(root)
  local n = 1
  local candidate = M.entry_path(root, '.direct-tmp-' .. n)
  while fs.exists(candidate) do
    n = n + 1
    candidate = M.entry_path(root, '.direct-tmp-' .. n)
  end
  return candidate
end

-- stage_moves(root, actions) -> { overrides = { src -> tmp }, temps = { tmp } }
-- when a rename `dst` is also some action's `src` (a swap or a chain), else nil.
-- Only `mv` actions participate. A staging rename failure returns
-- `nil, err, temps`, where `temps` are the entries ALREADY renamed to their
-- temp path: the caller must report them, because the entry no longer sits at
-- its original name and silently discarding the list would orphan it (B1/T-023).
-- The caller executes each Move from `overrides[src]` when present, while
-- `history.log` and `current_entry` keep using the ORIGINAL action (B11:
-- `current_entry` must never be a temp path).
local function stage_moves(root, actions)
  local dst_set = {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.dst ~= nil then
      dst_set[act.dst] = true
    end
  end
  local needed = false
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.src ~= nil and dst_set[act.src] then
      needed = true
      break
    end
  end
  if not needed then
    return nil
  end
  local overrides, temps = {}, {}
  for _, act in ipairs(actions) do
    if act.name == 'mv' and act.src ~= nil and dst_set[act.src]
      and overrides[act.src] == nil then
      local tmp = first_free_temp(root)
      local ok, err = fs.rename(act.src, tmp)
      if not ok then
        -- B1/T-023: return the temps accumulated so far ALONGSIDE the error,
        -- so the caller can report each entry that is now parked at a temp path
        -- instead of returning the error alone and orphaning them silently.
        return nil, err, temps
      end
      overrides[act.src] = tmp
      temps[#temps + 1] = tmp
    end
  end
  return { overrides = overrides, temps = temps }
end

-- ---------------------------------------------------------------------------
-- Buffer options (D11)
-- ---------------------------------------------------------------------------

local function set_options(bufnr)
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'direct'
  -- BufWriteCmd <buffer> DirectSync (spec section 6): a `:write` in a direct
  -- buffer routes to the sync instead of writing a file. Recreated per listing
  -- (the augment `direct`) after clearing this buffer's own autocmds, matching
  -- the retired `autocmd! * <buffer>` so repeated listings cannot stack handlers.
  local group = vim.api.nvim_create_augroup('direct', { clear = false })
  pcall(vim.api.nvim_clear_autocmds, { group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = bufnr,
    command = 'DirectSync',
    desc = 'direct: sync the listing on :write',
  })
end

-- result_entry(action) -> the entry a succeeded action leaves as the current
-- entry (Python `Action.do()` parity): the destination of Touch /
-- MakeDirectory / Move, nil for the removals. The original action is used, so a
-- staged temp path can never become the current entry (B11).
local function result_entry(act)
  if act.name == 'mv' or act.name == 'touch' or act.name == 'mkdir' then
    return act.dst
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Attach / create (B3)
-- ---------------------------------------------------------------------------

-- Buffer(path) -> a Buffer for `path`, with the existing buffer for the same
-- directory made current or a new one created. `current_entry` is captured from
-- the PRE-ATTACH current buffer name (B2).
function M.Buffer(path)
  local root = paths.root(path)
  local self = setmetatable({
    root = root,
    current_entry = M.current_entry(),
  }, Buffer)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    -- B3/B9: path identity, never `==` (a symlinked prefix makes the buffer
    -- name and root different spellings of the same directory) and never
    -- `vim.fn.bufnr` (which pattern-matches and is spelling-sensitive).
    if name ~= '' and fs.same_path(name, root) then
      vim.api.nvim_set_current_buf(bufnr)
      return self
    end
  end

  vim.cmd('enew')
  vim.api.nvim_buf_set_name(0, root)
  return self
end

-- M.restore() -> the Buffer for the current direct buffer (Python
-- `Buffer.restore()`). It attaches only; the caller decides when to list.
function M.restore()
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  return M.Buffer(name)
end

-- M.list(path) -> attach/create the buffer for `path` and list it (the
-- `:DirectList {dir}` equivalent). Returns the Buffer.
function M.list(path)
  local buffer = M.Buffer(path)
  buffer:list()
  return buffer
end

-- ---------------------------------------------------------------------------
-- B1/B2 listing
-- ---------------------------------------------------------------------------

-- place_cursor(lines) -> move the cursor to the first line whose full path is
-- `same_path` as current_entry (R4-safe), leaving it where it was otherwise
-- (B2). The column is reset to 0 on a match.
function Buffer:place_cursor(lines)
  if self.current_entry == nil then
    return
  end
  for index, line in ipairs(lines) do
    if fs.same_path(M.entry_path(self.root, line), self.current_entry) then
      pcall(vim.api.nvim_win_set_cursor, 0, { index, 0 })
      return
    end
  end
end

-- Buffer:list() -> replace the buffer lines with the directory listing, set the
-- direct-buffer options (D11), restore the cursor, and mark nomodified.
--
-- P3-NB1 (T-023 hardening): a directory can hold an entry whose NAME carries a
-- newline (or another control character / a tab). Such a name can never be a
-- buffer line -- `nvim_buf_set_lines` raises "'replacement string' item contains
-- newlines" -- so listing that directory used to abort the whole listing. The
-- representability guard (`action.path_reason`, the same one the history framing
-- uses) drops every unrepresentable line BEFORE the set, notifies per dropped
-- entry, and lists the survivors. A ' ' (space) name is NOT dropped: a space is
-- representable and must still list.
function Buffer:list()
  local lines, err = M.read(self.root)
  if not lines then
    ui.notify('direct: cannot list ' .. tostring(self.root) .. ': '
      .. tostring(err), vim.log.levels.ERROR)
    return nil, err
  end

  local safe = {}
  for _, line in ipairs(lines) do
    local reason = action_mod.path_reason(M.entry_path(self.root, line))
    if reason ~= nil then
      ui.notify('direct: skipping unlistable entry (' .. reason .. '): ' .. line,
        vim.log.levels.ERROR)
    else
      safe[#safe + 1] = line
    end
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ok, seterr = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, safe)
  if not ok then
    ui.notify('direct: cannot list ' .. tostring(self.root) .. ': '
      .. tostring(seterr), vim.log.levels.ERROR)
    return nil, seterr
  end
  set_options(bufnr)
  self:place_cursor(safe)
  vim.bo[bufnr].modified = false
  return true
end

-- ---------------------------------------------------------------------------
-- B4/B5/B11 sync
-- ---------------------------------------------------------------------------

-- build_actions(root, plan) -> actions, yanks. ADD/DELETE are emitted in
-- dirs-then-name order (D17); a DELETE also records the removed paths for the
-- auto-yank (B5 step 1), carrying the trailing slash for a directory.
local function build_actions(root, plan)
  local actions, yanks = {}, {}
  if plan.kind == 'ADD' then
    for _, line in ipairs(plan.added) do
      local path = M.entry_path(root, line)
      if is_dir_line(line) then
        actions[#actions + 1] = action_mod.MakeDirectory(path)
      else
        actions[#actions + 1] = action_mod.Touch(path)
      end
    end
  elseif plan.kind == 'DELETE' then
    for _, line in ipairs(plan.removed) do
      local path = M.entry_path(root, line)
      yanks[#yanks + 1] = path
      if is_dir_line(line) then
        actions[#actions + 1] = action_mod.RemoveDirectory(path)
      else
        actions[#actions + 1] = action_mod.Remove(path)
      end
    end
  elseif plan.kind == 'RENAME' then
    for _, move in ipairs(plan.moves) do
      actions[#actions + 1] = action_mod.Move(
        M.entry_path(root, move.src), M.entry_path(root, move.dst))
    end
  end
  return actions, yanks
end

-- Buffer:sync() -> true when a classified sync was applied (the buffer was
-- re-listed and marked nomodified), nil, reason when nothing was applied
-- (ambiguous, an unsafe path, a refused yank, or an unreadable root).
function Buffer:sync()
  local actual = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local expected, read_err = M.read(self.root)
  if not expected then
    ui.notify('direct: cannot read ' .. tostring(self.root) .. ': '
      .. tostring(read_err), vim.log.levels.ERROR)
    return nil, read_err
  end

  -- P2-NB2: refuse a path the history framing cannot represent, before any
  -- action or history write. The buffer is not re-listed and stays modified.
  local unsafe = first_unsafe(self.root, actual) or first_unsafe(self.root, expected)
  if unsafe ~= nil then
    ui.notify('Unsafe entry in the buffer (' .. unsafe.reason
      .. '); nothing was changed: ' .. unsafe.path, vim.log.levels.ERROR)
    return nil, unsafe.reason
  end

  local plan = M.classify(actual, expected)
  if plan.kind == 'AMBIGUOUS' then
    -- D4/OQ7: notify, change nothing, write no history, do NOT re-list, and
    -- leave the buffer modified so the unsaved intent is not discarded.
    ui.notify(ambiguous_message(plan, actual, expected), vim.log.levels.ERROR)
    return nil, plan.reason
  end

  local actions, yanks = build_actions(self.root, plan)

  -- B5 step 1: yank the removed paths before any action. A refused yank leaves
  -- the filesystem untouched (the register guard, B2/N2, decides).
  if #yanks > 0 then
    local ok, yerr = register.yank(yanks)
    if not ok then
      ui.notify('Action failed - could not yank deleted entries: '
        .. tostring(yerr), vim.log.levels.ERROR)
      return nil, yerr
    end
  end

  -- B11/D3: swap/chain renames are staged before the real moves.
  local staging, stage_err, stage_temps = stage_moves(self.root, actions)
  if staging == nil and stage_err ~= nil then
    ui.notify('Action failed - could not stage renames: ' .. tostring(stage_err),
      vim.log.levels.ERROR)
    -- B1/T-023: a failed staging rename leaves every already-staged entry at
    -- its temp path. Report each one -- the same treatment the post-execution
    -- leftover block below gives -- instead of returning on the error alone
    -- and orphaning the temps silently.
    for _, tmp in ipairs(stage_temps or {}) do
      if fs.exists(tmp) then
        ui.notify('direct: a failed rename left the staged entry ' .. tmp,
          vim.log.levels.ERROR)
      end
    end
    return nil, stage_err
  end

  local failed = {}
  for _, act in ipairs(actions) do
    local exec_action = act
    if staging ~= nil and act.name == 'mv'
      and staging.overrides[act.src] ~= nil then
      exec_action = action_mod.Move(staging.overrides[act.src], act.dst)
    end
    local ok, res, aerr = pcall(exec_action['do'])
    if ok and res then
      -- B5 steps 2-3: successes are pushed to history and become the current
      -- entry (the ORIGINAL action, never a temp path, B11). `history.log`
      -- reports a failed history write itself -- it never raises and never
      -- swallows the failure (P2-NB4, incl. the redo-reset failure) -- so the
      -- ignored return here cannot hide a write error.
      history.log(act)
      self.current_entry = result_entry(act)
    else
      ui.notify('Action failed - ' .. action_mod.describe_action(act),
        vim.log.levels.ERROR)
      failed[#failed + 1] = act
    end
  end

  -- B11: remove any staged temp that was not consumed. On the all-success path
  -- every temp is consumed, so this is normally a no-op. On the failure path a
  -- temp left over is reported instead of force-removed: deleting it could
  -- discard the very entry a failed move could not place, and B5 requires
  -- failures to be reported without losing data.
  if staging ~= nil then
    for _, tmp in ipairs(staging.temps) do
      if fs.exists(tmp) then
        if #failed == 0 then
          fs.rm_tree(tmp)
        else
          ui.notify('direct: a failed rename left the staged entry ' .. tmp,
            vim.log.levels.ERROR)
        end
      end
    end
  end

  -- B5 step 4: always re-list (the buffer now reflects reality), then
  -- nomodified. list() also restores the cursor from current_entry.
  self:list()

  if #actions > 0 then
    -- B15: one joined summary of the classified actions.
    ui.notify(action_mod.summarize(actions), vim.log.levels.INFO)
  end
  if #failed > 0 then
    -- B5 step 5: one extra summary error naming the count and the actions.
    local names = {}
    for _, act in ipairs(failed) do
      names[#names + 1] = action_mod.describe_action(act)
    end
    ui.notify(string.format('%d action(s) failed: %s', #failed,
      table.concat(names, ', ')), vim.log.levels.ERROR)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- B8 open / get_paths
-- ---------------------------------------------------------------------------

-- Buffer:open(line) -> open the entry under the cursor. A trailing '/' opens a
-- new direct listing; otherwise the file is `:edit`ed (D14: fnameescape +
-- vim.cmd, never string.format into a command). D8b/R16: the previous direct
-- buffer is wiped only when it is no longer current -- the observable property
-- is asserted, never the (unverified) E937.
function Buffer:open(line)
  local path = M.entry_path(self.root, line)
  local direct_buf = vim.api.nvim_get_current_buf()
  if is_dir_line(line) then
    M.list(path)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
  end
  if vim.api.nvim_buf_is_valid(direct_buf)
    and vim.api.nvim_get_current_buf() ~= direct_buf then
    pcall(vim.api.nvim_buf_delete, direct_buf, { force = true })
  end
  return true
end

-- Buffer:get_paths(firstline, lastline) -> the absolute path of every line in
-- the inclusive 1-based range (Python's buffer slice). Used by `:DirectYank`.
function Buffer:get_paths(firstline, lastline)
  local lines = vim.api.nvim_buf_get_lines(0, firstline - 1, lastline, false)
  local out = {}
  for _, line in ipairs(lines) do
    out[#out + 1] = M.entry_path(self.root, line)
  end
  return out
end

return M
