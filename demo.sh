mkdir demo
mkdir demo/dir1
echo 'this is file-1-a' >> demo/dir-1/file-1-a.txt
echo 'this is file-1-b' >> demo/dir-1/file-1-b.txt
mkdir demo/dir2
mkdir demo/dir2/dir2_1
echo 'this is file-2-1-a' >> demo/dir-2/dir-1/file-2-1-a.txt
asciinema rec
nvim -c ':source demo.vim'
rm -rf demo/
