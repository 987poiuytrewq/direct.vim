import os
import vim
from action import Move
from action import Remove
from action import Touch
from action import MakeDirectory
from action import print_actions
from history import History


class Buffer(object):
    PATH_VARIABLE = 'b:direct_path'

    def __init__(self, path=''):
        exists = vim.eval("exists('{}')".format(self.PATH_VARIABLE))
        if exists != '0':
            path = os.path.join(vim.eval(self.PATH_VARIABLE), path)
        self.root = os.path.abspath(path)
        vim.command("let {} = '{}'".format(self.PATH_VARIABLE, self.root))

    def list(self):
        current_buffer = vim.current.buffer
        current_buffer[:] = self.__read()
        current_buffer.name = '{}/'.format(os.path.relpath(self.root))

    def sync(self):
        actual_lines = map(self.__full_path, vim.current.buffer[:])
        expected_lines = map(self.__full_path, self.__read())

        actions = []
        if len(actual_lines) > len(expected_lines):
            for added_line in set(actual_lines) - set(expected_lines):
                if self.__isdir(added_line):
                    actions.append(MakeDirectory(added_line))
                else:
                    actions.append(Touch(added_line))
        elif len(actual_lines) < len(expected_lines):
            for removed_line in set(expected_lines) - set(actual_lines):
                actions.append(Remove(removed_line))
        else:
            for actual_line, expected_line in zip(
                actual_lines, expected_lines
            ):
                if actual_line != expected_line:
                    actions.append(Move(expected_line, actual_line))

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
            vim.command('e {}'.format(path))

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
            u'{}/'.format(directory) for directory in sorted(directories)
        ]
        lines += [u'{}'.format(file) for file in sorted(files)]
        return lines

    def __full_path(self, entry):
        return os.path.join(self.root, entry)

    def __isdir(self, line):
        return line.endswith("/")
