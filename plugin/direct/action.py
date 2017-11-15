import os
import shutil
import hashlib


class Action(object):
    def _normalise_path(self, path):
        return path.replace(r'\/$', '')

    def _trash_path(self, path):
        message = hashlib.md5()
        message.update(path)
        return message.hexdigest()

    def __repr__(self):
        words = [self.__class__.__name__]
        if hasattr(self, 'src'):
            words.append(self.src)
        if hasattr(self, 'dst'):
            words.append(self.dst)
        return '{}\n'.format(' '.join(words))


class Move(Action):
    def __init__(self, src, dst):
        self.src = self._normalise_path(src)
        self.dst = self._normalise_path(dst)

    def write(self):
        shutil.move(self.src, self.dst)


class Remove(Action):
    def __init__(self, src):
        self.src = self._normalise_path(src)
        self.dst = self._trash_path(src)

    def write(self):
        shutil.move(self.src, self.dst)


class RemoveDirectory(Action):
    def __init__(self, src):
        self.src = self._normalise_path(src)
        self.dst = self._trash_path(src)

    def write(self):
        archived = None
        shutil.move(archived, self.dst)
        os.remove(archived)
        shutil.rmtree(self.src)


class Restore(Action):
    def __init__(self, src, dst):
        self.src = self._normalise_path(src)
        self.dst = self._normalise_path(dst)

    def write(self):
        shutil.move(self.src, self.dst)


class RestoreDirectory(Action):
    def __init__(self, src, dst):
        self.src = self._normalise_path(src)
        self.dst = self._normalise_path(dst)

    def write(self):
        extracted = None
        shutil.move(extracted, self.dst)
        os.remove(self.src)


class Touch(Action):
    def __init__(self, dst):
        self.dst = self._normalise_path(dst)

    def write(self):
        open(self.dst, 'w').close()


class MakeDirectory(Action):
    def __init__(self, dst):
        self.dst = self._normalise_path(dst)

    def write(self):
        os.mkdir(self.dst)


def reverse(action):
    clazz = action.__class__
    if clazz == Move:
        return Move(action.dst, action.src)
    elif clazz == Remove:
        return Restore(action.dst, action.src)
    elif clazz == RemoveDirectory:
        return RestoreDirectory(action.dst, action.src)
    elif clazz == Restore:
        return Remove(action.dst)
    elif clazz == RestoreDirectory:
        return RemoveDirectory(action.dst)
    elif clazz == Touch:
        return Remove(action.dst)
    elif clazz == MakeDirectory:
        return RemoveDirectory(action.dst)
