source util.vim

call Pause()
call Input("G")
call Input("yy")
call Pause()
call Input("gg")
call Pause()
" <CR> is a buffer-local mapping: press it through Mapped(), which uses
" :normal without the bang. It used to call the Vimscript-era open() entry
" point directly, which no longer exists.
call Mapped("\<CR>")
call Pause()
call Input("p")
write
exit
