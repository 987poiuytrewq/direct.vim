# direct.vim -> Lua / Neovim-only migration SPEC

Status: ready for `developer`
Source research: `BEGIN_SPEC_INPUT` (researcher), verbatim + human decisions OQ1-OQ6.
Target platform: Neovim >= 0.12.0, Lua runtime, zero installable dependencies.
Revision 4: applied the third `reviewer` pass -- RB-1 (T-034 no longer prescribes a
comment containing the literal retired-call token, which AC17 forbids anywhere in
the repo), RB-2 (T-034's `Input("<CR>")` was unworkable: `demo/util.vim` drives
`execute "normal! "`, which bypasses mappings and does not translate `<>` notation;
re-issued as a mapped invocation, measured), RB-3 (the buffer-local mapping count
is **9**, not 8, in section 5, T-026, T-036 and AC13), plus RN-1..RN-7 (B3 spelling
rationale re-measured, `docs/ai/**` added to the 11.5 scan exclusions, 11.1 step 3
aligned to the self-built symlink form, R12's LICENSE task reference corrected, the
`.venv`/`demo.sh` clause restated, `tests/fixtures/live_init.lua` added to the
section 5 tree, and the section 14 spec count aligned). Every new claim
re-measured on `nvim 0.12.5` before writing.
Revision 3: applied the second `reviewer` pass -- blocking B7 (`ftplugin/direct.vim`
is now scheduled for deletion in sections 5, 14, T-026 and T-036), B8
(`demo/yank_paste.vim`'s `direct#open()` is now in T-034, asserted against the
full AC17 pattern set), B9 (B3 buffer reuse is `fs.same_path`, not string
equality, with an explicit symlinked-root test case), plus NB1-NB3 (the
`vim.loop` scan path, the `mkdtemp` evidence wording, and the phase-label
reconciliation). Every new claim re-measured on `nvim 0.12.5` before writing.
Revision 2: applied `reviewer` findings B1-B6 and N1-N8. Every claim the reviewer
challenged was re-measured on `nvim 0.12.5` before rewriting; two original
"verified" claims were found **not** to reproduce and are now marked as
hardening/defence (N2 `glob`+symlink, N3 `E937`).

---

## 1. Problem statement

`direct.vim` lets you open a directory as an editable buffer: each line is a file
or directory (directories carry a trailing `/`), and saving the buffer
synchronises the edits to the real filesystem. The feature is built on normal Vim
idioms (`:edit foo/`, `-`, `<CR>`, `dd`, `yy`, `p`, `u`), so it works without
learning new commands.

The implementation is Python 3 embedded in Vimscript (`python3 << endOfPython`
heredocs in `plugin/direct.vim`), which imposes hard constraints:

- It requires a Vim or Neovim build with `+python3`, and Neovim builds without
  Python are increasingly the default distribution.
- The Vimscript/Python boundary uses `vim.eval` round-trips and string
  interpolation into `vim.command`, which is where most of the latent bugs live
  (unescaped paths, swallowed exceptions, non-deterministic ordering).
- The test suite cannot run today: `plugin/tests/utils.py` uses Python 2
  `xrange`, and `conftest.py` imports undeclared `vimmock` and `mock`. There is
  no evidence that any change to this code is safe.

The user problem: the plugin cannot be installed on a normal modern Neovim, and
nothing about it can be verified without hand-repairing the test harness.

## 2. Context

Verified during specification on `nvim 0.12.5` (macOS, LuaJIT):

- `nvim --headless -l <script>` does **not** load user config or plugins from
  `runtimepath` (`#nvim_list_runtime_paths() == 4`, only default runtime dirs).
  A test harness must prepend the repo root and `runtime!` the plugin files
  itself.
- `plugin/netrwPlugin.vim` sourced under `-l` registers three
  `#FileExplorer` autocmds (`BufEnter`, `BufLeave`, `VimEnter`), so the
  neutralisation path is exercisable headlessly.
- `vim.fs.basename("/a/b/") == ""` (trailing slash must be stripped first).
- `vim.fn.sha256` takes exactly one argument (`pcall(vim.fn.sha256, "a", "b")`
  fails). There is **no** `mkdtemp` builtin: `exists('*mkdtemp') == 0`, and while
  `vim.fn.mkdtemp` is not `nil` (it is a callable proxy for an unknown name --
  `type(vim.fn.mkdtemp) == 'function'`), calling it raises
  `Vim:E117: Unknown function: mkdtemp`. The operative conclusion is unchanged:
  use `vim.uv.fs_mkdtemp` (and `vim.uv.fs_realpath`, not `vim.fs.realpath`).
- `vim.fn.readfile` on a missing path raises `Vim:E484`.
- **Correction (N2).** The anticipated "`glob` returns `{}` for a symlinked
  `/tmp`" failure does **not** reproduce: on `nvim 0.12.5`
  `vim.fn.glob("/tmp/<dir>/*.txt", true, true, true)` returns matches for the
  `/tmp` spelling exactly as it does for `/private/tmp`. The `wildignore`
  comparison is therefore specified as **defensive hardening** (D6/R17), not as
  a reproduced-bug fix.
- `nvim --headless -l` boots with `v:vim_did_enter == 1`, with
  `filetype plugin:OFF` (`filetype plugin on` is required before any ftplugin
  runs), and **without** `VimEnter` ever firing on its own.
- `vim.fs.realpath` does **not** exist on the target runtime; `vim.uv.fs_realpath`
  does. `vim.fs.abspath` does exist and is used by `paths.root()` (B3/T-006).

## 3. Objective

A Lua-runtime, Neovim-only replacement for `direct.vim` with behaviour parity on
the user-visible contract (listing, sync, undo/redo, yank/paste, navigation,
netrw neutralisation), the four known bugs from OQ3 fixed, the Python code and
Vim compatibility removed, and a runnable zero-dependency test suite.

## 4. Scope

### In scope

- All entry points: commands, global `-`, buffer-local mappings, `BufEnter`
  directory interception, netrw neutralisation, `BufWriteCmd` sync.
- All behaviour in `plugin/direct/{buffer,action,history,register,log,data}.py`.
- `docs/`, `doc/direct.txt`, `README.md`, `LICENSE` (MIT, OQ6).
- A Neovim/Lua test harness that runs under `nvim --headless -l` with no
  third-party plugins on the runtimepath.
- Removal of the Python package, `plugin/direct.vim`, `ftplugin/direct.vim`,
  `plugin/tests/`, `.venv`, and the Python-dependent demo harness.

### Out of scope (non-goals)

- Any Vim (non-Neovim) compatibility. `plugin/direct.vim` is deleted, not kept
  as a shim.
- New user-facing features are out of scope, except the narrow approved listing
  filename-highlighting feature documented in B16: no multi-select yank, no
  search/filter within a listing, no recursive sync of nested buffers, no
  conflict dialogs, no configurable keymaps beyond the `map_default_keys`
  opt-out, no telemetry, and no other new features.
- New runtime dependencies. No `plenary.nvim`, `busted`, `nlua`, `luarocks`,
  `mini.test`. Not even optional ones.
- Performance work beyond what the parity design implies (history logs are
  whole-file read/write; that is deliberate, see D12).
- Backwards compatibility of on-disk data written by the Python version
  (see R15/OQ7 consequences in D13).
- Porting the Python demo recording scripts into a reproducible capture
  pipeline. They are repaired to remove Python and otherwise left alone.

---

## 5. Target file layout

```
LICENSE                                  (new, MIT)
README.md                                (rewrite)
doc/direct.txt                           (update: nvim 0.12+, MIT, no python)
.gitignore                               (update: drop __pycache__/pyc, keep .cache)

plugin/direct.lua                        (new: commands, mappings, autocmds)
ftplugin/direct.lua                      (new: buffer-local mappings)
ftplugin/direct.vim                      (delete: superseded by ftplugin/direct.lua)
syntax/direct.vim                        (UNCHANGED)

lua/direct/init.lua                      (new: public API facade)
lua/direct/config.lua                    (new: defaults + setup merge)
lua/direct/buffer.lua                    (new: buffer model, listing, sync)
lua/direct/highlight.lua                  (new: static filename highlight data and extmarks)
lua/direct/action.lua                    (new: actions, serialize/reverse)
lua/direct/history.lua                   (new: undo/redo)
lua/direct/register.lua                  (new: yank/paste register)
lua/direct/log.lua                       (new: append-only line log)
lua/direct/paths.lua                     (new: XDG data dirs, digest, path helpers)
lua/direct/fs.lua                        (new: filesystem seam -- tests depend on this)
lua/direct/ui.lua                        (new: notify + injectable prompt)
lua/direct/health.lua                    (new: :checkhealth direct)

tests/run.lua                            (new: harness entry point)
tests/support/harness.lua                (new: tmpdirs, oracles, stubs, reporting)
tests/fixtures/live_init.lua             (new: minimal init for the 11.4 live smoke)
tests/paths_spec.lua
tests/fs_spec.lua
tests/log_spec.lua
tests/config_spec.lua
tests/action_spec.lua
tests/history_spec.lua
tests/register_spec.lua
tests/buffer_spec.lua
tests/highlight_spec.lua
tests/sync_spec.lua
tests/entry_spec.lua
tests/netrw_spec.lua
tests/health_spec.lua                    (added by T-027; these listed migration specs total 13)

demo/                                    (python-free repair only)
```

### Per-module responsibilities

| Module | Responsibility | Must NOT |
|---|---|---|
| `lua/direct/init.lua` | Public API: `setup`, `list`, `list_buffer`, `list_cwd`, `open`, `sync`, `undo`, `redo`, `yank`, `paste`, `paste_as`. Guard that commands run in a direct buffer. | Contain logic beyond dispatch and guard messages. |
| `lua/direct/config.lua` | Default options, `setup(opts)` merge, `install_mappings()`, `clear_mappings()`. No filesystem or buffer access. | Read `vim.env` (that is `paths`). |
| `lua/direct/paths.lua` | `root(path)`, `data_home()`, `data_dir(name)`, `digest(...)`, `dirname`, `basename`, `join`. Stateless (no caching of resolved dirs). | Touch the filesystem beyond `mkdirp` of a data dir. |
| `lua/direct/fs.lua` | Every filesystem primitive (D2). Single seam for tests. | Call `vim.fn.input`, `vim.cmd`, or any buffer API. |
| `lua/direct/ui.lua` | `notify(msg, level)` and `prompt(prompt, default, completion)`. `prompt` is the single injectable user-input seam (D9). | Contain business logic. |
| `lua/direct/log.lua` | Whole-file `push` / `pop` / `clear` over a line file, empty-guarded. | Parse action lines. |
| `lua/direct/action.lua` | Action table, `serialize`, `deserialize`, `reverse`, human `__tostring`, trash naming, `Paste`/`Unpaste` multi-actions, rename staging. | Touch history or register directly (history is pushed by callers, as today). |
| `lua/direct/history.lua` | `log(action)`, `undo()`, `redo()` over `history/undo.log` + `history/redo.log`. | Refresh buffers (callers do). |
| `lua/direct/register.lua` | `yank(sources)`, `paste(dst)`, register content pointer. | Implement copy operations (delegates to `fs`). |
| `lua/direct/buffer.lua` | Buffer attach/create, `list`, `sync`, `open`, `get_paths`, `current_entry`. | Call `vim.fn.input` directly (must go through `ui.prompt`). |
| `lua/direct/highlight.lua` | Static language/special-name matching and filename-only listing extmarks. | Fetch data, inspect file contents, or define palette colors. |
| `lua/direct/health.lua` | `:checkhealth direct` version/paths probe. | Fail on anything except `nvim < 0.12`. |
| `plugin/direct.lua` | Commands, netrw neutralisation, `BufEnter` intercept, deferred mapping install. | Implement behaviour. |
| `ftplugin/direct.lua` | Buffer-local mappings, guarded by `map_default_keys`. | Define commands. |
| `ftplugin/direct.vim` | **Deleted.** Neovim sources **both** `ftplugin/<ft>.vim` and `ftplugin/<ft>.lua` when both exist (verified on `nvim 0.12.5`: with both present, both run), so leaving the vimscript file in place installs 9 stale `direct#...` mappings that fail with `E117` at runtime and are caught by AC17. `ftplugin/direct.lua` is the replacement. | -- |

