import os
import shutil
import hashlib


class Action(object):
    def _normalise_path(self, path):
        return path.replace(r'\/$', '')


class Move(Action):
    ACTION = 'mv'

    def __init__(self, src, dst):
        self.src = self._normalise_path(src)
        self.dst = self._normalise_path(dst)

    def write(self):
        shutil.move(self.src, self.dst)


class Remove(Move):
    ACTION = 'rm'

    def __init__(self, src):
        self.src = self._normalise_path(src)
        self.dst = self._trash_path(src)

    def _trash_path(self, path):
        return hashlib.sha1(path)


class RemoveDirectory(Remove):
    ACTION = 'rmdir'

    def write(self):
        archived = None
        shutil.move(archived, self.dst)
        os.remove(archived)
        shutil.rmtree(self.src)


class Restore(Move):
    ARITY = 2
    ACTION = 'urm'


class RestoreDirectory(Move):
    ACTION = 'urmdir'

    def write(self):
        extracted = None
        shutil.move(extracted, self.dst)
        os.remove(self.src)


class Touch(Action):
    ARITY = 1
    ACTION = 'touch'

    def __init__(self, dst):
        self.dst = self._normalise_path(dst)

    def write(self):
        open(self.dst, 'w').close()


class MakeDirectory(Action):
    ACTION = 'mkdir'

    def write(self):
        os.mkdir(self.dst)
