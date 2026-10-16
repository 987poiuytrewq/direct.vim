-- lua/direct/buffer.lua -- directory buffer model, listing, sync, and open operations.
-- Path identity uses fs.same_path. Sync validates edits, stages dependent moves
-- records only successful actions, and re-lists to reflect the filesystem state.

local M = {}

-- Module tables are captured once so tests can stub `fs.rename`
-- `history.log`, `register.yank`, `ui.notify`,... on the very tables the
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
-- convention: a directory is never distinguished from a file by a
-- filesystem stat here.
local function is_dir_line(line)
  return type(line) == 'string' and line:sub(-1) == '/'
end

-- dirs_then_name(lines) -> a copy ordered directories first, each group sorted
-- ascending by byte-wise comparison. A directory line carries its
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
-- spelling is `root.. '/'.. line`, so a directory line keeps its trailing '/'
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

-- current_entry([name]) -> `name` when it names an existing filesystem entry
-- else nil. Defaults to the current buffer's stored name: the buffer name
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

-- ignore_set(root) -> the ignore set: the union of
-- `glob(root.. '/'.. pattern, true, true, true)` over the comma-separated
-- trimmed, non-empty `&wildignore` patterns, or nil when there are none. The
-- four glob arguments are {expr}, {nosuf}, {list}, {alllinks}: `nosuf` must be
-- passed or 'suffixes'/'wildmenu' would fabricate matches, `{list}` makes the
-- result an array, and `{alllinks}` follows symlinks while globbing. The
-- comparison itself is `same_path` (hardening), which is correct for
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

-- read(root) -> the listing lines, or nil, err when root is not readable.
function M.read(root)
  return fs.read_dir_lines(root, M.ignore_set(root))
end

-- ---------------------------------------------------------------------------
-- classification
-- ---------------------------------------------------------------------------

-- classify(actual, expected) -> a plan
-- { kind = 'ADD', added = <lines, dirs-then-name> }
-- { kind = 'DELETE', removed = <lines, dirs-then-name> }
-- { kind = 'RENAME', moves = { { src = <expected line>, dst = <actual line> } } }
-- { kind = 'AMBIGUOUS', reason = 'duplicate' | 'mixed' }
-- The duplicate check is FIRST: the Python version collapsed
-- duplicates through set diffs, and a duplicated line in a RENAME-shaped edit
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
-- the sync-boundary framing guard
-- ---------------------------------------------------------------------------

-- unsafe_path_reason(path) -> the shared `action.path_reason`: nil
-- when `path` can round-trip through the `NAME\tfield...` history framing, else
-- a short reason. A tab IS the field separator, so it would split one path into
-- two fields; any other control character (a newline included) cannot survive
-- `vim.fn.writefile`'s line handling either. A space is legal here: only the
-- `p`/`up` name lists use the ' ' ENTRY_SEPARATOR, and the sync classification
-- never builds those. This boundary keeps its own early refusal for the user
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
-- the comparison so the user can see what desynced.
local function ambiguous_message(plan, actual, expected)
  return string.format(
    'Ambiguous buffer content (%s). '
      .. 'You must only add, remove or rename in each edit.'
      .. '\nactual:   %s\nexpected: %s',
    plan.reason, table.concat(actual, ', '), table.concat(expected, ', '))
end

-- ---------------------------------------------------------------------------
-- rename staging
-- ---------------------------------------------------------------------------
--
-- The staging mechanism itself lives in `action.lua` (`action.stage_moves`
-- `action.first_free_temp`) because the group REVERSAL has to use the very same
-- one: a swap and its reversal must both route through `.direct-tmp-<n>`, or the
-- reversal renames a live name over a name whose contents are not saved anywhere
-- (the reported data-loss path). This module keeps the reporting around
-- it: the orphan temps of a failed staging rename and the temp of a move that
-- never landed are named, never silently dropped.
local stage_moves = action_mod.stage_moves

-- ---------------------------------------------------------------------------
-- Buffer options
-- ---------------------------------------------------------------------------

local function set_options(bufnr)
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'direct'
  -- BufWriteCmd <buffer> DirectSync: a `:write` in a direct
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

-- Return the destination left by a successful create/move, or nil for removals.
-- Use the original action so a staging temp can never become current_entry.
local function result_entry(act)
  if act.name == 'mv' or act.name == 'touch' or act.name == 'mkdir' then
    return act.dst
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Attach / create
-- ---------------------------------------------------------------------------

