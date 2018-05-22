# direct.vim

Edit directories in vim.

This plugin allows you to directly edit the filesystem. It does this by
treating directories as if they were files, with each line corresponding to a
file or directory. This allows you to:

- navigate around the filesytem easily
- rename, create and delete files and directories
- yank and paste files and directories
- undo and redo every change that you make to the filesystem

## Navigate

By default, the `-` key is bound to display the parent directory of the current
buffer (or the working directory if no buffer is open). Or, use the `:edit
foo/` command to open a directory.

Once you are viewing a directory you can go to its parent directory by pressing
`-`, or open a directory or file by pressing `<Enter>`.

## Edit

When viewing a directory, you can edit the listing of files and directories as
if you were editing a file, and your changes will be synchronised to the
filesystem.

### Rename

To rename files or directories, edit the lines and save the buffer. You can use
any vim commands to edit the line(s) to what you want them to be.  Directories
must always have a trailing slash however, otherwise they will be interpreted
as files.

### Create

To create files or directories, add new lines to the buffer at any location,
and save the buffer. To create a directory, the line must end in a trailing
slash, otherwise a file will be created.

### Delete

To delete files or directory, delete lines and save the buffer.

### Undo / Redo

When viewing a directory, the undo (`u`) and redo (`<C-r>`) mappings will undo
and redo any changes you made to the filesystem.

### Yank / Paste

When viewing ta directory any yank commands that operate on a full line (`yy`
and `Y`) will yank the file or directory to a register. 


Pasting (`p` and `P`) will paste the yanked file or directory into the current
directory. 


There is undo and redo support for these too, as well as prompting to overwrite
or rename in case of name clashes.


When yanking a directory, any contained files and direcoried are also
recursively yanked.
