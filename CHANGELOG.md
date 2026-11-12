# Changelog

Notable changes to direct.vim are documented here. Versions follow
[Semantic Versioning](https://semver.org/); release tags use the `v` prefix.

## [Unreleased]

### Changed

- Collapse chains of single-child directories into one row, such as
  `src/main/java/`, by default. Set `collapse_single_entry_directories = false`
  to keep one row per directory.

- Remove the legacy positional sync classifier; duplicate-row detection now
  happens in the identity-based sync plan.
- Correct the CI description, remove an unused LuaRocks rockspec, and point the
  historical Git-ignore benchmark to the current comparison.
- Run StyLua over all Lua modules, require zero Luacheck warnings, and expand
  LuaLS checking to the full module tree with `undefined-field` diagnostics on.
- Document that the default `gd`, `<leader>gr`, and `<leader>gu` mappings can
  shadow LSP or Git plugin keys inside Direct listings, with per-action examples
  for remapping them.
- Mark `:DirectGitRestore` backups in the trash view and offer a confirmed
  put-back that preserves the current file in trash as an undoable step.
- Make trash restore completion list IDs without sizing entries or recovering
  metadata; mark filesystem-estimated deletion dates in the trash view.

### Fixed

- Preserve changed worktree contents in trash before `:DirectGitRestore`; report
  backup IDs and original paths for manual recovery.
- Limit automatic trash retention to one full scan per data directory per
  Neovim session; `:DirectTrash` still forces a fresh pass.

### Added

- Add `:DirectToggleDirectoryCollapse`, mapped to `gC`, to switch directory
  collapsing for the current listing.
- Let `DirectSyncPre` cancel a save, and emit post events for trash operations,
  history reset and Git worktree restore.
- Add `:DirectTrash` completion for subcommands and IDs, plus confirmed restore
  and close mappings in the trash view.
- Recover original paths and entry types from history, with an estimated
  deletion time, when listing older trash entries without metadata. These
  entries can then be restored normally and considered for age-based retention.

## [0.2.1] - 2026-11-11

### Changed

- Make `:DirectGitStatus` and `:DirectGitDiff` use the current listing when run
  from one without `--dir`; add completion for their options, refs and dirs.
- Make `buffers.reuse = false` listings show their directory path, clean up
  clean buffers during navigation, and offer to switch to an existing modified
  listing for the same directory.

### Fixed

- Allow saves to proceed after unrelated external entries are added, removed or
  replaced at the root and in expanded directories, while preserving conflicts
  on edited sources and requested destinations. Clarify recovery after text undo
  loses a row identity.
- Keep forced trash restore/empty from stranding undo history: confirm and drop
  the affected records and earlier overlapping steps that depend on them. When
  a missing source makes undo/redo fail, explain how to drop that stack entry.
  Link paste/unpaste records to each created destination, including pasted
  directories, so deleting a pasted entry cannot leave its creator undoable.
- Preserve other windows showing a Direct listing when opening a file or
  navigating directories removes the source buffer.

### Added

- Add `:DirectHistory drop [undo|redo]` to remove one irrecoverable top step,
  with completion for the command and stack direction.

## [0.2.0] - 2026-11-11

### Fixed

- Avoid replacing the global `vim.fn.confirm` while applying LSP workspace edits.
- Refuse `p`, `P`, `:DirectPaste` without a directory, and `:DirectPasteAs` in
  a modified listing, preserving unsaved edits.
- Bound Git-ignore queries by `git.timeout_ms`; on timeout, keep the listing
  available without filtering, retry before save, and refuse edits to paths that
  would be hidden. Mark timed-out listings and let `gi` disable the filter
  without losing edits. Prune ignored/untracked subtrees during nested-repository
  discovery and cache unchanged snapshots.

### Added

- Add directory-targeted `:DirectGitStatus` and `:DirectGitDiff` commands; the
  latter can include staged, unstaged, and non-ignored untracked paths.
- Add `:DirectGitDiff` filtering for committed changes from a branch's merge
  base to `HEAD`, toggled in the current listing with `gd`.
- Add collapsed single-child directory chains, configurable buffer reuse and
  open placement, and support for Neovim 0.11.7.

### Changed

- Remove LuaRocks packaging; install the plugin through Git-based plugin
  managers or GitHub releases.

## [0.1.0] - 2026-11-09

Initial tagged release.

### Changed

- Replaced the conflicting `gc` / `gr` Git mappings with `<leader>gr` for
  confirmed worktree restore and `<leader>gu` for unstage.
- Git worktree restore names the path and affected tracked-file count before
  discarding changes.

### Included

- Edit directory listings to create, delete, rename, move, undo, and redo
  filesystem entries.
- Expand directories in place; combine root and expanded-tree changes in one
  save, with persistent JSONL history and recovery safeguards.
- Add asynchronous sync and cross-filesystem copy progress, Git status and
  actions, LSP file-operation notifications, trash management, and health
  diagnostics.
- Add per-action mappings, `<Plug>` actions, split/tab opens, user events, and
  a read-only filesystem history view.
