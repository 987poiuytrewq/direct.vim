import os
import shutil

from os.path import join

from direct.data import Local, digest
from direct.action import Paste
from direct.action import print_actions
from direct.history import History


class Register(object):
    def __init__(self):
        self.path = Local.register()
        self.content_path = join(self.path, 'content')

    def yank(self, sources):
        dst = join(self.path, digest(*sources))
        if not os.path.exists(dst):
            os.makedirs(dst)
        for src in sources:
            if os.path.isfile(src):
                shutil.copy(src, dst)
            if os.path.isdir(src):
                full_dst = join(dst, os.path.basename(os.path.abspath(src)))
                if os.path.exists(full_dst):
                    shutil.rmtree(full_dst)
                shutil.copytree(src, full_dst)
            print('Yanked {}'.format(src))
        with open(self.content_path, 'w') as content:
            content.write(dst)

    def paste(self, dst):
        with open(self.content_path, 'r') as content:
            src = content.read()
        src_names = os.listdir(src)
        dst_names = src_names
        action = Paste(src, dst, src_names, dst_names)
        try:
            action.do()
        except (IOError, OSError):
            print('Failed to paste')
        else:
            print_actions(action)
            History().log(action)
