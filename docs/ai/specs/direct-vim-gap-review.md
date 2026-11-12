# Spec: direct.vim improvements, second review

**Status:** A1–A13, A16–A24 are complete; A14–A15 remain proposed.
This replaces the first gap review, whose tasks (S1–S6, R1–R3, F1–F6, M1–M6)
have all landed on `master`.

**Source:** a second static review of `origin/master` at `d72b7ea`
(November 2026). As before, the findings come from reading the code; none has
been reproduced in a running Neovim. Each task's first step is to write a
failing test that reproduces the problem, or to record that it can't be
reproduced and drop the task.

**Last checked:** `origin/master` at `284a93e` (12 November 2026). That review
recorded A12's completion and found no new task IDs. A13 is addressed in this
PR; A14–A15 remain proposed.

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
| A7 | P3 | Complete | Stop trash retention from walking the whole trash on every save |
| A8 | P3 | Complete | Fill in metadata for trash entries that don't have it |
| A9 | P3 | Complete | Make `:DirectTrash` easier to use |
| A10 | P3 | Complete | Preserve worktree contents before Git restore |
| A11 | P3 | Complete | Let `DirectSyncPre` cancel a save, and add the missing events |
| A12 | P3 | Complete | Document default keys that shadow common user mappings |
| A13 | P4 | Complete | Widen lint, formatting and type-check coverage |
| A14 | P4 | Proposed | Fix stale docs and remove stray files |
| A15 | P4 | Proposed | Retire the positional root classifier |
| A16 | P2 | Complete | Let a listing made during a Git timeout be saved once Git recovers |
| A17 | P3 | Complete | Make listings opened with `buffers.reuse = false` readable and tidy |
| A18 | P3 | Complete | Make `:DirectGitStatus` and `:DirectGitDiff` use the current listing |
| A19 | P3 | Complete | Don't strand earlier history steps when a step is dropped |
| A20 | P3 | Complete | Don't close other windows when a listing is removed |
| A21 | P3 | Complete | Link paste steps to the entries they created when dropping history |
| A22 | P4 | Complete | Move unreleased trash changes out of the 0.2.1 changelog section |
| A23 | P3 | Complete | Make trash completion cheap, and date recovered entries sensibly |
| A24 | P3 | Complete | Let a Git-restore backup be put back safely from the trash view |

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

**Status: COMPLETE.** Automatic retention now scans a data directory at most
once per Neovim session, rather than recursively sizing every trash entry on
each successful save. Opening `:DirectTrash` forces a fresh retention pass, and
health diagnostics continue to report current trash sizes. Regression tests
count scans for a nested trash tree across repeated saves and verify that
retention still prunes when it runs.

