source util.vim

call Pause()
call Input("o")
call Type("c$", "A", "dir_b/")
call Pause()
write
call Input("o")
call Type("c$", "A", "file_2.txt")
write
exit
