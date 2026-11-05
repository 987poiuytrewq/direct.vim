function! Pause(...) abort
  redraw!
  let duration = a:0 > 0 ? a:1 : 1100
  execute 'sleep ' . duration . 'm'
endfunction

function! DemoFinish() abort
  if v:errmsg !=# ''
    echoerr 'demo script failed: ' . v:errmsg
    cquit 1
  endif
  qa!
endfunction

function! DemoFind(pattern) abort
  let row = search(a:pattern, 'w')
  if row == 0
    echoerr 'demo row not found: ' . a:pattern
    cquit 1
  endif
  return row
endfunction

function Input(characters)
  silent execute "normal! " . a:characters
  call luaeval('vim.uv.sleep(160)')
  redraw!
endfunction

" Mapped() drives :normal WITHOUT the bang, so buffer-local mappings fire and
" <> notation is translated from the double-quoted argument (e.g. "\<CR>").
" Input() uses :normal!, which skips mappings entirely, so a mapped key such as
" the direct listing's <CR> must be pressed through Mapped().
function Mapped(characters)
  silent execute "normal " . a:characters
  redraw!
  call luaeval('vim.uv.sleep(350)')
endfunction

function! Type(entry, position, string)
  silent execute "normal! " . a:entry
  let characters = split(a:string, '\zs')
  for character in characters
    call Input(a:position . character)
  endfor
  call Pause()
endfunction
