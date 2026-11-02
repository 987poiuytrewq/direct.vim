# direct.vim

Edit your filesystem with ordinary Neovim commands. Direct shows a directory as
a text listing: change the names, save, and Direct applies your edits.

## Install

Requires Neovim 0.12+. The core plugin has no dependencies; Git is needed for
Git status and Git-ignore features.

With Neovim's built-in `vim.pack`:

```lua
vim.pack.add({ 'https://github.com/987poiuytrewq/direct.vim' })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), load Direct at startup so
it can handle directories opened from the command line:

```lua
return {
  { '987poiuytrewq/direct.vim', lazy = false },
}
```

## Quick start

Open a directory with `nvim .` or `:DirectList path/to/directory`.

Default keys:

- `<Enter>` opens the file or directory under the cursor.
- `-` goes to the parent directory.
- `zo` expands a directory in place.
- `gh` shows or hides dotfiles.

Edit the listing like any other buffer:

| To… | Edit the listing |
|---|---|
| Rename | Change an existing name, e.g. `old.txt` to `new.txt` |
| Create | Add a line, e.g. `notes.md` or `reports/2026/summary.md` |
| Delete | Remove the line |

Save with `:write` to apply your change. Directory names must end in `/` (such
as `archive/`); file names must not. At the root level, save one kind of change
at a time—create, rename, or delete. A new relative path may contain `/`; Direct
creates missing parent directories. Absolute paths, empty path components, and
`.` or `..` components are refused; the final `/` remains the directory marker.
After saving a nested path, Direct expands its parent directories and moves the
cursor to the last added entry. If Direct can't tell what you meant, it refuses
the save and leaves the filesystem unchanged.

`yy` yanks the entry under the cursor and `p` pastes it.

**Undo keys are different in Direct:** `u` undoes the last filesystem operation
and `<C-r>` redoes it. Use `:undo` and `:redo` for text changes in the listing.

## Configuration

Calling `setup()` is optional. These are all supported options and defaults:

| Option | Default | Description |
|---|---|---|
| `map_default_keys` | `true` | Install Direct's default key mappings. |
| `show_hidden` | `true` | Show dotfiles; `gh` toggles visibility in a listing. |
| `respect_gitignore` | `false` | Apply Git ignore rules to listings; tracked files remain visible. |
| `show_folder_icons` | `false` | Show folder icons. |
| `show_file_icons` | `false` | Show generic file icons. |
| `icons.file` | U+F0214 | File glyph string. |
| `icons.folder` | U+F024B | Collapsed-folder glyph string. |
| `icons.folder_open` | U+F0770 | Expanded-folder glyph string. |
| `max_recursive_expand_depth` | `false` | Positive integer limit for recursive expansion; `false` is unlimited. |
| `git.enabled` | `true` | Show Git status in repositories. |
| `git.display` | `'both'` | Status display: `'icon'`, `'text'`, or `'both'`. |
| `git.statuses` | Four default styles | Configure status highlights, icons, and optional gutter symbols. |

Folder and file icons are enabled independently with `show_folder_icons` and
`show_file_icons`. Built-in glyphs require a Nerd Font; set `icons.file`,
`icons.folder`, and `icons.folder_open` to use your own glyphs. Git status icon
overrides in `git.statuses` take precedence over these base glyphs. `git.enabled`
controls status display; it does not control `respect_gitignore`.

The groups below can be customized in your colorscheme or with
`vim.api.nvim_set_hl()`. Direct's default links are reapplied after a colorscheme
change, without overriding user-defined groups.

For example, change the folder-icon color with:

```lua
vim.api.nvim_set_hl(0, 'DirectFolderIcon', { fg = '#e0af68' })
```

| Highlight group(s) | Applies to | Default link |
|---|---|---|
| `DirectDirectory` | Visible directory names | `Directory` |
| `DirectHiddenDirectory`, `DirectHiddenFile` | Hidden names | `Comment` |
| `DirectFolderIcon` | Visible folder icons | `Directory` |
| `DirectFileIcon` | File icons | `Normal` |
| `DirectHiddenFolderIcon`, `DirectHiddenFileIcon` | Hidden-entry icons | `Comment` |
| `DirectGitAddedIcon`, `DirectGitAdded` | Added status icon and name | `DiffAdd` |
| `DirectGitModifiedIcon`, `DirectGitModified` | Modified status icon and name | `DiffChange` |
| `DirectGitRenamedIcon`, `DirectGitRenamed` | Renamed status icon and name | `DiffChange` |
| `DirectGitConflictedIcon`, `DirectGitConflicted` | Conflicted status icon and name | `ErrorMsg` |

<details>
<summary>Git status styling options</summary>

`git.statuses` supports these status keys and default highlight groups:

| Status | `icon_hl` | `text_hl` | Default link |
|---|---|---|---|
| `added` | `DirectGitAddedIcon` | `DirectGitAdded` | `DiffAdd` |
| `modified` | `DirectGitModifiedIcon` | `DirectGitModified` | `DiffChange` |
| `renamed` | `DirectGitRenamedIcon` | `DirectGitRenamed` | `DiffChange` |
| `conflicted` | `DirectGitConflictedIcon` | `DirectGitConflicted` | `ErrorMsg` |

Each status also accepts `icon` (a glyph string or a table with `file`,
`folder`, and `folder_open` glyphs; unspecified variants keep their defaults)
and `gutter` (off by default, or `{ symbol = 'A', highlight = 'Group' }`). Set
`gutter = false` to disable a configured gutter.

</details>

```lua
require('direct').setup({
  show_hidden = false,
  respect_gitignore = true,
  show_folder_icons = true,
  show_file_icons = true,
  icons = { file = '·', folder = '▸', folder_open = '▾' },
  git = {
    display = 'text',
    statuses = {
      added = { text_hl = 'MyGitAdded' },
    },
  },
})
```

## More help

Run `:help direct.vim` inside Neovim for the complete key and command reference,
nested editing, configuration, safety details, and data/history behavior. Run
`:checkhealth direct` to check the Neovim version and data directory.

Upgrading from the Python version? Its undo/redo history does not migrate; see
the upgrade notes in `:help direct.vim` before upgrading.

## Development

Run the test suite with `make test`. Optional coverage tooling is documented by
`make coverage` in the `Makefile`. Contributions are welcome; please run the
tests before submitting a change.