*Checked at `f4d214f`:* the code matches (#113). `apply_retention` in
`lua/direct/trash.lua` skips after its first run per data directory per
session, and `:DirectTrash` forces a pass. Sizes still aren't stored in the
metadata, so that first pass, which can run during a save, still walks the
whole trash synchronously. That's within what this task asked for.

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

**Status: COMPLETE.** When metadata is absent, trash listing now matches the
entry's path against undo/redo delete or restore actions and writes a metadata
sidecar with the recovered original path, on-disk kind, and an estimated
deletion time. Unknown entries with no matching history remain recoverable via
an explicit path. Tests cover the listing, metadata reconstruction, and restore
without a supplied destination.

*Checked at `f4d214f`:* the code matches (#114). `M.entries` looks up
entries without metadata in the history's delete records and writes metadata
for them (`action.recover_trash_metadata`). The deletion time it writes is the
time of recovery, not an estimate of when the entry was deleted; see A23.

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

**Status: COMPLETE.** The trash table now aligns columns by display width.
`:DirectTrash` completes `restore`/`empty` and current trash IDs. In the
read-only view, `r` and `<CR>` confirm and restore the selected entry, then
refresh the view; `q` closes it. Tests cover command completion, alignment,
confirmed restore and view refresh/close.

*Checked at `f4d214f`:* the code matches (#115). The view's `r` and `<CR>`
restore with `force = true`, so restoring an entry the history still uses goes
through A6's prompt, which asks before dropping history steps. Completion is
tracked in A23.

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

**Status: COMPLETE (safe-backup fallback).** Before `:DirectGitRestore` runs,
existing changed tracked entries are copied into trash with metadata. The
notification gives backup IDs and original paths so users can restore them
manually. This takes the spec's explicitly allowed smaller alternative; the
operation is not added to `u`/`:DirectUndo`. Tests cover a confirmed directory
restore, backup contents for every changed tracked file, and the location
notification.

*Checked at `5cc0377`:* the code matches (`worktree_backups` in
`lua/direct/init.lua`). Changed files, symlinks and folders are copied into the
trash with metadata before Git runs, and a failure stops the restore and lists
any copies already made. Putting a backup back is still awkward; see A24.

**Problem.** `<leader>gr` / `:DirectGitRestore` asks first now, but the
discarded worktree changes are gone for good. They aren't in direct.vim's
history or the trash.

**Change.** Before restoring, copy each affected file's current content into
the trash, and record a history action so `u` puts the changes back. If that
seems too large, at least name the backup location in the message.

**Tests.** Restore a modified file, then `u`. The file has its modified
content again, and the history shows one step.

### A11 — `DirectSyncPre` can't cancel, and some operations send no events (P3)

**Status: COMPLETE in #122.** A `DirectSyncPre` handler can call
`require('direct.events').cancel(args.data, reason)` to refuse a sync before
yanks or filesystem effects; the listing stays modified and `DirectSyncPost`
reports the refusal. Added `DirectTrashPost`, `DirectHistoryResetPost`, and
`DirectGitRestorePost` with documented result data. Sync callbacks run while
the history lock is held; docs say they must stay fast and not start nested
Direct operations. Tests cover cancellation and each new post event.

*Checked at `5cca23f`:* the code matches. A handler cancels with
`require('direct.events').cancel(args.data, reason)`, using a token that's
only valid during that dispatch (`lua/direct/events.lua`), and a cancelled save
leaves the buffer modified and sends `DirectSyncPost` with `cancelled = true`.
`DirectTrashPost`, `DirectHistoryResetPost` and `DirectGitRestorePost` are
sent from `lua/direct/init.lua`. One thing to be aware of: if a
`DirectSyncPre` handler raises an error before calling `cancel`, `events.emit`
catches it, warns, and the save goes ahead. That's reasonable for a
notification hook, but a handler used as a guard should not rely on erroring
to block a save.

**Problem.** `DirectSyncPre` fires while the history lock is held, after the
plan is checked (`lua/direct/buffer/sync.lua`, around line 711). Handlers
can't stop the save; the docs only ask them to stay read-only. `:DirectTrash`
restore and empty, `:DirectHistoryReset` and Git restore send no events.

**Change.** User event data is copied by Neovim, so a handler cannot cancel by
mutating `args.data`. Provide `require('direct.events').cancel(args.data,
reason)` for `DirectSyncPre`; refuse the save with a message naming the event.
Add `DirectTrashPost`,
`DirectHistoryResetPost` and `DirectGitRestorePost`. Document whether handlers
run while the lock is held.

**Tests.** A handler that cancels leaves the disk and buffer unchanged and
the listing still modified. Each new event fires once with the documented
data.

### A12 — Some default keys shadow common user mappings (P3)

**Status: COMPLETE in #124.** Kept the key defaults and documented that `gd`,
`<leader>gr`, and `<leader>gu` override existing mappings inside Direct
listings. Added a per-action `mappings` example to move them and clarified that
`map_default_keys = false` disables defaults while retaining explicit and
`<Plug>` mappings. No runtime behavior changed.

*Checked at `5cca23f`:* README and `doc/direct.txt` now explain that
`gd`, `<leader>gr` and `<leader>gu` replace existing keys inside listings,
with a `mappings` example. The action names used (`git_diff`, `git_restore`,
`git_unstage`) match `BUFFER_MAPS` in `lua/direct/config.lua`. The defaults
themselves are unchanged.

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

*Checked at `51cb174`:* the code matches (`lua/direct/git_commands.lua`).
Without `--dir`, both commands use the current listing; a relative `--dir` is
resolved against it. `--ref` completion runs `git for-each-ref` with the
`git.timeout_ms` limit.

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

*Checked at `51cb174`:* the code matches for steps that record the paths they
touch. `filter_trash_records` (`lua/direct/history/history.lua`) keeps
dropping records whose `src` or `dst` overlaps a dropped record's paths until
none are left, and the prompt counts all of them. Because it follows overlaps
in both directions, a step that touched a high-level folder can pull in many
others; the confirmation count is the only guard, which seems acceptable.
Paste steps are missed; see A21.

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

*Checked at `51cb174`:* the code matches. Both `discard_left_clean_listing`
(`lua/direct/buffer/list.lua`) and `Buffer:open` (`lua/direct/buffer/open.lua`)
skip the removal when `vim.fn.win_findbuf` finds the listing in another
window.

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

### A21 — Paste steps aren't linked to the entries they created (P3)

**Status: COMPLETE.** The A19 dependency scan now expands `p` and `up` records
to individual destination entries in `renames`, using the register copy to
identify directories. Forced trash cleanup therefore drops a paste creator when
one of its files—or a descendant of one of its pasted directories—is deleted.
Tests verify both cases, confirmation counts both actions, and no broken paste
undo remains.

*Checked at `707db8d`:* the code matches. `action_path_entries`
(`lua/direct/history/history.lua`) adds one path per `renames` entry for `p`
and `up` records, the pasted entry in the destination folder. It checks the
register copy to tell folders from files, and treats the entry as a folder if
that copy is gone.

**Problem.** The A19 dependency walk reads each record's `src` and `dst`, and
the `actions` of batches (`action_path_entries` in
`lua/direct/history/history.lua`). A paste record (`M.Paste` in
`lua/direct/action/action.lua`) stores the register folder as `src`, the
destination folder as `dst`, and the pasted names in `renames`, which the walk
doesn't read. The destination usually has no trailing separator (it comes
from `vim.fs.dirname` or the listing root in `Buffer:paste_destination`), and
`p` isn't one of the action names treated as a folder, so files inside it
don't count as overlapping.

So with an undo stack of "paste `x` into `d`", then "delete `d/x`",
force-emptying the trash drops the delete but keeps the paste. Undoing the
paste then fails, because `d/x` is gone, and `:DirectHistory drop` is needed
again.

**Change.** Teach `action_path_entries` about paste and unpaste records: add
`dst/<name>` for each `renames` entry, marked as a folder when the pasted
entry is one. Alternatively, treat a paste's `dst` as a folder. That's
simpler, but drops more than needed.

**Tests.** Paste a file, delete it, force-empty the trash: the confirmation
counts both steps, and undo afterwards doesn't fail on the paste.

### A22 — The changelog lists unreleased changes under 0.2.1 (P4)

**Status: COMPLETE.** Moved post-tag entries from #113–#116 (A7–A10) out of
`[0.2.1]` and into `[Unreleased]`. A CI check and unit tests now prevent
pull requests from editing published release sections; the `release` label is
the explicit exception for release PRs. Verified that the current released
section matches `git show v0.2.1:CHANGELOG.md`.

*Checked at `5cc0377`:* the `[0.2.1]` section on `master` now matches
`git show v0.2.1:CHANGELOG.md` exactly. The new CI step
(`scripts/check_changelog_released.py`) compares every released section between
the base branch and the pull request, and is skipped for PRs labelled
`release`. It only runs on pull requests, so commits pushed straight to
`master` aren't checked.

**Problem.** `v0.2.1` is tagged at `06063c3`. #113–#116 landed after that, but
each added its entry to the `[0.2.1]` section of `CHANGELOG.md` (trash
retention, legacy trash metadata, trash-view usability and Git restore backup), not to
`[Unreleased]`. Anyone reading the changelog will think `v0.2.1` has them, and
the next release's notes will leave them out. The README's release checklist
already says to add entries under Unreleased.

**Change.** Move post-tag entries to `[Unreleased]`. Add a CI check that fails
when a pull request edits a released section of `CHANGELOG.md`, with the
`release` label as an explicit exception for release PRs.

**Tests.** Unit tests allow changes under `[Unreleased]` and reject edits to a
released section. After the move, `git show v0.2.1:CHANGELOG.md` and the
`[0.2.1]` section on master match.

### A23 — Trash completion is expensive, and recovered entries get the wrong date (P3)

**Status: COMPLETE in #118.** Restore-ID completion now lists trash-directory names
without measuring entries, taking the history lock or writing metadata.
Recovered timestamps use the trash entry's `ctime`, falling back to `mtime`,
and are marked as estimates in metadata and the view. Tests verify completion
does not call the full entry scan or write metadata, and an old `mtime` is used
and displayed as estimated when `ctime` is unavailable.

*Checked at `6538ac9`:* the code matches (`lua/direct/trash.lua`,
`lua/direct/action/action.lua`). Completion now reads only the trash folder's
names. One small leftover: those names include history reservations, which
`M.entries()` used to hide and `:DirectTrash restore` refuses, so completion
can offer an ID that won't restore.

**Problem.**

- `:DirectTrash restore <Tab>` calls `trash.complete`, which calls
  `M.entries()` (`lua/direct/trash.lua`). That measures every entry with the
  recursive `path_size`, and when entries lack metadata it takes the history
  lock and writes metadata files. So pressing Tab walks the whole trash and can
  change files on disk.
- `action.recover_trash_metadata` (`lua/direct/action/action.lua`) sets
  `deleted_at` to the current time. A trash entry deleted months ago therefore
  looks new, so age-based retention won't remove it for another full
  `max_age_days`, and the view shows the wrong date with no sign it's a guess.

**Change.**

- Give completion a cheap path: list the trash directory's names (skipping
  `.direct-trash.json` files) without measuring sizes or recovering metadata.
- When recovering metadata, estimate the deletion time from the trash entry
  itself (its `ctime`, which a rename into the trash updates, or else its
  `mtime`), and record that the time is estimated, for example
  `deleted_at_estimated = true`. Show it as estimated in the view.

**Tests.** Completion on a trash with a large folder entry doesn't measure
sizes (count the calls) and writes nothing. A recovered entry whose file is
two days old gets a deletion time about two days ago, marked as estimated.

### A24 — A Git-restore backup can't be put back in one step (P3)

**Status: COMPLETE in #120 (safe put-back fallback).** Git-restore backups are marked
in their metadata. In the trash view, `r` / `<CR>` on one asks before moving
the current occupant into trash and restoring the backup. The two filesystem
actions are recorded as one undoable batch, so undo returns to the post-Git-
restore state without losing either version. This implements the task's
explicit fallback; `:DirectGitRestore` itself is still not reversed by `u`.
Tests cover cancellation, preserving the displaced version, put-back, and undo.

*Checked at `bd337c3`:* the code matches. `put_back_git_backup` in
`lua/direct/trash.lua` asks first, then records "move the current file to the
trash" and "restore the backup" as one history step, so nothing is
overwritten and `u` reverses the put-back. `:DirectTrash restore <id>` takes
the same path when no other destination is given. `:DirectGitRestore` itself
still isn't in the undo history, as the PR notes.

**Problem.** #116 copies changed files into the trash before
`:DirectGitRestore`, and the message says to restore them manually. But
`trash.restore` (`lua/direct/trash.lua`) refuses when the destination exists,
and after Git restores a file, its original path always exists again. So
`:DirectTrash restore <id>`, and `r` / `<CR>` in the trash view, refuse for
exactly these backups. The only ways back are restoring to another path with
`:DirectTrash restore <id> <path>` and copying the file over by hand, or
using the trash folder directly. The restore also still isn't in the undo
history, so `u` can't reverse it.

**Change.**

- Record a Git restore as a history action whose undo moves the current file
  into the trash and restores the backup to its place, without overwriting,
  so `u` brings the worktree changes back. This was A10's original goal.
- At least, mark these trash entries as Git-restore backups in their metadata,
  and in the trash view offer to put one back by first moving the current file
  into the trash (with a confirmation), so nothing is overwritten.

**Tests.** Change a tracked file, `:DirectGitRestore` it, then `u` (or put
the backup back from the trash view). The file has its changed content again,
and the restored version is in the trash.

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
- The follow-up `v0.2.1` release includes A5–A6 and A17–A21; its annotated tag
  and GitHub release point at `06063c3`.
- Add a short release checklist (to `CONTRIBUTING.md` or the README's
  development section): update the changelog, tag, release.
- Consider a CI check that fails when code under `lua/` changes but
  `CHANGELOG.md` doesn't, with a label to skip it.

### A13 — Lint and type checks cover only part of the code (P4)

**Status: COMPLETE.** `make lint` now requires zero Luacheck warnings and runs
StyLua across all of `lua/direct`. LuaLS checks the entire module tree for
errors, keeps the public `init.lua` and `config.lua` checks at warning level,
and adds warning-level checks for fully annotated modules. Removed the global
`undefined-field` suppression and annotated the folder-record shape where
needed. Formatting is a separate first commit in this PR.

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

A1–A4 and A16 were released in `v0.2.0`; A5–A6 and A17–A21 were released in
`v0.2.1`.

A7–A12, A23 and A24 are complete but not released.

1. A14–A15, in any order.
   when nothing else is changing `lua/`.
