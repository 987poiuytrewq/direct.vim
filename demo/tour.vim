" The headless version of the tour that drive.expect records. Keep the two in
" step: each section here matches a section there.
let v:errmsg = ''
execute 'source ' . fnameescape($DIRECT_DEMO_SCRIPT_DIR . '/util.vim')

" 1. The project listing: icons, Git status, and no ignored files.
call Caption('direct.vim: edit your filesystem like a buffer')
call Pause(1800)

" 2. Browse a project as a tree.
call Caption('Browse a project as a tree, with Git status')
call DemoFind('^lua/$')
call Mapped('zo')
call Input('j')
call Mapped('zo')
call WaitFor('utils.lua')

" 3. Rename one file by editing its name.
call Caption('Rename a file by editing its name')
call DemoFind('utils\.lua$')
call Input('cwstrings')
write
call WaitFor('strings.lua')

" 4. Rename several files with :s.
call Caption('Rename many at once, with any Vim command')
call DemoFind('^tests/$')
call Mapped('zo')
call WaitFor('config_test.lua')
%s/_test/_spec/
write
call WaitFor('config_spec.lua')
call Mapped('zM')
call WaitFor('config_spec.lua', 0)

" 5. Create a file, with its parent folders.
call Caption('Add a line to create a file, parent folders included')
call Input('Go' . 'docs/guide/getting-started.md')
write
call WaitFor('getting-started.md')

" 6-8. Delete a file, undo the deletion on disk, then redo it.
call Caption('Delete a line to delete the file')
call DemoFind('scratch\.txt$')
call Input('dd')
write
call WaitFor('scratch.txt', 0)
call Caption('Changed your mind? u undoes it on disk')
call Mapped('u')
call WaitFor('scratch.txt')
call Caption('...and Ctrl-r redoes it')
call Mapped("\<C-r>")
call WaitFor('scratch.txt', 0)

" 9. Copy a folder. Pasting next to the original asks for a new name. The
" recording types the answer into the prompt; headless, answer it directly.
call Mapped('zM')
call Caption('Copy whole folders with yy and p')
call DemoFind('^examples/$')
call Mapped('zo')
call Input('j')
call Mapped('yy')
call Input('k')
lua _G.demo_ui_input = vim.ui.input
lua vim.ui.input = function(_, on_confirm) on_confirm('advanced') end
call Mapped('p')
call WaitFor('advanced/')
lua vim.ui.input = _G.demo_ui_input

" 10-11. Git: show only what changed, then stage a file.
call Mapped('zM')
call Caption('gs shows only what changed')
call Mapped('gs')
call WaitFor('getting-started.md')
call Caption('ga stages a file, gr unstages it')
call DemoFind('README\.md$')
call Mapped('ga')
call luaeval('vim.wait(5000, function() return vim.fn.system({"git", "diff", "--cached", "--name-only"}):find("README.md", 1, true) ~= nil end, 50)')

" 12. Back to the full listing.
call Caption(':help direct.vim')
call Mapped('gs')
call WaitFor('LICENSE')
call Pause(1500)

call DemoFinish()
