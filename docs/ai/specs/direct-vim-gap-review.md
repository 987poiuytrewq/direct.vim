# Spec: direct.vim improvements, second review

**Status:** A1–A6 and A16–A20 are complete; A7–A15 remain proposed.
This replaces the first gap review, whose tasks (S1–S6, R1–R3, F1–F6, M1–M6)
have all landed on `master`.

**Source:** a second static review of `origin/master` at `d72b7ea`
(November 2026). As before, the findings come from reading the code; none has
been reproduced in a running Neovim. Each task's first step is to write a
failing test that reproduces the problem, or to record that it can't be
reproduced and drop the task.

**Last checked:** `origin/master` at `0577a4e` (11 November 2026). That check
read #107 (Git views use the current listing) and #108 (window-safe listing
cleanup). A19 is addressed here; A7–A15 remain.

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

| ID | Priority | Status | Task |
|----|----------|--------|------|
| A1 | P1 | Complete | Stop `p` / `P` from discarding unsaved listing edits |
| A2 | P2 | Complete | Stop Git-ignore filtering from blocking, and from walking the whole tree |
| A3 | P2 | Complete | Don't fail the whole listing when one subfolder can't be read |
| A4 | P2 | Complete | Release what the README documents |
| A5 | P2 | Complete | Let a save continue after unrelated changes on disk, without losing edits |
| A6 | P2 | Complete | Keep forced trash operations from leaving undo history stuck |
| A7 | P3 | Proposed | Stop trash retention from walking the whole trash on every save |
| A8 | P3 | Proposed | Fill in metadata for trash entries that don't have it |
| A9 | P3 | Proposed | Make `:DirectTrash` easier to use |
| A10 | P3 | Proposed | Make Git worktree restore undoable |
| A11 | P3 | Proposed | Let `DirectSyncPre` cancel a save, and add the missing events |
| A12 | P3 | Proposed | Review default keys that shadow common user mappings |
| A13 | P4 | Proposed | Widen lint, formatting and type-check coverage |
| A14 | P4 | Proposed | Fix stale docs and remove stray files |
| A15 | P4 | Proposed | Retire the positional root classifier |
| A16 | P2 | Complete | Let a listing made during a Git timeout be saved once Git recovers |
| A17 | P3 | Complete | Make listings opened with `buffers.reuse = false` readable and tidy |
| A18 | P3 | Complete | Make `:DirectGitStatus` and `:DirectGitDiff` use the current listing |
| A19 | P3 | Complete | Don't strand earlier history steps when a step is dropped |
| A20 | P3 | Complete | Don't close other windows when a listing is removed |

## Safety

### A1 — `p` / `P` discard unsaved listing edits (P1)

**Status: COMPLETE.** `p`, `P`, `:DirectPaste` without a directory, and
`:DirectPasteAs` refuse to paste while the current listing has unsaved edits,
preserving the buffer and filesystem. Explicit `:DirectPaste {dir}` remains
available because it does not refresh the current listing. The help and README
explain that `p` / `P` perform filesystem paste rather than Vim text put.
Regression tests cover mapped keys, paste-as, the refusal message, and the
explicit-directory form.

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

**Status: COMPLETE.** Top-level and expanded-folder sync now permit unrelated
disk changes while retaining identity checks on edited, moved and deleted
sources and no-clobber checks on destinations. If text undo/redo loses a root
row identity, the refusal now explains that Direct cannot safely identify the
edit and offers explicit recovery choices rather than implying a re-list will
preserve it. Tests cover expanded sibling creation/deletion, replaced sources,
and the text-undo guidance; `make test` passes.

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

**Status: COMPLETE.** Forced restore and empty now identify history records
that reference affected trash paths, confirm the undo/redo step counts before
proceeding, and atomically rewrite only the affected stacks under the history
lock. Remaining history stays usable. `:DirectHistory drop [undo|redo]`
explicitly removes only the chosen stack's top record. Tests cover forced
restore and empty, confirmation cancellation, retaining lower stack entries,
and both drop directions; `make test` passes.

*Checked at `f6a41cc`:* the code matches. The forced paths in
`lua/direct/trash.lua` plan which history records refer to the affected trash
entries (`history.plan_trash_history`), ask with the step counts, and rewrite
the stacks before removing anything. One consequence is tracked as A19.

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

**Status: COMPLETE.** Git-ignore Git processes now use `git.timeout_ms`; a timed
out list falls back to showing ignored entries with one warning, while sync
refuses if its safety snapshot cannot be validated. Nested-repository discovery
uses index gitlinks, traverses tracked folders, and prunes ignored and untracked
folders. Unchanged, fully fingerprinted repository/scope snapshots are reused;
index, ignore-source, directory, and Git environment changes invalidate them.
The deep ignored-tree benchmark now covers a nested `node_modules`-style tree.
Tests cover hung Git, cache reuse/invalidation, pruning, gitlinks and nested
repositories; `make test` passes.

*Checked at `9266805`:* the code matches. The queries are still waited on in
the foreground, but each wait is now capped by `git.timeout_ms` (1000 ms by
default), so a stuck Git freezes the editor for at most a few of those steps.
After a timeout, saving that listing is refused; see A16.

