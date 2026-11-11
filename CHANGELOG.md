# Changelog

Notable changes to direct.vim are documented here. Versions follow
[Semantic Versioning](https://semver.org/); release tags use the `v` prefix.

## [Unreleased]

### Fixed

- Bound Git-ignore queries by `git.timeout_ms`; on timeout, keep the listing
  available without filtering and refuse unsafe saves. Prune ignored/untracked
  subtrees during nested-repository discovery and cache unchanged snapshots.
- Refuse `p`, `P`, `:DirectPaste` without a directory, and `:DirectPasteAs` in
  a listing with unsaved edits, rather than pasting to disk and refreshing away
  those edits.

### Added

- Add directory-targeted `:DirectGitStatus` and `:DirectGitDiff` commands; the
  latter can include staged, unstaged, and non-ignored untracked paths.
- Add `:DirectGitDiff` filtering for committed changes from a branch's merge
  base to `HEAD`, toggled in the current listing with `gd`.

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
