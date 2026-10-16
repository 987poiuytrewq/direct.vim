function Pause()
  redraw!
  sleep 500m
endfunction

function Input(characters)
silent execute "normal! " . a:characters
call luaeval('vim.uv.sleep(30)')
redraw!
endfunction

" Mapped() drives :normal WITHOUT the bang, so buffer-local mappings fire and
" <> notation is translated from the double-quoted argument (e.g. "\<CR>").
" Input() uses :normal!, which skips mappings entirely, so a mapped key such as
" the direct listing's <CR> must be pressed through Mapped().
function Mapped(characters)
silent execute "normal " . a:characters
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
