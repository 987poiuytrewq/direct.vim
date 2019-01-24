#!/bin/bash
function reset() {
  rm -rf ~/.local/share/direct
  rm -rf demo/
  mkdir demo
  mkdir demo/dir_a
  touch demo/dir_a/file_a1.txt
  touch demo/file_1.txt
}

# for file in 'create' 'delete' 'rename'
for file in 'yank_paste'
do
  reset
  asciinema rec $file.json -c "nvim -c 'source $file.vim' -- demo"
done

