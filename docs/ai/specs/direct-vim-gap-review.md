# Spec: direct.vim improvements, second review

**Status:** PROPOSED. Nothing here has been implemented yet. This replaces the
first gap review, whose tasks (S1–S6, R1–R3, F1–F6, M1–M6) have all landed
on `master`.

**Source:** a second static review of `origin/master` at `d72b7ea`
(November 2026). As before, the findings come from reading the code; none has
been reproduced in a running Neovim. Each task's first step is to write a
failing test that reproduces the problem, or to record that it can't be
reproduced and drop the task.

**Update:** A2 was revised after `e517c21` (Git-ignore queries in parallel,
merged in #97, `origin/master` at `67a3063`). The other tasks have not been
rechecked against commits after `d72b7ea`.

## Conventions

- One task per branch and pull request, tests first, run with `make test` and
  `make lint`.
- Keep the existing guarantees: changes never overwrite an existing entry,
  history is journaled, unsaved listing edits are never discarded without an
  explicit `!`, and the repo's own test harness is used.
- Update `README.md`, `doc/direct.txt` and `CHANGELOG.md` whenever behaviour,
  options or mappings change.
- Priorities: **P1** can lose the user's work or data, **P2** is a safety,
  robustness or release gap, **P3** is a usability or feature gap, **P4** is
  project maturity.

## What the first review's work changed

Checked by reading the code at `d72b7ea`:

- Unsaved listing edits are protected on open, navigation and refresh, with
  `!` forms to discard them on purpose.
- `u` / `<C-r>` fall back to text undo in a modified listing, and ask before
  reverting changes outside the current directory (`undo_confirm`).
- Damaged or unknown history files are kept and block operations;
  `:DirectHistoryReset` backs them up first.
- `:DirectTrash` lists, restores and empties the trash, with optional
  retention (`trash_retention`), and trash entries now have metadata files.
- Git worktree restore asks first and moved to `<leader>gr`; unstage moved to
  `<leader>gu`.
- `git status` runs in the background with a timeout.
- Top-level saves pair rows by identity, so renames, creates and deletes can
  be mixed in one save.
- Remappable mappings and `<Plug>` actions, split and tab opens, `User`
  events, `:DirectHistory`, consistent `direct:` messages, `:DirectGitDiff`,
  collapsed single-child directory chains, Neovim 0.11.7 support, a
  changelog with a `v0.1.0` tag, and CI with lint, stable and nightly jobs.

## Task list

| ID | Priority | Task |
|----|----------|------|
| A1 | P1 | Stop `p` / `P` from discarding unsaved listing edits |
| A2 | P2 | Stop Git-ignore filtering from blocking, and from walking the whole tree |
| A3 | P2 | Don't fail the whole listing when one subfolder can't be read |
| A4 | P2 | Release what the README documents |
| A5 | P2 | Let a save continue after unrelated changes on disk, without losing edits |
| A6 | P2 | Keep forced trash operations from leaving undo history stuck |
| A7 | P3 | Stop trash retention from walking the whole trash on every save |
| A8 | P3 | Fill in metadata for trash entries that don't have it |
| A9 | P3 | Make `:DirectTrash` easier to use |
| A10 | P3 | Make Git worktree restore undoable |
| A11 | P3 | Let `DirectSyncPre` cancel a save, and add the missing events |
| A12 | P3 | Review default keys that shadow common user mappings |
| A13 | P4 | Widen lint, formatting and type-check coverage |
| A14 | P4 | Fix stale docs and remove stray files |
| A15 | P4 | Retire the positional root classifier |

## Safety

### A1 — `p` / `P` discard unsaved listing edits (P1)

**Problem.** `M.paste` in `lua/direct/init.lua` doesn't check whether the
listing is modified. It copies the direct register onto disk at once, then
`paste_and_refresh` calls `Buffer:refresh_after_paste`
(`lua/direct/buffer/open.lua`, around lines 190–217). That re-lists with
`{ allow_modified = true, reset_undo = true }`, which replaces the buffer and
clears its undo. The toggles, open and navigation all refuse in this
situation, but paste doesn't.

The common Vim habit `ddp` (move a line down) runs into this. `dd` deletes a
row as an unsaved edit, and `p` then pastes whatever was last yanked into the
direct register onto disk. That could have been yanked hours ago, or in
another Neovim instance. The `dd` edit and every other unsaved edit are then
thrown away.

**Change.**

- Refuse `p`, `P` and `:DirectPasteAs` in a modified listing with the usual
  "sync or discard them first" message. `:DirectPaste {dir}` from another
  buffer is unaffected.
- Alternatively, refresh after the paste while keeping the unsaved edits
  (re-plan them against the new listing). Only do this if it can be done
  safely; refusing is the simpler fix.
- Mention in `doc/direct.txt` (`direct.vim-yank`) that `p` in a listing is a
  filesystem paste, not Vim's put.

**Tests.** `dd` then `p` in a listing changes nothing on disk, keeps the
edit, and reports the refusal. A paste in a clean listing works as now.

### A5 — A save is refused after any change on disk (P2)

**Problem.** `classify_identity` (`lua/direct/buffer/sync_plan.lua`) refuses
the whole save with "directory changed on disk since it was listed" if any
root entry was added, removed or replaced since the listing was made, even
an entry the user didn't edit. Build tools, log files, `.DS_Store` and Git
operations do this all the time. Since the S1 fix, the only way out is
`:DirectList!`, which throws away every unsaved edit. "Re-list this
directory" after text undo has the same problem.

**Change.**

- Add a way to re-read the disk while keeping the edits. For example, a
  `:DirectRefresh` that keeps identity-matched edited rows, adds rows for new
  entries, and drops rows for entries removed on disk. It refuses if an
  edited row's entry itself changed or vanished.
- Or let the save go ahead when the outside changes don't touch any edited
  row or any destination name. Still refuse when they do.
- Either way, say in the refusal message which entries changed and what the
  user can do.

**Tests.** With an unsaved rename of `a`, an outside process creates `z`.
The save either succeeds, renaming `a` and leaving `z`, or the refresh keeps
the rename. An outside change to `a` itself, or a new entry with the rename's
target name, is still refused.

### A6 — Forced trash operations can leave undo history stuck (P2)

**Problem.** `:DirectTrash! empty` and `:DirectTrash! restore`
(`lua/direct/trash.lua`, `empty_locked` and `M.restore` with `force`) remove
or move trash entries that the undo history still refers to. The history
entries are left as they are. An undo of that delete then can't find its
source. Undo and redo entries are kept until their filesystem change
succeeds, so the failed entry probably stays at the top of the stack and
blocks every undo beneath it. The only way out then is `:DirectHistoryReset`,
which drops the whole history. Confirm this with a test first.

**Change.**

- When forcing, remove or mark the history entries that depend on the
  removed trash entries, in the same locked transaction. Say how many undo
  steps are lost before asking for confirmation.
- Give users a way to drop just the top undo or redo entry when it can no
  longer be applied (for example, `:DirectHistory drop`), instead of
  resetting everything.

**Tests.** Delete a file, force-empty the trash, then `u`. The user is told
the step is gone, and the next undo below it still works. Dropping the top
entry leaves the rest of the stack in place.

## Robustness and performance

### A2 — Git-ignore filtering still blocks and walks the whole tree (P2)

**What's improved.** Since `e517c21` (#97), `ignore_snapshot` starts
`rev-parse --show-prefix` and both `git ls-files` inventories at the same time
after the repository check, instead of one after another.
`docs/performance/ignore-snapshot-approaches.md` measures the snapshot about
28% faster on its 20,000-file fixtures (for example 72 → 52 ms).

**What's left.** `respect_gitignore` is on by default. Every listing calls
`git.ignore_snapshot` (`lua/direct/buffer/listing.lua`), and every save
re-checks it (`current_repo_state` in `lua/direct/git.lua`). Both still:

- wait for Git synchronously, with no timeout. The commands overlap now, but
  `run_parallel` still blocks on `process:wait()`, so a slow or hung Git (a
  network filesystem, a locked index, a credential prompt from a hook) still
  freezes the editor. Only `git status` (`read_async`) has a timeout;
- call `nested_repo_roots`, which is unchanged. It scans every directory
  under the listed root looking for nested `.git` folders, including
  `node_modules`, build output and ignored folders. The benchmark fixtures
  are one level deep, so this cost isn't in the numbers above;
- rebuild the snapshot from scratch each time, with no cache between
  listings and saves. The new repository checks add a `rev-parse` call per
  scope in `current_repo_state`, `inventory_for` and for each nested
  repository.

The benchmark also shows row construction and rendering costing about 530 ms
for a flat 20,000-entry listing with filtering off. That's a separate cost
worth tracking, but it isn't part of this task.

**Change.**

- Find nested repositories without scanning the tree: use gitlinks from
  `git ls-files --stage` (mode `160000`) for submodules, and skip ignored and
  untracked folders (already known from the inventories) when scanning for
  other nested repositories.
- Give the ignore queries a timeout, configurable like `git.timeout_ms`. If
  filtering can't finish in time, list without it once and say so, rather
  than freezing or refusing to list. At save time, refuse with a clear message
  rather than wait indefinitely.
- Cache the snapshot per repository and scope, and reuse it until the index or
  the ignore files change. Reuse the repository check within one listing or
  save instead of repeating `rev-parse`.
- Add a benchmark fixture with a deep tree (for example a nested
  `node_modules`) to `bench/ignore_snapshot_approaches.py`, and record the
  results in `docs/performance/ignore-snapshot-approaches.md`.

**Tests.** A fake `git` that hangs doesn't hold up the listing past the
timeout. A test that counts directory scans shows ignored folders aren't
entered. Nested repositories and submodules are still found, and a second
listing of an unchanged repository doesn't re-run the inventories.

### A3 — One unreadable subfolder fails the whole listing (P2)

**Problem.** `nested_repo_roots` (`lua/direct/git.lua`) returns an error when
`fs_scandir` fails on any directory below the listed root. `ignore_snapshot`
passes the error up, and the listing fails. So a single unreadable folder deep
inside a repository (a root-owned Docker volume, for example) makes the
repository root impossible to list while Git-ignore filtering is on.

**Change.** Skip unreadable directories in the nested-repository scan, and
warn once per listing that naming them. A2 may remove this scan; if so, make
sure the replacement handles this case too.

**Tests.** A repository with a `chmod 000` subfolder still lists, with a
warning. On Windows, skip the test or use an equivalent ACL.

### A7 — Trash retention walks the whole trash after every save (P3)

**Problem.** When `trash_retention` is set, `Buffer:sync` and
`Buffer:sync_async` (`lua/direct/buffer/sync.lua`, around lines 969 and 1005)
call `trash.apply_retention()` after every successful save. That calls
`M.entries`, which measures each entry with a recursive `path_size`, and
reads every history entry for references. With a large trash, every `:w`
pays for a full synchronous walk.

**Change.** Record each entry's size in its metadata when it's deleted, and
use that. Run retention at most once per session or once a day, or in the
background. Keep the full walk for `:DirectTrash` and `:checkhealth`.

**Tests.** With retention on and a large fake trash, a save doesn't scan the
trash's contents (count the calls). Retention still removes the oldest
unreferenced entries when it runs.

## Features and usability

### A8 — Older trash entries have no metadata (P3)

**Problem.** Entries trashed before metadata files existed, including those
from the Python version, show as "unknown" in `:DirectTrash`. They can't be
restored without typing the original path. Age-based retention never removes
them, and the size warning can never clear.

**Change.** When the trash is listed and an entry has no metadata, look it up
in the history's delete actions. Where an action names it, write the metadata
(original path, kind, an estimated deletion time). Add a note to
`doc/direct.txt` about what's left after that.

**Tests.** An entry without metadata but referenced by a history delete shows
its original path, and restores without one being typed.

### A9 — `:DirectTrash` is hard to use (P3)

**Problem.** The view (`trash.show`) is tab-separated text that isn't lined
up. Restoring means typing a 64-character hex ID. `:DirectTrash` has no
completion for its subcommands or IDs (`plugin/direct.lua`), and the view has
no mappings.

**Change.** Line up the columns. Add command completion for `restore` and
`empty` and for IDs. Add view mappings, such as `<CR>` or `r` to restore the
entry under the cursor (asking first), and `q` to close.

**Tests.** Completion returns the subcommands and the current IDs. Restoring
from the view restores the right entry and refreshes the view.

### A10 — Git worktree restore can't be undone (P3)

**Problem.** `<leader>gr` / `:DirectGitRestore` asks first now, but the
discarded worktree changes are gone for good. They aren't in direct.vim's
history or the trash.

**Change.** Before restoring, copy each affected file's current content into
the trash, and record a history action so `u` puts the changes back. If that
seems too large, at least name the backup location in the message.

**Tests.** Restore a modified file, then `u`. The file has its modified
content again, and the history shows one step.

### A11 — `DirectSyncPre` can't cancel, and some operations send no events (P3)

**Problem.** `DirectSyncPre` fires while the history lock is held, after the
plan is checked (`lua/direct/buffer/sync.lua`, around line 711). Handlers
can't stop the save; the docs only ask them to stay read-only. `:DirectTrash`
restore and empty, `:DirectHistoryReset` and Git restore send no events.

**Change.** Let a handler cancel the save, for example by setting
`data.cancel = true` on a table that is checked afterwards. Refuse the save
with a message naming the event. Add `DirectTrashPost`,
`DirectHistoryResetPost` and `DirectGitRestorePost`. Document whether handlers
run while the lock is held.

**Tests.** A handler that cancels leaves the disk and buffer unchanged and
the listing still modified. Each new event fires once with the documented
data.

### A12 — Some default keys shadow common user mappings (P3)

**Problem.** The buffer-local defaults `<leader>gr`, `<leader>gu` and `gd`
(`BUFFER_MAPS` in `lua/direct/config.lua`) override mappings many users
already have in every buffer, such as LSP references or a gitsigns reset.
Users can now remap them, but they may not realise what's being hidden.

**Change.** Pick keys under a prefix that's less often taken, or document
the clash in the README's key table with a one-line `mappings` example
showing how to move them. Note any change in the changelog.

## Project maturity

### A4 — The tagged release lags the README (P2)

**Problem.** The README tells lazy.nvim users to set `version = '*'`, which
installs `v0.1.0`. That tag is at `3f1236f`, before Neovim 0.11 support, the
Git diff view, collapsed directory chains, the module split and the
`vim.fn.confirm` fix. The README already documents those, and says 0.11.7 is
supported, but `v0.1.0` needs 0.12. `CHANGELOG.md` lists only the Git diff
under Unreleased.

**Change.**

- Fill in the Unreleased section (0.11.7 support, collapsed chains, the
  confirm fix, removal of LuaRocks packaging), then tag `v0.2.0` and publish
  a GitHub release.
- Add a short release checklist (to `CONTRIBUTING.md` or the README's
  development section): update the changelog, tag, release.
- Consider a CI check that fails when code under `lua/` changes but
  `CHANGELOG.md` doesn't, with a label to skip it.

### A13 — Lint and type checks cover only part of the code (P4)

**Problem.** `make lint` lets luacheck pass with up to 48 warnings
(`LUACHECK_MAX_WARNINGS`). StyLua and LuaLS only check `init.lua` and
`config.lua`, and `.luarc.json` turns off `undefined-field` everywhere.

**Change.** Reduce the luacheck allowance step by step to zero. Run StyLua
over all of `lua/` (one formatting-only commit). Extend LuaLS checks module by
module, and turn `undefined-field` back on where the annotations allow.

### A14 — Stale docs and stray files (P4)

**Problem.**

- `README.md` ("Development") says CI runs against 0.11.7 on every pull
  request. It now also runs lint, latest stable and nightly, and on pushes to
  `master`.
- `luacov-reporters-0.1.0-1.rockspec` at the repo root isn't used by the
  Makefile or the scripts, now that LuaRocks packaging has been removed.
- `docs/performance/gitignore-benchmark.md` describes a baseline from before
  the current implementation. Its successor,
  `docs/performance/ignore-snapshot-approaches.md`, now covers the current
  code.

**Change.** Update the README's CI paragraph. Delete the rockspec if nothing
needs it. Remove the old benchmark, or point it at the new one.

### A15 — The positional root classifier is still used (P4)

**Problem.** `sync_plan.classify` still pairs rows by position. It's kept
"observable for compatibility" and is only used to detect duplicate lines
before `classify_identity` runs (`lua/direct/buffer/sync.lua`, around line
333). It's exported as `M.classify` from `lua/direct/buffer/buffer.lua`, so a
future change could rely on it again by mistake.

**Change.** Move the duplicate check into `classify_identity`, stop exporting
the positional classifier, and delete it along with its tests (or turn the
tests into identity-based ones).

## Suggested order

1. A1 on its own, first.
2. A2 and A3 together, since they touch the same scan, then A5 and A6.
3. A4 as soon as A1 is merged, so users on `version = '*'` get the fixes.
4. Everything else, in any order. A13's formatting-only commit is easiest
   when nothing else is changing `lua/`.