---

## 6. Public API

### Commands (unchanged names and arity)

| Command | Signature | Notes |
|---|---|---|
| `:DirectList` | `-nargs=1 -complete=dir` | Lists `{dir}` in a direct buffer. |
| `:DirectListBuffer` | none | Lists the parent dir of the current file, or `getcwd()` when `&buftype != ''`. |
| `:DirectListCwd` | none | Lists `getcwd()`. |
| `:DirectSync` | none | Runs the sync classification. Bound to `BufWriteCmd`. |
| `:DirectUndo` | none | Undo last filesystem action. |
| `:DirectRedo` | none | Redo last undone action. |
| `:DirectYank` | `-range` | Yanks the ranged entries. No range = current line. |
| `:DirectPaste` | `-nargs=? -complete=dir` | Pastes into `{dir}`, or into the current buffer's root. |
| `:DirectPasteAs` | `-nargs=1 -complete=file` | Pastes into the current buffer's root as `{name}`. |

All commands are `noremap`-equivalent (`command!`) and `<silent>` where parity
allows. `DirectUndo`/`DirectRedo`/`DirectYank`/`DirectPaste`/`DirectPasteAs`
must notify an error and do nothing when the current buffer is not a direct
buffer (`&filetype !=# 'direct'`), instead of operating on `bufname()` garbage.
The single exception is **`:DirectPaste {dir}`**: it pastes into an explicitly
named directory and never touches the current buffer (B7/N6), so it is exempt
from the direct-buffer guard. The **no-arg** `:DirectPaste` is not exempt -- it
pastes into the current buffer's root and is therefore guarded.

### `setup(options)`

```lua
require('direct').setup({
  map_default_keys = true,   -- boolean; false removes every default mapping
})
```

- `setup()` is optional. Defaults apply when it is never called.
- `setup()` is idempotent and may be called more than once; later calls replace
  the option table and re-apply mappings.
- Unknown keys are rejected with a `notify(..., ERROR)` naming the key. This
  catches typos instead of silently ignoring them.
- **Timing (D10).** `plugin/direct.lua` registers commands and autocmds at load
  but installs the global `-` mapping only after the user's config has run:
  on `VimEnter` if `setup()` has not been called yet, otherwise immediately from
  `setup()`. This makes the opt-out actually work, which the Python version
  cannot offer.

### Mappings

Global (installed only when `map_default_keys` is true):

| Mode | Key | Action |
|---|---|---|
| normal | `-` | `:<C-U>DirectListBuffer<CR>` |

Buffer-local, `ftplugin=direct` (installed only when `map_default_keys` is true):

| Mode | Key | Action |
|---|---|---|
| normal | `<CR>` | open entry under cursor |
| normal | `-` | open `../` (parent directory) |
| normal | `u` | `:DirectUndo` |
| normal | `<C-r>` | `:DirectRedo` |
| normal | `yy`, `Y` | `:DirectYank` (current line) |
| visual | `y` | `:'<,'>DirectYank` (selected range) |
| normal | `p`, `P` | `:DirectPaste` |

Buffer-local mappings win over the global `-` inside a direct buffer, which is
why the global `-` resolving to `getcwd()` inside a direct buffer (a parity quirk,
preserved) is never observable.

### Buffer options and autocmds

Set on every direct buffer: `buftype=acwrite`, `buflisted`, `noswapfile`,
`filetype=direct`; `nomodified` after every refresh (D11). Set via
`vim.bo[...]`, never bare `set`.

Autocmds (augroup `direct`):

- `BufWriteCmd <buffer> <cmd> DirectSync` (buffer-local, per direct buffer).
- `BufEnter *` directory interception (D8).
- `VimEnter *` netrw neutralisation (D7) + deferred mapping install (D10).

---

## 7. Behaviour contract

### B1. Listing

`buffer:list()` reads `<root>` and produces buffer lines:

1. Enumerate with `vim.fs.dir(root)`.
2. Resolve `type == 'link'` entries through `vim.uv.fs_stat` (Python's
   `os.path.isdir`/`os.path.isfile` follow symlinks, so a symlink to a directory
   must list as `link/`). Entries whose stat fails (broken symlink) or whose type
   is neither `file` nor `directory` (fifo, socket, device) are **omitted**,
   matching Python where both `isdir` and `isfile` are false.
3. Filter by `wildignore` (D6).
4. Emit directories first, each name + `/`, each group sorted by byte-wise
   ascending comparison (`table.sort`, default `lt` on strings).
5. Hidden entries (leading `.`) are included and highlighted by the unchanged
   `syntax/direct.vim`.
6. Replace buffer contents with `nvim_buf_set_lines(0, 0, -1, false, lines)`.
7. Restore the cursor (B2), then set `nomodified`.

### B2. Current entry and cursor

- `current_entry` is derived from the current buffer name: if
  `fs.stat(bufname)` succeeds, it is that absolute path, else `nil`.
- After a listing, the cursor is placed on the first line whose full path is
  `same_path` as `current_entry` (R4-safe comparison), else it is left where it
  was. Cursor column is reset to 0 (`nvim_win_set_cursor(0, {line, 0})`).
- `same_path(a, b)` = equal `fs_stat.ino` **and** `fs_stat.dev`, i.e. the Lua
  equivalent of `os.path.samefile`; falls back to normalised string equality when
  either side cannot be stat'ed.

### B3. Buffer attach

- `root = paths.root(input)`, which **absolutises** (T-006; reviewer B6):
  `vim.fs.abspath(vim.fs.normalize(input))`. `vim.fs.normalize` alone does not
  make a path absolute, so a relative `:DirectList .` would otherwise never
  match a buffer name (buffer names are stored absolute).
- Reuse an existing buffer **only** when a buffer's stored name denotes the same
  directory as `root`. The check iterates `vim.api.nvim_list_bufs()` and compares
  `vim.api.nvim_buf_get_name(b)` against `root` with **`fs.same_path`**, not with
  `==`. The name taken from the buffer is the one `nvim_buf_get_name` returns,
  which is the **resolved** spelling (measured: a buffer named through
  `<link>/sub` reads back as the real path), **not** `bufname('%')`, which returns
  the **unresolved** spelling the buffer was created with. `same_path` compares
  ino+dev, so it is correct whichever of the two spellings it is handed, and
  correct for either spelling of `root`.
- **Why not string equality (B9).** `nvim_buf_set_name` resolves a symlinked
  prefix, so a buffer created for `/tmp/x` reads back as `/private/tmp/x`, while
  `paths.root()`'s `vim.fs.abspath` does not resolve symlinks and returns
  `/tmp/x`. Verified on `nvim 0.12.5`: `nvim_buf_get_name(b) == root` is **false**
  for any root under a symlinked prefix (macOS `/tmp`, `/var`), so string
  equality creates a duplicate buffer instead of reusing one. `fs.same_path`
  (ino+dev, the D2 identity) is spelling-independent and is correct for every
  root spelling (measured true for the resolved/unresolved/mixed spellings of the
  same directory). Note `vim.fs.same_path` does **not** exist on the target
  runtime (verified) -- it is `direct.fs.same_path`, our own D2 seam.
- **The test must assert this explicitly (B9).** 11.1 step 3 realpaths the
  harness root, which would mask the bug: every fixture root would already be in
  `/private/tmp` spelling and string equality would accidentally pass. Therefore
  the symlinked-root case is asserted **directly**: create a directory under a
  genuinely symlinked prefix (`/tmp` on macOS) and list it through the
  *unresolved* `/tmp/...` spelling, asserting the buffer is **reused** (no second
  buffer created, `nvim_buf_get_name` still the `/private/tmp` spelling). The
  spec creates the symlinked prefix itself (a temp dir plus a symlink into it)
  rather than hard-coding `/tmp`, so the case is meaningful on every platform;
  if no symlinked prefix is available the case skips loudly rather than passing
  vacuously.
- `vim.fn.bufnr(root)` must not be used as the reuse test:
  `bufnr({expr})` treats `{expr}` as a *pattern* and returns the first listed
  buffer whose name matches, so it also selects a buffer for a nested path or
  for a file inside `root` (measured: `bufnr('sub')` selects the `<root>/sub`
  buffer). An anchored form removes the pattern over-match but is still
  **spelling-sensitive**, because `bufnr` matches the **unresolved**
  `bufname('%')` spelling, not the resolved `nvim_buf_get_name` one (measured:
  `bufnr('^<unresolved>/sub$')` hits, `bufnr('^<resolved>/sub$')` returns `-1`).
  So it is not the chosen route either -- `fs.same_path` over
  `nvim_list_bufs()` is.
- On a hit, the matched buffer becomes the current buffer; otherwise `enew`
  then `nvim_buf_set_name(0, root)`.

### B4. Sync classification

Inputs: `actual` = buffer lines (order significant), `expected` = fresh listing
(B1). Both are mapped to full paths via `root .. '/' .. line`; directories are
detected by the trailing `/` in the **buffer line**, not by stat (the user
controls that with the trailing slash).

```
1. If any line in `actual` is duplicated            -> AMBIGUOUS  (reason: duplicate)
2. Else if |actual| > |expected| and expected ⊆ actual -> ADD
3. Else if |actual| < |expected| and actual   ⊆ expected -> DELETE
4. Else if |actual| == |expected|                  -> RENAME
5. Else                                            -> AMBIGUOUS  (reason: mixed)
```

- **ADD** -> for each added name, in (directories first, then name ascending)
  order: trailing `/` -> `MakeDirectory`, else `Touch`.
- **DELETE** -> for each removed name, same ordering: trailing `/` ->
  `RemoveDirectory`, else `Remove`. All removed paths are yanked into the
  register first (parity: "deleted files are automatically yanked").
- **RENAME** -> for `i in 1..#actual`, if `actual[i] ~= expected[i]` emit
  `Move(src = expected[i], dst = actual[i])`, in buffer order. Then apply the
  clobber guard (D3).
- **AMBIGUOUS** -> no actions, no history write, buffer is **not** re-listed and
  **stays modified**, and the user gets a message naming the reason and the two
  sides of the comparison (D4, R9). `<CR>` to open, `u` to undo.

Duplicate detection is new (R7/OQ3): the Python code silently collapsed
duplicates through `set()` diffs, and a duplicated line in a RENAME-shaped edit
produced a self-move.

### B5. Applying actions

For a classified sync:

1. `DELETE` -> `register:yank(removed_paths)`.
2. Apply actions in the classified order. Each action that raises or returns a
   libuv error is caught, reported as `Action failed - <description>` via
   `ui.notify(..., ERROR)`, and skipped; it is **not** pushed to history. The
   interpolated text is the action's **human description** (`action:describe()`,
   e.g. `Removed a.txt`), **not** its serialized form (`rm\ta.txt`).
3. Each action that succeeds is pushed to `History():log()`.
4. Re-list the buffer from disk (the buffer now reflects reality), then
   `nomodified`.
5. If there were failures, additionally `ui.notify` a single summary error naming
   the count and the action names.

Partial failure therefore leaves a consistent buffer: successes are undoable,
failures are reported, and the buffer matches the filesystem.

### B6. Undo / redo

- `history:log(action)` -> push `action:serialize()` to `undo.log`, clear
  `redo.log`.
