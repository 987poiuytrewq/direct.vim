# Spec: direct.vim improvements, third review

**Status:** PROPOSED. Five tasks, A26–A30; none has been started.

**Source:** a third static review of `origin/master` at `ad25866`
(12 November 2026). Every task from the earlier reviews (S1–S6, R1–R3, F1–F6,
M1–M6 and A1–A25) is complete and has been removed from this doc; the previous
version, with each task's history, is in git at `ad25866`. Numbering carries on
from A25 so IDs stay unique.

As before, the findings come from reading the code; none has been reproduced
in a running Neovim. Each task's first step is to write a failing test that
reproduces the problem, or to record that it can't be reproduced and drop the
task.

**Last checked:** `origin/master` at `ad25866` (12 November 2026).

## Decisions

These were settled with the maintainer on 12 November 2026 and are written
into each task below:

- **A26:** `history_limit` defaults to 1000 steps per stack, and trash
  retention is on by default, removing unreferenced entries after 90 days.
- **A27:** after a delete, the register points at the deleted entries in the
  trash instead of copying them.
- **A28:** deleting a collapsed row removes the whole chain it shows, but never
  anything that wasn't visible.
- **A29:** an asynchronous paste releases the history lock while its prompt
  is open.
- **A30:** the next release is `v0.3.0`, tagged now with A7–A25. A26–A29 go in
  a later release.

## Conventions

- One task per branch and pull request, tests first, run with `make test` and
  `make lint`.
- Keep the existing guarantees: changes never overwrite an existing entry,
  history is journaled, unsaved listing edits are never discarded without an
  explicit `!`, and the repo's own test harness is used.
- Update `README.md`, `doc/direct.txt` and `CHANGELOG.md` (under
  `[Unreleased]`) whenever behaviour, options or mappings change.
- Priorities: **P1** can lose the user's work or data, **P2** is a safety,
  robustness or release gap, **P3** is a usability or feature gap, **P4** is
  project maturity.

## Task list

| ID | Priority | Status | Task |
|----|----------|--------|------|
| A26 | P2 | Proposed | Stop history, trash and register from growing forever |
| A27 | P2 | Proposed | Stop deletes on save from copying everything into the register first |
| A28 | P3 | Proposed | Define, document and test edits to collapsed rows |
| A29 | P3 | Proposed | Handle a busy history lock from another Neovim instance clearly |
| A30 | P4 | Proposed | Release, coverage floor, wider CI and a stale comment |

## Robustness and performance

### A26 — History, trash and register grow forever (P2)

**Problem.**

- **History.** The undo and redo stacks have no size limit. Every save, undo,
  redo, paste and yank reads both files and deserializes every record
  (`M.classify` in `lua/direct/history/format.lua`, around line 116), then
  `commit_stacks` (`lua/direct/history/history.lua`, around line 543) rewrites
  the journal and both stacks with a disk sync. So each operation gets slower
  as the history grows, without bound.
- **Trash.** `apply_retention` (`lua/direct/trash.lua`, around line 500) only
  considers entries the history doesn't refer to. Since the history is never
  trimmed, every deleted file stays referenced, so even with
  `trash_retention` set, deleted files are kept forever. Retention is also off
  by default (`trash_retention = false` in `lua/direct/config.lua`).
- **Register.** `M.yank` (`lua/direct/register.lua`, around line 66) copies
  each new selection into `register/<digest>`. Nothing removes the old copies,
  and every save that deletes rows adds one (see A27).
- **Health.** `:checkhealth direct` reports the trash size, but not the
  register size or the number of history steps (`lua/direct/health.lua`).

**Change.**

- Add a `history_limit` option, defaulting to 1000 steps per stack. When a
  commit would go over it, drop the oldest records. That's safe for the
  A19 dependency rules, because nothing older depends on the oldest record.
  Say once, the first time steps are dropped, that older undo steps were
  removed.
- Once records are dropped, their trash entries are unreferenced, so retention
  can remove them. Turn retention on by default:
  `trash_retention = { max_age_days = 90 }`. `false` still turns it off.
  Record both new defaults under Changed in the changelog, and update the
  README's defaults block and `doc/direct.txt`.
- Remove register copies that no history record refers to and that aren't the
  current register. A paste's redo copies from its register folder, so keep
  any folder a paste record names.
- Report history step counts and the register's size in `:checkhealth`, and
  warn above a threshold.
- Consider caching the parsed stacks between operations, re-reading only when
  the files' size or modification time changes, so each operation doesn't
  re-validate every record.

**Tests.** With the defaults, `require('direct.config').options` has
`history_limit = 1000` and `trash_retention.max_age_days = 90`. With
`history_limit = 3`, five saves leave three undo steps and
the oldest trash entries unreferenced. Retention then removes them. An old,
unreferenced register copy is removed; the current one and one named by a
paste record are kept. `:checkhealth` shows the step counts and register size.

### A27 — Deletes on save copy everything into the register first (P2)

**Problem.** Before a save that deletes rows changes anything, `sync_locked`
(`lua/direct/buffer/sync.lua`, around line 819) calls `register.yank` on
every deleted path, and `_yank_one` (`lua/direct/register.lua`) copies each
one in full with `fs.copy_tree`. This runs synchronously, before the
background moves added for R2. Then the originals are moved to the trash. So
deleting a 5 GB `build/` folder:

- copies 5 GB into `~/.local/share/direct/register/`, doubling the disk used;
- freezes the editor for the whole copy;
- leaves that copy behind for good (A26).

`yy` on a large folder has the same freeze.

**Change.**

- For deleted rows, don't copy: point the register at the entries' trash
  paths instead, and copy from there on `p`. If a trash entry is restored by
  undo or removed by retention, fall back to its restored path or drop it from
  the register, and say so on `p`.
