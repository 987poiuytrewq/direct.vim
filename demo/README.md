# Scripted demos

`demo.sh` records one continuous, repeatable terminal tour of Direct with
asciinema. The opening listing is a menu of three sections; the script enters
each section, demonstrates its workflow, and returns to the menu:

- `01-file-edits/` — rename, create, delete, and filesystem undo/redo.
- `02-browse-and-move/` — expand/collapse a folder and move a child to its parent.
- `03-copy-and-paste/` — copy a directory tree using `yy` and `p`.

The recording sends normal terminal keys for navigation and edits; `:w` is the
only Ex command it types. With the demo's `map_default_keys = true`, `u` and
`<C-r>` invoke filesystem undo and redo. Use `:undo` and `:redo` for listing text
history.

Each section uses a small fixture with action-oriented names such as
`rename-me.txt`, `delete-me.txt`, and `move-from/move-me.txt`. The file-edit
section also shows a hidden file and an expandable hidden folder. The tour uses a
disposable Git repository and isolated `XDG_DATA_HOME`; it does not touch the
user's files or Direct data. Both file and folder icons are enabled (a Nerd Font
is needed to render them), and Git status colors are enabled.

```sh
./demo/demo.sh
./demo/demo.sh --force
```

Recordings are written to `demo/casts/` by default. Set `CAST_DIR` to choose a
different directory. Existing recordings are never overwritten unless `--force`
is supplied. Recordings capture actual terminal input, so the asciinema player
can show its keystroke overlay. The tour only types safe names into its disposable
fixture. Run it headlessly and validate its filesystem result without asciinema
or Expect using:

```sh
./demo/demo.sh --check
```

The fixture and plugin data are removed after each run. `nvim` and Neovim 0.12+
and Git are required for `--check`; recording also requires asciinema and Expect.
