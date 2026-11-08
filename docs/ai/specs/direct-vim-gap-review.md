# Spec: direct.vim gap review follow-ups

**Status:** S1, S2 and S3 are complete; the remaining tasks are proposed and have
not been checked item by item. This replaces `direct-vim-remaining-improvements.md`.
Its main pieces (JSONL history, no-overwrite moves, exclusive `touch`, the
safeguard on undoing a paste) appear in the current code, but that was not
checked item by item.

**Source:** a static review of the code at `debabf2` (November 2026). The
findings come from reading the code; none has been reproduced in a running
Neovim yet. Each task's first step is to write a failing test that reproduces
the problem, or to record that it can't be reproduced.

## Conventions

- One task per branch and pull request, tests first, run with `make test`.
- Keep the existing guarantees: changes never overwrite an existing entry,
  history is journaled, and the repo's own test harness is used.
- Update `README.md` and `doc/direct.txt` whenever behaviour or options
  change.
- Priorities: **P1** can lose the user's work or data, **P2** is a safety or
  robustness gap, **P3** is a usability or feature gap, **P4** is project
  maturity.

## Task list

| ID | Priority | Status | Task |
|----|----------|--------|------|
| S1 | P1 | Complete | Stop opening, navigating or refreshing from throwing away unsaved listing edits |
| S2 | P1 | Complete | Make `u` / `<C-r>` safe when the listing has unsaved edits, and make clear what they undo |
| S3 | P1 | Complete | Keep a damaged or unrecognised history file instead of wiping it |
| S4 | P2 | Proposed | Add a way to see, restore from and empty the trash, and keep it from growing forever |
| S5 | P2 | Proposed | Ask before `gc` discards Git changes, and review the `gc` / `gr` key clashes |
| S6 | P3 | Proposed | Add an optional preview of the planned changes before `:w` applies them |
| S7 | P4 | Proposed | Put the lock file inside the `direct/` data directory |
| R1 | P2 | Proposed | Stop `git status` from freezing the editor |
| R2 | P3 | Proposed | Run long moves during `:w` without blocking the editor |
| R3 | P3 | Proposed | Make `:checkhealth direct` check more |
| F1 | P3 | Proposed | Let users remap individual keys |
| F2 | P3 | Proposed | Open entries in a split, vertical split or new tab |
| F3 | P3 | Proposed | Send `User` events for other plugins and configs to hook into |
| F4 | P3 | Proposed | Add a command to view the history |
| F5 | P3 | Proposed | Allow mixed changes at the top level in one save, or explain the rule better |
| F6 | P3 | Proposed | Optional extra columns (size, date modified, permissions) and sorting |
| F7 | P3 | Proposed | Give every message the same `direct:` prefix |
| M1 | P4 | Proposed | Version tags, releases and a changelog |
| M2 | P4 | Proposed | Widen CI: latest stable and nightly Neovim, and pushes to `master` |
| M3 | P4 | Proposed | Add linting, formatting and type checks |
| M4 | P4 | Proposed | Split the largest modules up |
| M5 | P4 | Proposed | Replace the temporary override of `vim.fn.confirm` |
| M6 | P4 | Proposed | Decide whether to support Neovim 0.11 |

## Safety

### S1 — Unsaved listing edits are thrown away (P1)

