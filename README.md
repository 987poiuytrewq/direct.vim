# direct.vim

**Edit your filesystem like a text buffer.**

direct.vim lists a directory in a Neovim buffer, one line per entry. Rename,
create, delete and move files with ordinary Vim editing, then `:write` to apply
the changes. Every filesystem change can be undone and redone.

```
src/
  components/
    button.lua
    input.lua
  init.lua
docs/
README.md
```

- **Edit with Vim.** Use `cw`, `dd`, `o`, `:s`, macros or anything else, then `:w`.
- **Browse as a tree.** Expand directories in place with the usual fold keys
  (`zo`, `zc`, `zR`, …). To move an entry, change its indentation.
- **Undo filesystem changes.** `u` and `<C-r>` undo and redo renames, creates,
  deletes and pastes. The history is kept on disk, so it survives restarts.
- **Yank and paste files.** `yy` and `p` copy files and whole directory trees.
- **Git integration.** Status symbols and colours, a changed-files-only view,
  stage/reset/restore keys, and `.gitignore` filtering.
- **No dependencies.** Pure Lua, no Python, and no icon plugin required.

## Requirements

- Neovim **0.12** or later
- Git, for status and ignore filtering (optional)
- A [Nerd Font](https://www.nerdfonts.com/), for the default icons (optional;
  you can turn icons off or replace them)

Run `:checkhealth direct` to check your setup.

## Installation

With Neovim's built-in `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/987poiuytrewq/direct.vim' })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), load it at startup so it
can take over directories opened from the command line (`nvim .`):

```lua
{ '987poiuytrewq/direct.vim', lazy = false }
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug '987poiuytrewq/direct.vim'
```

`setup()` is optional, and direct.vim replaces netrw for directory buffers
automatically.

## Quick start

1. Open a directory: run `nvim .`, run `:edit some/dir/`, or press `-` in any
   file to list its directory.
2. Move around: `<Enter>` opens the entry under the cursor and `-` goes up to
   the parent directory.
3. Edit the listing, then `:w`:

| To…    | Do this                                                     |
|--------|-------------------------------------------------------------|
| Rename | Change a name, e.g. `old.txt` → `new.txt`                   |
| Create | Add a line, e.g. `notes.md` or `reports/2026/summary.md`    |
| Delete | Delete the line (the entry is yanked, so `p` puts it back)  |
| Move   | Re-indent the line under another expanded directory         |

4. Changed your mind? Press `u` to undo the filesystem change.

### Rules for edits

