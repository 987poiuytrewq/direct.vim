
function Pause()
python << endOfPython
import random
import time
duration = random.uniform(0.03, 0.10)
time.sleep(duration)
endOfPython
redraw!
endfunction

function Input(characters)
    silent execute "normal! " . a:characters
    call Pause()
endfunction

function! Type(entry, position, string)
  silent execute "normal! " . a:entry
  let characters = split(a:string, '\zs')
  for character in characters
    call Input(a:position . character)
  endfor
endfunction

augroup autosave
  autocmd!
augroup END

redraw!
T watch -n 0.1 -t tree --dirsfirst --noreport -F demo
call Type("c$", "A", "rename_directories/")
write
call Input("j^")
call Type("ct.", "a", "rename_files")
write
call Input("o")
call Type("c$", "A", "create_directories/")
write
call Input("o")
call Type("c$", "A", "create_files.txt")
write
vs rename_files.txt
call Type("c$", "A", "yank files including their content")
write
wincmd h
call Input("yy")
call Input("p")
