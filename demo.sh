#!/bin/bash
mkdir demo
mkdir demo/view_directories
echo 'content of file1' >> demo/and_view_files.txt
nvim -c 'source demo.vim' -- demo
rm -rf demo/
