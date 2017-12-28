import os
import shutil

from direct import directories
from direct.action import Paste
from direct.history import History


class Register(object):
    def __init__(self):
        self.path = directories.register_directory
        self.content_path = os.path.join(self.path, 'content')

    def yank(self, *sources):
        dst = os.path.join(self.path, directories.digest(*sources))
        if not os.path.exists(dst):
            os.makedirs(dst)
        for src in sources:
            shutil.copy(src, dst)
        with open(self.content_path, 'w') as content:
            content.write(dst)

    def paste(self, dst):
        with open(self.content_path, 'r') as content:
            src = content.read()
        action = Paste(src, dst)
        action.do()
        History().log(action)

    def clear(self):
        shutil.rmtree(self.path)
