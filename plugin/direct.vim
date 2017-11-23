python import sys
python import vim
python sys.path.append(vim.eval('expand("<sfile>:h")'))

function! direct#list(...)
enew
set filetype=direct
setlocal filetype=direct buftype=acwrite noswapfile nomodified
augroup direct
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> DirectSync
augroup END

let root = getcwd()
if a:0 > 0
    let root = a:1
endif

python << endOfPython
from direct.buffer import DirectBuffer
DirectBuffer(vim.eval('root')).list()
endOfPython
endfunction


function! direct#sync()
python << endOfPython
from direct.buffer import DirectBuffer
DirectBuffer().sync()
DirectBuffer().list()
endOfPython
setlocal nomodified
endfunction


function! direct#open(...)
let line = getline('.')
if a:0 > 0
    let line = a:1
endif

python << endOfPython
from direct.buffer import DirectBuffer
DirectBuffer().open(vim.eval('line'))
endOfPython
endfunction


function! direct#undo()
python << endOfPython
from direct.buffer import DirectBuffer
from direct.history import History
History().undo()
DirectBuffer().list()
endOfPython
endfunction


function! direct#redo()
python << endOfPython
from direct.buffer import DirectBuffer
from direct.history import History
History().redo()
DirectBuffer().list()
endOfPython
endfunction


command! -nargs=? -complete=dir DirectList call direct#list(<f-args>)
command! DirectSync call direct#sync()
command! DirectUndo call direct#undo()
command! DirectRedo call direct#redo()
