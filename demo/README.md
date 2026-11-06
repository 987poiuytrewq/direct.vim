# Scripted demo

`demo.sh` records a one-minute tour of direct.vim with asciinema, for the top
of the project README.

## The tour

The tour works on a small Neovim plugin project, `~/my-plugin`. It's a Git
repository with a couple of changed files, so Git status shows from the first
frame, and its `build/` and `debug.log` are ignored and so hidden.

Each scene has a caption that names what's about to happen:

1. **Edit your filesystem like a buffer.** The listing, with icons and Git
   status.
2. **Browse a project as a tree.** `zo` expands `lua/` and `lua/my-plugin/`.
3. **Rename a file by editing its name.** `cw` renames `utils.lua` to
   `strings.lua`, and `:w` applies it.
4. **Rename many at once.** `:%s/_test/_spec/` renames three test files in one
   save.
5. **Create a file, parent folders included.** A new line,
   `docs/guide/getting-started.md`, creates both folders and the file.
6. **Delete a line to delete the file.** `dd` on `scratch.txt`, then `:w`.
7. **Undo it on disk.** `u` brings `scratch.txt` back.
8. **Redo it.** `Ctrl-r` deletes it again.
9. **Copy whole folders.** `yy` and `p` copy `examples/minimal/`, and the
   "already exists" prompt names the copy `examples/advanced/`.
10. **Show only what changed.** `gs` shows everything the tour changed.
11. **Stage a file.** `ga` stages `README.md`.
12. **`:help direct.vim`.** `gs` returns to the full listing.

## Files

- `drive.expect` records the tour. It types the keys into asciinema's
  terminal, so the recording's keystroke overlay shows them. Captions are
  sent to Neovim over its `--listen` socket, so they don't show up as
  keystrokes.
- `tour.vim` is the same tour, run headlessly by `--check`. Keep the two in
  step: their numbered sections match.
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
make demo-check    # play the tour headlessly and check the result
```

`make demo-gif` uses [agg](https://github.com/asciinema/agg). Set `DEMO_FONT`
to a Nerd Font you have installed (default: `JetBrainsMono Nerd Font`), and
`DEMO_GIF` to write the GIF somewhere else.

`demo.sh` can also be run directly:

```sh
./demo/demo.sh            # record demo/casts/tour.cast
./demo/demo.sh --force    # replace an existing recording
./demo/demo.sh --check    # play the tour headlessly and check the result
```

Recording needs Neovim 0.12+, Git, asciinema 3 and Expect, and the GIF needs
agg; `--check` needs only Neovim and Git. Use a terminal font with Nerd Font icons.

The first run downloads the plugins, at pinned versions, into `demo/.plugins/`
(ignored by Git). Set `PLUGIN_DIR` to keep them somewhere else. Without them,
the demo uses Neovim's default colour scheme and a plain status line.

Recordings go to `demo/casts/` (also ignored); set `CAST_DIR` to change that.
The project and the demo's data directory are temporary and removed after each
run, so the tour never touches your own files or direct.vim history.
