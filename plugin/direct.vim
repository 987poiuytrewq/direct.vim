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
from direct.buffer import Buffer
Buffer(vim.eval('root')).list()
endOfPython
endfunction


function! direct#sync()
python << endOfPython
from direct.buffer import Buffer
buffer = Buffer()
buffer.sync()
buffer.list()
endOfPython
setlocal nomodified
endfunction


function! direct#open(...)
let line = getline('.')
if a:0 > 0
    let line = a:1
endif

python << endOfPython
from direct.buffer import Buffer
Buffer().open(vim.eval('line'))
endOfPython
endfunction


function! direct#undo()
python << endOfPython
from direct.buffer import Buffer
from direct.history import History
History().undo()
Buffer().list()
endOfPython
endfunction


function! direct#redo()
python << endOfPython
from direct.buffer import Buffer
from direct.history import History
History().redo()
Buffer().list()
endOfPython
endfunction

function! direct#yank()
let line = getline('.')
python << endOfPython
from direct.buffer import Buffer
from direct.register import Register
Register().yank(vim.eval('line'))
Buffer().list()
endOfPython
endfunction

function! direct#paste()
python << endOfPython
from direct.buffer import Buffer
from direct.register import Register
buffer = Buffer()
Register().paste(buffer.root)
buffer.list()
endOfPython
endfunction


command! -nargs=? -complete=dir DirectList call direct#list(<f-args>)
command! DirectSync call direct#sync()
command! DirectUndo call direct#undo()
command! DirectRedo call direct#redo()
command! DirectYank call direct#yank()
command! DirectPaste call direct#paste()
