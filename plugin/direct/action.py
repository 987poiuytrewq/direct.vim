import os
import shutil
import hashlib

from directories import trash_directory


class Action(object):
    def serialize(self):
        words = [self.NAME]
        if hasattr(self, 'src'):
            words.append(self.src)
        if hasattr(self, 'dst'):
            words.append(self.dst)
        return '{}\n'.format(' '.join(words))

    @classmethod
    def deserialize(cls, line):
        words = line.split(' ')
        action_name = words[0]
        for SubAction in cls.__subclasses__():
            if SubAction.NAME == action_name:
                return SubAction(*words[1:])


class Move(Action):
    NAME = 'mv'

    def __init__(self, src, dst):
        self.src = src
        self.dst = dst

    def write(self):
        shutil.move(self.src, self.dst)

    def __str__(self):
        return 'Moved {} to {}'.format(
            os.path.relpath(self.src), os.path.relpath(self.dst)
        )


class Remove(Action):
    NAME = 'rm'

    def __init__(self, src, dst=None):
        self.src = src
        if dst:
            self.dst = dst
        else:
            message = hashlib.md5()
            message.update(self.src)
            self.dst = os.path.abspath(
                os.path.join(trash_directory, message.hexdigest())
            )

    def write(self):
        shutil.move(self.src, self.dst)

    def __str__(self):
        return 'Removed {}'.format(os.path.relpath(self.src))


class RemoveDirectory(Remove):
    NAME = 'rmdir'


class Restore(Move):
    NAME = 'rs'

    def __str__(self):
        return 'Restored {}'.format(os.path.relpath(self.dst))


class RestoreDirectory(Move):
    NAME = 'rsdir'


class Touch(Action):
    NAME = 'touch'

    def __init__(self, dst):
        self.dst = dst

    def write(self):
        open(self.dst, 'w').close()

    def __str__(self):
        return 'Created {}'.format(os.path.relpath(self.dst))


class MakeDirectory(Action):
    NAME = 'mkdir'

    def __init__(self, dst):
        self.dst = dst

    def write(self):
        os.makedirs(self.dst)

    def __str__(self):
        return 'Created {}'.format(os.path.relpath(self.dst))


REVERSALS = {
    Move.NAME:
        lambda action: Move(action.dst, action.src),
    Remove.NAME:
        lambda action: Restore(action.dst, action.src),
    RemoveDirectory.NAME:
        lambda action: RestoreDirectory(action.dst, action.src),
    Restore.NAME:
        lambda action: Remove(action.dst),
    RestoreDirectory.NAME:
        lambda action: RemoveDirectory(action.dst),
    Touch.NAME:
        lambda action: Remove(action.dst),
    MakeDirectory.NAME:
        lambda action: RemoveDirectory(action.dst),
}


def reverse(action):
    return REVERSALS[action.NAME](action)
