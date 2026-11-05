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

function! Caption(text) abort
  call v:lua.DemoCaption(a:text)
endfunction

" WaitFor(text[, present]) waits, while processing events, until a line of the
" listing contains text (or, with present = 0, until none does). Paste and Git
" commands finish asynchronously, so the next step waits for their result.
function! WaitFor(text, ...) abort
  let present = a:0 > 0 ? a:1 : 1
  let found = luaeval('vim.wait(10000, function() '
        \ . 'for _, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do '
        \ . 'if line:find(_A[1], 1, true) then return _A[2] end end '
        \ . 'return not _A[2] end, 50)', [a:text, present ? v:true : v:false])
  if !found
    echoerr 'demo: timed out waiting for ' . (present ? '' : 'no ') . a:text
    cquit 1
  endif
  redraw!
endfunction
