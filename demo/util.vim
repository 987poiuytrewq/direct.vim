function Pause()
  redraw!
  sleep 500m
endfunction

function Input(characters)
silent execute "normal! " . a:characters
python << endOfPython
import random
import time
duration = random.uniform(0.01, 0.05)
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
