T watch -n 0.1 -t tree demo/
e demo/

function s:macro(keys)
  let @a=a:keys
  sleep 1
  echo "Sending keys: " . a:keys
  :redraw
  sleep 1
  normal! @a
  :redraw
endfunction

:redraw
call s:macro("cefolder\<esc>")
call s:macro("\<cr>")
call s:macro("\<cr>")
call s:macro("-")