- `undo()` -> pop the last `undo.log` line, `reverse` it, execute. On success
  push the serialized reversal to `redo.log`. On failure: push the **original**
  line back onto `undo.log` and notify (D13; the Python version dropped it).
- `redo()` is symmetric over `redo.log`.
- `pop()` on an empty or missing log returns `nil` silently and changes
  nothing (D12, R10); the `Nothing to undo` / `Nothing to redo` message is
  raised by `history.undo`/`history.redo` (T-008/T-015), not by `pop()`.
- `DirectUndo` / `DirectRedo` re-list the current buffer after the attempt
  (parity), so the listing always reflects the filesystem even when the action
  failed.

### B7. Yank, paste, and the prompt

- `DirectYank` (range, or current line) -> `register:yank(paths)`; the buffer is
  re-listed afterwards (parity). Yanked entries are copied, not moved.
- **`:DirectPaste` has two forms and they differ (N6).**
  - `:DirectPaste` with **no argument** pastes into the current buffer's root
    and **re-lists** that buffer (parity: `direct#paste()` calls
    `Register().paste(buffer.root)` then `buffer.list()`).
  - `:DirectPaste {dir}` pastes into `{dir}` and **does not re-list**. The
    Python path calls only `Register().paste(dst)`; `Buffer` is never
    restored, so the current buffer is untouched whatever it is. This is the
    asymmetry the T-016 test must pin.
  - `:DirectPasteAs {name}` pastes into the current buffer's root as `{name}`
    and **does re-list** (parity).