**Status: COMPLETE.** Modified listings are preserved on navigation and
refresh, opening a file from a modified listing is refused, and `:DirectList!`
(plus the other listing commands' bang forms) deliberately discards edits.
Regression tests cover these paths; `make test` passes.

**Problem.** `Buffer:list()` (`lua/direct/buffer.lua`, around lines 739–985)
always replaces the buffer's lines and sets `modified = false`.
`Buffer:open()` (around lines 2184–2219) opens a file and then force-deletes
the listing with `nvim_buf_delete(..., { force = true })`. Unsaved renames,
creates and deletes are lost without a warning when the user:

- presses `<CR>` on a file;
- presses `<CR>` on a folder and later comes back, which reuses the buffer and
  lists it again;
- presses `-` or `z-`, or runs `:DirectList`, on a directory that already has
  a modified listing open.

The toggles already refuse in this case (`toggle_hidden`, `toggle_gitignore`
and the Git-status filter, around lines 1297–1390).

**Change.**

- Opening a file: don't force-delete a modified listing. Either keep it as a
  hidden buffer or refuse with the same "sync or discard them first" message
  the toggles use. Pick one, document it, and test it.
- Listing a buffer that is reused and modified: refuse instead of listing it
  again, unless the call is an internal refresh straight after a successful
  sync, undo, redo or paste.
- Offer a deliberate way to discard edits (for example `:DirectList!` or
  `:edit!`) so a refused user isn't stuck.

**Tests.** Edit a listing, then `<CR>` on a file, `<CR>` on a folder then `-`,
and `-` back onto the modified directory. In each case the edits are still in
the buffer, or the user was told and nothing changed. The discard command does
discard.

### S2 — `u` reverts changes on disk from anywhere (P1)

**Status: COMPLETE.** Dirty listings route `u` / `<C-r>` and `:DirectUndo` /
`:DirectRedo` to text undo/redo. Clean listings confirm before changing paths
outside their directory by default; `undo_confirm` configures the prompt policy.
The prompt names the action and full affected paths, and the normal action
summary remains after success. Regression tests cover declining and accepting
an outside undo, same-directory undo, dirty text undo/redo, and config modes.
`make test` passes.

**Problem.** In a listing, `u` runs `:DirectUndo`, which reverts the last
change on disk from one history shared by every listing and every Neovim
instance (`lua/direct/init.lua`, `M.undo` / `M.redo`). It asks no
confirmation and doesn't check `modified`, then lists the buffer again,
which throws away unsaved edits (see S1). Someone who presses `u` out of
habit after a stray `dd` can revert an unrelated rename in another directory.

**Change.**

- When the listing is modified, `u` / `<C-r>` don't touch the disk. Either
  fall back to text `:undo` / `:redo` (recommended, because it matches what
  users expect) or refuse with a clear message. `:DirectUndo` /
  `:DirectRedo` behave the same way.
- Before reverting a change outside the current listing's directory, say what
  will be reverted and where, and ask to confirm. Add an option to always
  confirm, never confirm, or confirm only for changes elsewhere (default:
  elsewhere).
- Keep the summary shown after an undo, and make sure it names the paths.

**Tests.** `dd` then `u` in a listing puts the line back and doesn't change
the disk. An undo whose change is in another directory asks first, and
declining changes nothing. An undo in the same directory works as it does
now.

### S3 — Damaged history is wiped silently (P1)

**Status: COMPLETE.** Missing and empty logs start fresh. Recognized legacy
Python logs are backed up before a warned reset; damaged, future, or unknown
logs remain byte-for-byte and block operations. `:DirectHistoryReset` backs up
readable non-empty stacks before resetting them. Tests cover malformed JSONL,
unknown versions, invalid UTF-8, missing final newlines, legacy backups, and the
explicit reset command. `make test` passes.

**Problem.** `history_format.classify` returns `reset` for any file it
doesn't recognise: a bad line, a missing final newline, a different header or
a newer version. `preflight_locked` (`lua/direct/history.lua`, around lines
556–571) then resets both stacks "without migration or a warning". Trash
entries are named by a hash of their original path, and only the history
records what they were, so losing the history leaves deleted files on disk
with no way to find them.

**Change.**

- A missing or empty file is still a fresh start.
- A recognised old format (the Python version's logs) may still be reset, but
  with a warning, and only after the old file is copied to a timestamped
  backup in `history/`.
- Anything else (a newer version, a bad line, invalid UTF-8) is kept exactly
  as it is, and the operation is refused with a message that names the file.
  This is what the earlier spec intended.
- Add `:DirectHistoryReset` (or similar) that moves the bad files to a backup
  and starts fresh, so the user can get going again.
- Update `doc/direct.txt` under `direct.vim-history-format`.

**Tests.** A bad line, a newer version and a missing newline are each kept
byte for byte and block the operation. An old-format file is backed up and
then reset, with a warning. The reset command creates a backup.

### S4 — No way to manage the trash (P2)

**Problem.** Deleted entries go to `<data>/trash/<sha256>`
(`lua/direct/action.lua`, `first_free_trash`) and are never removed. There's
no way to list them, restore one, or empty the trash. Deleting a large tree on
another drive copies it into the data directory.

**Change.**

- Store a small file next to each trash entry giving its original path and the
  time it was deleted, so the trash can be read without the history.
- Add `:DirectTrash` to show trashed entries (original path, deleted time,
  size), with a way to restore one (without overwriting anything) and to empty
  the trash. Entries the history still refers to are protected unless the user
  forces it.
- Add an optional retention setting (age and/or total size), off by default.
  Show the trash's size in `:checkhealth`.
- Look at warning or asking before deleting a large tree that would have to be
  copied to another filesystem.

**Tests.** Delete, then list the trash, restore, and empty it. An entry the
history still refers to isn't removed without forcing. Restoring onto an
existing path is refused.

### S5 — `gc` discards Git changes with no confirmation (P2)

**Problem.** `gc` runs `git checkout -- {}` (`lua/direct/config.lua`,
`BUFFER_MAPS`). It can't be undone with `u`, and on a directory row it
discards every change beneath it. Inside listings, `gc` also overrides
Neovim's built-in comment key, and `gr` makes the 0.11+ default LSP keys
(`grn`, `grr`, `gra`, `gri`) wait for `timeoutlen`.

**Change.**

- Ask before discarding, naming the path and how many changed files it
  covers. Use `git restore` where it's available.
- Decide whether `gc` and `gr` should move to other keys (for example `gR` to
  restore, `gu` to unstage). If they move, document the change in the
  changelog (M1).

**Tests.** Declining the prompt leaves the working tree as it was. Accepting
it restores the file.

### S6 — No preview before `:w` (P3)

**Change.** Add an option (`confirm = false | true | 'destructive'`) that
shows the planned operations (renames, creates, moves, deletes) in a prompt or
floating window before anything changes. The planned actions already exist
(`build_actions`, `action.summarize`). Declining leaves the buffer modified
and the disk untouched.

**Tests.** With the option on, declining changes nothing and keeps the edits.
`'destructive'` asks only when something would be deleted or moved.

### S7 — Lock file outside the data directory (P4)

**Problem.** The lock is at `$XDG_DATA_HOME/.direct-history.lock`
(`lua/direct/history_lock.lua`, `lock_path`), not under `direct/`.

**Change.** Move it to `<data>/direct/.direct-history.lock`. Running an old
and a new version at the same time would then use different locks, so
document that, or check both locks during one release.

## Robustness and performance

### R1 — `git status` blocks with no timeout (P2)

**Problem.** `lua/direct/git.lua` calls `vim.system(...):wait()` with no
timeout on every listing and refresh. A large repository or a slow
filesystem freezes the editor.

**Change.** Pass a timeout to `wait()` (configurable, for example
`git.timeout_ms`). Better, read the Git status in the background and add the
status symbols when it arrives. If it times out, show the listing without
Git status and tell the user once.

**Tests.** With a fake `git` that hangs, the listing appears within the
timeout and shows a warning.

### R2 — Long moves during `:w` block the editor (P3)

**Change.** Run the actions from `:w` in the background the same way paste,
undo and redo already do (`execute_async`), keeping the lock and the
"operation pending" refusals. Show progress for long copies to another
filesystem.

### R3 — `:checkhealth direct` checks very little (P3)

**Change.** Check that Git is available and its version, that the data
directory can be written to, the state of the history files (OK, kept because
damaged, or recovery needed), any unfinished transaction, the trash's size,
whether nvim-web-devicons is installed, and the current icon settings.

## Features and usability

### F1 — Keys can't be remapped one at a time (P3)

**Problem.** `map_default_keys` turns every mapping on or off at once. There
are no `<Plug>` mappings, and the folder keys (`zo`, `zc`, `za` and their
recursive forms) have no public Lua function, so users who turn the defaults
off can't rebuild them.

**Change.** Add a `mappings` table option where each action can be given a
key, or `false` to turn it off. Add `<Plug>(direct-…)` mappings. Expose
`expand`, `collapse` and `toggle` (with recursive variants) in
`require('direct')`.

### F2 — No split, vertical split or tab open (P3)

**Change.** Add `open({ split = 'horizontal' | 'vertical' | 'tab' })` and
default keys (for example `<C-s>`, `<C-v>`, `<C-t>`). These must follow S1:
the listing isn't discarded.

### F3 — No events for other plugins to hook into (P3)

**Change.** Send `User` events (for example `DirectListPost`,
`DirectSyncPre`, `DirectSyncPost`, `DirectUndoPost`, `DirectPastePost`) with
the root and the actions in `data`. Document them.

### F4 — No history view (P3)

**Change.** Add `:DirectHistory` to show the undo and redo stacks with each
action's summary and paths, read-only.

### F5 — Top-level saves can't mix change types (P3)

**Change.** Look at allowing renames, creates and deletes together at the top
level when the planner can match them up unambiguously, as it already does
inside expanded folders. If that isn't safe, make the refusal message explain
the rule and suggest a fix.

### F6 — No extra columns or sorting (P3)

**Change.** Optional, display-only columns for size, date modified and
permissions, plus a sort option (name, type, size, date). They must not
affect how the sync reads rows.

### F7 — Message prefixes aren't consistent (P3)

**Change.** Give every user-facing message the `direct:` prefix (for example
`Nothing to undo` and `Failed to undo action - …` in `history.lua`), and
route them all through `ui.notify`.

## Project maturity

### M1 — No version tags, releases or changelog (P4)

**Change.** Add `CHANGELOG.md`, tag versions (starting at `v1.0.0` or
`v0.x`), and publish GitHub releases. Look at publishing to LuaRocks so
`rocks.nvim` and lazy.nvim can use it.

### M2 — CI covers too little (P4)

**Change.** Run CI on pushes to `master` as well as pull requests. Add jobs
for the latest stable Neovim and nightly. Nightly may fail without failing
the build.

### M3 — No linting, formatting or type checks (P4)

**Change.** Add a `luacheck` (or `selene`) config and `stylua`, plus a
`make lint` target that runs in CI. Add LuaLS type annotations for the
public API in `lua/direct/init.lua` and `config.lua`, and check them with
`lua-language-server --check`.

### M4 — The largest modules are hard to work on (P4)

**Change.** Split `buffer.lua` (about 2.4k lines) into the listing, row
state and marks, open and navigation, and sync. Split `history.lua` and
`fs.lua` the same way where the boundaries are clear. Move code only, with no
behaviour changes, and keep the tests passing at every commit.

### M5 — `vim.fn.confirm` is replaced temporarily (P4)

**Problem.** `lua/direct/file_operations.lua` (around lines 494–510) swaps
the global `vim.fn.confirm` while a workspace edit is applied, to tell
whether the user declined it.

**Change.** Find a supported way to tell whether an edit was declined (for
example, checking the edit's change annotations before applying it). If
there isn't one, keep the swap, but restore it in every code path and add a
test that it always is.

### M6 — Neovim 0.12 is required (P4)

**Change.** Find out which 0.12-only APIs are used. Then either support 0.11
with fallbacks and add it to CI, or keep 0.12 and explain why in the
README.

## Suggested order

1. S1, S2 and S3 (P1), one pull request each, in that order: S2 builds on
   S1's modified-buffer guard.
2. S5, R1 and S4.
3. M1 and M2, so later changes are released and tested properly.
4. Everything else, in any order. M4 is easiest when nothing else is changing
   the same files.
