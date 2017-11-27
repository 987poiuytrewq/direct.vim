import os
import shutil
import hashlib


class Action(object):
    def _normalise_path(self, path):
        return path.replace(r'\/$', '')

    def __repr__(self):
        words = [self.NAME]
        if hasattr(self, 'src'):
            words.append(self.src)
        if hasattr(self, 'dst'):
            words.append(self.dst)
        return '{}\n'.format(' '.join(words))


class Move(Action):
    NAME = 'mv'

    def __init__(self, src, dst):
        self.src = self._normalise_path(src)
        self.dst = self._normalise_path(dst)

    def write(self):
        shutil.move(self.src, self.dst)


class Remove(Action):
    NAME = 'mv'
    TRASH_DIR = '/home/duncan/.direct/trash'

    def __init__(self, src):
        self.src = self._normalise_path(src)
        message = hashlib.md5()
        message.update(self.src)
        self.dst = os.path.abspath(
            os.path.join(self.TRASH_DIR, message.hexdigest())
        )

    def write(self):
        shutil.move(self.src, self.dst)


class Touch(Action):
    NAME = 'touch'

    def __init__(self, dst):
        self.dst = self._normalise_path(dst)

    def write(self):
        open(self.dst, 'w').close()


class MakeDirectory(Action):
    NAME = 'mkdir'

    def __init__(self, dst):
        self.dst = self._normalise_path(dst)

    def write(self):
        os.mkdir(self.dst)


def reverse(action):
    clazz = action.__class__
    if clazz == Move:
        return Move(action.dst, action.src)
    elif clazz == Remove:
        return Move(action.dst, action.src)
    elif clazz == Touch:
        return Remove(action.dst)
    elif clazz == MakeDirectory:
        return Remove(action.dst)
