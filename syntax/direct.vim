if exists("b:current_syntax")
  finish
endif

syntax match DirectHiddenDirectory "^\s*\..*/$"
syntax match DirectHiddenFile "^\s*\..*[^/]$"
syntax match DirectDirectory "^\s*[^.[:space:]].*/$"
highlight default link DirectDirectory Directory
highlight default link DirectHiddenDirectory Comment
highlight default link DirectHiddenFile Comment

function! s:DefineHiddenHighlightDefaults() abort
  highlight default link DirectDirectory Directory
  highlight default link DirectHiddenDirectory Comment
  highlight default link DirectHiddenFile Comment
endfunction

augroup direct_hidden_highlight_defaults
  autocmd!
  autocmd ColorScheme * call <SID>DefineHiddenHighlightDefaults()
augroup END

let b:current_syntax = "direct"
