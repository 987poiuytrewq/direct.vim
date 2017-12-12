import os
import shutil
import hashlib

from direct import directories


class Action(object):
    def serialize(self):
        words = [self.NAME]
        if hasattr(self, 'src'):
            words.append(self.src)
        if hasattr(self, 'dst'):
            words.append(self.dst)
        return ' '.join(words)


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

    def __init__(self, src):
        self.src = src
        message = hashlib.md5()
        message.update(self.src)
        self.dst = os.path.abspath(
            os.path.join(directories.trash_directory, message.hexdigest())
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
    SubAction.NAME: reverse
    for SubAction, reverse in (
        (Move, lambda src, dst: Move(dst, src)),
        (Remove, lambda src, dst: Restore(dst, src)),
        (RemoveDirectory, lambda src, dst: RestoreDirectory(dst, src)),
        (Restore, lambda src, dst: Remove(dst)),
        (RestoreDirectory, lambda src, dst: RemoveDirectory(dst)),
        (Touch, lambda dst: Remove(dst)),
        (MakeDirectory, lambda dst: RemoveDirectory(dst)),
    )
}


def reverse(line):
    words = line.split(' ')
    return REVERSALS[words[0]](*words[1:])
