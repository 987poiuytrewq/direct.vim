if exists("b:current_syntax")
  finish
endif

syntax match DirectHiddenDirectory "^\s*\..*/$"
syntax match DirectHiddenFile "^\s*\..*[^/]$"
highlight default link DirectHiddenDirectory NonText
highlight default link DirectHiddenFile Comment

function! s:DefineHiddenHighlightDefaults() abort
  highlight default link DirectHiddenDirectory NonText
  highlight default link DirectHiddenFile Comment
endfunction

augroup direct_hidden_highlight_defaults
  autocmd!
  autocmd ColorScheme * call <SID>DefineHiddenHighlightDefaults()
augroup END