- **Directories end with a separator, files don't.** `archive/` is a directory
  and `archive` is a file. On Windows the separator is `\`; you can change it
  with the `directory_separator` option.
- **Make one kind of change per save at the root level.** A single `:w` can
  rename, create or delete, but not mix them. Changes inside expanded
  directories are more flexible.
- **Unclear edits change nothing.** If direct.vim can't tell what you meant, or
  the directory changed on disk since you listed it, the save is refused, the
  filesystem is left alone, and your edits stay in the buffer so you can fix
  them.

`u` / `<C-r>` undo filesystem changes. Use `:undo` / `:redo` to undo only text
changes in the listing.

## Key mappings

All mappings are buffer-local to direct listings, except the global `-`.

| Key              | Action                                              |
|------------------|-----------------------------------------------------|
| `-`              | List the current file's directory, or go to the parent |
| `z-`             | Go to the parent and expand the directory you left  |
| `<CR>`, double-click | Open the file or directory                      |
| `zo` `zc` `za`   | Expand, collapse or toggle one directory            |
| `zO` `zC` `zA`   | The same, recursively                               |
| `zR` `zM`        | Expand or collapse everything                       |
| `]d` `[d`        | Next or previous directory row                      |
| `u` `<C-r>`      | Undo or redo the last filesystem change             |
| `yy` `Y`, visual `y` | Yank entries                                    |
| `p` `P`          | Paste into the directory under the cursor           |
| `gh`             | Show or hide dotfiles                               |
| `gi`             | Toggle `.gitignore` filtering                       |
| `gs`             | Toggle a view of changed files only                 |
| `]c` `[c`        | Next or previous changed entry                      |
| `ga` `gr` `gc`   | `git add`, `git reset` or `git checkout` the entry  |

With mouse support on (`:set mouse=a`), click a folder icon to expand or
collapse it. To turn off every default mapping, set
`map_default_keys = false`.

## Configuration

These are the defaults:

```lua
require('direct').setup({
  map_default_keys = true,           -- install the mappings above
  show_hidden = true,                -- show dotfiles (toggle with `gh`)
  respect_gitignore = true,          -- hide Git-ignored entries (toggle with `gi`)
  indent_size = 2,                   -- spaces per tree level (integer > 1)
  directory_separator = package.config:sub(1, 1), -- '/' or '\\'
  max_recursive_expand_depth = false, -- limit for zO/zR; false = unlimited
  show_folder_icons = true,
  show_file_icons = true,
  icons = {
    file = '\u{f15b}',
    folder = '\u{f07b}',
    folder_open = '\u{f07c}',
    deleted_file = '\u{f016}',
    deleted_folder = '\u{f114}',
    deleted_folder_open = '\u{f115}',
  },
  git = {
    enabled = true,       -- read `git status` for each listing
    show_symbols = true,  -- right-aligned status symbols
    show_deleted = true,  -- show rows for deleted tracked files
    symbols = {           -- one display cell each, or '' to hide
      added = '\u{f067}',
      deleted = '\u{f068}',
      modified = '\u{f01f}',
      renamed = '\u{f061}',
      ignored = '\u{f070}',
      staged = '\u{f00c}',
      conflict = '\u{f00d}',
    },
  },
})
```

You can call `setup()` more than once. Each call replaces the previous options,
and unknown or invalid options are reported as errors instead of being silently
ignored.

### Highlights

Every highlight links to a standard group by default, so it follows your
colour scheme. To change one, use `vim.api.nvim_set_hl()`:

| Group                                       | Default link            |
|---------------------------------------------|-------------------------|
| `DirectDirectory`                           | `Directory`             |
| `DirectHiddenFolderIcon`, `DirectHiddenFileIcon` | `Comment`          |
| `DirectGitDeletedFile`, `DirectGitDeletedDirectory` | `ErrorMsg`      |
| `DirectGit*` status groups                  | `DiffAdd`, `DiffChange`, `DiffDelete`, `ErrorMsg`, `Comment` |

`:help direct.vim` lists every group.

## Git

In a Git repository, each row shows its status on the right, and the names of
changed entries are coloured to match. Directories show the combined status of
their contents, and deleted tracked files appear as protected rows so you can
restore them.

- `gs` shows only changed entries, with directories fully expanded.
- `]c` / `[c` jump between changed entries.
- `ga` / `gr` / `gc` stage, unstage or restore the entry under the cursor.
- `gi` toggles ignore filtering. Filtering uses Git itself, so nested
  `.gitignore` files, `.git/info/exclude` and your global excludes file all
  apply. Tracked files are never hidden.

### Run commands on entries

`:DirectRun {cmd}` runs a shell command asynchronously from the listing's
directory. Each `{}` in the command is replaced with the escaped path of the
entry under the cursor:

```vim
:DirectRun wc -l {}
:DirectGit git log --oneline -5 -- {}
```

`:DirectGit` works the same way and also refreshes the Git status in the listing
when the command finishes.

## LSP integration

Renames, creates and deletes are reported to language servers that support
`workspace/*Files` file operations. For a rename, servers are asked first
through `willRenameFiles`, so they can update imports before the file moves.

## Commands

| Command                    | Description                                           |
|----------------------------|-------------------------------------------------------|
| `:DirectList {dir}`        | List a directory                                      |
| `:DirectListBuffer`        | List the current file's directory                     |
| `:DirectListCwd`           | List the working directory                            |
| `:DirectSync`              | Apply edits (same as `:write`)                        |
| `:DirectUndo` / `:DirectRedo` | Undo or redo a filesystem change                   |
| `:DirectYank`              | Yank the entries in a range                           |
| `:DirectPaste [dir]`       | Paste here, or into `{dir}`                           |
| `:DirectPasteAs {name}`    | Paste under a new name                                |
| `:DirectFoldAll` / `:DirectUnfoldAll` | Collapse or expand everything              |
| `:DirectToggleHidden`      | Show or hide dotfiles                                 |
| `:DirectToggleGitIgnore`   | Toggle `.gitignore` filtering                         |
| `:DirectToggleGitStatus` / `:DirectGitStatus` | Toggle, or enter, the changed-only view |
| `:DirectNextChange` / `:DirectPreviousChange` | Jump between changed entries       |
| `:DirectRun {cmd}` / `:DirectGit {cmd}` | Run a command on the current entry       |

## How safe is it?

direct.vim is built so that a mistake can be undone:

- Deleted entries go to a trash directory, and undo restores them from there.
- Files are created, moved and renamed with no-replace operations, so an
  existing file is never silently overwritten.
- A save is checked against the filesystem before anything is changed. If the
  directory has changed since it was listed, the save is refused.
- Undo history is stored on disk under `$XDG_DATA_HOME/direct` (or
  `~/.local/share/direct`) and journaled, so an interrupted operation can be
  finished or reported after a crash.
- Neovim instances on the same machine share a lock, so they don't change the
  filesystem or the history at the same time.

Other programs don't use the lock, and network filesystems are not guaranteed
to work. Windows paths are handled, but native Windows support has not been
verified. `:help direct.vim-data` explains exactly what is guaranteed.

## Documentation

This README is an overview. The full reference is in Neovim:

```vim
:help direct.vim
```

It covers every command, option, mapping and highlight group, the Lua API, the
sync and ambiguity rules, the data directory layout, and how to upgrade from the old
Python version.

## Development

The tests run in Neovim's embedded Lua and have no other dependencies:

```sh
make test
```

For coverage, install [LuaRocks](https://luarocks.org/) for Lua 5.1, then run:

```sh
make install          # installs LuaCov into ./.rocks
make coverage         # writes coverage/index.html
make coverage-summary # writes coverage/summary.md
```

CI runs the suite on Linux, macOS and Windows against Neovim 0.12.0 and the
latest stable release on every pull request.

### Demo recording

`./demo/demo.sh` records a scripted tour of direct.vim with
[asciinema](https://asciinema.org/), using a throwaway Git repository and data
directory. `./demo/demo.sh --check` runs the same tour headlessly and checks
the result. See [`demo/README.md`](demo/README.md) for details.

## License

[MIT](LICENSE) © Duncan Williams
