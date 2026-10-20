# direct.vim

Edit directories in Neovim.

Load a directory into a buffer with each root-level line corresponding to a file
or subdirectory. Edit those root rows to create, rename, or delete filesystem
entries. Directories can also be unfolded for browsing; their child rows are
display-only in Phase 1.

- navigate around the filesystem easily
- rename, create and delete files and directories
- yank and paste files and directories
- full undo and redo history for every change that you make to the filesystem

## Filename highlights

Listing files receive user-overridable `DirectLang<Name>` highlight groups for
the supported programming languages in GitHub Innovation Graph's 2026Q1
programming-only top 20. The list is a static snapshot, ranked by `num_pushers`
summed across economies; because some economy data is suppressed, this method
is a lower bound, not a complete measure. No data is fetched at runtime.
PLpgSQL is omitted because Neovim has no dedicated filetype for it.

Exact, case-sensitive matches for `Makefile`, `GNUmakefile`, `CMakeLists.txt`,
`Rakefile`, `justfile`, `Dockerfile`, `Containerfile`, `Jenkinsfile`,
`Vagrantfile`, `README.md`, `LICENSE`, `CODEOWNERS`, and `Gemfile` use
`DirectSpecialFile` instead. This is a bounded conventional filename list, not a
frequency ranking. These matches take precedence over language detection.
Directories and dotfiles are not highlighted by these groups; existing hidden
entry styling remains unchanged. Detection uses Neovim's filename-only filetype
matching and reads no file contents.

By default `DirectSpecialFile` links to `Special` and language groups link to
`Type`. Define any of these groups yourself
before listing to override its default link. There is no built-in palette or
color configuration.

Sources: [Innovation Graph language data](https://raw.githubusercontent.com/github/innovationgraph/main/data/languages.csv)
and its [datasheet](https://github.com/github/innovationgraph/blob/main/docs/datasheet.md).

## Requirements

- Neovim >= 0.12
- No Python: the plugin is pure Lua and needs nothing beyond the Neovim runtime.

Run `:checkhealth direct` to confirm the version and the data home in use.

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
})
```

It is idempotent, may be called more than once, and reports an unknown option
name as an error instead of silently ignoring it.

## Navigate

In normal mode, `-` lists the directory of the current file, or the working
directory when the buffer is not tied to one (a buffer with no file name, or a
non-empty `&buftype` such as a direct listing). You can also open a directory
with `:edit foo/` or by starting Neovim on it.

Once a directory is listed, `-` goes up to its parent directory and `<Enter>`
opens the entry under the cursor: a directory line opens a new listing, a file
line opens the file.

Use `zo` or `za` on a directory to unfold it in place. Children are read lazily,
one level at a time; repeating an unfold does not re-read or duplicate them, and
collapsing only hides the already-loaded rows. The initial listing remains flat.
This is available in every direct listing and has no configuration toggle.

## Edit

When viewing a directory, edit its root listing as if you were editing a file,
using any Vim command (`di`, `o`, `:s`, macros, and so on). Saving synchronises
root-level changes with the filesystem and then re-lists the directory.

A save is classified as exactly one of *rename*, *create* or *delete*:

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

An edit that both adds and deletes entries, or that leaves a duplicated line,
is reported as ambiguous, naming both sides of the comparison. Nothing is
changed, no history is written, and the buffer stays modified so you can fix it.

`&wildignore` is honoured: entries matching one of its patterns are not listed
and are left untouched.

### Unfolded rows (Phase 1)

Only depth-zero/root rows participate in the legacy positional create/delete/
rename classifier. Unfolded child rows are display-only: editing, adding,
deleting, duplicating, or losing a child's identity refuses the whole save
before classifier actions, filesystem changes, auto-yank, register, or history
effects. Keep child rows exactly as materialized. Directory indentation is
presentation only; `>>` and `<<` do not enable move synchronization.

Unfolding has its own text-undo block. `:undo` removes the latest materialized
child rows without undoing an unrelated earlier root edit; the next save
synchronizes the surviving root rows.

A root file rename or other root-file change remains available while its child
rows are unfolded. A root directory with loaded descendants cannot be renamed
or deleted in that buffer; collapsing is visual only. Close/wipe and reopen the
parent listing to start without those loaded descendants. Phase 1 does not ship
child moves, subtree indentation mapping, or history recovery for tree edits.
Root names beginning with whitespace and names that could escape the listed
directory (such as `../x` or `a/b`) are refused at save time.

Windows-specific component checks reject backslashes, drive prefixes, and
reserved device names. Native Windows filesystem traversal has not been
verified; this documentation does not claim Windows support.

### Undo / Redo

In a direct buffer, `u` and `<C-r>` are mapped to `:DirectUndo` and
`:DirectRedo`, so the keys you would use for text undo perform the
*filesystem* undo/redo instead. That history records the actions a sync, paste,
undo or redo performed and reverses or re-applies them; `:DirectUndo` right
after a paste, for example, undoes the paste.

The filesystem undo is separate from Neovim's text undo. `:undo` (or any other
text-undo command) only reverses changes to the buffer's lines: it never
renames, creates, deletes or restores anything on disk. Only `:DirectUndo`
reverses a filesystem action.

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
`zo`/`za` are always installed):

| Mode | Key | Action |
|---|---|---|
| normal | `<CR>` | open the entry under the cursor |
| normal | `zo` | lazily unfold one directory level |
| normal | `za` | lazily unfold or visually collapse one directory |
| normal | `-` | open `../` (the parent directory) |
| normal | `u` | `:DirectUndo` |
| normal | `<C-r>` | `:DirectRedo` |
| normal | `yy`, `Y` | `:DirectYank` (current line) |
| visual | `y` | `:DirectYank` (selected range) |
| normal | `p`, `P` | `:DirectPaste` |

The buffer-local `-` wins over the global `-` inside a direct buffer.
`zo` and `za` are installed for every direct listing, independently of
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

## Upgrading from the Python version

The Lua rewrite uses a new on-disk format and does **not** carry the Python-era
data over:

- **History** — the Lua logs are version-tagged, and a log without the tag is
  never executed: it is renamed aside to `<name>.legacy` (or
  `<name>.legacy.<n>` if that name is already taken) and a warning
  (`Ignoring history written by an older version`) is shown. **Undo history
  does not survive the upgrade.**
- **Register** — entries written by the Python version are still listed, but a
  name the Lua version cannot round-trip (a space, a tab or another control
  character) is skipped with an error.
- **Trash** — Python-era trash entries are still read, so an entry removed
  before the upgrade can still be restored.
