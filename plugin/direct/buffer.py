import os
import vim

from direct.action import Move
from direct.action import Remove
from direct.action import RemoveDirectory
from direct.action import Touch
from direct.action import MakeDirectory
from direct.action import print_actions
from direct.history import History
from direct.register import Register


class Buffer(object):
    def __init__(self, path):
        self.root = BufferRoot(path)

        # change window to buffer if it already exists
        if any(
            buffer.name == self.root.absolute_path for buffer in vim.buffers
        ):
            vim.command('buffer {}'.format(self.root.absolute_path))
        else:
            # else create new buffer and dump path
            vim.command('enew')
            vim.current.buffer.name = self.root.absolute_path
            self.root.dump()

    @classmethod
    def restore(cls):
        '''Restore buffer from dumped path'''
        path = BufferRoot.load()
        return cls(path)

    def list(self):
        '''Display directory content in buffer'''
        vim.current.buffer[:] = self.__read()

    def sync(self):
        '''Synchronise buffer content with directory content'''
        actual_lines = map(self.__full_path, vim.current.buffer[:])
        expected_lines = map(self.__full_path, self.__read())

        actions = []
        yanks = []
        if len(actual_lines) > len(expected_lines):
            for added_line in set(actual_lines) - set(expected_lines):
                if self.__isdir(added_line):
                    actions.append(MakeDirectory(added_line))
                else:
                    actions.append(Touch(added_line))
        elif len(actual_lines) < len(expected_lines):
            for removed_line in set(expected_lines) - set(actual_lines):
                yanks.append(removed_line)
                if self.__isdir(removed_line):
                    actions.append(RemoveDirectory(removed_line))
                else:
                    actions.append(Remove(removed_line))
        else:
            for actual_line, expected_line in zip(
                actual_lines, expected_lines
            ):
                if actual_line != expected_line:
                    actions.append(Move(expected_line, actual_line))

        if actions:
            if yanks:
                Register().yank(*yanks)

            history = History()
            for action in actions:
                action.do()
                history.log(action)
            print_actions(*actions)

    def open(self, line):
        '''Open file or change directory'''
        path = self.__full_path(line)
        if self.__isdir(path):
            # disable writes
            vim.command('set buftype=nofile')
            self.root.change_directory(line[:-1])
            self.list()
            # enable writes
            vim.command('set buftype=acwrite nomodified')
            vim.current.buffer.name = self.root.absolute_path
            self.root.dump()
        else:
            vim.command('edit {}'.format(path))

    def get_lines(self, firstline, lastline):
        current_buffer = vim.current.buffer
        return current_buffer[slice(int(firstline) - 1, int(lastline))]

    def __read(self):
        files = []
        directories = []

        for entry in os.listdir(self.root.absolute_path):
            if os.path.isdir(self.__full_path(entry)):
                directories.append(entry)
            elif os.path.isfile(self.__full_path(entry)):
                files.append(entry)

        lines = []
        lines += [
            u'{}{}'.format(directory, os.path.sep)
            for directory in sorted(directories)
        ]
        lines += [u'{}'.format(file) for file in sorted(files)]
        return lines

    def __full_path(self, entry):
        return os.path.join(self.root.absolute_path, entry)

    def __isdir(self, line):
        return line.endswith(os.path.sep)


class BufferRoot(object):
    ROOT_VARIABLE = 'b:direct_buffer_root'

    def __init__(self, relative_path):
        self.absolute_path = os.path.abspath(relative_path)

    def change_directory(self, offset_path):
        self.absolute_path = os.path.join(self.absolute_path, offset_path)

    def dump(self):
        vim.command(
            "let {} = '{}'".format(self.ROOT_VARIABLE, self.absolute_path)
        )

    @classmethod
    def load(cls):
        return vim.eval(cls.ROOT_VARIABLE)
