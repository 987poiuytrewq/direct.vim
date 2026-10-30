# direct.vim

Edit directories in Neovim.

Load a directory into a buffer with each root-level line corresponding to a file
or subdirectory. Edit those root rows to create, rename, or delete filesystem
entries. Directories can also be expanded for browsing and editing; their child
rows are materialized in the buffer and removed when collapsed.

- navigate around the filesystem easily
- rename, create and delete files and directories
- yank and paste files and directories
- full undo and redo history for every change that you make to the filesystem

## Filename highlights

Visible directories use the syntax group `DirectDirectory` (default link
`Directory`) at any indentation depth. Hidden directories and files retain
their prior `Comment` defaults. Listing files receive no custom filename,
filetype, or special-name highlights.

Highlight defaults are user-overridable and are reapplied after a `ColorScheme`
event.

## Requirements

- Neovim >= 0.12
- No Python: the plugin is pure Lua and needs nothing beyond the Neovim runtime.

Run `:checkhealth direct` to confirm the version and the data home in use.

## Development and coverage

The test suite uses Neovim's embedded Lua and has no runtime test dependencies:

```sh
make test
```

To install the optional coverage tooling locally, install LuaRocks (configured
for Lua 5.1, as used by Neovim's LuaJIT) and run:

```sh
make install
make coverage
make coverage-summary
```

`make install` checks for Neovim >= 0.12 and installs LuaCov and its summary
reporter into the ignored `.rocks/` directory. Coverage reports are written to
`coverage/index.html` and `coverage/summary.out`. Run `make coverage-summary`
after `make coverage` to wrap the package-generated plain-text summary in
`coverage/summary.md`; in GitHub Actions, it appends that report to the run
summary. The normal `make test` run does not need LuaRocks or LuaCov. CI runs
`make coverage` for each Neovim version, publishes each HTML report as a
downloadable artifact, and displays the coverage summary directly in the run
summary.

## Install

Install with your favourite package manager. For example, with
[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug '987poiuytrewq/direct.vim'
```

## Setup

`setup()` is optional; the defaults apply when you never call it.

```lua
require('direct').setup({
  map_default_keys = true, -- set false to install no default mappings
  show_folder_icons = false, -- opt in to Nerd Font folder icons
  show_file_icons = false, -- opt in to a generic Nerd Font file icon
  max_recursive_expand_depth = false, -- false means unlimited
})
```

It is idempotent, may be called more than once, and reports an unknown option
name as an error instead of silently ignoring it.

### File and folder icons

Set `show_folder_icons = true` to show inline directory glyphs, and
`show_file_icons = true` to show one generic icon for every file; both default
to `false`. A Nerd Font is required to render them. Collapsed directories use
`nf-md-folder` (U+F024B), expanded directories use `nf-md-folder_open` (U+F0770),
and files use `nf-md-file` (U+F0214), regardless of filetype. When only one kind
of icon is enabled, the other kind reserves a blank icon slot so entry names
stay aligned. Icons are virtual text, so the listing lines and filesystem
behavior are unchanged. No icon plugin or other dependency is required.

## Navigate

In normal mode, `-` lists the directory of the current file, or the working
directory when the buffer is not tied to one (a buffer with no file name, or a
non-empty `&buftype` such as a direct listing). You can also open a directory
with `:edit foo/` or by starting Neovim on it.

Once a directory is listed, `-` goes up to its parent directory and `<Enter>`
opens the entry under the cursor: a directory line opens a new listing, a file
line opens the file.

Use `zo` or `za` on a directory to expand it in place. Children are read lazily,
one level at a time; repeating an expansion does not re-read or duplicate them.
`zO` and `zA` recursively expand a directory, while `zC` recursively collapses
it. `zR` expands all root directories and `zM` collapses them all. Recursive
expansion is unlimited by default; set `max_recursive_expand_depth` to a positive
integer to cap how many directory levels those recursive-open commands expand.
The limit does not affect one-level `zo`/`za` browsing. `za` or `zc` on an
expanded directory removes its child rows; expanding again re-reads the
directory. The initial listing remains flat.

## Edit

When viewing a directory, edit its listing as if you were editing a file, using
any Vim command (`di`, `o`, `:s`, macros, and so on). Saving synchronises the
changes with the filesystem and then re-lists the directory.

At the root level, a save is classified as exactly one of *rename*, *create* or
*delete*:

- **Rename** — edit the line of the file or directory you want to rename, and
  save.
- **Create** — add new lines at any location, and save.
- **Delete** — delete the lines for the entries you want to remove, and save.
  Deleted entries are yanked automatically, so you can paste them back.

### The trailing-slash rule

A directory must always be written with a trailing slash, and a file must never
have one: the line, not the filesystem, decides what will be created or
renamed. Renaming `foo/` to `foo` therefore replaces the directory `foo` with a
file, and adding a line `bar` creates a file while `bar/` creates a directory.

At the root level, an edit that both adds and deletes entries, or that leaves a
duplicated line, is reported as ambiguous, naming both sides of the comparison.
Nothing is changed, no history is written, and the buffer stays modified so you
can fix it.

`&wildignore` is honoured using the value captured when each directory is
listed. Changing the option does not change an existing listing's sync rules;
re-list after changing it. Filtered entries are excluded from sync, and a sync
is refused before filesystem or history effects if an add/rename would use an
occupied filtered path or a directory move would carry a filtered descendant or
an entry the listing cannot represent, such as a dangling symlink or FIFO.
Directory-only patterns such as `cache/` also protect matching nested directories.
Directory symlinks are treated as leaves when renamed; their targets are not
scanned or moved.

### Expanded rows

Every expanded directory is an independent edit scope. Edit, add, or delete its
children just as you would at the root. Directory lines end in `/`; files do
not. Edits in multiple expanded directories are combined into one sync, and
deleted entries are auto-yanked before they are removed.

Indentation defines the tree: root rows have no leading spaces, direct children
have two, and each additional level adds two more. A child must be under a
directory. Change a row's indentation or move it beneath another expanded
directory to move it; the move keeps the entry and its contents. New rows may be
nested under a directory created in the same edit. Directory renames and moves
carry their contents and retain visible expansions when possible.

Before syncing an edited subtree, direct checks that its directory contents have
not changed on disk since expansion. Invalid indentation, missing parents,
duplicate destinations, lost identities, or a stale snapshot refuse the whole
sync before auto-yank, filesystem, or history effects. A whole-line replacement
whose identity is lost is treated as a rename only when sibling identities make
that pairing unambiguous; otherwise the save is refused. Root-level edits retain
the existing rename/create/delete classifier and its ambiguity rules.

Deleting a directory row removes and auto-yanks the whole tree, including
materialized descendants, unless you reindent surviving rows under another
directory in the same edit to move them out first. Moving or renaming a directory
together with separate edits to its descendants must be saved in separate syncs
when their filesystem action order would otherwise be ambiguous.

Expansion and collapse remain ordinary text-undo changes. `u` after a collapse
restores the child rows and their identities; `<C-r>` re-applies the collapse.
Redo restores materialized identities only when the original undo sequence and
exact directory snapshot still match. A changed or ambiguous snapshot remains
unsafe to save, open, or yank.
Entry names beginning with whitespace and names that could escape the listed
directory (such as `../x` or `a/b`) are refused at save time.

Windows-specific component checks reject backslashes, drive prefixes, and
reserved device names. Native Windows filesystem traversal has not been
verified; this documentation does not claim Windows support.

### Undo / Redo

In a direct buffer, `u` and `<C-r>` perform Neovim text undo and redo. The
filesystem action history is separate: use `:DirectUndo` and `:DirectRedo` to
reverse or re-apply actions a sync or paste performed; `:DirectUndo` right after
a paste, for example, undoes the paste.

Text undo only reverses buffer-line changes; it never renames, creates, deletes
or restores anything on disk. Only `:DirectUndo` reverses a filesystem action.

## Yank / Paste

`yy` and `Y` yank the file or directory on the current line, and a visual `y`
yanks the selected range. `p` and `P` paste the yanked entries into the current
directory. Directories are yanked recursively, so you can copy directory trees
around the filesystem.

If an entry with the same name already exists, you are prompted
(`File already exists. Paste as: `, or `Directory ...`) and can paste it under
another name; an empty answer skips that entry and leaves the original
untouched.

Yank and paste share the undo/redo history, so they can be undone like any other
filesystem change.

## Commands

| Command | Arguments | Description |
|---|---|---|
| `:DirectList {dir}` | `{dir}`, `dir` completion | List `{dir}` in a direct buffer. |
| `:DirectListBuffer` | none | List the directory of the current file, or the working directory when the buffer is not tied to one (no file name, or a non-empty `&buftype`). |
| `:DirectListCwd` | none | List the current working directory. |
| `:DirectSync` | none | Classify and apply the current direct buffer's edits; also runs on `:write` in a direct buffer. |
| `:DirectUndo` | none | Undo the last filesystem action. |
| `:DirectRedo` | none | Redo the last undone action. |
| `:DirectYank` | range (default: current line) | Yank the ranged entries. |
| `:DirectPaste [dir]` | optional `{dir}` (directory completion) | Paste into the current buffer's directory (no argument; re-lists it), or into `{dir}` without touching the current buffer. |
| `:DirectPasteAs {name}` | `{name}` | Paste into the current buffer's directory as `{name}`. |

`:DirectSync`, `:DirectUndo`, `:DirectRedo`, `:DirectYank`, `:DirectPaste` (no
argument), `:DirectPasteAs`, and the public `open()` API report an error and do
nothing when the current buffer is not a direct buffer. `open()` is also used by
the direct-buffer entry mappings. `:DirectPaste {dir}` is the exception: it
pastes into an explicitly named directory and never touches the current buffer,
so it needs no direct buffer. `:DirectList`, `:DirectListBuffer`,
`:DirectListCwd`, `list(path)`, `list_buffer()`, and `list_cwd()` are also
unrestricted because they target an explicit directory or derive one to list
instead of operating on the current buffer's listing.

## Mappings

Global (normal mode), installed when `map_default_keys` is true:

| Key | Action |
|---|---|
| `-` | `:DirectListBuffer` |

Buffer-local, in a direct buffer (standard actions follow `map_default_keys`;
`zo`/`za`/`zc` are always installed):

| Mode | Key | Action |
|---|---|---|
| normal | `<CR>` | open the entry under the cursor |
| normal | `zo` | lazily expand one directory level |
| normal | `za` | expand or collapse one directory |
| normal | `zc` | collapse one directory |
| normal | `-` | open `../` (the parent directory) |
| normal | `u` | Neovim text undo |
| normal | `<C-r>` | Neovim text redo |
| normal | `yy`, `Y` | `:DirectYank` (current line) |
| visual | `y` | `:DirectYank` (selected range) |
| normal | `p`, `P` | `:DirectPaste` |

The buffer-local `-` wins over the global `-` inside a direct buffer.
`zo`, `za`, and `zc` are installed for every direct listing, independently of
`map_default_keys`.

## Data directory

State has no cache and is resolved on every use:

1. `$XDG_DATA_HOME/direct` when `$XDG_DATA_HOME` is set and non-empty;
2. otherwise `$HOME/.local/share/direct`
   (falling back to Neovim's standard data directory, with a warning, when
   neither variable is set).

Run `:checkhealth direct` to print the resolved data home. Inside it:

- `history/` — `undo.log` and `redo.log`, the filesystem undo/redo history;
- `trash/` — removed entries, kept so an undo can restore them;
- `register/` — the most recent yank, and its content pointer.

### History format and safety

Undo and redo are stored as JSONL. Each stack begins with the exact header
`{"format":"direct-history","version":1}` followed by one canonical JSON
action record per line; paste and unpaste records store name lists as JSON
arrays. Before an operation reads the register or changes the filesystem, direct
validates its path inputs and classifies both history files from their raw
bytes. Invalid UTF-8, control characters, malformed JSON, or unknown history
formats are refused without changing the history, register, or filesystem.

Recognized legacy Lua v2/v3 logs and strictly framed Python-era tab logs are
reset to an empty current-format history with a warning. They are never replayed
or migrated, and no backup is created. Unknown, future, malformed, or unreadable
logs are instead preserved byte-for-byte; the triggering operation is refused.

History rewrites use an exclusive temporary file in the same directory, then
flush, close, and atomically rename it over the owned log. This protects each
single-file rewrite, but does not make the full pop → filesystem action → append
sequence transactional. A crash between those steps can leave history and disk
out of sync; there is no cross-operation journal or inter-process lock.

## Upgrading from the Python version

The Lua rewrite uses a new on-disk format and does **not** migrate the Python-era
data:

- **History** — recognized Python-era tab logs and recognized Lua v2/v3 logs are
  discarded and reset to empty JSONL history with a warning and no backup. They
  are never executed or migrated, so their undo history does not survive. Old
  space-framed Python logs and any unknown, malformed, or unreadable log are
  preserved byte-for-byte and block the triggering operation.
- **Register** — entries written by the Python version are still listed. Names
  containing spaces are supported by the JSONL format; names containing control
  characters or invalid UTF-8 are skipped with an error.
- **Trash** — Python-era trash entries are still read, so an entry removed
  before the upgrade can still be restored.
