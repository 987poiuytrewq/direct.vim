import os
import shutil

from os.path import basename, join

from direct import directories
from direct.action import Paste
from direct.history import History


class Register(object):
    def __init__(self):
        self.path = directories.register_directory
        self.content_path = join(self.path, 'content')

    def yank(self, *sources):
        dst = join(self.path, directories.digest(*sources))
        if not os.path.exists(dst):
            os.makedirs(dst)
        for src in sources:
            if os.path.isfile(src):
                shutil.copy(src, dst)
            if os.path.isdir(src):
                shutil.copytree(src, join(dst, basename(src)))
        with open(self.content_path, 'w') as content:
            content.write(dst)

    def paste(self, dst):
        with open(self.content_path, 'r') as content:
            src = content.read()
        action = Paste(src, dst)
        action.do()
        History().log(action)
