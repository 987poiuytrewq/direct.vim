# Scripted demo

`demo.sh` records a one-minute tour of direct.vim with asciinema, for the top
of the project README.

## The tour

The tour works on a small Neovim plugin project, `~/my-plugin`. It's a Git
repository with a couple of changed files, so Git status shows from the first
frame, and its `build/` and `debug.log` are ignored and so hidden.

It starts straight in with a file operation. Each scene has a caption card
naming what's happening, with the keys it uses underneath (the GIF has no
keystroke overlay):

1. **Rename a file.** `cw` renames `scratch.txt` to `notes.txt`, and `:w`
   applies it.
2. **Create a file, folders included.** A new line,
   `docs/guide/getting-started.md`, creates both folders and the file.
3. **Delete a file, then undo and redo it on disk.** `dd` and `:w` delete
   `notes.txt`, `u` brings it back, and `Ctrl-r` deletes it again.
4. **Expand folders and edit inside them.** `zo` opens `lua/my-plugin/`, and
   `cw` renames `utils.lua` to `strings.lua`.
5. **Rename many at once.** `:%s/_test/_spec/` renames three test files in one
   save.
6. **Copy whole folders.** `yy` and `p` copy `examples/minimal/`, and the
   "already exists" prompt names the copy `examples/advanced/`.
7. **See what changed, and stage it.** `gs` shows only changed files, and `ga`
   stages `README.md`.
8. **Back to the full listing**, with the title and `:help direct.vim`.

Neovim starts inside the project, so messages show paths relative to it.
Searches type only enough of a name to match one line.

## Files

- `drive.expect` plays the tour. It types the keys into asciinema's terminal,
  so the recording's keystroke overlay shows them. Captions are sent to
  Neovim over its `--listen` socket, so they don't show up as keystrokes.
  `--check` plays the same script in a plain terminal instead of asciinema's.
- `init.lua` is the demo's Neovim config. It uses kickstart.nvim's options and
  the plugins most setups have: tokyonight, lualine, bufferline and
  nvim-web-devicons. It also shortens paths in messages to `~/my-plugin`.
- `demo.sh` creates the project, downloads the plugins, runs the tour, and
  checks the project ends up as expected.

## Usage

```sh
make demo          # record the tour and convert it to demo/tour.gif
make demo-record   # only record demo/casts/tour.cast
make demo-gif      # only convert the recording to demo/tour.gif
make demo-check    # play the tour without recording, and check the result
```

`make demo-gif` uses [agg](https://github.com/asciinema/agg). Set `DEMO_FONT`
to a Nerd Font you have installed (default: `JetBrainsMono Nerd Font`), and
`DEMO_GIF` to write the GIF somewhere else.

`demo.sh` can also be run directly:

```sh
./demo/demo.sh            # record demo/casts/tour.cast
./demo/demo.sh --force    # replace an existing recording
./demo/demo.sh --check    # play the tour without recording, and check the result
```

Recording needs Neovim 0.12+, Git, asciinema 3 and Expect, and the GIF needs
agg; `--check` needs only Neovim, Git and Expect. A check takes as long as a
recording, about a minute. Use a terminal font with Nerd Font icons.

The first run downloads the plugins, at pinned versions, into `demo/.plugins/`
(ignored by Git). Set `PLUGIN_DIR` to keep them somewhere else. Without them,
the demo uses Neovim's default colour scheme and a plain status line.

Recordings go to `demo/casts/` (also ignored); set `CAST_DIR` to change that.
The project and the demo's data directory are temporary and removed after each
run, so the tour never touches your own files or direct.vim history.
