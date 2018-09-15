
function Pause()
python << endOfPython
import random
import time
duration = random.uniform(0.02, 0.10)
time.sleep(0.01)
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
  call Pause()
endfunction

augroup autosave
  autocmd!
augroup END

redraw!
T watch -n 0.1 -t tree --dirsfirst --noreport -F demo
" sleep 1
call Type("c$", "A", "rename_directories/")
write
call Input("j^")
call Type("c$", "a", "rename_files.txt")
write
call Input("o")
call Type("c$", "A", "create_directories/")
write
call Input("o")
call Type("c$", "A", "create_files.txt")
write
call Type("c$", "A", "delete_files.txt")
write
call Input("dd")
write
call Input("gg")
call Type("c$", "A", "delete_directories/")
write
call Input("dd")
write
call Input("G")
call Type("c$", "A", "yank_files.txt")
write
call Input("gg")
call Type("c$", "A", "and_paste_them/")
write
call Input("G")
call Input("yy")
call Input("gg")
call feedkeys("\<CR>")
sleep 1
call Input("p")
" write
" call Type("c$", "A", "with_contents.txt")
" call feedkeys("\<CR>")
