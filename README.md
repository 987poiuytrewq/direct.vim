# direct.vim

**Edit your filesystem like a text buffer.**

direct.vim lists a directory in a Neovim buffer, one line per entry. Rename,
create, delete and move files with ordinary Vim editing, then `:write` to apply
the changes. Every filesystem change can be undone and redone.

Saving a listing starts a background sync and returns control to Neovim. The
listing stays modified until the filesystem changes and history are committed;
other direct operations are refused while the save is pending. Cross-filesystem
copies show a progress notification.

<img src="demo/tour.gif" width="600" alt="direct.vim demo: renaming, creating and deleting files by editing a listing, undoing on disk, opening files and folders, renaming with :s, copying a folder, and staging with Git">

- **Edit with Vim.** Use `cw`, `dd`, `o`, `:s`, macros or anything else, then `:w`.
- **Browse as a tree.** Expand directories in place with the usual fold keys
  (`zo`, `zc`, `zR`, …). To move an entry, change its indentation.
- **Undo filesystem changes.** `u` and `<C-r>` undo and redo saved renames,
  creates, deletes and pastes. With unsaved listing edits, they undo or redo
  buffer text instead. The filesystem history survives restarts.
- **Yank and paste files.** `yy` and `p` copy files and whole directory trees.
- **Git integration.** Status symbols and colours, a changed-files-only view,
  stage/reset/restore keys, and `.gitignore` filtering.
- **No dependencies.** Pure Lua and no Python. Icons work without an icon
  plugin, and use filetype icons when nvim-web-devicons is installed.

## How it compares

direct.vim is **not** a sidebar file tree, and it doesn't preview files. If
that's what you want, use [neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim)
or [nvim-tree](https://github.com/nvim-tree/nvim-tree.lua).

It's closest to [oil.nvim](https://github.com/stevearc/oil.nvim) and
[mini.files](https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-files.md):
all three turn a directory into a buffer you edit and save. The differences:

- **Trees you can edit.** direct.vim expands folders in place, and you can
  edit, move and re-indent entries across the whole tree in one save. oil.nvim
  shows one folder per buffer, and mini.files shows folders as columns.
- **Undo on disk.** `u` and `Ctrl-r` undo and redo renames, creates, deletes
  and pastes after they're saved, and the history survives restarts. The
  others can send deletions to a trash folder, but saved changes can't be
  undone.
- **Git built in.** Status symbols and colours, a changed-files-only view and
  staging keys, with no extra plugins. oil.nvim has third-party extensions for
  Git status.
- **No previews or remote files.** oil.nvim and mini.files preview files, and
  oil.nvim can browse SSH and S3. direct.vim does neither.

|  | direct.vim | oil.nvim | mini.files | neo-tree, nvim-tree | netrw |
|---|:---:|:---:|:---:|:---:|:---:|
| Change files by editing text | ✓ | ✓ | ✓ | — | — |
| Layout | Buffer, folders expand as a tree | Buffer, one folder | Floating columns | Sidebar tree | Buffer, list or tree |
| Edit across expanded folders | ✓ | — | — | — | — |
| Undo changes after saving | ✓ | — | — | — | — |
| Git status built in | ✓ | Via extensions | — | ✓ | — |
| LSP file operations | ✓ | ✓ | ✓ | Via a plugin | — |
| File preview | — | ✓ | ✓ | ✓ | ✓ |
| Sidebar | — | — | — | ✓ | ✓ |
| Remote filesystems | — | ✓ | — | — | ✓ |

Based on each project's documentation in November 2026; check their docs for
the latest.

## Requirements

- Neovim **0.12** or later, on Linux, macOS or Windows
- Git, for status and ignore filtering (optional)
- A [Nerd Font](https://www.nerdfonts.com/), for the default icons (optional;
  you can turn icons off or replace them)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons), for icons
  that match each file's type (optional; without it, files use one generic
  icon)

Run `:checkhealth direct` to check Neovim, Git, data-directory write access,
history recovery state, trash size and icon configuration.

## Installation

With Neovim's built-in `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/987poiuytrewq/direct.vim' })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), load it at startup so it
can take over directories opened from the command line (`nvim .`):

