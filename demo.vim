function Pause()
for _ in range(5)
  sleep 100m
endfor
endfunction

function Input(characters)
silent execute "normal! " . a:characters
python << endOfPython
import random
import time
duration = random.uniform(0.02, 0.10)
time.sleep(duration)
endOfPython
redraw!
endfunction

function! Type(entry, position, string)
silent execute "normal! " . a:entry
let characters = split(a:string, '\zs')
for character in characters
  call Input(a:position . character)
endfor
call Pause()
endfunction

augroup autosave
  autocmd!
augroup END

redraw!
T watch -n 0.1 -t tree --dirsfirst --noreport -F demo

call Pause()
call Type("c$", "A", "rename_directories/")
write
call Input("j^")
call Type("c$", "a", "rename_files.txt")
write

call Pause()
call Input("o")
call Type("c$", "A", "create_directories/")
write
call Input("o")
call Type("c$", "A", "create_files.txt")
write

call Pause()
call Input("gg")
call Type("c$", "A", "delete_directories/")
call Pause()
call Input("dd")
write
call Input("G")
call Type("c$", "A", "delete_files.txt")
write
call Pause()
call Input("dd")
write

call Pause()
call Input("G")
call Type("c$", "A", "yank_files.txt")
write
call Input("gg")
call Type("c$", "A", "and_paste_them/")
write

call Pause()
call Input("G")
call direct#yank()
call Input("gg")

call Pause()
call direct#open()

call Pause()
call direct#paste()
call Pause()
call Type("c$", "A", "with_contents.txt")
write

call Pause()
call direct#open()

call Pause()
call direct#open('../')

call Pause()
call direct#open('../')
call Input("G")

call Pause()
call Input("dd")
write

call Pause()
call Input("gg")
call Type("c$", "A", "yank_directories_too/")
write

call Pause()
call direct#yank()
call direct#pasteas("and_paste_them/")

call Pause()
call Type("c$", "A", "undo_everything/")
write

for _ in range(15)
  call Pause()
  call direct#undo()
  redraw!
endfor
