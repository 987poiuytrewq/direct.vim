python import sys
python import vim
python sys.path.append(vim.eval('expand("<sfile>:h")'))

function! direct#list(path)
python << endOfPython
from direct.buffer import Buffer
Buffer(vim.eval('a:path')).list()
endOfPython
set filetype=direct buftype=acwrite buflisted noswapfile nomodified
augroup direct
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> DirectSync
augroup END
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

function! direct#yank() range
python << endOfPython
from direct.buffer import Buffer
from direct.register import Register
buffer = Buffer()
sources = buffer.get_lines(vim.eval('a:firstline'), vim.eval('a:lastline'))
Register().yank(*sources)
buffer.list()
endOfPython
endfunction

function! direct#paste(...)
let dst = ''
if a:0 > 0
    let dst = a:1
endif

python << endOfPython
from direct.buffer import Buffer
from direct.register import Register
dst = vim.eval('dst')
if dst:
    Register().paste(dst)
else:
    buffer = Buffer()
    Register().paste(buffer.root)
    buffer.list()
endOfPython
endfunction


command! -nargs=1 -complete=dir DirectList call direct#list(<f-args>)
command! DirectListBuffer call direct#list(expand('%:p:h'))
command! DirectListCwd call direct#list(getcwd())
command! DirectSync call direct#sync()
command! DirectUndo call direct#undo()
command! DirectRedo call direct#redo()
command! -range DirectYank <line1>,<line2>call direct#yank()
command! -nargs=? -complete=dir DirectPaste call direct#paste(<f-args>)

augroup direct_replace_netrw
  autocmd!
  autocmd VimEnter * if exists('#FileExplorer') | exe 'au! FileExplorer *' | endif
  autocmd BufEnter * if !exists('b:direct_path') && isdirectory(expand('%'))
    \ | redraw | echo '' | exe 'DirectList %'
    \ | elseif exists('b:direct_path') && &buflisted && bufnr('$') > 1 | setlocal nobuflisted | endif
augroup END
nnoremap <silent> - :<C-U>DirectListBuffer<CR>
