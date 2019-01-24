# direct.vim

Edit directories in vim.

Load up a directory in vim and edit files and subirectorie using normal vim
commands. No need to remember extra commands or keybindings. 

It does this by loading a directories into a buffer, with each line
corresponding to a file or directory. You can then edit the buffer to make
whatever changes you like to your files and directories and, when you save the
buffer, your changes are synchronised with the filesystem.

- navigate around the filesytem easily
- rename, create and delete files and directories
- yank and paste files and directories
- full undo and redo history for every change that you make to the filesystem

## Navigate

By default, the `-` key is bound to display the parent directory of the current
buffer (or the working directory if no buffer is open). Or, use the `:edit
foo/` command to open a directory.

Once you are viewing a directory you can go to its parent directory by pressing
`-`, or open a directory or file by pressing `<Enter>`.

## Edit

When viewing a directory, you can edit the listing of files and directories as
if you were editing a file, and your changes will be synchronised to the
filesystem. You can use whatever vim commands you like to edit the buffer, and
changes will be written when the buffer is saved.

### Rename

To rename files or directories, edit the line corresponding to the file or
directory you want to rename, and save the buffer. Directories must always have
a trailing slash however, otherwise they will be interpreted as files.

### Create

To create files or directories, add new lines to the buffer at any location,
and save the buffer. To create a directory, the line must end in a trailing
slash, otherwise a file will be created.

### Delete

To delete files or directory, delete the lines corresponding to the files or
directories you want to delete, and save the buffer.

### Undo / Redo

When viewing a directory, the undo (`u`) and redo (`<C-r>`) mappings will undo
and redo any changes you made to the filesystem.

### Yank / Paste

When viewing ta directory any yank commands that operate on a full line (`yy`
and `Y`) will yank the file or directory to a register. Any deleted files or
direcotries are automatically yanked, as when deleting text in vim.


Pasting (`p` and `P`) will paste the yanked file or directory into the current
directory. 


There is undo and redo support for these too, as well as prompting to overwrite
or rename in case of name clashes.


Directories are yanked recursively so that you can yank and paste directory
trees around the filesystem.

## Install 

Install using your favourite package manager.

### Plug

```
Plug '987poiuytrewq/direct.vim'
```