**Review at task start.** Since `e517c21` (#97), `ignore_snapshot` starts
`rev-parse --show-prefix` and both `git ls-files` inventories at the same time
after the repository check, instead of one after another.
`docs/performance/ignore-snapshot-approaches.md` measures the snapshot about
28% faster on its 20,000-file fixtures (for example 72 → 52 ms).

**Gaps addressed by this task.** `respect_gitignore` is on by default. Every listing calls
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

**Status: COMPLETE.** Unreadable directories encountered during nested-repository
discovery are skipped, collected into one warning for the listing, and included
in the cache fingerprint so permission changes invalidate cached state. A
regression test injects an `EACCES` scan failure and confirms other entries list.

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

### A16 — A listing made during a Git timeout can never be saved (P2)

**Status: COMPLETE.** Sync retries Git-ignore queries for a timed-out listing
and checks every planned source/destination against the recovered rules. Saves
proceed when changed paths remain visible, and refuse if a changed path would be
hidden or the retry times out. `gi` can disable filtering without re-listing or
discarding edits when the listing is already unfiltered. A persistent virtual
line marks timed-out listings even after the one-time notification is suppressed.
Regression tests cover recovery, ignored-row refusal, repeated timeouts, the
`gi` escape hatch and visible marking; `make test` passes.

*Checked at `3d7e746`:* the code matches. Saves re-run the Git-ignore query,
check each planned action's source and destination against it, and only then
clear the timeout state. One thing to confirm by hand: the marker is a virtual
line above the first row, and the tests check `b:direct_gitignore_timed_out`
rather than whether that line is actually on screen when a listing first opens.

**Problem.** When a Git-ignore query times out, `capture_filter` and
`filtered_paths` (`lua/direct/buffer/listing.lua`) set `git_timeout = true`
and store the error on the listing's directory snapshot. At save time,
`sync_locked` (`lua/direct/buffer/sync.lua`, around line 160) sees that flag
and refuses, reusing the stored error. It doesn't query Git again, so the
save is refused even after Git is fast again.

The ways out are blocked too. `gi` refuses with unsaved edits
(`lua/direct/buffer/buffer.lua`, around line 778), and re-listing refuses
with unsaved edits. So edits made in a listing that was created during a
single slow Git call can only be thrown away with `:DirectList!`.

The timeout warning is also shown once per repository per session
(`warn_ignore_timeout` in `lua/direct/git.lua`). A later timeout lists
ignored entries silently, so the user can't tell the listing is unfiltered.

**Change.**

- At save time, retry the Git-ignore query for a timed-out snapshot. If it now
  succeeds, check the edits against its result: refuse only if a row the user
  edited, deleted or moved is ignored and would have been hidden, or if the
  retry also times out.
- Let `gi` turn filtering off in a modified listing when the listing is
  already unfiltered because of a timeout, since that doesn't change what's
  shown.
- Mark a timed-out listing visibly (for example in the status line text or a
  first virtual line) for as long as it's unfiltered, instead of relying on a
  one-time warning.

**Tests.** With a fake `git` that hangs once and then works: list, edit,
save. The save succeeds. If it hangs every time, the save is refused with a
message saying how to continue, and `gi` works. A second timed-out listing in
the same session is still marked as unfiltered.

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

### A17 — Listings opened with `buffers.reuse = false` are hard to tell apart (P3)

**Status: COMPLETE.** Independent listings now use readable `direct://<path>#<n>`
names. With `open_in = 'current'`, navigation removes the clean listing being
left while keeping modified listings hidden. Opening a directory that already
has a modified listing asks whether to switch to it or create a second listing.
Tests cover path-readable names, five down/up cycles without buffer buildup,
and switching to a hidden modified listing; `make test` passes.

*Checked at `f6a41cc`:* the code matches (`M.Buffer` in
`lua/direct/buffer/buffer.lua` and `discard_left_clean_listing` in
`lua/direct/buffer/list.lua`). The way the clean listing is removed closes
other windows that show it; that's tracked as A20.

**Problem.** With `buffers = { reuse = false }`, `M.Buffer`
(`lua/direct/buffer/buffer.lua`) names each new listing
`direct://listing/<sha256 of the path>/<bufnr>`. Buffer lists, tab lines and
status lines then show a 64-character hash instead of the directory. Every
`<CR>` into a folder and every `-` back up also creates another listed buffer
(`bufhidden = 'hide'`), and none of them are cleaned up. Going down and back
up leaves two listings of the same directory, and unsaved edits stay in the
older, hidden one.

**Change.**

- Name these buffers so the directory is readable, for example
  `direct://<path>#<n>`, keeping them unique.
- When `open_in = 'current'`, remove the listing being left if it has no
  unsaved edits, as opening a file already does.
- Before creating a second listing for a directory, say if an existing one
  has unsaved edits, and offer to switch to it.
- Document the trade-offs of `reuse = false` in `doc/direct.txt`.

**Tests.** With `reuse = false`, `:ls` shows the directory path. Going down
and back up five times leaves no extra clean listings behind. A hidden listing
with unsaved edits is mentioned when the same directory is opened again.

### A18 — `:DirectGitStatus` and `:DirectGitDiff` ignore the current listing (P3)

**Status: COMPLETE.** Without `--dir`, both commands now apply to the current
Direct listing when invoked there, and retain the working-directory default
elsewhere. Explicit relative `--dir` values are resolved from the current
listing or working directory according to invocation context. Add completion
for command options, `--dir`, branch/tag refs and directories. Tests cover
current-buffer targeting, relative `--dir` and completion; `make test` passes.

**Problem.** Without `--dir`, both commands open a listing of the working
directory (`open_listing` in `lua/direct/git_commands.lua`), even when run from
a listing of another directory. `gd` calls `require('direct').git_diff()` and
toggles the current listing, so the key and the command behave differently
in the same buffer. Neither command has completion for its options or for
`--dir`, and `--dir` paths are resolved against the working directory.

**Change.**

- Inside a listing, default `--dir` to that listing's directory. Keep the
  working directory as the default elsewhere.
- Add completion for `--ref` (branches and tags), `--dir` (directories) and
  `--include-uncommitted`.
- Update `doc/direct.txt` (`direct.vim-git-view` and the command entries).

**Tests.** `:DirectGitDiff` in a listing of `src/` filters that listing,
the same as `gd`. Outside a listing it uses the working directory.
Completion returns the options and a branch name.

### A19 — Dropping a history step can strand the step below it (P3)

**Status: COMPLETE.** Forced trash cleanup now removes the transitive set of
history records whose paths overlap the deleted record's paths, so earlier
undo/redo entries cannot remain stranded beneath it. Confirmation counts all
removed records. Missing-source undo/redo errors recommend
`:DirectHistory drop undo|redo`, and that command completes its subcommand and
stack direction. Tests cover the rename/delete dependency, recovery after a
failed undo, and completion.

**Problem.** Forced trash operations remove every history record that refers
to the affected trash entries (`filter_trash_records` and
`plan_trash_history` in `lua/direct/history/history.lua`), wherever those
records sit in the stack. Records below a removed one may depend on what it
did. For example, with an undo stack of "rename `b` to `a`", then "delete
`a`", force-emptying the trash removes the delete. Undoing the rename then
looks for `a`, which isn't there, so that undo fails and stays at the top of
the stack. `:DirectHistory drop` gets past it, but only one step at a time,
and the confirmation prompt didn't mention that earlier steps might stop
working.

**Change.**

- When planning which records to remove, also find earlier records whose
  paths overlap with a removed record's paths, and either remove them too or
  list them in the confirmation prompt as likely to fail.
- When an undo or redo fails because its source is missing, say in the error
  that `:DirectHistory drop` removes that step.
- Add completion for `:DirectHistory` (`drop`, `undo`, `redo`).

**Tests.** With the stack above, force-empty the trash: either both steps
are removed, or the prompt names the rename as affected. A failed undo's
message mentions `:DirectHistory drop`.

### A20 — Removing a listing closes other windows that show it (P3)

**Status: COMPLETE.** Clean Direct buffers are now deleted after navigation
only when no window displays them. Modified buffers remain preserved as before.
Tests cover file opens and `buffers.reuse = false` directory navigation from
one split while another still displays the source listing.

**Problem.** `discard_left_clean_listing` (`lua/direct/buffer/list.lua`) and
`Buffer:open` (`lua/direct/buffer/open.lua`, when opening a file with
`open_in = 'current'`) remove the listing being left with
`nvim_buf_delete`. That wipes the buffer, which closes every other window
still showing it. So with the same listing in two splits, opening a file or
going into a folder in one split closes the other split. The `buffers.reuse =
false` clean-up from A17 makes this happen on every folder change, not just
when opening a file.

**Change.** Only remove the listing when no other window shows it (check
`vim.fn.win_findbuf`). Otherwise leave it in place, or let it become hidden
as usual.

**Tests.** Open a listing in two splits, open a file from one: the other
split still shows the listing. With `reuse = false`, go into a folder from
one split: the other split keeps its listing.

## Project maturity

### A4 — The tagged release lags the README (P2)

**Status: COMPLETE.** Prepared `v0.2.0` release notes covering 0.11.7 support,
collapsed chains, configurable buffers, Git diff, the WorkspaceEdit confirmation
fix, LuaRocks removal, and A1–A3/A16 improvements. Added a release checklist to
the README. *Checked at `3d7e746`:* the annotated `v0.2.0` tag points at
`3d7e746`, and the GitHub release was published on 11 November 2026. No
changelog-only CI gate was added; the manual checklist keeps that
policy lightweight until it proves necessary.

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

A1–A4 and A16 were released in `v0.2.0`; A5–A6 and A17–A20 are complete.

1. A release (`v0.2.1` or `v0.3.0`) with A5–A6 and A17–A20.
2. Everything else, in any order. A13's formatting-only commit is easiest
   when nothing else is changing `lua/`.