- Explicit yanks (`yy`, visual `y`) still copy, since the source stays in
  place and may change. Run that copy in the background, under the existing
  pending guard, so `yy` on a large folder doesn't freeze the editor.
- Update `doc/direct.txt` (`direct.vim-yank`) to describe what the register
  holds after a delete.

**Tests.** Deleting a folder on save leaves no copy of it under `register/`,
and `p` afterwards pastes it. After `u` restores it, `p` still works or says
why not. `yy` on a large folder returns before the copy finishes and marks the
operation pending.

### A29 — A busy history lock gives a cryptic, immediate failure (P3)

**Problem.** The history lock doesn't wait. On Unix it is
`flock(fd, LOCK_EX | LOCK_NB)` (`lua/direct/platform/unix.lua`, around line
92), and on Windows `LockFileEx` with fail-immediately
(`lua/direct/platform/windows.lua`, around line 173). While one Neovim
instance holds it, a save, undo, redo or yank in another fails at once with
`direct: history unavailable: flock failed (errno 11)`.

The lock is held for the whole of an operation, including while an
asynchronous paste waits on its "already exists. Paste as:" prompt
(`lua/direct/action/action.lua`, around line 760), and while a long
cross-filesystem move runs. So a second instance can fail just because the
first is waiting for the user to type a name.

**Change.**

- When the lock is busy (`EWOULDBLOCK`, or Windows' lock violation), retry for
  a short time, for example up to 2 seconds, before giving up.
- Replace the errno text with a plain message: another Neovim instance is
  using direct.vim's history, it may be waiting on a prompt, and the operation
  can be retried. Write the holder's process ID into the lock file, if that
  can be done safely, so the message can name it.
- Release the lock while an asynchronous paste waits on its prompt. After the
  answer, take the lock again, re-run the history preflight, and check that
  the destination is still free before copying. If anything changed, ask
  again or stop, without overwriting. Other instances can then save and undo
  while the prompt is open.

**Tests.** While a paste prompt is open, another process can take and
release the lock. If that process creates the chosen destination meanwhile,
the paste asks again rather than overwriting. With the lock held by a second
process, an operation in the first
retries, then fails with the new message. If the second process releases it
within the retry window, the operation succeeds.

## Features and usability

### A28 — Edits to collapsed rows aren't defined or tested (P3)

**Problem.** Folder chains collapse by default since #95, so many listings now
show rows like `a/b/c/`. Only renaming one is tested
(`tests/buffer/buffer_rows_spec.lua`, around line 149), and the help only says
"each path component remains editable".

- **Delete.** Deleting the row `a/b/c/` goes through `build_actions` in
  `lua/direct/buffer/sync_plan.lua` (around line 390), which removes only
  `c/` and leaves `a/b/` behind as empty folders that the next listing shows
  as `a/b/`. Someone deleting the visible row may expect all of it to go.
- **Yank, paste, move.** Yanking a collapsed row, pasting onto one, and
  re-indenting one under an expanded folder have no sync tests.
- **Windows.** `render_chain` in `lua/direct/buffer/collapse.lua` joins
  components with `/` but ends the row with the platform's folder marker, so
  on Windows a row reads `a/b/c\`.

**Change.**

- Deleting a collapsed row removes the whole chain it shows. Remove the
  deepest folder (with its contents, as a normal folder delete), then each
  parent in the chain, deepest first, but only if it is now completely empty
  on disk. A parent that still holds hidden or Git-ignored entries is kept, so
  nothing that wasn't shown is deleted. Record all of it as one history step,
  so one `u` restores everything.
- Document this under `direct-collapse_single_entry_directories` and in the
  README's "Rules for edits", and note it in the changelog.
- Add sync tests for deleting, yanking, pasting onto and moving collapsed
  rows, and for undoing each.
- Use one separator in collapsed rows on Windows, the same one new nested
  paths use.

**Tests.** Deleting `a/b/c/` removes `a/`, `b/` and `c/` when they hold
nothing else. With a hidden file in `a/`, only `b/` and `c/` go and `a/` stays.
One `u` restores the whole chain. Plus the yank, paste and move cases above,
each followed by `u`. On Windows, a collapsed row
uses a single separator and still renames correctly.

## Project maturity

### A30 — Release, coverage floor, wider CI and a stale comment (P4)

**Problem.**

- 18 completed tasks are on `master` but not released (A7–A15, A22–A25),
  including #95's change to the collapsing default, which changes how every
  listing looks. The latest tag is `v0.2.1`.
- CI publishes coverage (`make coverage`) but never fails on it, so coverage
  can drop unnoticed.
- Latest stable Neovim is tested only on Linux; macOS and Windows run only
  0.11.7.
- A comment above `preflight_locked` (`lua/direct/history/history.lua`, around
  line 571) still says unsupported history formats are "silently reset".
  Since S3 they are kept and block operations.

**Change.**

- Tag `v0.3.0` now, with A7–A25, using the README's release checklist, and
  publish its GitHub release. It's a minor bump because collapsing is now on
  by default. A26–A29, which change more defaults, go in a later release.
- Add a coverage floor near the current figure to `make ci`.
- Add macOS and Windows to the stable-Neovim job, or run the full matrix on
  stable weekly.
- Correct the comment.

**Tests.** None beyond CI itself: a deliberately lowered coverage figure fails
`make ci` locally.

## Suggested order

1. A30's `v0.3.0` release first. It's quick and gets A7–A25 to users.
2. A27, then A26. A27 stops the biggest copies, and A26's register clean-up
   builds on it.
3. A29 and A28, in either order.
4. The rest of A30.
