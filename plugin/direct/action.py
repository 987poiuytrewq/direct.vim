import os
import shutil
import vim

from abc import ABCMeta, abstractmethod
from os.path import abspath, join, relpath

from direct import directories


class Action(object):
    FIELD_SEPARATOR = '\t'
    __metaclass__ = ABCMeta

    def serialize(self):
        words = [self.NAME]
        if hasattr(self, 'src'):
            words.append(self.src)
        if hasattr(self, 'dst'):
            words.append(self.dst)
        return self.FIELD_SEPARATOR.join(words)

    @staticmethod
    def _get_input(prompt, text, completion):
        '''Get user input'''
        vim.command('call inputsave()')
        vim.command(
            "let response = input('{}', '{}', '{}')".format(
                prompt, text, completion
            )
        )
        vim.command('call inputrestore()')
        return vim.eval('response')

    def _close_src_buffer(self):
        '''If the src file is already open, close the buffer'''
        for buffer in vim.buffers:
            if buffer.name == self.src:
                vim.command(
                    'bwipeout! {buffer_number}'.format(
                        buffer_number=buffer.number
                    )
                )

    @abstractmethod
    def do(self):
        '''Perform the action

        :returns: any newly created file system entries
        '''
        pass


class Move(Action):
    NAME = 'mv'

    def __init__(self, src, dst):
        self.src = src
        self.dst = dst

    def do(self):
        self._close_src_buffer()
        shutil.move(self.src, self.dst)
        return self.dst

    def __str__(self):
        return 'Moved {src} to {dst}'.format(
            src=relpath(self.src), dst=relpath(self.dst)
        )


class Remove(Action):
    NAME = 'rm'

    def __init__(self, src):
        self.src = src
        self.dst = abspath(
            join(directories.trash_directory, directories.digest(self.src))
        )

    def do(self):
        self._close_src_buffer()
        shutil.move(self.src, self.dst)

    def __str__(self):
        return 'Removed {}'.format(relpath(self.src))


class RemoveDirectory(Remove):
    NAME = 'rmdir'


class Restore(Move):
    NAME = 'rs'

    def __str__(self):
        return 'Restored {dst}'.format(dst=relpath(self.dst))


class RestoreDirectory(Restore):
    NAME = 'rsdir'


class Touch(Action):
    NAME = 'touch'

    def __init__(self, dst):
        self.dst = dst

    def do(self):
        open(self.dst, 'w').close()
        return self.dst

    def __str__(self):
        return 'Created {dst}'.format(dst=relpath(self.dst))


class MakeDirectory(Action):
    NAME = 'mkdir'

    def __init__(self, dst):
        self.dst = dst

    def do(self):
        os.makedirs(self.dst)
        return self.dst

    def __str__(self):
        return 'Created {dst}'.format(dst=relpath(self.dst))


class MultiAction(Action):
    """Action that operates on more than one entry"""
    ENTRY_SEPARATOR = ' '  # nbsp

    def __init__(self, src, dst, src_names, dst_names):
        self.src = src
        self.dst = dst
        self.renames = dict(zip(src_names, dst_names))

    def serialize(self):
        return self.FIELD_SEPARATOR.join((
            super(MultiAction, self).serialize(),
            self.ENTRY_SEPARATOR.join(self.renames.keys()),
            self.ENTRY_SEPARATOR.join(self.renames.values())
        ))


class Paste(MultiAction):
    """Defines an action for copying entries from a register (self.src) to a
    directory (self.dst)"""
    NAME = 'p'

    def do(self):
        full_dst = None
        for src_name, dst_name in self.renames.items():
            full_src = join(self.src, src_name)
            full_dst = join(self.dst, dst_name)

            if os.path.exists(full_dst):
                entry_type = 'File' if os.path.isfile(
                    full_dst
                ) else 'Directory'
                dst_name = self._get_input(
                    '{entry_type} already exists. Paste as: '.format(
                        entry_type=entry_type
                    ),
                    src_name,
                    'file'
                )
                self.renames[src_name] = dst_name
                full_dst = join(self.dst, dst_name)

            if os.path.isfile(full_src):
                shutil.copyfile(full_src, full_dst)
            if os.path.isdir(full_src):
                shutil.copytree(full_src, full_dst)

        # set last pasted entry as current entry
        return full_dst

    def __str__(self):
        return 'Pasted into {dst}'.format(
            dst=(relpath(self.dst) + os.path.sep)
        )


class Unpaste(MultiAction):
    """Defines an action for undoing a Paste action. This is effectively the
    same as removing the pasted entries but also writes the original names of
    the files into the history so it can be reversed"""
    NAME = 'up'

    def do(self):
        for src_name, dst_name in self.renames.items():
            full_src = join(self.src, src_name)

            # no need to move to the trash as we know it came from a register
            if os.path.isfile(full_src):
                os.remove(full_src)
            if os.path.isdir(full_src):
                shutil.rmtree(full_src)

    def __str__(self):
        return 'Reversed paste into {src}'.format(
            src=(relpath(self.src) + os.path.sep)
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
        (Paste, lambda src, dst, src_names, dst_names: Unpaste(
            dst, src, dst_names.split(MultiAction.ENTRY_SEPARATOR),
            src_names.split(MultiAction.ENTRY_SEPARATOR))
         ),
        (Unpaste, lambda src, dst, src_names, dst_names: Paste(
            dst, src, dst_names.split(MultiAction.ENTRY_SEPARATOR),
            src_names.split(MultiAction.ENTRY_SEPARATOR))
         ),
    )
}


def reverse(line):
    words = line.split(Action.FIELD_SEPARATOR)
    return REVERSALS[words[0]](*words[1:])


def print_actions(*actions):
    actions_string = ', '.join(str(action) for action in actions)
    print(actions_string[0].upper() + actions_string[1:])
