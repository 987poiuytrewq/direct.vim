import os
import vim
from action import Move
from action import Remove
from action import RemoveDirectory
from action import Touch
from action import MakeDirectory
from history import History


class DirectBuffer(object):
    def __init__(self, root=None):
        self.root = root or os.getcwd()
        self.directories = []
        self.files = []
        for entry in os.listdir(self.root):
            if os.path.isdir(entry):
                self.directories.append(entry)
            elif os.path.isfile(entry):
                self.files.append(entry)

    def list(self):
        current_buffer = vim.current.buffer
        current_buffer[:] = self.__lines()
        current_buffer.name = '{}/'.format(self.root)

    def sync(self):
        actual_lines = vim.current.buffer[:]
        expected_lines = self.__lines()

        actions = []
        if len(actual_lines) > len(expected_lines):
            for added_line in set(actual_lines) - set(expected_lines):
                if self.__isdir(added_line):
                    actions.append(MakeDirectory(added_line))
                else:
                    actions.append(Touch(added_line))
        elif len(actual_lines) < len(expected_lines):
            for removed_line in set(expected_lines) - set(actual_lines):
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

        history = History()
        for action in actions:
            action.write()
            history.log(action, history.undo_filename)

    def open(self):
        current_line = vim.current.line
        if self.__isdir(current_line):
            DirectBuffer(current_line[:-1]).list()
        else:
            vim.command('e {}'.format(current_line))

    def __lines(self):
        lines = []
        lines += [
            u'{}/'.format(directory) for directory in sorted(self.directories)
        ]
        lines += [u'{}'.format(file) for file in sorted(self.files)]
        return lines

    def __isdir(self, line):
        return line[-1] == '/'
