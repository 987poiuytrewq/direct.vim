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
{ '987poiuytrewq/direct.vim', lazy = false }
```

## Quick start

Open a directory with `nvim .` or `:DirectList path/to/directory`.

Default keys (`map_default_keys = true`):

- `<Enter>` opens the file or directory under the cursor.
- `-` goes to the parent directory.
- `zo` expands a directory in place.
- `gh` shows or hides dotfiles.

Edit the listing like any other buffer:

| To… | Edit the listing |
|---|---|
| Rename | Change an existing name, e.g. `old.txt` to `new.txt` |
| Create | Add a line, e.g. `notes.md` |
| Delete | Remove the line |

Save with `:write` to apply your change. Directory names must end in `/` (such
as `archive/`); file names must not. At the root level, keep each save to one
kind of change—create, rename, or delete. Ambiguous edits are refused without
changing the filesystem.

`yy` yanks the entry under the cursor and `p` pastes it. Press `u` to undo the
last filesystem operation or `<C-r>` to redo it. Use `:undo` and `:redo` for
text changes in the listing.

## Optional setup

You can use Direct without calling `setup()`. For example, to hide dotfiles by
default and filter Git-ignored entries:

```lua
require('direct').setup({
  show_hidden = false,
  respect_gitignore = true,
})
```

Dotfiles are shown by default; `gh` toggles their visibility. Git-ignore
filtering is off by default. Folder and file icons are also available and
require a Nerd Font.

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
