" --------------------------------
" Add our plugin to the path
" --------------------------------
python import sys
python import vim
python sys.path.append(vim.eval('expand("<sfile>:h")'))

" --------------------------------
"  Function(s)
" --------------------------------
function! direct#list()
enew
python << endOfPython

import os
from direct import DirectBuffer
DirectBuffer(os.getcwd()).list()

endOfPython
endfunction

function! direct#sync()
python << endOfPython

import os
from direct import DirectBuffer
DirectBuffer(os.getcwd()).sync()
DirectBuffer(os.getcwd()).list()

endOfPython
endfunction

" --------------------------------
"  Expose our commands to the user
" --------------------------------
command! DirectList call direct#list()
command! DirectSync call direct#sync()
