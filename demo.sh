#!/bin/bash
rm -rf ~/.local/share/direct
rm -rf demo/
mkdir demo
mkdir demo/view_directories
echo 'content of file is yanked and pasted' >> demo/and_view_files.txt
nvim -c 'source demo.vim' -- demo
rm -rf demo/
