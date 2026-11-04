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
their `Comment` defaults. When icons are enabled, hidden directory and file icons
also use the `Comment` style; visible directory and file icons retain their
`Directory` and `Normal` defaults. Listing files receive no filename-,
filetype-, or special-name-derived highlights; Git status styling is described below.

Direct loads its listing syntax locally, including when Neovim's global syntax
loader is disabled.

The hidden icon groups are `DirectHiddenFolderIcon` and `DirectHiddenFileIcon`;
both link to `Comment` by default and can be overridden independently.

Git-deleted tracked entries use `DirectGitDeletedFile` and
`DirectGitDeletedDirectory` for their names; both link to `ErrorMsg` by default.

Highlight defaults are user-overridable and are reapplied after a `ColorScheme`
event.

## Requirements

- Neovim >= 0.12
- No Python: the plugin is pure Lua. Git is needed for Git status and Git-ignore
  features.

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

Other package managers work too. For example, with
[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug '987poiuytrewq/direct.vim'
```

## Quick start

Open a directory with `nvim .` or `:DirectList path/to/directory`.

Default keys:

- `<Enter>` opens the file or directory under the cursor.
- `-` goes to the parent directory.
- `zo` expands a directory in place.
- `gh` shows or hides dotfiles.
- `gi` toggles Git-ignore filtering.
- `gs` shows only entries with a Git status; press it again to restore the listing.

Edit the listing to rename, create, or delete entries, then save with `:write`.
Directory names end in the platform's filesystem separator by default; file
names do not. At the root level, save one kind of change at a time. `yy` yanks
the entry under the cursor and `p` pastes it.

| To… | Edit the listing |
|---|---|
| Rename | Change an existing name, e.g. `old.txt` to `new.txt` |
| Create | Add a line, e.g. `notes.md` or `reports/2026/summary.md` |
| Delete | Remove the line |

Save with `:write` to apply your change. Directory names must end in the
configured directory separator (such as `archive/` on POSIX or `archive\\` on
Windows); file names must not. At the root level, save one kind of change at a
time—create, rename, or delete. A new relative path may contain the platform's
separator; Direct creates missing parent directories. Absolute paths, empty
path components, and `.` or `..` components are refused; the final separator
remains the directory marker.
After saving a nested path, Direct expands its parent directories and moves the
cursor to the last added entry. If Direct can't tell what you meant, it refuses
the save and leaves the filesystem unchanged.

## Setup

`setup()` is optional; the defaults apply when you never call it.

```lua
require('direct').setup({
  directory_separator = package.config:sub(1, 1), -- '/' or '\\'; defaults to the filesystem separator
  map_default_keys = true, -- set false to install no default mappings
  show_hidden = true, -- set false to hide dot-prefixed entries
  respect_gitignore = true, -- set false to show Git-ignored entries
  show_folder_icons = true, -- show Font Awesome folder icons
  show_file_icons = true, -- show a generic Font Awesome file icon
  icons = {
    file = '\u{f15b}',
    folder = '\u{f07b}',
    folder_open = '\u{f07c}',
    deleted_file = '\u{f016}',
    deleted_folder = '\u{f114}',
    deleted_folder_open = '\u{f115}',
  },
  max_recursive_expand_depth = false, -- false means unlimited
  git = { enabled = true, show_symbols = true, show_deleted = true },
})
```

It is idempotent, may be called more than once, and reports an unknown option
name as an error instead of silently ignoring it.

Dot-prefixed files and directories are visible by default. Set
`show_hidden = false` to hide them; `:DirectToggleHidden` (also mapped to `gh`)
switches the current direct buffer's view. The toggle is refused while the
listing has unsaved edits. It refreshes from disk and collapses expanded
subtrees so every visible level uses the same setting.

Git-ignore filtering is enabled by default. Set `respect_gitignore = false` to
show ignored entries; `:DirectToggleGitIgnore` (also mapped to `gi`) switches
the current direct buffer's view. Like the hidden-entry toggle, it refuses
unsaved edits and refreshes the listing, collapsing expanded subtrees.

In a direct listing, `gs` (or `:DirectToggleGitStatus`) toggles a view that shows
only entries with a Git status and expands all directories recursively. Use
`:DirectGitStatus` to enter that view without toggling it off when already there.
Directories with changed descendants are included, and their children are
filtered the same way. These commands are refused while the listing has unsaved
edits. Outside a Git repository, or with `git.enabled = false`, the filtered
view is empty. Hidden entries remain excluded from sync while this view is
active; they are not treated as deletions.

Configuration defaults:

| Option | Default | Description |
|---|---|---|
| `map_default_keys` | `true` | Install Direct's default key mappings. |
| `show_hidden` | `true` | Show dotfiles; `gh` toggles visibility in a listing. |
| `respect_gitignore` | `true` | Apply Git ignore rules to listings; tracked files remain visible. `gi` toggles the current view. |
| `show_folder_icons` | `true` | Show folder icons. |
| `show_file_icons` | `true` | Show generic file icons. |
| `icons.file` | U+F15B | Font Awesome file glyph. |
| `icons.folder` | U+F07B | Font Awesome folder glyph. |
| `icons.folder_open` | U+F07C | Font Awesome open-folder glyph. |
| `icons.deleted_file` | U+F016 | Outlined file glyph for deleted rows. |
| `icons.deleted_folder` | U+F114 | Outlined folder glyph for deleted rows. |
| `icons.deleted_folder_open` | U+F115 | Outlined open-folder glyph for expanded deleted rows. |
| `max_recursive_expand_depth` | `false` | Positive integer limit for recursive expansion; `false` is unlimited. |
| `git.enabled` | `true` | Enable Git status data and worktree filename/icon colors. |
| `git.show_symbols` | `true` | Show the right-aligned Git status symbols. |
| `git.show_deleted` | `true` | Show synthetic rows for tracked deletions when Git status is enabled. |
| `git.symbols` | Neo-tree defaults | Configure status and stage glyphs shown at the right of each row. |

For complete command, safety, and data/history documentation, see `:help direct.vim`.
Run `:checkhealth direct` to check the Neovim version and data directory.

### File and folder icons

Set `show_folder_icons = false` to hide inline directory glyphs, and
`show_file_icons = false` to hide generic file icons; both default to `true`.
A Font Awesome Nerd Font is required to render them. Collapsed directories use
`nf-fa-folder` (U+F07B), expanded directories use `nf-fa-folder-open` (U+F07C),
and files use `nf-fa-file` (U+F15B), regardless of filetype. When only one kind
of icon is enabled, the other kind reserves a blank icon slot so entry names
stay aligned. Icons are virtual text, so the listing lines and filesystem
behavior are unchanged. No icon plugin or other dependency is required.
Deleted tracked rows use the regular-outline `nf-fa-file-o` and
`nf-fa-folder-o` glyphs; expanded deleted folders use `nf-fa-folder-open-o`.
Set `icons.file`, `icons.folder`, `icons.folder_open`, and the `deleted_*`
variants to customize every file and folder glyph. Git status colors filenames
and icons to match the first (leftmost) status symbol: the index status when
present, otherwise the worktree status.
Highlight groups can be customized in your colorscheme or with
`vim.api.nvim_set_hl()`.
With folder icons enabled, click an icon to expand or collapse that directory in
place; mouse input must be enabled in Neovim (for example, `:set mouse=a`).

### Git status

In a Git repository, Direct reads porcelain status once per listing refresh and
shows a Neo-tree-style status component, right-aligned at the end of each row.
The component is virtual text: it does not change the editable listing lines.
Its two status slots are separated by one space.
Set `git.show_symbols = false` to hide the component while keeping filename and
icon colors. Those colors match the first (leftmost) status symbol, using the
index status when present and otherwise the worktree status.
`git.show_symbols` defaults to `true`. `T` is normalized to `M`;
untracked `??` maps to `_A` and uses the added symbol. Ignored `!!` entries use
the ignored symbol.

The default glyphs are `` added, `` modified, `` deleted, `` renamed,
`` ignored, `` staged, and `` conflict. A staged-only change shows its type
glyph and the staged check; a worktree-only change has a blank second slot. When
both porcelain columns have changes, both change-type glyphs are shown. Untracked
`??` displays the added glyph followed by a blank slot. Copies use the added
glyph, matching Neo-tree's status component. Directories aggregate changed
descendants independently in the index and worktree columns. Re-list to refresh
Git status.

The status component is right-aligned in the window. Very long row text may leave
less room for it. Missing tracked files and directories containing deleted
tracked descendants appear as protected rows. Their names use the same color as
the first status symbol, including staged-only tombstones. Set
`git.show_deleted = false` to hide these synthetic
rows while retaining Git status on entries that still exist. This option has no
effect when Git status is disabled; it defaults to `true`.

Press `gs` or run `:DirectToggleGitStatus` to show only entries with a status and
recursively expand the view; press it again to restore the normal listing. Use
`:DirectGitStatus` to enter the filtered view without toggling it off when
already active. Directories inherit status from changed descendants. This is a
view filter, so entries it hides are not treated as deletion sources during sync.
Outside a Git repository, or when `git.enabled = false`, the filtered view
contains no entries.

The symbols can be customized independently by status:

```lua
require('direct').setup({
  git = {
    symbols = {
      added = "+",
      deleted = "-",
      modified = "~",
      renamed = ">",
      ignored = "i",
      staged = "✓",
      conflict = "!",
    },
  },
})
```

Symbols can be set to an empty string to hide that marker. The status highlight
groups link to `DiffAdd`, `DiffDelete`, `DiffChange`, `ErrorMsg`, and `Comment`
by default, so they follow the colorscheme. Override the `DirectGit*` groups to
customize them. Deleted rows can
be targeted by `:DirectRun`, expanded and collapsed with the `z` commands, and
staged/reset/restored with `ga`, `gr`, and `gc`. Other listing edits, opens,
yanks, and pastes on those rows are ignored.

## Run shell and Git commands

In a Direct listing, `:DirectRun {command}` runs asynchronously from the listing
directory. Each `{}` is replaced by the shell-escaped absolute path of the
current entry. Leave `{}` unquoted so paths containing spaces or shell
metacharacters remain one argument. Captured output and exit status are reported
when the command finishes. The current row must name an existing entry, except
for a tracked Git-deleted row, which can be targeted to restore or stage it.
`DirectRun` does not refresh Git status.

Use `:DirectGit {command}` for a Git command that should also refresh the status
decorations in the originating loaded listing when it completes. It uses the
same placeholder behavior as `DirectRun`, and refreshes without re-listing or
changing buffer text. Successful Git commands are quiet; failures report their
exit status and captured output.
The default `ga`, `gr`, and `gc` mappings run `git add -- {}`, `git reset -- {}`,
and `git checkout -- {}` for the current entry through `:DirectGit`.

Git ignore filtering is separate from status display and is on by default. Set
`respect_gitignore = false` to show ignored entries. Press `gi` or run
`:DirectToggleGitIgnore` to toggle filtering in the current listing. When enabled,
Direct uses Git itself to apply root and nested
`.gitignore` files, negations, anchoring, escaped patterns, `.git/info/exclude`,
and the configured global excludes file. Tracked files remain visible, and a
directory containing tracked descendants remains visible. Outside a repository
this filter has no effect. Git must be available when the option is enabled; if
an ignore query fails in a detected repository, the listing fails closed rather
than guessing. Changing an effective ignore source or tracked index membership
after a listing makes sync refuse before filesystem or history effects; re-list
to accept the new state. The rule snapshot is intentionally conservative: it
currently walks the full repository to fingerprint ignore sources, so large
trees incur a full-tree scan when listing or validating sync. A change to a
nested repository's ignore source can require a re-list even when that source
did not affect this view.

## Navigate

In normal mode, `-` lists the directory of the current file, or the working
directory when the buffer is not tied to one (a buffer with no file name, or a
non-empty `&buftype` such as a direct listing). You can also open a directory
with `:edit foo/` or by starting Neovim on it.

Once a directory is listed, `-` goes up to its parent directory and `<Enter>`
opens the entry under the cursor. Double-clicking any entry does the same: a
directory opens a new listing, and a file opens the file.

Use `zo` or `za` on a directory to expand it in place. Children are read lazily,
one level at a time; repeating an expansion does not re-read or duplicate them.
`zO` and `zA` recursively expand a directory, while `zC` recursively collapses
it. `zR` expands all root directories and `zM` collapses them all. Recursive
expansion is unlimited by default; set `max_recursive_expand_depth` to a positive
integer to cap how many directory levels those recursive-open commands (including
`:DirectUnfoldAll`) expand.
The limit does not affect one-level `zo`/`za` browsing. `za` or `zc` on an
expanded directory removes its child rows; expanding again re-reads the
directory. The initial listing remains flat.

Use `:DirectUnfoldAll` to recursively expand all directories in the listing and
`:DirectFoldAll` to collapse them all; these are the command-line equivalents of
`zR` and `zM`.

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

### The directory-separator rule

A directory must always be written with a trailing configured separator, and a
file must never have one: the line, not the filesystem, decides what will be
created or renamed. By default, the marker is the platform's filesystem
separator; `directory_separator` can override it with `/` or `\\`. The selected
marker is reserved inside entry names, so names containing it are omitted from
the editable listing to avoid ambiguity.

At the root level, an edit that both adds and deletes entries, or that leaves a
duplicated line, is reported as ambiguous, naming both sides of the comparison.
Nothing is changed, no history is written, and the buffer stays modified so you
can fix it.

`&wildignore`, dot-hidden visibility, Git-ignore filtering, and the `gs`
Git-status-only view are independent; entries hidden by any active filter are
omitted. `&wildignore` keeps its existing behavior.
Each directory captures the filter settings and matches used for that listing.
Changing an option does not rewrite an existing listing's sync rules; re-list to
refresh them. Filtered entries are excluded from sync, and sync is refused before
filesystem or history effects if an add/rename would use an occupied filtered
path or a directory move would carry a filtered descendant or an entry the
listing cannot represent, such as a dangling symlink or FIFO. Newly appearing
entries matching the captured filters are not treated as delete sources.
Directory-only `&wildignore` patterns such as `cache/` also protect matching
nested directories. Directory symlinks are treated as leaves when renamed; their
targets are not scanned or moved.

### LSP workspace file operations

Direct sends `workspace/didCreateFiles`, `workspace/didRenameFiles`, and
`workspace/didDeleteFiles` after successful filesystem changes when a running
workspace client advertises the corresponding `workspace.fileOperations`
capability. For renames it also sends the `workspace/willRenameFiles` request
before staging or changing paths, and applies returned WorkspaceEdits in stable
client-ID order. Clients are selected by workspace coverage (not by attachment
to the direct listing buffer); advertised file/folder and glob filters are
honoured where Neovim exposes them. Paths are sent as `file:` URIs.

`willRenameFiles` is asynchronous: `:write` returns while requests are pending,
and the listing remains modified and guarded until the callback completes. Other
direct filesystem operations are refused during that interval. A server error or
timeout warns and the rename proceeds without that server's edit. If applying a
returned edit fails, the rename is refused; edits applied by earlier clients may
already be present. Direct then revalidates the listing and filesystem snapshots
before it performs its own changes.

Post-operation notifications describe only logical workspace paths whose
filesystem effects succeeded, including paste and undo/redo reversals. Trash,
register, staging, temporary, marker, and quarantine paths are never reported;
yank alone does not emit a file-operation event. Servers that do not advertise
the relevant capability receive no file-operation requests or notifications.

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

Expansion and collapse remain ordinary text-undo changes. `:undo` after a
collapse restores the child rows and their identities; `:redo` re-applies the
collapse. Redo restores materialized identities only when the original undo
sequence and exact directory snapshot still match. A changed or ambiguous
snapshot remains unsafe to save, open, or yank.
Entry names beginning with whitespace and names that could escape the listed
directory (such as `../x` or `a/b`) are refused at save time.

Windows-specific component checks reject backslashes, drive prefixes, and
reserved device names. Native Windows filesystem traversal has not been
verified; this documentation does not claim Windows support.

### Undo / Redo

In a direct buffer, `u` and `<C-r>` undo and redo filesystem actions. The
`:DirectUndo` and `:DirectRedo` commands do the same; `:DirectUndo` right after a
paste, for example, undoes the paste. Use `:undo` and `:redo` for Neovim text
changes in the listing.

Text undo only reverses buffer-line changes; it never renames, creates, deletes,
or restores anything on disk. Only filesystem undo reverses a filesystem action.

## Yank / Paste

`yy` and `Y` yank the file or directory on the current line, and a visual `y`
yanks the selected range. `p` and `P` paste the yanked entries into the
directory under the cursor, or into the parent directory when the cursor is on
a file. This also works on entries shown inside expanded directories. Directories
are yanked recursively, so you can copy directory trees around the filesystem.

If an entry with the same name already exists, you are prompted
(`File already exists. Paste as: `, or `Directory ...`) and can paste it under
another name; an empty answer skips that entry and leaves the original
untouched.

Yank and paste share the undo/redo history, so they can be undone like any other
filesystem change.

Undoing a paste first verifies each pasted file, directory tree, or symlink
against the current register copy. If any target is missing, changed, unreadable,
or the register has been changed by another yank, the whole Unpaste is refused
and the history entry is retained. Matching entries are atomically moved to
same-directory `.direct-unpaste-*` quarantine paths and checked again before any
are removed. If capture fails, Direct restores captured entries without
overwriting new occupants; blocked quarantines are reported for manual recovery.
Deletion acts on the captured quarantine paths, never on the original paste
names, so a new object appearing at an original name is left alone. A crash or
failure during deletion can leave quarantine debris, and an identical-content
replacement cannot be distinguished from the original paste. Open file handles
and competing same-user processes can still race content checks; there is no
filesystem snapshot or inter-process lock.

Paste name clashes use Neovim's callback-based `vim.ui.input`; there is no
synchronous prompt fallback. Cancel, an empty answer, or an invalid name skips
that entry. Answers that still clash are retried up to ten times. Entries copied
before a later skip or error are retained and recorded; if every entry is
skipped, no history action or success notice is produced. While a prompt is
pending, sync, paste, undo, and redo are refused. History writes and listing
refresh happen only after the callback flow completes. Grouped moves continue to
use their existing synchronous staging path.

## Commands

| Command | Arguments | Description |
|---|---|---|
| `:DirectList {dir}` | `{dir}`, `dir` completion | List `{dir}` in a direct buffer. |
| `:DirectListBuffer` | none | List the directory of the current file, or the working directory when the buffer is not tied to one (no file name, or a non-empty `&buftype`). |
| `:DirectListCwd` | none | List the current working directory. |
| `:DirectSync` | none | Classify and apply the current direct buffer's edits; also runs on `:write` in a direct buffer. |
| `:DirectFoldAll` | none | Collapse all expanded directories in the current listing. |
| `:DirectUnfoldAll` | none | Recursively expand all directories in the current listing. |
| `:DirectToggleHidden` | none | Toggle dot-hidden entries in the current direct listing and refresh its view. |
| `:DirectToggleGitIgnore` | none | Toggle Git-ignore filtering in the current direct listing. |
| `:DirectToggleGitStatus` | none | Toggle the Git-status-only view in the current direct listing. |
| `:DirectGitStatus` | none | Enter the expanded Git-status-only view without toggling it off. |
| `:DirectUndo` | none | Undo the last filesystem action. |
| `:DirectRedo` | none | Redo the last undone action. |
| `:DirectYank` | range (default: current line) | Yank the ranged entries. |
| `:DirectPaste [dir]` | optional `{dir}` (directory completion) | With no argument, paste into the directory under the cursor (or a file's parent) and refresh the listing; with `{dir}`, paste there without touching the current buffer. |
| `:DirectPasteAs {name}` | `{name}` | Paste into the cursor row's directory (or a file's parent) under `{name}`. |

`:DirectSync`, `:DirectFoldAll`, `:DirectUnfoldAll`, `:DirectToggleHidden`,
`:DirectToggleGitIgnore`, `:DirectToggleGitStatus`, `:DirectGitStatus`, `:DirectUndo`, `:DirectRedo`, `:DirectYank`, `:DirectPaste` (no argument),
`:DirectPasteAs`, `:DirectRun`, and the public `open()` API report an error and do
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

Buffer-local, in a direct buffer (all mappings follow `map_default_keys`):

| Mode | Key | Action |
|---|---|---|
| normal | `<CR>` | open the entry under the cursor |
| normal | `zo` | lazily expand one directory level |
| normal | `za` | expand or collapse one directory |
| normal | `zc` | collapse one directory |
| normal | `zO` | recursively expand the directory under the cursor |
| normal | `zA` | recursively expand or collapse the directory under the cursor |
| normal | `zC` | recursively collapse the directory under the cursor |
| normal | `zR` | recursively expand all directories (`:DirectUnfoldAll`) |
| normal | `zM` | collapse all directories (`:DirectFoldAll`) |
| normal | `[d` | jump to the previous visible directory row |
| normal | `]d` | jump to the next visible directory row |
| normal | `-` | open `../` (the parent directory) |
| normal | `u` | undo the last filesystem operation |
| normal | `<C-r>` | redo the last filesystem operation |
| normal | `yy`, `Y` | `:DirectYank` (current line) |
| visual | `y` | `:DirectYank` (selected range) |
| normal | `p`, `P` | `:DirectPaste` |
| normal | `gh` | `:DirectToggleHidden` |
| normal | `gi` | `:DirectToggleGitIgnore` |
| normal | `ga` | `:DirectGit git add -- {}` |
| normal | `gr` | `:DirectGit git reset -- {}` |
| normal | `gc` | `:DirectGit git checkout -- {}` |
| normal | `gs` | `:DirectToggleGitStatus` |

The buffer-local `-` wins over the global `-` inside a direct buffer. All
buffer-local mappings, including fold and mouse mappings, are omitted when
`map_default_keys` is false.
`[d` and `]d` include nested directories shown in expanded subtrees, skip
collapsed descendants, and move the cursor without changing expansion state.

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

Filesystem destinations are placed with atomic no-replace operations. On Darwin
and Linux, direct uses the platform's exclusive rename primitive; unsupported
platforms or filesystems fail closed. `touch` uses exclusive file creation and
directory creation refuses an existing path. For cross-device moves, files are
copied to an exclusive temporary file and directories to a private temporary
tree in the destination parent before no-replace placement. Symlinks are
recreated without following them; FIFO, socket, and device sources are refused.
If a destination commits but the source cannot be removed, direct reports both
paths, keeps the completed destination in history, and may leave two copies.
Before removing an EXDEV source, direct atomically captures it in a private
temporary directory beside the source and compares the copied file bytes or
directory contents and symlink targets. If it changed or cannot be verified,
direct restores it with no-replace or preserves and reports its exact temporary
path instead of deleting newer data. A crash in that brief capture/verify/remove
window can leave a `.direct-exdev-source-*` recovery directory. Concurrent
writers can still change open files after comparison; there is no filesystem
snapshot or inter-process lock. The final destination rename is atomic
no-replace, but source/temp inode checks and cleanup remain pathname operations.
A same-user process can race a replacement after a check; in that narrow window
direct may preserve and report a stranded temp or quarantine path for manual
recovery. Network filesystems and unsupported filesystem semantics are not
guaranteed.

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
