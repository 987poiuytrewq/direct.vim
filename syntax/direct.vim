if exists("b:current_syntax")
  finish
endif

syntax match DirectDirectory "^[^\.].*/$"
syntax match DirectHiddenDirectory "^\..*/$"
syntax match DirectHiddenFile "^\..*[^/]$"
highlight! link DirectDirectory Directory
highlight! link DirectHiddenDirectory Comment
highlight! link DirectHiddenFile Comment
