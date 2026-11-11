# Changelog

Notable changes to direct.vim are documented here. Versions follow
[Semantic Versioning](https://semver.org/); release tags use the `v` prefix.

## [Unreleased]

### Fixed

- Allow saves to proceed after unrelated external additions/removals while
  preserving conflicts on edited sources and requested destinations.

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
