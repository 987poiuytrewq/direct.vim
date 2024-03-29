python3 import sys
python3 import vim
python3 sys.path.append(vim.eval('expand("<sfile>:h")'))


function! direct#list(path)
python3 << endOfPython
import os
from direct.buffer import Buffer
buffer = Buffer(vim.eval('a:path'))
buffer.list()
endOfPython
set filetype=direct buftype=acwrite buflisted noswapfile nomodified
augroup direct
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> DirectSync
augroup END
endfunction


function! direct#sync()
python3 << endOfPython
from direct.buffer import Buffer, AmbiguousBufferError
buffer = Buffer.restore()
try:
  buffer.sync()
except AmbiguousBufferError:
  pass
else:
  buffer.list()
endOfPython
setlocal nomodified
endfunction


function! direct#open(...)
let line = getline('.')
if a:0 > 0
    let line = a:1
endif

python3 << endOfPython
from direct.buffer import Buffer
buffer = Buffer.restore()
buffer.open(vim.eval('line'))
endOfPython
endfunction


function! direct#undo()
python3 << endOfPython
from direct.buffer import Buffer
from direct.history import History
History().undo()
buffer = Buffer.restore()
buffer.list()
endOfPython
endfunction


function! direct#redo()
python3 << endOfPython
from direct.buffer import Buffer
from direct.history import History
History().redo()
buffer = Buffer.restore()
buffer.list()
endOfPython
endfunction


function! direct#yank() range
python3 << endOfPython
from direct.buffer import Buffer
from direct.register import Register
buffer = Buffer.restore()
sources = buffer.get_paths(vim.eval('a:firstline'), vim.eval('a:lastline'))
Register().yank(sources)
buffer.list()
endOfPython
endfunction


function! direct#paste(...)
let dst = ''
if a:0 > 0
    let dst = a:1
endif

python3 << endOfPython
from direct.buffer import Buffer
from direct.register import Register
dst = vim.eval('dst')
if dst:
    Register().paste(dst)
else:
    buffer = Buffer.restore()
    Register().paste(buffer.root)
    buffer.list()
endOfPython
endfunction


function! direct#pasteas(name)
python3 << endOfPython
name = vim.eval('a:name')
from direct.buffer import Buffer
from direct.register import Register
buffer = Buffer.restore()
Register().paste(buffer.root, name=name)
buffer.list()
endOfPython
endfunction


function! direct#getbufd()
if &buftype == ''
  return expand('%:p:h')
else
  return getcwd()
end
endfunction


command! -nargs=1 -complete=dir DirectList call direct#list(<f-args>)
command! DirectListBuffer call direct#list(direct#getbufd())
command! DirectListCwd call direct#list(getcwd())
command! DirectSync call direct#sync()
command! DirectUndo call direct#undo()
command! DirectRedo call direct#redo()
command! -range DirectYank <line1>,<line2>call direct#yank()
command! -nargs=? -complete=dir DirectPaste call direct#paste(<f-args>)
command! -nargs=1 -complete=file DirectPasteAs call direct#pasteas(<f-args>)

augroup direct_replace_netrw
  autocmd!
  autocmd VimEnter * if exists('#FileExplorer') | execute 'autocmd! FileExplorer *' | endif
  autocmd BufEnter * if isdirectory(expand('%')) | execute 'DirectList %' | endif
augroup END
nnoremap <silent> - :<C-U>DirectListBuffer<CR>
