nnoremap <buffer><silent> <CR> :<C-U>call direct#open()<CR>
nnoremap <buffer><silent> - :<C-U>call direct#open('../')<CR>
nnoremap <buffer><silent> u :<C-U>call direct#undo()<CR>
nnoremap <buffer><silent> <C-r> :<C-U>call direct#redo()<CR>
nnoremap <buffer><silent> yy :<C-U>call direct#yank()<CR>
nnoremap <buffer><silent> Y :<C-U>call direct#yank()<CR>
nnoremap <buffer><silent> p :<C-U>call direct#paste()<CR>
nnoremap <buffer><silent> P :<C-U>call direct#paste()<CR>
