import hashlib
import os
import shutil
import vim

from os.path import abspath, join, relpath

from direct import directories


class Action(object):
    def serialize(self):
        words = [self.NAME]
        if hasattr(self, 'src'):
            words.append(self.src)
        if hasattr(self, 'dst'):
            words.append(self.dst)
        return ' '.join(words)

    def _digest(path):
        message = hashlib.md5()
        message.update(path)
        return message.hexdigest()


class Move(Action):
    NAME = 'mv'

    def __init__(self, src, dst):
        self.src = src
        self.dst = dst

    def do(self):
        # if the file is already open, save it as dst
        buffer_exists = False
        for buffer in vim.buffers:
            if buffer.name == self.src:
                buffer_exists = True
                direct_buffer = vim.current.buffer
                print 'direct buffer {}', format(direct_buffer.number)
                print 'found open buffer'
                vim.current.buffer = buffer
                print 'switched to buffer {}'.format(vim.current.buffer.number)
                vim.command('keepalt saveas! {}'.format(self.dst))
                vim.current_buffer = direct_buffer

        # else just move the file
        if not buffer_exists:
            shutil.move(self.src, self.dst)

    def __str__(self):
        return 'Moved {} to {}'.format(relpath(self.src), relpath(self.dst))


class Remove(Action):
    NAME = 'rm'

    def __init__(self, src):
        self.src = src
        self.dst = abspath(
            join(directories.trash_directory, directories.digest(self.src))
        )

    def do(self):
        shutil.move(self.src, self.dst)
        # if the file is already open, close the buffer
        for buffer in vim.buffers:
            if buffer.name == self.src:
                vim.command('bwipeout! {}'.format(buffer.number))

    def __str__(self):
        return 'Removed {}'.format(relpath(self.src))


class RemoveDirectory(Remove):
    NAME = 'rmdir'


class Restore(Move):
    NAME = 'rs'

    def __str__(self):
        return 'Restored {}'.format(relpath(self.dst))


class RestoreDirectory(Restore):
    NAME = 'rsdir'


class Touch(Action):
    NAME = 'touch'

    def __init__(self, dst):
        self.dst = dst

    def do(self):
        open(self.dst, 'w').close()

    def __str__(self):
        return 'Created {}'.format(relpath(self.dst))


class MakeDirectory(Action):
    NAME = 'mkdir'

    def __init__(self, dst):
        self.dst = dst

    def do(self):
        os.makedirs(self.dst)

    def __str__(self):
        return 'Created {}'.format(relpath(self.dst))


class Paste(Action):
    NAME = 'p'

    def __init__(self, src, dst):
        self.src = src
        self.dst = dst

    def do(self):
        for entry in os.listdir(self.src):
            full_entry = join(self.src, entry)
            if os.path.isfile(full_entry):
                shutil.copy(full_entry, self.dst)
            if os.path.isdir(full_entry):
                shutil.copytree(full_entry, join(self.dst, entry))

    def __str__(self):
        return 'Pasted into {}{}'.format(relpath(self.dst), os.path.sep)


class Unpaste(Action):
    NAME = 'up'

    def __init__(self, src, dst):
        self.src = src
        self.dst = dst

    def do(self):
        for entry in os.listdir(self.dst):
            full_entry = join(self.src, entry)
            if os.path.isfile(full_entry):
                os.remove(full_entry)
            if os.path.isdir(full_entry):
                shutil.rmtree(full_entry)

    def __str__(self):
        return 'Reversed paste into {}{}'.format(
            relpath(self.src), os.path.sep
        )


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
        (Paste, lambda src, dst: Unpaste(dst, src)),
        (Unpaste, lambda src, dst: Paste(dst, src)),
    )
}


def reverse(line):
    words = line.split(' ')
    return REVERSALS[words[0]](*words[1:])


def print_actions(*actions):
    actions_string = ', '.join(str(action) for action in actions)
    print(actions_string[0].upper() + actions_string[1:])
