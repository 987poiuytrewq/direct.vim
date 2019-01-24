source util.vim

call Pause()
call Type("c$", "a", "dir_b/")
call Pause()
write
call Input("G")
call Type("c$", "a", "file_2.txt")
write
exit
