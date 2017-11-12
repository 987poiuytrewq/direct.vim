if exists("b:current_syntax") 
  finish
endif

syntax match DirectDirectory "^.*/$"
highlight! link DirectDirectory Directory