-- Capture current_entry before switching buffers, then reuse a buffer only when
-- fs.same_path confirms that it represents the requested directory.
function M.Buffer(path)
  local root = paths.root(path)
  local self = setmetatable({
    root = root,
    current_entry = M.current_entry(),
  }, Buffer)

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    -- Compare by path identity, never `==` (a symlinked prefix makes the buffer
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

-- Attach to the current buffer's directory without listing; the caller decides when to refresh.
function M.restore()
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  return M.Buffer(name)
end

-- List a directory in an attached direct buffer.
function M.list(path)
  local buffer = M.Buffer(path)
  buffer:list()
  return buffer
end

-- ---------------------------------------------------------------------------
-- listing
-- ---------------------------------------------------------------------------

-- Restore the cursor to the pre-attach entry; leave it unchanged if that entry
-- no longer exists. Reset the column on a match.
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

-- Refresh the listing and restore cursor/options; mark unmodified after refresh.
--
-- (hardening): a directory can hold an entry whose NAME carries a
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
-- sync
-- ---------------------------------------------------------------------------

-- build_actions returns actions and yanks. ADD/DELETE follow dirs-then-name
-- order; deleted directory paths retain their trailing slash in the auto-yank.
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

-- log_applied(actions, applied) records successful actions in history. History
-- is written per GROUP of interlinked moves: a swap or
-- an N-way rotation is ONE entry, so one `DirectUndo` reverses the whole
-- permutation instead of renaming a live name over an unsaved one. Every other
-- action is its own entry, exactly as before.
--
-- A group with any member that did NOT apply is not recorded at all: its
-- reversal would pass through a colliding name (the reported defect), and
-- already never records a reversal for entries that were never written (the
-- Paste precedent). A singleton group is logged only when its action applied.
local function log_applied(actions, applied)
  for _, group in ipairs(action_mod.move_groups(actions)) do
    local members, complete = {}, true
    for _, index in ipairs(group) do
      if not applied[index] then
        complete = false
      end
      members[#members + 1] = actions[index]
    end
    if complete then
      if #members == 1 then
        history.log(members[1])
      else
        history.log(action_mod.Group(members))
      end
    end
  end
end

-- Buffer:sync -> true when a classified sync was applied (the buffer was
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

  -- refuse a path the history framing cannot represent, before any
  -- action or history write. The buffer is not re-listed and stays modified.
  local unsafe = first_unsafe(self.root, actual) or first_unsafe(self.root, expected)
  if unsafe ~= nil then
    ui.notify('Unsafe entry in the buffer (' .. unsafe.reason
      .. '); nothing was changed: ' .. unsafe.path, vim.log.levels.ERROR)
    return nil, unsafe.reason
  end

  local plan = M.classify(actual, expected)
  if plan.kind == 'AMBIGUOUS' then
    -- notify, change nothing, write no history, do NOT re-list, and
    -- leave the buffer modified so the unsaved intent is not discarded.
    ui.notify(ambiguous_message(plan, actual, expected), vim.log.levels.ERROR)
    return nil, plan.reason
  end

  local actions, yanks = build_actions(self.root, plan)

  -- Yank removed paths before applying actions. If yanking is refused, leave
  -- the filesystem untouched.
  if #yanks > 0 then
    local ok, yerr = register.yank(yanks)
    if not ok then
      ui.notify('Action failed - could not yank deleted entries: '
        .. tostring(yerr), vim.log.levels.ERROR)
      return nil, yerr
    end
  end

  -- swap/chain renames are staged before the real moves.
  local staging, stage_err, stage_temps = stage_moves(actions)
  if staging == nil and stage_err ~= nil then
    ui.notify('Action failed - could not stage renames: ' .. tostring(stage_err),
      vim.log.levels.ERROR)
    -- a failed staging rename leaves every already-staged entry at
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

  -- steps 2-3: apply every action, then push the successes to history as
  -- whole dependent move groups. `history.log` reports a failed history
  -- write itself -- it never raises and never swallows the failure (
  -- incl. the redo-reset failure) -- so the ignored return here cannot hide a
  -- write error.
  local failed, applied = {}, {}
  for i, act in ipairs(actions) do
    local exec_action = act
    if staging ~= nil and act.name == 'mv'
      and staging.overrides[act.src] ~= nil then
      exec_action = action_mod.Move(staging.overrides[act.src], act.dst)
    end
    local ok, res, aerr = pcall(exec_action['do'])
    if ok and res then
      applied[i] = true
      self.current_entry = result_entry(act)
    else
      ui.notify('Action failed - ' .. action_mod.describe_action(act),
        vim.log.levels.ERROR)
      failed[#failed + 1] = act
    end
  end
  log_applied(actions, applied)

  -- remove any staged temp that was not consumed. On the all-success path
  -- every temp is consumed, so this is normally a no-op. On the failure path a
  -- temp left over is reported instead of force-removed: deleting it could
  -- discard the very entry a failed move could not place, and requires
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

  -- Re-list so the buffer reflects the filesystem, restore the cursor, and
  -- mark it unmodified only after the refresh succeeds.
  self:list()

  if #actions > 0 then
    -- Emit one joined summary for the classified actions.
    ui.notify(action_mod.summarize(actions), vim.log.levels.INFO)
  end
  if #failed > 0 then
    -- Emit one additional error summary naming the failed actions.
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
-- open / get_paths
-- ---------------------------------------------------------------------------

-- Open directories with a direct listing and files with `:edit`. Pass paths
-- through fnameescape so special characters cannot become Ex syntax. Remove
-- the old direct buffer only after another buffer is current.
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
