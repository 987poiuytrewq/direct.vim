let v:errmsg = ''
execute 'source ' . fnameescape($DIRECT_DEMO_SCRIPT_DIR . '/util.vim')

" The root listing is a simple menu of the three demo sections.
call Pause(1800)

" Section 1: rename, save, then use u/C-r for filesystem undo/redo.
call DemoFind('01-file-edits/$')
call Mapped("\<CR>")
call Pause(1200)

" Dotfiles and dot-directories are visible; expand the hidden folder in place.
call DemoFind('\.demo-settings/$')
call Mapped('zo')
call Pause()
call DemoFind('\.demo-settings/$')
call Mapped('zc')
call Pause()

call DemoFind('rename-me.txt$')
call Type('c$', 'A', 'renamed-file.txt')
write
call Pause()
call Mapped('u')
call Pause()
call Mapped("\<C-r>")
call Pause()
call Input('G')
call Input('o')
call Type('c$', 'A', 'created-folder/')
write
call Pause()
call Input('G')
call Input('o')
call Type('c$', 'A', 'created-file.txt')
write
call Pause()
call DemoFind('delete-me.txt$')
call Input('dd')
write
call Pause()
call Mapped('u')
call Pause()
call Mapped("\<C-r>")
call Pause()
call Mapped('-')
call Pause()

" Section 2: expand a folder and move its child to the parent with <<.
call DemoFind('02-browse-and-move/$')
call Mapped("\<CR>")
call Pause(1200)
call DemoFind('move-from/$')
call Mapped('zo')
call Pause()
call Input('j')
call Input('j')
call Input('<<')
write
call Pause()
call DemoFind('move-from/$')
call Mapped('zc')
call Pause()
call Mapped('zo')
call Pause()
call Mapped('-')
call Pause()

" Section 3: copy a directory tree into another folder with yy and p.
call DemoFind('03-copy-and-paste/$')
call Mapped("\<CR>")
call Pause(1200)
call DemoFind('copy-from/$')
call Mapped('yy')
call Pause()
call DemoFind('copy-to/$')
call Mapped('p')
call Pause()
call DemoFind('^  copy-from/$')
call Mapped('zc')
call Pause()
call Mapped('zo')
call Pause()
call DemoFind('examples/$')
call Mapped('zo')
call Pause()
call Mapped('u')
call Pause()
call Mapped("\<C-r>")
call Pause()
call Mapped('-')
call Pause()

call DemoFinish()
