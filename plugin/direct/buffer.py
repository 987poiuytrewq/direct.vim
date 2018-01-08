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
    PATH_VARIABLE = 'b:direct_path'

    def __init__(self, path=''):
        exists = vim.eval("exists('{}')".format(self.PATH_VARIABLE))
        if exists != '0':
            path = os.path.join(vim.eval(self.PATH_VARIABLE), path)
        self.root = os.path.abspath(path)
        vim.command("let {} = '{}'".format(self.PATH_VARIABLE, self.root))

        if any(buffer.name == self.root for buffer in vim.buffers):
            vim.command('buffer {}'.format(self.root))
        else:
            vim.command('enew')
            vim.current.buffer.name = self.root

    def list(self):
        vim.current.buffer[:] = self.__read()

    def sync(self):
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
        path = self.__full_path(line)
        if self.__isdir(path):
            Buffer(line[:-1]).list()
        else:
            vim.command('edit {}'.format(path))

    def get_lines(self, firstline, lastline):
        current_buffer = vim.current.buffer
        return current_buffer[slice(int(firstline) - 1, int(lastline))]

    def __read(self):
        files = []
        directories = []

        for entry in os.listdir(self.root):
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
        return os.path.join(self.root, entry)

    def __isdir(self, line):
        return line.endswith(os.path.sep)
