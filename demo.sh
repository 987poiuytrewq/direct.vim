#!/bin/bash
mkdir demo
mkdir demo/dir-1
echo 'this is file-1-a' >> demo/dir-1/file-1-a.txt
echo 'this is file-1-b' >> demo/dir-1/file-1-b.txt
mkdir demo/dir-2
mkdir demo/dir-2/dir-2-1
echo 'this is file-2-1-a' >> demo/dir-2/dir-2-1/file-2-1-a.txt
nvim -c ':source demo.vim'
rm -rf demo/