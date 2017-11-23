import os
import vim
from action import Move
from action import Remove
from action import RemoveDirectory
from action import Touch
from action import MakeDirectory
from history import History


class DirectBuffer(object):
    def __init__(self, path=''):
        self.__recover_root(path)
        self.directories = []
        self.files = []
        for entry in os.listdir(self.root):
            if os.path.isdir(self.__absolute_path(entry)):
                self.directories.append(entry)
            elif os.path.isfile(self.__absolute_path(entry)):
                self.files.append(entry)

    def list(self):
        current_buffer = vim.current.buffer
        current_buffer[:] = self.__lines()
        current_buffer.name = '{}/'.format(self.root)
        self.__persist_root()

    def sync(self):
        actual_lines = map(self.__absolute_path, vim.current.buffer[:])
        expected_lines = map(self.__absolute_path, self.__lines())

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
            history.log(action)

    def open(self, line):
        path = self.__absolute_path(line)
        if self.__isdir(path):
            DirectBuffer(line[:-1]).list()
        else:
            vim.command('e {}'.format(path))

    def __absolute_path(self, entry):
        return os.path.join(self.root, entry)

    def __isdir(self, line):
        return line.endswith("/")

    def __lines(self):
        lines = []
        lines += [
            u'{}/'.format(directory) for directory in sorted(self.directories)
        ]
        lines += [u'{}'.format(file) for file in sorted(self.files)]
        return lines

    def __persist_root(self):
        vim.command("let b:direct_root = '{}'".format(self.root))

    def __recover_root(self, path):
        vim.command(
            """
            if !exists('b:direct_root')
                let b:direct_root = ''
            endif
        """
        )
        self.root = os.path.abspath(os.path.join(vim.eval("b:direct_root"), path))