```lua
{ '987poiuytrewq/direct.vim', version = '*', lazy = false }
```

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug '987poiuytrewq/direct.vim'
```

`setup()` is optional, and direct.vim replaces netrw for directory buffers
automatically.

Releases are tagged with a `v` prefix; see [CHANGELOG.md](CHANGELOG.md) for
release notes. The LuaRocks package is named `direct-vim` and can be installed
with `:Rocks install direct-vim` after publication. The `lux.toml` manifest
includes the Lua modules and Neovim runtime directories. Maintainers can publish
a tagged version with Lux after configuring a LuaRocks API key; lazy.nvim users
can select tagged releases with `version = '*'`.

## Quick start

1. Open a directory: run `nvim .`, run `:edit some/dir/`, or press `-` in any
   file to list its directory.
2. Move around: `<Enter>` or a double-click opens the entry under the cursor,
   and `-` goes up to the parent directory.
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
- **A save can mix root renames, creates and deletes.** Direct pairs edited
  rows by their row identities, not by line position. The whole save is one
  undoable history entry when it mixes change types; deleted entries are
  yanked before removal.
- **A row's identity decides whether an edit is a rename.** Editing its name
  while the row mark survives is a rename. An unmarked row is a create, and a
  marked row that disappears is a delete. If a whole-line edit such as `cc` or
  `S` loses its mark, Direct treats it as delete-plus-create; the old entry is
  yanked and the new one is empty. If text undo/redo leaves an identity unclear,
  the save is refused and the listing must be reviewed or re-listed.
- **The root directory must still match its list-time snapshot.** A visible
  entry added, removed or replaced on disk since listing causes the save to be
  refused rather than guessing what the edit means.
- **Unclear edits change nothing.** If direct.vim can't tell what you meant, or
  the directory changed on disk since you listed it, the save is refused, the
  filesystem is left alone, and your edits stay in the buffer so you can fix
  them.

When a listing has unsaved edits, `u` / `<C-r>` (and `:DirectUndo` /
`:DirectRedo`) undo or redo buffer text only. Once the listing is clean, they
operate on the filesystem history, except that a local text undo's paired redo
stays text-only until the listing is refreshed. The default asks before
changing files outside the current listing; configure `undo_confirm` to change
that behavior.

## Key mappings

All mappings are buffer-local to direct listings, except the global `-`.

| Key              | Action                                              |
|------------------|-----------------------------------------------------|
| `-`              | List the current file's directory, or go to the parent |
| `z-`             | Go to the parent and expand the directory you left  |
| `<CR>`, double-click | Open the file or directory                      |
| `<C-s>` `<C-v>` `<C-t>` | Open in a horizontal split, vertical split, or tab |
| `zo` `zc` `za`   | Expand, collapse or toggle one directory            |
| `zO` `zC` `zA`   | The same, recursively                               |
| `zR` `zM`        | Expand or collapse everything                       |
| `]d` `[d`        | Next or previous directory row                      |
| `]f` `[f`        | Next or previous file row                           |
| `u` `<C-r>`      | Undo or redo the last filesystem change             |
| `yy` `Y`, visual `y` | Yank entries                                    |
| `p` `P`          | Paste into the directory under the cursor           |
| `gh`             | Show or hide dotfiles                               |
| `gi`             | Toggle `.gitignore` filtering                       |
| `gs`             | Toggle a view of changed files only                 |
| `]c` `[c`        | Next or previous changed entry                      |
| `ga` `<leader>gu` `<leader>gr` | Stage, unstage, or confirm restore of the entry |

With mouse support on (`:set mouse=a`), double-click an entry to open it, and
click a folder icon to expand or collapse that folder. Set `map_default_keys =
false` to disable default key bindings; explicit entries in `mappings` remain
active.

## Configuration

These are the defaults:

```lua
require('direct').setup({
  map_default_keys = true,           -- install the mappings above
  mappings = {                       -- per-action key override or false to disable
    expand = 'o',
    undo = '<leader>u',
    toggle_hidden = false,
  },
  show_hidden = true,                -- show dotfiles (toggle with `gh`)
  respect_gitignore = true,          -- hide Git-ignored entries (toggle with `gi`)
  indent_size = 2,                   -- spaces per tree level (integer > 1)
  undo_confirm = 'elsewhere',        -- true, false, or confirm only outside this listing
  trash_retention = false,           -- or { max_age_days = 30, max_size_bytes = 1e9 }
  directory_separator = package.config:sub(1, 1), -- '/' or '\\'
  max_recursive_expand_depth = false, -- limit for zO/zR; false = unlimited
  show_folder_icons = true,
  show_file_icons = true,
  show_filetype_icons = true,        -- bufferline-style filename icons via nvim-web-devicons
  icons = {
    file = '\u{f15b}',
    folder = '\u{f07b}',
    folder_open = '\u{f07c}',
    deleted_file = '\u{f016}',
    deleted_folder = '\u{f114}',
    deleted_folder_open = '\u{f115}',
  },
  git = {
    enabled = true,       -- show Git status when its background query completes
    timeout_ms = 1000,    -- background status-query deadline
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

Git status is read in the background so it doesn't delay the initial listing.
When the query completes, Direct adds the status decorations and deleted rows.
`git.timeout_ms` sets the deadline in milliseconds; a timed-out query leaves
the listing usable without status and reports one warning per repository.

You can call `setup()` more than once. Each call replaces the previous options,
and unknown or invalid options are reported as errors instead of being silently
ignored.

`mappings` accepts action names such as `open`, `undo`, `redo`, `yank`,
`paste`, `toggle_hidden`, `toggle_gitignore`, `git_add`, `next_change`,
`open_horizontal`, `open_vertical`, `open_tab`, `expand`, `collapse`, `toggle`,
and their recursive variants. A non-empty key string overrides that action's
default; `false` disables its physical default.
Every action also has a `<Plug>(direct-...)` mapping for composing your own
bindings. For example:

```lua
vim.keymap.set('n', '<leader>e', '<Plug>(direct-expand)', { remap = true })
```

The folder actions are also public Lua functions: `require('direct').expand()`,
`collapse()`, `toggle()`, `expand_recursive()`, `collapse_recursive()`, and
`toggle_recursive()`.

Pass a `split` option to open the selected entry in a new layout, leaving the
current listing in place: `require('direct').open({ split = 'horizontal' })`,
`require('direct').open({ split = 'vertical' })`, or
`require('direct').open({ split = 'tab' })`. The default bindings are `<C-s>`,
`<C-v>`, and `<C-t>`.

`undo_confirm` controls prompts before filesystem undo/redo: `true` always
prompts, `false` never prompts, and `'elsewhere'` (the default) prompts only if
the affected paths are outside the current listing's directory.

`trash_retention` is off by default. Set `max_age_days`, `max_size_bytes`, or
both to prune old, unreferenced trash entries; history-referenced entries are
kept unless explicitly forced through `:DirectTrash! empty`.

With `show_filetype_icons` enabled, file icons use bufferline.nvim's built-in
basename-based nvim-web-devicons lookup. The dependency is optional; Direct uses
`icons.file` when it is unavailable. Set the option to `false` to use the
generic glyph for every file.

### Highlights

Every highlight links to a standard group by default, so it follows your
colour scheme. To change one, use `vim.api.nvim_set_hl()`:

| Group                                       | Default link            |
|---------------------------------------------|-------------------------|
| `DirectDirectory`                           | `Directory`             |
| `DirectFileIcon`                             | `Normal`                |
| `DirectHiddenFolderIcon`, `DirectHiddenFileIcon` | `Comment`           |
| `DirectGitDeletedFile`, `DirectGitDeletedDirectory` | `ErrorMsg`      |
| `DirectGit*` status groups                  | `Added`, `Changed`, `Removed`, `ErrorMsg`, `Comment` |

Visible file icons use `DirectFileIcon`; hidden file icons retain
`DirectHiddenFileIcon`. nvim-web-devicons supplies file glyphs, but its
highlight groups do not override Direct's groups. Git status still colours the
file names and folder icons.

`:help direct.vim` lists every group.

## Git

In a Git repository, each row shows its status on the right, and the names of
changed entries are coloured to match. Directories show the combined status of
their contents, and deleted tracked files appear as protected rows so you can
restore them.

- `gs` shows only changed entries, with directories fully expanded.
- `]c` / `[c` jump between changed entries.
- `ga` stages the entry; `<leader>gu` unstages it.
- `<leader>gr` asks before discarding tracked worktree changes under the entry.
  The prompt names the path and counts changed files. It leaves untracked and
  staged-only changes alone.
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

## Events for plugins

direct.vim emits Neovim `User` autocmds after a listing, before and after a
filesystem sync, and after filesystem undo, redo, and paste. Event callbacks
receive a `data` table with an absolute `root` and an `actions` array. For
example:

```lua
vim.api.nvim_create_autocmd('User', {
  pattern = 'DirectSyncPost',
  callback = function(event)
    if event.data.success then
      print('Synced', event.data.root, #event.data.actions, 'actions')
    end
  end,
})
```

Supported patterns are `DirectListPost`, `DirectSyncPre`, `DirectSyncPost`,
`DirectUndoPost`, `DirectRedoPost`, and `DirectPastePost`. `DirectListPost` has
an empty `actions` array. Sync post data also includes `applied`, `failed`,
`yanks`, `success`, and `error`; paste post includes `changed`, `entry`,
`success`, and `error`. Undo/redo post actions describe the reversal. Action
records use the same `name`, `src`, `dst`, and nested `actions` fields as the
Direct history model. Event data is copied before dispatch, so changing it in a
callback does not modify Direct's operation. Keep `DirectSyncPre` handlers
read-only; if one edits the listing, that sync is safely refused and must be
reviewed and saved again.

## Commands

direct.vim notifications are prefixed with `direct:` so they can be
distinguished from messages from Neovim and other plugins.

| Command                    | Description                                           |
|----------------------------|-------------------------------------------------------|
| `:DirectList[!] {dir}`     | List a directory; `!` discards its unsaved listing edits |
| `:DirectListBuffer[!]`     | List the current file's directory; `!` discards its unsaved listing edits |
| `:DirectListCwd[!]`        | List the working directory; `!` discards its unsaved listing edits |
| `:DirectSync`              | Apply edits (same as `:write`)                        |
| `:DirectUndo` / `:DirectRedo` | Undo/redo filesystem changes, or text while modified |
| `:DirectHistory`           | Show the undo and redo stacks in a read-only view     |
| `:DirectHistoryReset`      | Back up and reset both history stacks                 |
| `:DirectTrash`             | List, restore, or empty trashed entries               |
| `:DirectYank`              | Yank the entries in a range                           |
| `:DirectPaste [dir]`       | Paste here, or into `{dir}`                           |
| `:DirectPasteAs {name}`    | Paste under a new name                                |
| `:DirectFoldAll` / `:DirectUnfoldAll` | Collapse or expand everything              |
| `:DirectToggleHidden`      | Show or hide dotfiles                                 |
| `:DirectToggleGitIgnore`   | Toggle `.gitignore` filtering                         |
| `:DirectToggleGitStatus` / `:DirectGitStatus` | Toggle, or enter, the changed-only view |
| `:DirectNextFile` / `:DirectPreviousFile` | Jump between files, skipping directories |
| `:DirectNextChange` / `:DirectPreviousChange` | Jump between changed entries       |
| `:DirectRun {cmd}` / `:DirectGit {cmd}` | Run a command on the current entry       |

`:DirectTrash` opens a read-only list. Use `:DirectTrash restore {id}` to
restore an entry (or add a destination for old entries without metadata), and
`:DirectTrash empty` to remove unreferenced entries. Prefix the command with
`!` only to override history protection; an existing restore destination is
never overwritten.

`:DirectHistory` shows both filesystem history stacks newest first, with each
action's summary and affected paths. It is a read-only snapshot: it does not
recover an unfinished transaction, initialize missing logs, or rewrite damaged
history. The current buffer remains loaded when the view replaces it.

Relisting a directory with unsaved edits is refused so the listing is not
silently overwritten. Opening a file from a modified listing is also refused;
opening a directory keeps the original listing available. Sync the edits, or
use the command's `!` form to deliberately discard edits in the listing being
refreshed.

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
- Damaged or unknown history is preserved and blocks filesystem operations.
  `:DirectHistoryReset` first backs up readable history files before resetting.
- Neovim instances on the same machine share a lock, so they don't change the
  filesystem or the history at the same time.

The lock file is stored at `<data>/direct/.direct-history.lock`. Do not run an
older direct.vim version at the same time as this version: older versions use
`<data>/.direct-history.lock`, so the two versions would not coordinate with
each other. The old lock file is left untouched and is harmless once no older
version is running.

Other programs don't use the lock, and network filesystems are not guaranteed
to work. `:help direct.vim-data` explains exactly what is guaranteed.

## Documentation

This README is an overview. The full reference is in Neovim:

```vim
:help direct.vim
```

It covers every command, option, mapping and highlight group, the Lua API, the
sync and ambiguity rules, the data directory layout, and how to upgrade from the old
Python version.

## Development

On macOS, install the prerequisites with [Homebrew](https://brew.sh/):

```sh
brew install neovim git                    # tests and coverage
brew install asciinema agg expect          # demo recording
brew install --cask font-jetbrains-mono-nerd-font
```

The font is only needed for the demo GIF, which renders the file icons with
it.

The tests run in Neovim's embedded Lua and need only Neovim 0.12 or later:

```sh
make test
```

For coverage, `make coverage` fetches [LuaCov](https://github.com/lunarmodules/luacov)
with Git into the ignored `.rocks/` directory, then runs the suite with it:

```sh
make coverage          # writes coverage/index.html and coverage/summary.out
make coverage-summary  # writes coverage/summary.md
```

CI runs the suite with coverage on Linux, macOS and Windows against Neovim
0.12.0, and checks the demo tour, on every pull request.

### Demo recording

`make demo` records a scripted tour of direct.vim with
[asciinema](https://asciinema.org/) and converts it to `demo/tour.gif` with
[agg](https://github.com/asciinema/agg). The tour uses a throwaway Git
repository and data directory. `make demo-check` plays the same tour without
recording it and checks the result. See [`demo/README.md`](demo/README.md) for details.

## License

[MIT](LICENSE) © Duncan Williams
