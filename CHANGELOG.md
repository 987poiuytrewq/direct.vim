# Changelog

Notable changes to direct.vim are documented here. Versions follow
[Semantic Versioning](https://semver.org/); release tags use the `v` prefix.

## [Unreleased]

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