- `Register:yank(sources)`: destination is `register/<digest(sorted sources)>`
  (R7 fix: sorting makes the digest stable regardless of the caller's order);
  files via `copyfile`, directories via recursive `copytree` into
  `<dst>/<basename(abspath(src))>` (R4 fix: strip the trailing slash before
  `basename`), replacing an existing entry of that name; the pointer
  `register/content` is rewritten to the absolute destination path.
- `Register:paste(dst)`: entries are enumerated from the register directory in
  **sorted** order (R7 fix), each copied to `dst` with the same name.
- Name clash inside `Paste`: if the destination exists, prompt
  `'<File|Directory> already exists. Paste as: '` with default `src_name` and
  completion `file`, through the injectable seam (D9). An **empty** answer skips
  that entry and reports it; the Python version silently overwrote the existing
  entry (D8a).
- The pasted entry list becomes the current entry when possible (parity: last
  pasted entry).
- `Paste` is undoable: `reverse(Paste)` is `Unpaste`, which deletes the pasted
  entries without trashing them.

### B8. Opening entries

`<CR>` on a line:
- trailing `/` -> `:DirectList <path>` (a new direct buffer);
- otherwise -> `:edit <fnameescape(path)>`.

Afterwards the previous direct buffer is deleted **only if it is no longer the
current buffer** (D8b, R16). The Python version always ran `bwipeout! <n>`
unconditionally. Guarding it is defence in depth: the `E937` it was meant to
prevent is **unverified on the target runtime** (N3), so the contract is
expressed as the observable outcome (the file buffer is current, the previous
direct buffer is gone) and never as an assertion about an error code.

### B9. Data directory (OQ2 PARITY)

`paths.data_home()`:
1. `$XDG_DATA_HOME` if set and non-empty;
2. else `$HOME/.local/share`;
3. else fall back to `vim.fn.stdpath('data')` and notify a warning (the only
   place `stdpath` is allowed).

`paths.data_dir(name)` returns the directory string `<data_home>/direct/<name>`
for `name` in `history`, `trash`, `register`, created on demand with `mkdir -p`;
**on failure it returns `nil, err` rather than raising** (e.g. `<data_home>/direct`
is occupied by a file, or the data home is not writable). Resolution is
**stateless** (recomputed per call) so test isolation by `XDG_DATA_HOME` works
without a cache-invalidation hook.

- `history/undo.log`, `history/redo.log`
- `trash/<digest>`
- `register/<digest>` and `register/content`

P2/P3 consumers of a data dir -- `history`, `register`, and the trash paths in
`action` -- must be written against that failure shape (capture
`dir, err = paths.data_dir(...)` and notify or skip) and must not assume a
string return.

`digest(...)` = `vim.fn.sha256(table.concat(paths, '\0'))` (single argument, NUL
joined; L9).

### B10. Trash naming (R5 fix)

`Remove` targets `<trash>/<digest(src)>`; if that path already exists, the first
free `<digest>-<n>` (`n = 1, 2, ...`) is used. The chosen path is stored in the
action's `dst` field, which is serialized, so `Restore` always reverses to the
exact entry. The Python version produced one destination per path and could
clobber or nest into an existing trash entry.

### B11. Rename clobber guard (R8 fix)

Before executing `Move` actions in the RENAME branch, compute
`srcs = { src of every action }`. If any `dst` is also in `srcs` (a swap or a
chain, e.g. `a -> b`, `b -> a`), stage first: move every such source to a unique
free temp path `<root>/.direct-tmp-<n>` (same directory, so the move cannot cross
a filesystem), execute the real moves, then remove any temp path that was not
consumed. Otherwise move directly. `current_entry` must never be set to a temp
path.

### B12. Netrw neutralisation (R2 fix)

1. At load, in `plugin/direct.lua`: if `vim.fn.exists('#FileExplorer') > 0`,
   clear the `FileExplorer` group (`nvim_clear_autocmds({ group = 'FileExplorer' })`),
   wrapped in `pcall`.
2. Again on `VimEnter` (netrw's plugin file may load after ours, and it
   re-registers on `VimEnter`).
3. Register our own `BufEnter` intercept at load, not at `VimEnter`, so
   `nvim somedir/` (where `BufEnter` fires *before* `VimEnter`) is also
   captured. The Python version only ran the `VimEnter` clear, so
   `nvim somedir/` from the command line still opened netrw.

Intercept body: on `BufEnter`, if **the buffer has a name that resolves to an
existing directory** (`fs.is_dir(name)`) **and `&filetype !=# 'direct'`**, then
`require('direct').list(<that path>)`. There is no "and the buffer has no name"
clause: a nameless buffer has no path to list, so such a clause would make the
predicate unsatisfiable and the intercept would never fire (corrected from the
earlier draft). The `filetype` guard is required: a direct buffer's name *is* a
directory, so without it the intercept re-triggers `DirectList` on every entry
into a direct buffer (parity behaviour, harmless but wasteful, and it perturbs
cursor tracking).

### B13. `wildignore` filtering (D6)

For each comma-separated, trimmed, non-empty pattern in `&wildignore`, glob
`root .. '/' .. pattern` with `vim.fn.glob(path, true, true, true)` -- the four
arguments are `{expr}, {nosuf}, {list}, {alllinks}`, so `nosuf` is the
**second** argument and the fourth is `alllinks`. Passing `nosuf` is mandatory,
otherwise `suffixesadd`/wildmenu suffixes fabricate matches; `{list}` makes the
result an array and `{alllinks}` follows symlinks while globbing. The union of
matches forms the ignore set. An entry is ignored when `same_path` (D2) matches
any member. `same_path` rather than string equality is **defensive hardening**
(D6/R17): the anticipated failure -- `glob` returning nothing when the root was
reached through a symlinked prefix -- does **not** reproduce on the target
runtime (section 2), but inode comparison is correct for every root spelling and
costs one `fs_stat`, so it is kept.

### B14. Undo/redo of sync vs. Vim's own undo

Direct history is filesystem-level and independent of buffer-local `u` undo,
which is overloaded. This is parity and is documented as such.

### B15. Success notifications (parity, N5)

The Python version printed a success line on **every** mutating path. Parity is
the goal, so these messages are **kept, not dropped**: they are user-visible
feedback, and the spec previously left them unspecified. They go through
`ui.notify` (D9/`ui.lua`), which routes to `vim.notify` and is therefore
observable under `-l` via `:messages`.

| Trigger | Message |
|---|---|
| `sync` after applying actions (B5) | joined summary (below), once |
| `undo()` / `redo()` success (B6) | joined summary of the reversal, once |
| `paste` success (B7) | joined summary of the `Paste` action, once |
| every source yanked (B7) | `Yanked <path>`, one per source, in input order |

**Joined summary format.** Given the list of applied actions `a1..an`, the
message is:

```
describe(a1) .. ', ' .. describe(a2) .. ', ' .. .. describe(an)
```

with the **first character of the whole string upper-cased** and every other
character left untouched (the Python `print_actions` behaviour:
`actions_string[0].upper() + actions_string[1:]`). It is emitted as a **single**
notification, not one per action.

**Description rules (N8).**

- `describe(action)` is the action's **human** description, never its serialized
  form. Failure prefixes use the same text (B5 step 2, B6).
- Every path inside a description is rendered **CWD-relative**
  (`vim.fn.fnamemodify(p, ':.')`, the Lua equivalent of Python's
  `relpath`), so `Removed a.txt` rather than `Removed /long/tmp/.../a.txt`. This
  is what makes the summary short and is why the oracle can assert on it.
- `Yanked <path>` is the exception: the Python code interpolated the raw `src`,
  so the yank line keeps the **absolute** source path. Pinned deliberately so a
  test does not guess.
- Example: a sync that moves `a.txt` to `b.txt` and removes `c.txt` notifies
  `Moved a.txt to b.txt, Removed c.txt` (first letter already capital).

### B16. Listing filename highlights (narrow approved feature exception)

Direct listing rows receive filename-only extmarks in a namespace separate from
`direct-listing-rows`. Recompute only on a full listing render/re-render and on
materialized child-row insertion; do not add a text-change autocmd. Highlight
regular file rows only, not directories. Dotfiles retain the existing syntax
styling and are not covered by the new groups.

Language membership is the static GitHub Innovation Graph programming-only
2026Q1 top-20 snapshot, in descending `num_pushers` summed across economies:
JavaScript, Python, TypeScript, Shell, Dockerfile, Java, C++, C, Makefile,
Batchfile, C#, PHP, CMake, PowerShell, Kotlin, Ruby, Go, Swift, Rust, PLpgSQL.
The method is a lower bound because some economy data is suppressed. Use
`vim.filetype.match({ filename = basename })` only, with no content reads or
runtime network calls. The mapped members are JavaScript, Python, TypeScript,
Shell, Dockerfile, Java, C++, C, Makefile, Batchfile, C#, PHP, CMake,
PowerShell, Kotlin, Ruby, Go, Swift, and Rust. PLpgSQL has no dedicated Neovim
filetype and is intentionally unhighlighted.

Special-name matching is a separate, bounded conventional list, not a popularity
ranking: the exact, case-sensitive basenames `Makefile`, `GNUmakefile`,
`CMakeLists.txt`, `Rakefile`, `justfile`, `Dockerfile`, `Containerfile`,
`Jenkinsfile`, `Vagrantfile`, `README.md`, `LICENSE`, `CODEOWNERS`, and `Gemfile`.
These names take precedence over detected language filetypes, and a row receives
exactly one mark. `DirectSpecialFile` defaults to a link to `Special`; one
`DirectLang<Name>` group per mapped language defaults to `Type`, except Shell,
which links to `sh`. All definitions use `default=true`, so user definitions
are preserved. No palette, plugin colors, option, or new dependency is added.

Sources: [Innovation Graph language data](https://raw.githubusercontent.com/github/innovationgraph/main/data/languages.csv)
and [datasheet](https://github.com/github/innovationgraph/blob/main/docs/datasheet.md).

---

## 8. The `lua/direct/fs.lua` seam

Every filesystem operation goes through this module. It exists so that tests can
(a) run against real temp directories and (b) force specific failures (cross
device, permission denied, mid-action failure) without patching `vim.uv`.

Required functions:

| Function | Contract |
|---|---|
| `M.stat(path)` | `vim.uv.fs_stat` result or `nil, err`. |
| `M.exists(path)` | `boolean` |
| `M.is_dir(path)`, `M.is_file(path)` | follow symlinks (stat, not lstat) |
| `M.list_dir(path)` | array of names, **sorted ascending** (determinism, R7) |
| `M.iter_dir(path)` | iterator yielding `{ name, type }` from `vim.fs.dir` |
| `M.read_dir_lines(root, ignore_set)` | the B1 listing pipeline; returns string array |
| `M.same_path(a, b)` | ino+dev equality, normalised-string fallback |
| `M.rename(src, dst)` | `uv.fs_rename`; **on `EXDEV` only**, copy-then-remove fallback (D5) |
| `M.copy_file(src, dst)` | `uv.fs_copyfile`, preserving mode |
| `M.copy_tree(src, dst)` | recursive, hand-rolled (no `cp -r`), mkdir -p semantics |
| `M.rm_file(path)` | `uv.fs_unlink` |
| `M.rm_tree(path)` | `vim.fs.rm(path, { recursive = true })` |
| `M.mkdirp(path)` | `vim.fn.mkdir(path, 'p')` |
| `M.touch(path)` | `vim.fn.writefile({}, path)` |
| `M.realpath(path)` | `uv.fs_realpath` or the input |
| `M.abspath(path)`, `M.basename(path)`, `M.dirname(path)`, `M.join(...)` | thin wrappers; `basename` strips a trailing slash first (R4) |

Rules:

- Every function returns `true` / `nil, err, code`; it must never raise a Lua
  error. Callers branch on the return value.
- Functions call each other through the module table (`M.copy_file`), never
  through a captured local, so a test stub on `M.copy_file` is honoured by
  `M.copy_tree`.
- No `vim.cmd`, no `vim.fn.input`, no buffer access. `fs.lua` is headless-safe.

---

## 9. Technical decisions

| ID | Decision | Rationale |
|---|---|---|
| D1 | Neovim floor 0.12.0, enforced by `health.lua` and documented in README/help. | OQ1. `vim.uv` (0.10+), `vim.fs.rm`/`abspath` (0.11+), `vim.keymap.set`. `vim.loop` is never referenced. |
| D2 | Path identity via `fs_stat.ino` + `.dev` in one shared `fs.same_path`, reused for cursor restore, `wildignore`, and **buffer reuse in B3** (B9). | Python's `os.path.samefile`; also fixes the symlinked-root `glob` issue and the spelling mismatch between `nvim_buf_set_name` (resolves symlinks) and `vim.fs.abspath` (does not). |
| D3 | RENAME clobber guard stages to `.direct-tmp-<n>` only when a `dst` is also a `src`. | R8. Minimal change; no behaviour difference for the common case. |
| D4 | AMBIGUOUS sync leaves the buffer modified and does not re-list. | R9 + OQ3. The Python version marked it unmodified, silently discarding unsaved intent. **Confirmed by the human.** |
| D5 | `rename` falls back to copy+remove **only** on `EXDEV`; other libuv errors propagate. | R6. `/tmp` vs another device is real; masking permission errors would hide bugs. |
| D6 | `wildignore` uses `glob(path, true, true, true)` (`nosuf` is the 2nd argument) compared through `same_path`. | B13. **Hardening, not a reproduced bug** -- see N2/R17. |
| D7 | Clear the whole `FileExplorer` group at load **and** on `VimEnter`, and register our intercept at load. | R2; fixes the `nvim somedir/` CLI gap. `pcall`-guarded: the group may not exist. |
| D8a | Empty paste prompt answer skips the entry and reports; it does not overwrite. | Non-destructive default; the Python version overwrote on `<CR>`. Divergence, deliberate. |
| D8b | `open()` deletes the previous direct buffer only if it is no longer current. | R16 / `E937`. The `E937` premise is **unverified on the target runtime** (N3), so this is retained as a defence, not as a bug fix. The test asserts the observable outcome, never the error code. |
| D9 | `lua/direct/ui.lua` exposes `prompt(...)`; `action.lua` calls `ui.prompt(...)` through the module table. | R1. Tests replace `require('direct.ui').prompt`; `vim.fn.input` is then never reached under `-l`. |
| D10 | Mappings install on `VimEnter`, or **immediately at load** when `v:vim_did_enter` is already `1` -- which is always true under `nvim --headless -l` (reviewer B3), so the harness exercises the immediate path. | Makes `map_default_keys = false` actually work, and keeps the immediate path reachable in tests instead of only under a real startup. |
| D11 | Options set through `vim.bo`; `nomodified` only after a real refresh. | Removes the Python version's global `set` leakage. |
| D12 | `log.lua` reads and rewrites the whole file; `pop()` returns `nil` when empty. | R10 (1-line truncation bug) and `E484`. History files are kilobytes. |
| D13 | Failed undo/redo pushes the original line back onto its source log. | Prevents silently losing history on a transient failure. |
| D14 | All inter-command strings use `vim.fn.fnameescape`; all `:` invocations from Lua use `vim.cmd` with a list of args or an escaped string, never `string.format` into a command. | Fixes paths containing spaces, `|`, `%`, `#`. |
| D15 | Digest is `sha256` over NUL-joined paths; sources sorted before digesting. | L9, R7. |
| D16 | Trash names get a `-<n>` collision suffix. | R5. |
| D17 | Action ordering is explicit everywhere (sort dirs-then-name; register names sorted; moves in buffer order). | R7. |
| D18 | Register/trash/history data written by the Python version is **not** readable by the Lua version (md5 -> sha256, trash naming changed). **History logs are version-gated: the Lua history owns `undo.log`/`redo.log` under `paths.data_dir('history')`; the first line of each log must be exactly `#direct-history-v2`. Logs without this marker (Python-era or empty) are never read or executed — `history.undo()`/`redo()` notify `WARN` (`Ignoring history written by an older version`), quarantine the foreign log by renaming it to `<name>.legacy` (or `<name>.legacy.<n>` on collision), and leave it untouched if the rename fails. Undo history does not survive the upgrade.** Register — Python-written entries are read but only entries whose basename passes the name validator (no space/tab/control char, per the R1 guard) are honored. Trash — read for restore. | Consequence of D15/D16 and the version-gate mechanism (T-017/B1). Must be stated in README and help, and is the one user-visible migration cost. |
| D19 | `demo/` is repaired to remove `python << endOfPython` (`util.vim` uses `vim.uv.sleep`), stale `demo/demo/` and `demo/*.json` removed. No new demo pipeline. | R13; the demo currently cannot run on a Neovim without `+python3`. |
| D20 | Tests are zero-dependency `nvim --headless -l`, one process, no busted/plenary. | Constraint from the brief and research. |

---

## 10. Acceptance criteria

### Phase gate: behaviour

1. `:DirectList <dir>` and `:edit <dir>` both open a buffer whose lines are
   directories (trailing `/`) sorted, then files sorted, hidden entries
   included, with `buftype=acwrite`, `buflisted`, `noswapfile`, `filetype=direct`.
2. `&wildignore` removes matching entries and non-matching entries survive; a
   pattern list with spaces around commas is tolerated.
3. A symlink to a directory lists as `name/`; a symlink to a file lists as
   `name`; a broken symlink is omitted.
4. `:write` in a direct buffer triggers the sync and clears `modified`.
5. Each of ADD (file and directory), DELETE (file and directory), RENAME (file
   and directory) produces exactly the expected filesystem state, and each
   produces exactly the recorded history entry.
6. A mixed add+delete buffer notifies with a message that names the reason and
   both sides, performs no filesystem change, writes no history, and leaves the
   buffer modified.
7. A buffer with a duplicated line is reported as ambiguous, not silently
   collapsed.
8. A swap rename (`a -> b`, `b -> a`) and a chain rename (`a -> b`, `b -> c`)
   both complete correctly with no data loss and no leftover `.direct-tmp-*`.
9. `:DirectUndo` after any mutation restores the previous filesystem state,
   including restoring a trashed directory tree; `:DirectRedo` re-applies it.
   Ten alternating mutations produce ten correct reversals in order.
   **History version-gate (filesystem state): (a) a legacy unmarked `undo.log`
   containing a space-named paste line is never executed — `history.undo()`
   deletes nothing and emits the ignore notify (`Ignoring history written by an
   older version`); (b) a Lua-written (marked with `#direct-history-v2`) log
   round-trips undo/redo correctly; (c) cross-process replay (separate Neovim
   instances writing/reading the same marked log) still works.**
10. Yank a file and a directory tree; paste into another directory; the pasted
    tree matches the source tree. With a name clash, an injected prompt answer of
    `other.txt` produces `other.txt` and leaves the original untouched; an empty
    answer skips the entry and leaves the original untouched.
11. Deleted entries are automatically yanked and can be pasted back.
12. With netrw loaded, after our `VimEnter` handler there are zero
    `#FileExplorer` `BufEnter` autocmds, and `:edit <dir>` yields
    `filetype=direct` with the correct listing. Additionally, entering a
    directory buffer that is **not** a direct buffer is converted by the
    `BufEnter` intercept to `filetype=direct` with the correct listing -- a
    dead predicate cannot satisfy this clause.
13. `map_default_keys = false` installs no global `-` and no buffer-local
    mappings; with the default, all nine buffer-local mappings (plus the global
    `-`) resolve to their commands.
    This is only reachable because the harness enables `filetype plugin on`
    (11.1; reviewer B3): under `-l` with filetype plugins off, `ftplugin/direct.lua` never
    runs and the assertion would be vacuously true.
14. `require('direct').setup({ map_default_keys = false })` from a user config
    actually suppresses the global `-` mapping in a real startup (live smoke).
15. `:checkhealth direct` reports `nvim >= 0.12` OK / not OK, and the resolved
    data directory.
16. `nvim --headless -l tests/run.lua` runs the whole suite with a temp
    `XDG_DATA_HOME`, no third-party plugin on the runtimepath, and exits non-zero
    on any failure.
17. No `python3`, `python <<`, `has('python')`, `direct#`, or `plugin/direct/`
    reference remains anywhere in the repository **outside
    `docs/lua-migration-spec.md`** (this spec necessarily names the patterns it
    retires, so it is excluded from the scan; the `rg` command in 11.5 encodes
    the same exclusion). The success-message contract is B15, asserted through
    the success oracle in 11.2. The scan covers, in particular,
    `ftplugin/direct.vim` (9 `direct#` hits -- deleted by T-036) and
    `demo/yank_paste.vim:9` (`call direct#open()` -- repaired by T-034), which
    carry no `python3` on the same line and are therefore missed by a
    Python-only scan.

### Documentation gate

18. `README.md` states the Neovim >= 0.12 requirement and no Python, lists all
    commands and mappings, documents the trailing-slash convention, the undo/redo
    semantics, the data directory, and the D18 upgrade consequence.
19. `doc/direct.txt` carries the same facts as `:help direct.txt` with valid tag
    syntax (`helptags` clean) and an MIT licence section.
20. `LICENSE` is MIT with a copyright line naming the author.
21. B16's static snapshot and exact special-name list produce one filename-only
    extmark for supported file rows, none for directories/unknown names, and
    remain separate from row identities through re-render and child insertion.
    Default links preserve user highlight definitions.

---

## 11. Validation plan

### 11.1 Harness

```
nvim --headless -l tests/run.lua              # everything
nvim --headless -l tests/run.lua sync         # only *_sync_spec.lua
nvim --headless -l tests/run.lua --verbose    # per-assert output
```

`tests/run.lua` boot sequence, in order:

1. **Prepend the repo root** to `runtimepath` (mandatory: `-l` does not load user
   config or plugins) and run
   `runtime! plugin/direct.lua ftplugin/direct.lua syntax/direct.vim`.
2. **`vim.cmd('filetype plugin on')`** -- mandatory (reviewer B3). Verified on
   `nvim 0.12.5`: under `nvim --headless -l` Neovim boots with `filetype
   plugin:OFF`, so `ftplugin/direct.lua` is never sourced and every
   buffer-local mapping assertion (AC13, T-026) would be vacuous. The explicit
   alternative, if `filetype plugin on` proves too broad, is a per-buffer
   `vim.cmd('runtime! ftplugin/direct.lua')` inside `buffer:attach`; the chosen
   route is recorded in `tests/run.lua` with the reason.
3. **Create one temp root** via `vim.uv.fs_mkdtemp` and **immediately** resolve
   it with `vim.uv.fs_realpath` (`vim.fs.realpath` does not exist on the target
   runtime -- reviewer B4; this is the same call as `fs.realpath` in section 8). Every
   fixture path derives from that resolved root so `glob` and `fs_realpath`
   agree. This is defensive hygiene, not a fix for a reproduced failure (N2:
   `glob` does resolve symlinked prefixes on this runtime). **Caveat (B9):**
   because every fixture root is already realpath-resolved, this step would
   *mask* a spelling-sensitive buffer-reuse comparison, so T-018 asserts the
   symlinked-root case against a symlinked prefix the spec **builds itself**
   (a temp dir plus a symlink into it, per B3) and lists it through the
   *unresolved* spelling of that prefix -- never a hard-coded `/tmp` path.
4. **Set `vim.env.XDG_DATA_HOME = <temp>/data`** *before* loading the plugin, and
   re-set it per spec; `paths` holds no cache so per-spec isolation is total.

Then, per run:

- **D10 consequence under `-l`.** Verified: `v:vim_did_enter == 1` already when
  the `-l` script starts. Therefore `VimEnter` has already "fired" as far as the
  guard is concerned, and `plugin/direct.lua` **must install the global `-`
  mapping immediately at load** when `map_default_keys` is true, rather than
  waiting for a `VimEnter` that will never come. A harness-visible consequence:
  `map_default_keys = false` is what suppresses the mapping in tests, and the
  global mapping is present from the first assertion unless explicitly disabled.
- **`VimEnter` is never fired by the runtime under `-l`.** Any behaviour wired
  only to `VimEnter` -- netrw neutralisation step 2 (B12), the deferred-install
  path of D10 -- must be triggered explicitly by the harness with
  `nvim_exec_autocmds('VimEnter', {})` (verified: the call does fire registered
  `VimEnter` autocmds). `netrw_spec.lua` (T-028) and any D10 deferred-install
  case must call it; a spec that assumes it happens for free is wrong.
- Discovers `tests/*_spec.lua` (or the subset named on the command line), runs
  each in a fresh state: fresh temp workspace, fresh data home, buffers wiped
  (`%bwipeout!`), autocmds cleared and re-registered, options restored. Because
  step 2 already turned filetype plugins on globally, per-spec reset restores
  the buffer-local mappings' owning `filetype=direct` buffers rather than the
  global `filetype` option.
- Prints `ok/FAIL` per assertion, a per-spec summary, and exits `1` if any
  assertion or spec failed, `0` otherwise. Any uncaught Lua error fails the run.

`tests/support/harness.lua` provides:

- `describe`/`it`/`assert_eq`/`assert_true`/`assert_nil`/`assert_error`
  (minimal, ~80 lines, no dependencies).
- `sandbox()` -> `{ root = <tmpdir>, data_home = <tmp>/data }`, removed in
  teardown via `vim.fs.rm(..., { recursive = true })`.
- `mkfile(root, rel, contents)`, `mkdir(root, rel)`, `ls(root)` (sorted names),
  `exists(root, rel)`, `inode_of(path)`.
- `fs_snapshot(root)` / `assert_fs_eq(root, expected)` -- the filesystem oracle:
  a sorted list of relative paths with entry types.
- `buf_lines(bufnr)` / `assert_buf_eq(lines)` -- the buffer oracle.
- `stub(mod, name, fn)` returning a restore function: swaps a field on a module
  table (used for `fs.rename`, `fs.copy_file`, `ui.prompt`, `history`).
- `capture_messages()` / `assert_notified(pattern, level)` -- the message oracle,
  reading `:messages`.
- `with_prompt(fn, answers)` -- replaces `require('direct.ui').prompt` with a
  scripted responder (fixes R1: `vim.fn.input` is never called).

### 11.2 Oracles

Every behaviour assertion uses at least one of:

- **Buffer oracle**: `nvim_buf_get_lines` + `&filetype`/`&buftype`/`&modified`.
- **Filesystem oracle**: `fs_snapshot` (relative path + type) + inode comparison
  when the contract promises identity preservation (Move must preserve `ino`,
  as `test_action.py` asserted).
- **History oracle**: exact `undo.log` / `redo.log` line counts and exact
  serialized action names, in order.
- **Message oracle**: `:messages` content for ambiguous sync, action failure,
  undo/redo failure, paste clash.
- **Success-message oracle** (N5, B15): `:messages` content for the success
  paths, asserted as **exact strings**, not patterns:
  - After a sync / undo / redo / paste, exactly **one** new message equal to the
    B15 joined summary: descriptions `, `-joined, first character upper-cased.
    With CWD set to the listing root, a move of `a.txt` to `b.txt` yields
    exactly `Moved a.txt to b.txt`.
  - After a yank of `n` sources, exactly `n` messages of the form
    `Yanked <absolute path>`, in input order.
  - A negative half: a failing action produces the B5 error line
    `Action failed - <human description>` and the success summary contains only
    the actions that succeeded.

### 11.3 Per-behaviour mapping

| Contract | Spec file | Key cases |
|---|---|---|
| B1 listing, B13 wildignore | `buffer_spec.lua` | dirs-then-files order, hidden entries, symlinked dir, broken symlink omitted, wildignore with/without spaces, suffix-entry not matched |
| B16 filename highlights | `highlight_spec.lua` | static language membership and runtime detection, exact special names/precedence, directories/dotfiles/unknown names, separate namespace lifecycle, override preservation |
| B2 current entry | `buffer_spec.lua` | file entry, directory entry, missing entry, cursor lands on the right line |
| B4 classification, B5 apply | `sync_spec.lua` | add file, add dir, delete file, delete dir, rename file, rename dir, mixed -> ambiguous, duplicate line -> ambiguous, delete auto-yanks |
| B6 undo/redo | `history_spec.lua` | undo/redo round trip for each action type, undo of trash restore, 10-step alternation, undo failure pushes back (stubbed `fs.rename`), empty undo log notifies |
| B7 yank/paste | `register_spec.lua` | yank file, yank dir tree, paste, paste clash renamed (scripted prompt), paste clash empty answer skips, paste of empty register notifies, digest stability, **`:DirectPaste` with no arg re-lists while `:DirectPaste {dir}` does not (N6)** |
| B15 success messages | `sync_spec.lua`, `register_spec.lua`, `history_spec.lua` | joined summary after sync/undo/redo/paste is a single capitalised `, `-joined CWD-relative line; one `Yanked <abs>` line per yanked source |
| B3 attach (path identity, not name string) | `buffer_spec.lua` | given `root` with a buffer for `<root>/nested/` and a buffer for `<root>/a.txt` open, `:DirectList <root>` selects **neither** and creates/focuses the buffer for exactly `<root>` (reviewer B2); **symlinked-root reuse (B9): a dir created under a self-built symlinked prefix and listed via the unresolved spelling reuses the one buffer (no duplicate), asserted explicitly so 11.1 step 3's realpath does not mask it** |
| B3/B8 open | `buffer_spec.lua`, `entry_spec.lua` | open file (file buffer current, previous direct buffer gone), open dir, open parent with `-`, name containing a space |
| B12 netrw | `netrw_spec.lua` | load netrwPlugin, assert `BufEnter` autocmds present, fire `VimEnter` via `nvim_exec_autocmds('VimEnter', {})` (11.1), assert zero remain, `:edit <dir>` -> `filetype=direct`; CLI-style `BufEnter` before `VimEnter` captured; **a non-direct directory buffer is converted to `filetype=direct` by the intercept (reviewer B1)** |
| D5 cross-device | `fs_spec.lua` | stub `vim.uv.fs_rename` to return an `EXDEV` error -> content copied, source removed; stub a non-EXDEV error -> propagated, source intact |
| D16 trash collision | `action_spec.lua` | remove, restore, remove again -> two distinct trash entries, no nesting |
| D12 log | `log_spec.lua` | push/pop round trip, pop on empty returns `nil` silently (no notify; the empty-pop message belongs to `history.undo`, T-015), pop on 1-line file leaves the file empty (R10), missing file does not raise `E484` |
| D9 prompt seam | `register_spec.lua` | no `vim.fn.input` call is made under `-l` (assert the run completes) |
| D10 mappings | `entry_spec.lua` | default mappings present per buffer; `map_default_keys=false` absent; commands exist with expected completion/range attributes |
| D1/D15 | `paths_spec.lua`, `health_spec.lua` | `XDG_DATA_HOME` honoured, `$HOME/.local/share` fallback, digest is sha256 of NUL-joined paths, trailing-slash basename, **`root('.')` yields an absolute path (reviewer B6)** |

### 11.4 Live smoke evidence (not automatable under `-l`)

Verified: `nvim --headless -l` does not load plugins from `runtimepath`, so a
real start is required for two checks. Record as `manual_oracle`:

```
nvim --clean --cmd "set rtp+=$PWD" -u tests/fixtures/live_init.lua   # then:
  :echo &filetype                                    " expect direct
  :echo join(getline(1,'$'), ' ')                    " expect "sub/ a b.txt"
  nvim --clean --cmd "set rtp+=$PWD" /tmp/any-dir/   " CLI: must not be netrw
  :echo &filetype                                    " expect direct
  nvim --clean --cmd "set rtp+=$PWD" -u tests/fixtures/live_init.lua  " with setup{map_default_keys=false}
  :nnoremap <                                        " expect - unmapped
```

The init file is passed with `-u`, never as the file-to-edit argument: naming it
positionally would make Neovim edit the Lua source instead of loading it (N4).
In a real startup `filetype plugin` is on by default, so
`ftplugin/direct.lua` loads normally here -- this is exactly the difference from
`-l` that 11.1 has to compensate for.

`tests/fixtures/live_init.lua` is a minimal init that prepends the repo, calls
`setup()` with the option under test, and nothing else. This is evidence for
D10 and the CLI half of D7, both of which `-l` cannot prove.

### 11.5 Static checks

```
# B5/N2/RN-2: docs/lua-migration-spec.md names these very patterns, and so can the
# harness run reports under docs/ai/ (they quote the spec and the grep output), so
# both are excluded.
rg -n --glob '!docs/lua-migration-spec.md' --glob '!docs/ai/**' \
   "python3|python <<|has\('python'\)|direct#|plugin/direct/" .        # expect no hits
rg -n "vim\.loop" . --glob '!docs/lua-migration-spec.md' --glob '!docs/ai/**'   # expect no hits
nvim --headless -c "helptags doc" -c "qa"                              # expect no errors
```

The first command's globs are what makes AC17 satisfiable: without them the scan
always hits this spec, and it would equally fail on any harness report that quotes
it. T-037 uses the same command, so the AC and the static check agree by
construction.

---

## 12. Risks and edge cases

| ID | Risk | How the spec addresses it |
|---|---|---|
| R1 | `vim.fn.input()` stalls `nvim -l`. | D9: single injectable seam `ui.prompt`; the harness's `with_prompt` replaces it and no test ever reaches `vim.fn.input`. Verified need, kept as a hard rule. |
| R2 | netrw intercepts `:edit <dir>`. | D7/B12: clear `#FileExplorer` at load **and** on `VimEnter`, register our `BufEnter` intercept at load (covers `nvim dir/`), assert zero remaining autocmds in `netrw_spec.lua`. |
| R3 | Symlink misclassification when `type == 'link'` is not resolved. | B1 step 2: `vim.uv.fs_stat` resolution; broken/non-regular entries omitted; test cases. |
| R4 | `vim.fs.basename` returns `''` for a trailing-slash path. | `fs.basename` strips a trailing slash before delegating (D-table `fs.lua`); used by register yank; test asserts a directory yank stores `dir1`, not `''`. |
| R5 | Trash digest collision on repeated removal of the same path. | B10/D16: `-<n>` suffix chosen as the first free name, persisted in the serialized `dst`. Test: remove/restore/remove -> two distinct trash entries. |
| R6 | Cross-device rename. | D5: `EXDEV`-only copy+remove fallback inside `fs.rename`; other errors propagate. Test stubs `vim.uv.fs_rename`. |
| R7 | Python `set` diffs: non-deterministic action order, non-deterministic register digest, silently collapsed duplicates. | D15 (sort before digest), D17 (explicit ordering everywhere), B4 step 1 (duplicate detection). Three dedicated test cases. |
| R8 | Equal-length zip can issue `Move` pairs that clobber each other (swap). | B11/D3: stage to `.direct-tmp-<n>` when any destination is also a source. Test: swap and chain. |
| R9 | `AmbiguousBufferError` swallowed, buffer left out of sync with disk. | B4/B5 + D4: informative message naming the reason and both sides, no actions, buffer stays modified so the user is forced to resolve it. **Confirmed by the human.** |
| R10 | `Log.pop` on a 1-line file leaves the line in place. | D12: whole-file rewrite; `pop` of the last line leaves an empty file; on an empty log `log.pop` returns `nil` silently instead of raising -- `history.undo`/`redo` are what raise the `Nothing to undo`/`Nothing to redo` message (T-008/T-015). Test asserts the exact file contents. |
| R11 | Neovim version floor. | D1: 0.12 floor, `health.lua` check, README/help statements, no `vim.loop`. |
| R12 | No LICENSE. | OQ6/T-033: MIT `LICENSE`, doc section updated, acceptance criterion 20. |
| R13 | Stale artifacts `.venv` (a *file*), `demo/demo/`, `demo/*.json`, **`ftplugin/direct.vim`** (B7), and the `call direct#open()` in `demo/yank_paste.vim` (B8). | **P6** removal tasks T-036 (deletes `ftplugin/direct.vim` with the rest of the Python implementation) and T-037 (repo-wide grep); T-034 repairs `demo/yank_paste.vim`; acceptance criterion 17 (repo-wide grep) plus explicit file lists in T-034/T-036. |
| R14 | Python suite un-runnable (`xrange`, undeclared `vimmock`/`mock`). | P0 builds a new zero-dependency harness; the Python tests are deleted rather than ported 1:1. No pytest dependency is introduced. |
| R15 | *(new, found while specifying)* On-disk data written by the Python version is unreadable (md5 -> sha256, trash naming changed); undo history does not survive the upgrade. | D18: accepted, documented in README/help, stated in the release-facing docs task. Also means old `trash/` entries are never cleaned by the Lua version. |
| R16 | *(new, found while specifying)* `open()` always ran `bwipeout!` on the previous direct buffer, which raises `E937` when `:edit` reused that buffer -- i.e. pressing `<CR>` on a file. **The `E937` premise does not reproduce on the target runtime (N3):** with `buftype=acwrite` the `:edit` creates a *new* buffer and the wipe succeeds. The guard is kept as defence in depth, not claimed as a bug fix. | D8b: delete the previous buffer only when it is no longer current. The test asserts the **observable** property -- after `<CR>` on a file the file buffer is current and the previous direct buffer is gone -- and makes no assertion about `E937`. |
| R17 | *(new, found while specifying)* `wildignore` could silently stop matching when the root is reached through a symlinked prefix (macOS `/tmp`). **Not reproduced (N2)**: `glob` resolves both spellings on `nvim 0.12.5`. | D6/B13: `same_path` comparison against glob results as **defensive hardening**; harness roots are still `vim.uv.fs_realpath`-resolved so the test cannot accidentally depend on prefix resolution. |
| R18 | Failure of a single action mid-sync leaves history and buffer inconsistent. | B5: per-action error capture, successes only to history, always re-list, one summary error. Test stubs one action to fail and asserts the other still applied and is undoable. |
| R19 | `Paste` iterates a Python `dict`, so multi-entry pastes have unspecified order and the prompt order is unpredictable. | B7: sorted iteration, and the injected prompt answers are consumed in that documented order. |
| R20 | History logs grow without bound (no trimming). | Accepted, documented: they are kilobytes and trimming would break undo. Not a fix. |

---

## 13. Open questions

All of OQ1-OQ7 are resolved by the human and are encoded above. One accepted
consequence remains recorded below.

**OQ7 -- resolved.** Confirmed by the human: D4 stands as written. An AMBIGUOUS
sync notifies informatively, performs nothing, does not re-list, and **leaves
the buffer modified**. The T-022 assertion on the `modified` flag is therefore
confirmed and not pending. (T-022's *other* assertion, formerly phrased as
"raises no `E937`", was reworded in N3 to an observable property: the `E937`
premise is unverified on the target runtime, so the test asserts the current
buffer and the wiped previous buffer instead.)

**Accepted consequence (R15/D18):** undo history, trash, and register contents
written by the Python version become unreadable after the upgrade. There is no
migration path (md5 -> sha256, different trash naming). Accepted and documented
rather than migrated.

**B1 resolved as option 1 (version-gate legacy history).** Trigger: T-017
data-integrity review (blocking finding B1: Python-era `undo.log` with a
space-named paste line desyncs and `:DirectUndo` permanently deletes unrelated
files). Mechanism: Lua history owns `undo.log`/`redo.log`; first line must be
`#direct-history-v2`; logs without the marker are never executed — `WARN`
notify (`Ignoring history written by an older version`), quarantine by renaming
to `<name>.legacy` (or `<name>.legacy.<n>`), leave untouched on rename failure.
Result: D18 becomes factually true for history; undo history does not survive
the upgrade.

---

## 14. Auto-Forecast

- **estimated_scope**: `large`
- **affected_files**:
  - created: `LICENSE`, `plugin/direct.lua`, `ftplugin/direct.lua`,
    `lua/direct/{init,config,buffer,action,history,register,log,paths,fs,ui,health}.lua`
    (**11** modules), `tests/run.lua`, `tests/support/harness.lua`,
    `tests/fixtures/live_init.lua`, and **12** `tests/*_spec.lua` -- the 12
    listed in section 5, including `tests/health_spec.lua`, added by T-027 (N7)
  - modified: `README.md`, `doc/direct.txt`, `.gitignore`, `demo/util.vim`,
    `demo/yank_paste.vim`, `demo/*.vim`
  - removed: `plugin/direct.vim`, **`ftplugin/direct.vim`** (B7 -- both ftplugin
    variants are sourced when both exist, so the stale vimscript must go with the
    Python implementation; the replacement is `ftplugin/direct.lua`),
    `plugin/direct/` (7 files),
    `plugin/tests/` (8 files), `.venv`, `demo/demo/`, `demo/*.json` (**4**
    files: `create`, `delete`, `rename`, `yank_paste`) (N7)
  - net: about 40 files touched, roughly 1.6k-2.2k lines of new Lua + tests.
- **suggested_phases**: P0-P6 below (section 15 defines exactly seven phases,
  P0 through P6; the removal work is P6). Each phase ends with a runnable
  `nvim --headless -l tests/run.lua` and is independently reviewable.
- **gate results**:
  - **P2 (T-017): accepted — `pass_with_observations`, no blocking findings.**
    B1 (the persisted-history seam: a Python-era `undo.log` desyncs and
    `:DirectUndo` deletes unrelated files) is **closed** by the history
    version-gate (D18): logs are `#direct-history-v2`-marked, unmarked logs are
    never executed, and are quarantined as `<name>.legacy`. Two observations are
    carried forward as explicit later-phase items:
    - **P2-NB2 → P3 review item (T-023), must be resolved by P3.** PATH fields
      are not separator-validated: `entry_name_reason` guards **names**, not
      **paths**, so a tab inside a path desyncs the `NAME\tfield` framing. This
      is **not reachable at P2** (no buffer/sync writes absolute paths into a
      history line) but **becomes reachable in P3 buffer/sync**, where the sync
      boundary hands attacker/OS-chosen path strings to `action.serialize`. P3
      must resolve it: either validate and refuse separator or control
      characters in paths at the sync boundary, or make the framing itself safe
      (so a tab in a path cannot split a field).
    - **P2-NB6 → P6/T-036 confirmation item.** Until T-036 deletes
      `plugin/direct.vim` and `plugin/direct/`, a legacy Python writer could
      append an **UNMARKED** line into a **MARKED** Lua log. The version gate
      validates the first line only and therefore **cannot defend against a
      writer that appends to its own format**. Do not treat the marker as a
      defence while the Python plugin still ships; P6/T-036 confirms removal.

---

## 15. Task plan

Owner key: `D` = `developer`, `R` = `reviewer`.
Validation shorthand: `SUITE` = `nvim --headless -l tests/run.lua`,
`SUITE:<name>` = `nvim --headless -l tests/run.lua <name>`,
`LIVE` = section 11.4 manual smoke, `GREP` = section 11.5 static checks.

### P0 -- Scaffolding and test harness (blocks everything)

| ID | Owner | Description | Files | Deps | Acceptance | Validation |
|---|---|---|---|---|---|---|
| T-001 | D | Create the Lua skeleton: empty-but-requirable `lua/direct/*.lua` stubs for all **11** modules (N7), `plugin/direct.lua` and `ftplugin/direct.lua` registering nothing yet. Leave `syntax/direct.vim` untouched. | `lua/direct/*.lua`, `plugin/direct.lua`, `ftplugin/direct.lua` | - | `nvim --headless --clean -c "lua require('direct')" -c qa` exits 0; the **created** layout matches section 5, including exactly 11 `lua/direct/*.lua` files, `plugin/direct.lua`, and `ftplugin/direct.lua` (the files section 5 marks `(delete)` still exist here and are removed in P6/T-036) | `nvim --headless --clean -c "set rtp+=$PWD" -c "lua require('direct')" -c qa` |
| T-002 | D | Build `tests/run.lua` per the 11.1 boot sequence: rtp prepend + `runtime!` of plugin/ftplugin/syntax, **`vim.cmd('filetype plugin on')`** (`-l` boots with filetype plugins off), temp root from `vim.uv.fs_mkdtemp` resolved with **`vim.uv.fs_realpath`** (`vim.fs.realpath` does not exist), per-spec temp `XDG_DATA_HOME`, spec discovery + name filter, buffer/autocmd/option reset between specs, `ok/FAIL` reporting, non-zero exit on failure or uncaught error. Record that `v:vim_did_enter == 1` under `-l`, so `VimEnter` needs an explicit `nvim_exec_autocmds('VimEnter', {})` in the specs that depend on it. | `tests/run.lua` | T-001 | Running with no specs exits 0; a deliberately failing assertion exits 1; a probe spec confirms `filetype plugin on` was applied (an ftplugin in a temp rtp dir actually loads) | `SUITE`; `SUITE:nonexistent` exits 0 |
| T-003 | D | Build `tests/support/harness.lua`: `describe`/`it`/assertions, `sandbox()`, `mkfile`/`mkdir`/`ls`/`exists`/`inode_of`, `fs_snapshot`/`assert_fs_eq`, `buf_lines`/`assert_buf_eq`, `stub()`, `capture_messages`/`assert_notified`, `with_prompt`. | `tests/support/harness.lua` | T-002 | A smoke spec can assert buffer, filesystem, message, stub, and prompt oracles | `SUITE` with the smoke spec |
| T-004 | D | Prove the harness oracles against the temp layout: add a trivial `paths_spec` asserting `sandbox()` roots exist and `fs_snapshot` shape. | `tests/paths_spec.lua` | T-003 | `SUITE:paths` passes and reports 1 spec | `SUITE:paths` |
| T-005 | R | Review harness determinism, isolation (no `XDG_DATA_HOME` bleed, no leaked buffers/autocmds, temp cleanup), and zero-dependency compliance. | `tests/**` | T-004 | Written verdict; no blocking findings, or they are fixed before P1 | `SUITE` twice in a row gives identical output **after substituting the run's temp-root token** (the run-unique `direct-tests-*` / `direct-sandbox-*` root): raw stdout legitimately differs run-to-run because B15 `Yanked <abs>` carries an absolute run-unique path inside `vim.notify` text, while behavioural determinism — spec counts, pass/fail, action results — is exact |

### P1 -- Primitives (paths, fs, log, ui, config)

| ID | Owner | Description | Files | Deps | Acceptance | Validation |
|---|---|---|---|---|---|---|
| T-006 | D | `paths.lua`: `root()` = **`vim.fs.abspath(vim.fs.normalize(input))`** (reviewer B6 -- `vim.fs.normalize` alone does not absolutise, so a relative input must go through `vim.fs.abspath`), `data_home()` per B9 with the `stdpath` fallback warning, `data_dir()` with `mkdirp`, statelessness, `digest()` = `sha256` of NUL-joined paths, `basename` trailing-slash safety. | `lua/direct/paths.lua`, `tests/paths_spec.lua` | T-004 | `XDG_DATA_HOME` honoured; unset -> `$HOME/.local/share/direct`; both with neither -> warning + `stdpath`; digest matches a hand-computed sha256; **`paths_spec` asserts `root('.')`, `root('..')` and `root('a/b')` all return absolute paths**, and that the result denotes the same directory as a buffer name stored for it (`fs.same_path`, the B3 attach comparison -- **not** string equality, which B9 shows fails under a symlinked prefix) | `SUITE:paths` |
| T-007 | D | `fs.lua` per section 8: all primitives, `same_path` (ino+dev), `EXDEV` fallback in `rename`, recursive `copy_tree`, module-table self-calls so stubs work, never raises. | `lua/direct/fs.lua`, `tests/fs_spec.lua` | T-006 | Every function returns `true` or `nil, err`; stubbing `vim.uv.fs_rename` with an `EXDEV` error copies content and removes the source; a non-EXDEV error leaves the source intact | `SUITE:fs` |
| T-008 | D | `log.lua`: whole-file `push`/`pop`/`clear`, `nil` on empty, missing file treated as empty (no `E484`), no `E484` anywhere. | `lua/direct/log.lua`, `tests/log_spec.lua` | T-006 | push/pop round trip over 20 lines; popping the only line leaves an empty file; popping empty returns `nil` **silently, with no notify** -- the empty-pop notification is `history.undo`'s responsibility in P2 (T-015), not `log.pop`'s | `SUITE:log` |
| T-009 | D | `ui.lua`: `notify(msg, level)` via `vim.notify`, and `prompt()` wrapping `inputsave`/`input`/`inputrestore`, called through the module table so it is replaceable. | `lua/direct/ui.lua` | T-006 | `with_prompt` replaces it and no `vim.fn.input` call is made; default `prompt` still uses the three calls in order | `SUITE` (prompt spec in P2) |
| T-010 | D | `config.lua`: defaults (`map_default_keys = true`), `setup()` merge with unknown-key rejection, `install_mappings`/`clear_mappings`, deferred install on `VimEnter` (D10), idempotency. | `lua/direct/config.lua`, `tests/config_spec.lua` | T-009 | Two `setup()` calls converge; unknown key notifies; `VimEnter` installs exactly once | `SUITE:config` |
| T-011 | R | Review primitives against sections 7/8: no `vim.loop`, no bare `set`, no `stdpath('data')/direct`, `fnameescape` on every path-to-command conversion. | `lua/direct/{paths,fs,log,ui,config}.lua` | T-010 | Written verdict | `GREP` |

### P2 -- Actions, history, register

| ID | Owner | Description | Files | Deps | Acceptance | Validation |
|---|---|---|---|---|---|---|
| T-012 | D | `action.lua` single-entry actions: `Move`, `Remove`, `RemoveDirectory`, `Restore`, `RestoreDirectory`, `Touch`, `MakeDirectory`; trash naming with `-<n>` suffix (B10); close-src-buffer before destructive ops; human-readable descriptions. | `lua/direct/action.lua`, `tests/action_spec.lua` | T-007 | `Move` preserves `ino` for files and directories; remove/restore/remove produces two distinct trash entries with no nesting | `SUITE:action` |
| T-013 | D | `action.lua` multi-actions: `Paste`/`Unpaste` with sorted iteration, clash prompt via `ui.prompt`, empty answer skips and reports, file and recursive tree copy, last pasted entry returned. | `lua/direct/action.lua`, `tests/register_spec.lua` | T-012, T-009 | Scripted prompt `other.txt` renames without touching the original; empty answer leaves the original and skips; tree paste matches the source tree | `SUITE:register` |
| T-014 | D | `action.lua` serialisation: `NAME\tfield...` with `p`/`up` appending two separator-joined name lists, `deserialize`/`reverse` table covering every action including `Paste`->`Unpaste` renames swapping. | `lua/direct/action.lua`, `tests/action_spec.lua` | T-013 | Round trip `reverse(serialize(a))` yields the reversal with `src`/`dst` swapped and `renames` inverted, for all 9 action types | `SUITE:action` |
| T-015 | D | `history.lua`: `log`/`undo`/`redo` over `undo.log`/`redo.log`; empty-log notify -- `history.undo`/`redo` raise the `Nothing to undo`/`Nothing to redo` message themselves, because `log.pop` returns `nil` silently (T-008); failed reversal pushes the original line back (D13); `log` clears redo. | `lua/direct/history.lua`, `tests/history_spec.lua` | T-014, T-008 | Undo/redo round trip per action type; stubbed failing `fs.rename` keeps the undo entry and notifies; `log` after undo clears redo | `SUITE:history` |
| T-016 | D | `register.lua`: `yank` with sorted digest and trailing-slash-safe `basename`, replacing an existing entry of that name; `paste` delegating to `Paste` and logging history; `content` pointer; notify when the register is empty. Distinguish the two `:DirectPaste` forms (B7/N6): the **no-arg** form pastes into the buffer root **and re-lists**, the **`{dir}`** form pastes into `{dir}` and **does not re-list**. | `lua/direct/register.lua`, `tests/register_spec.lua` | T-013, T-015 | Yank a directory stores `dir1` (not `''`); digest stable across call orderings; `content` holds the absolute register path; empty register notifies; **`:DirectPaste` with no arg leaves the current buffer re-listed with the new entries, `:DirectPaste {other}` leaves the current buffer's lines byte-identical**; each yank emits one `Yanked <abs>` line (B15) | `SUITE:register` |
| T-017 | R | Review actions/history/register for data-integrity hazards: destructive defaults, history written only for succeeded actions, no orphan trash or temp entries. | `lua/direct/{action,history,register}.lua` | T-016 | Written verdict | `SUITE` |

### P3 -- Buffer and sync

| ID | Owner | Description | Files | Deps | Acceptance | Validation |
|---|---|---|---|---|---|---|
| T-018 | D | `buffer.lua` attach/create per B3 -- existing-buffer match by **path identity, not string equality** (`fs.same_path(nvim_buf_get_name(b), root)` over `nvim_list_bufs()`; **not** `nvim_buf_get_name(b) == root`, which fails under a symlinked prefix, and **not** `vim.fn.bufnr(root)`, which pattern-matches) and `paths.root()` absolutising -- plus listing per B1 + B13: `vim.fs.dir` + symlink resolution, broken/non-regular omission, `wildignore` via `glob(nosuf)` + `same_path`, dirs-then-files, option setting (D11). | `lua/direct/buffer.lua`, `tests/buffer_spec.lua` | T-007, T-006 | Listing cases from section 11.3 all pass, including symlinked dir as `name/` and broken symlink omitted; **given buffers for `<root>/nested/` and `<root>/a.txt`, `:DirectList <root>` selects the buffer for exactly `<root>` and not either of those (reviewer B2)**; **symlinked-root case (B9): a directory created under a symlinked prefix the spec builds itself and listed via the *unresolved* spelling reuses the existing buffer instead of creating a second one -- asserted explicitly, because 11.1 step 3 realpaths the harness root and would otherwise mask the defect** | `SUITE:buffer` |
| T-019 | D | `buffer.lua` current entry and cursor restore per B2 via `fs.same_path`. | `lua/direct/buffer.lua`, `tests/buffer_spec.lua` | T-018 | File entry, directory entry, missing entry (`nil`), and the cursor lands on the matching line | `SUITE:buffer` |
| T-020 | D | `buffer.lua` sync classification per B4: duplicate detection, ADD/DELETE/RENAME/AMBIGUOUS, deterministic ordering (D17), delete auto-yank. | `lua/direct/buffer.lua`, `tests/sync_spec.lua` | T-018, T-016 | Each class produces exactly the expected filesystem state and history lines; mixed and duplicated are ambiguous | `SUITE:sync` |
| T-021 | D | `buffer.lua` action application per B5: per-action error capture, history only for successes, always re-list, summary error; rename staging guard per B11/D3. | `lua/direct/buffer.lua`, `tests/sync_spec.lua` | T-020 | Swap and chain renames complete with no leftover `.direct-tmp-*`; a stubbed failing action leaves the others applied and undoable | `SUITE:sync` |
| T-022 | D | `buffer.lua` ambiguous handling per D4 (confirmed, OQ7 resolved) and `open`/`get_paths` per B8/D8b/D14. | `lua/direct/buffer.lua`, `tests/sync_spec.lua`, `tests/buffer_spec.lua` | T-021 | Ambiguous notifies with reason and both sides, writes nothing, stays modified; **after `<CR>` on a file the file buffer is the current buffer and the previous direct buffer is wiped** -- the observable property, asserted without reference to `E937` (N3: the `E937` premise is unverified on the target runtime and the guard is defence only); a name with a space opens correctly | `SUITE:sync`, `SUITE:buffer` |
| T-023 | R | Review buffer/sync against sections 7 B1-B5, B11, B13 and D4; confirm no path reaches `vim.fn.input` directly. | `lua/direct/buffer.lua` | T-022 | Written verdict | `SUITE`, `GREP` |

### P4 -- Entry points

| ID | Owner | Description | Files | Deps | Acceptance | Validation |
|---|---|---|---|---|---|---|
| T-024 | D | `init.lua` public API per section 6 with the non-direct-buffer guards and user-facing messages -- **including the one exemption**: `:DirectPaste {dir}` is not guarded, the no-arg form is. | `lua/direct/init.lua` | T-022, T-010 | Every API function is callable; `:DirectUndo` outside a direct buffer notifies and changes nothing; `:DirectPaste {dir}` works outside a direct buffer while `:DirectPaste` there notifies and changes nothing | `SUITE:entry` |
| T-025 | D | `plugin/direct.lua`: the 9 commands with the exact flags, netrw neutralisation at load and `VimEnter`, the **`BufEnter` intercept with the satisfiable predicate** (`has a name that resolves to an existing directory` AND `&filetype !=# 'direct'` -- no "has no name" clause, which would be unsatisfiable and dead, reviewer B1), and deferred mapping install (immediately under `-l`, where `v:vim_did_enter == 1`). | `plugin/direct.lua` | T-024 | Commands exist with expected `-nargs`/`-range`/`-complete`; `nvim_get_autocmds` shows the intercept registered; **the intercept actually converts a non-direct directory buffer to `filetype=direct` with the correct listing, so a dead predicate fails this task** | `SUITE:entry`, `SUITE:netrw` |
| T-026 | D | `ftplugin/direct.lua`: the **9** buffer-local mappings (8 `n`-mode + 1 `v`-mode, matching the ones the deleted `ftplugin/direct.vim` installed), `<Cmd>`-based, guarded by `map_default_keys`. | `ftplugin/direct.lua`, `tests/entry_spec.lua` | T-025 | Default: all nine buffer-local mappings (plus the global `-`) resolve to their commands; `map_default_keys=false`: none exist; **no mapping's rhs contains `direct#`** (the replacement is `ftplugin/direct.lua`, not the leftover vimscript). **Reachable only because T-002 ran `filetype plugin on`** -- under `-l` with filetype plugins off the ftplugin never loads and this would be vacuously green (reviewer B3). | `SUITE:entry` |
| T-027 | D | `health.lua`: `:checkhealth direct` reporting the Neovim version and the resolved data directory. | `lua/direct/health.lua`, `tests/health_spec.lua` | T-024 | `checkhealth direct` runs without error and reports both facts | `:checkhealth direct` under `--headless`, captured |
| T-028 | D | `netrw_spec.lua`: the R2 regression -- source `plugin/netrwPlugin.vim`, assert `FileExplorer` `BufEnter` autocmds exist, fire `VimEnter` **explicitly** via `nvim_exec_autocmds('VimEnter', {})` (under `-l` `VimEnter` never fires on its own), assert zero remain, `:edit <dir>` -> `filetype=direct` and correct lines; plus the CLI ordering case, plus the intercept-fires case (a non-direct directory buffer becomes `filetype=direct`, reviewer B1). | `tests/netrw_spec.lua` | T-025 | All three cases pass | `SUITE:netrw` |
| T-029 | D | `LIVE` evidence for D10 and the CLI half of D7: `tests/fixtures/live_init.lua` plus a recorded transcript. | `tests/fixtures/live_init.lua`, docs note | T-026, T-028 | Transcript shows `filetype=direct` from `:edit <dir>` and from `nvim <dir>/`, and `-` unmapped under `map_default_keys=false` | `LIVE` |
| T-030 | R | Review entry points against section 6: command flags, mapping completeness, netrw guarantee, mapping opt-out. | `plugin/direct.lua`, `ftplugin/direct.lua`, `lua/direct/init.lua` | T-029 | Written verdict | `SUITE`, `LIVE` transcript |

### P5 -- Documentation and licence

| ID | Owner | Description | Files | Deps | Acceptance | Validation |
|---|---|---|---|---|---|---|
| T-031 | D | `README.md` rewrite: Neovim >= 0.12, no Python, install, navigate, edit (rename/create/delete with the trailing-slash rule), undo/redo semantics, yank/paste, data directory, commands table, mappings table, and the D18 upgrade note. | `README.md` | T-030 | Acceptance criteria 18 | Manual read-through against `doc/direct.txt` |
| T-032 | D | `doc/direct.txt`: remove the `has('python')` requirement, add the 0.12 floor, document `setup()`, the commands/mappings tables, the data directory and the upgrade note; MIT licence section with a real tag. | `doc/direct.txt` | T-031 | `helptags doc` produces no errors; content matches README | `nvim --headless -c "helptags doc" -c qa` |
| T-033 | D | `LICENSE` (MIT, copyright line naming the author) and `.gitignore` update (drop `__pycache__`/`*.pyc`, keep `.cache`). | `LICENSE`, `.gitignore` | T-031 | Acceptance criteria 20 | Read the file |
| T-034 | D | Repair `demo/` to be Python-free **and** free of the retired Vimscript entry point: replace the `python << endOfPython` sleep in `util.vim` with `vim.uv.sleep` (measured: `vim.uv.sleep` is a function and sleeps synchronously); **`demo/yank_paste.vim:9` must be replaced by a mechanism that actually opens the entry** -- `demo/util.vim`'s `Input()` drives `execute "normal! "`, which both bypasses mappings *and* (the `!` form) does not translate `<>` notation, so `call Input("<CR>")` opens nothing (measured on `nvim 0.12.5`). Add a **mapped** helper to `demo/util.vim` -- `silent execute "normal " . a:characters`, i.e. `normal` **without** the `!`, invoked with a single-escaped key (`call Mapped("\<CR>")`) -- which does fire the buffer-local `<CR>` mapping (measured); `lua require('direct').open()` is an accepted equivalent. **RB-1:** no comment, helper name or doc line may contain the literal retired-call token, because AC17 forbids it anywhere in the repo and would fail this task's own acceptance; write "it used to call the Vimscript-era `open()` entry point directly" instead. Delete the stale `demo/demo/` tree and `demo/*.json`. **RN-5:** `.venv` is an 11-byte *file* at the repo root whose whole content is the line `direct.vim` -- a stale Python-setup artifact that is **removed** by T-036, not repaired here, and `demo/demo.sh` contains no `.venv` reference and needs no change, so it is not in this task's file list. | `demo/util.vim`, `demo/yank_paste.vim`, `demo/*.vim` | T-033 | The 11.5 `GREP` returns **no hits for the full AC17 pattern set** (`python3`, `python <<`, `has('python')`, `direct#`, `plugin/direct/`) -- "no Python references" alone is insufficient, because `demo/yank_paste.vim` contained a retired-call line with no Python on it. **Functional half (`manual_oracle`):** run the `yank_paste` demo once by hand (`demo.sh`'s `reset` to build the fixture, then `nvim -c 'source yank_paste.vim' -- demo`) and observe that it enters the `sub/` buffer -- the replacement must *open* the entry, not merely compile. Delete any `demo/demo/` and `demo/*.json` that this run regenerates before the task is closed. | `GREP`; one manual demo run |
| T-035 | R | Review docs against implemented behaviour -- every command, mapping, and documented promise must exist. | `README.md`, `doc/direct.txt`, `LICENSE` | T-034 | Written verdict | `SUITE`, `helptags` |

### P6 -- Removal of the Python implementation

| ID | Owner | Description | Files | Deps | Acceptance | Validation |
|---|---|---|---|---|---|---|
| T-036 | D | Delete the Python implementation, its tests, **and the stale vimscript ftplugin**: `plugin/direct.vim`, **`ftplugin/direct.vim`** (B7 -- Neovim sources `ftplugin/direct.vim` *and* `ftplugin/direct.lua` when both exist, so leaving the old file installs 9 `direct#` mappings that raise `E117` and keep AC17 unsatisfiable; the replacement is `ftplugin/direct.lua`, still 9 mappings per T-026), `plugin/direct/` (7 files), `plugin/tests/` (8 files), `.venv` (the 11-byte `direct.vim` file at the repo root, per T-034). | removed files | T-035 | `git status` shows the deletions; `ftplugin/direct.lua` still exists and `ftplugin/direct.vim` does not; no buffer-local mapping's rhs contains `direct#`; the plugin still loads and the suite still passes | `SUITE`, `T-001` smoke, `GREP` |
| T-037 | D | Repo-wide audit for Python-era residue: `python3`, `python <<`, `has('python')`, `direct#`, `plugin/direct/`, stale `__pycache__`, `xrange`, `vimmock`. Run it as the 11.5 command, which **excludes `docs/lua-migration-spec.md` and `docs/ai/**`** -- this spec necessarily quotes the patterns it retires, and so does any harness run report under `docs/ai/` that quotes the spec or the scan output, so an unexcluded scan can never pass and AC17 would be unsatisfiable (reviewer B5). | repo-wide | T-036 | `GREP` (with the `--glob '!docs/lua-migration-spec.md' --glob '!docs/ai/**'` exclusions) returns no hits anywhere in the repository; AC17 is therefore literally satisfiable | `GREP` |
| T-038 | R | Final review: full suite green, `helptags` clean, static checks clean, doc/impl consistency, no third-party runtimepath dependency. | repo-wide | T-037 | Written verdict with evidence for each acceptance criterion 1-20 | `SUITE`, `LIVE`, `GREP` |

---

## 16. Handoff packet

- **objective**: Lua-runtime, Neovim-only replacement for `direct.vim`, full
  parity plus the OQ3 fixes, Python removed, ported tests.
- **decisions locked**: D1-D20 in section 9; OQ1-OQ6 as given; OQ7 resolved
  (buffer stays modified, D4 confirmed). All decisions locked.
- **files read during specification**: `plugin/direct.vim`,
  `plugin/direct/{__init__,buffer,action,data,history,log,register}.py`,
  `plugin/tests/{conftest,utils,test_action,test_buffer,test_history,test_log,test_register}.py`,
  `ftplugin/direct.vim`, `syntax/direct.vim`, `doc/direct.txt`, `README.md`,
  `.gitignore`, `demo/{demo.sh,util.vim,yank_paste.vim}`, `.venv`.
- **facts verified on `nvim 0.12.5`** (section 2) rather than assumed: `-l`
  boots with `v:vim_did_enter == 1` and `filetype plugin:OFF`;
  `vim.fs.realpath` is nil while `vim.uv.fs_realpath` exists; `bufnr(root)`
  pattern-matches a nested buffer while an anchored `bufnr` does not;
  `nvim_exec_autocmds('VimEnter', {})` does fire registered autocmds;
  `vim.fs.abspath` exists; `exists('*mkdtemp') == 0` and calling the
  `vim.fn.mkdtemp` proxy raises `E117`; **both `ftplugin/<ft>.vim` and
  `ftplugin/<ft>.lua` are sourced when both exist (B7)**; **`nvim_buf_set_name`
  resolves a symlinked prefix (`/tmp/x` reads back `/private/tmp/x`) while
  `vim.fs.abspath` does not, so `nvim_buf_get_name(b) == root` is false there
  and ino+dev comparison is true (B9)**; **`nvim_buf_get_name` returns the
  resolved spelling while `bufname('%')` returns the unresolved one, and
  `bufnr()` pattern-matches the unresolved `bufname()` form -- anchored
  `bufnr('^<unresolved>$')` hits, `bufnr('^<resolved>$')` returns `-1` (RN-1)**;
  `vim.fs.same_path` is nil on this runtime (it is our own
  `direct.fs.same_path`); **`:normal!` bypasses mappings *and* does not
  translate `<>` notation, so `execute "normal! <CR>"` fires nothing while
  `execute "normal \<CR>"` does fire the buffer-local `<CR>` mapping, and a bare
  `nvim_feedkeys(k, 'm')` fires nothing until the typeahead is flushed
  (RB-2)**; **`vim.uv.sleep` exists and sleeps synchronously**; `.venv` is an
  11-byte *file* containing the single line `direct.vim`, and `demo/demo.sh`
  contains no `.venv` reference (RN-5).
- **claims corrected by re-measurement** (N2, N3, RN-1, RB-2): `glob` under a
  symlinked `/tmp` **does** return matches; the `E937` on `bwipeout!` **does not**
  reproduce with `buftype=acwrite`; the B3 spelling rationale named the wrong
  accessor; and T-034's original `Input("<CR>")` prescription was unworkable. All
  are now specified as hardening / defence or as a corrected mechanism, never as
  reproduced-bug fixes or as an unverified recipe.
- **validation state**: no implementation exists yet; the harness design is
  validated against the real runtime (rtp behaviour, netrw autocmds, `sha256`
  arity, `readfile` `E484`, `basename` trailing slash, filetype-off boot,
  `realpath` location, `bufnr` matching semantics, dual ftplugin sourcing,
  `mkdtemp` absence, the symlink-spelling divergence behind B9, the
  `bufname`/`nvim_buf_get_name`/`bufnr` spelling split behind RN-1, and the
  `:normal` vs `:normal!` mapping behaviour behind RB-2).
- **blockers**: none. OQ7 is resolved; T-022's assertion is unblocked.
- **next action**: delegate P0 to `developer`.
