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


let root = ''
if a:0 > 0
    let root = a:1
endif
python << endOfPython

from direct.buffer import DirectBuffer
DirectBuffer(root=vim.eval('root')).list()

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

function! direct#open()
python << endOfPython

from direct import DirectBuffer
DirectBuffer().open()

endOfPython
endfunction

command! -nargs=? -complete=dir DirectList call direct#list(<f-args>)
command! DirectSync call direct#sync()
