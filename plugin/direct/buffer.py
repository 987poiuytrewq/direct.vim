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
        self.root = os.path.abspath(path)
        self.current_entry = self.__full_path(vim.current.buffer.name)

        # change window to buffer if it already exists
        for buffer in vim.buffers:
            if buffer.name == self.root:
                vim.current.buffer = buffer
                return

        # else create new buffer and dump path
        vim.command('enew')
        vim.current.buffer.name = self.root

    @classmethod
    def restore(cls):
        return cls(vim.current.buffer.name)

    def list(self):
        '''Display directory content in buffer'''
        lines = self.__read()
        vim.current.buffer[:] = lines
        if self.current_entry:
            # set current line
            for index, line in enumerate(lines):
                if os.path.samefile(
                    self.__full_path(line), self.current_entry
                ):
                    vim.command(str(index + 1))
                    break

    def sync(self):
        '''Synchronise buffer content with directory content'''
        actual_lines = map(self.__full_path, vim.current.buffer[:])
        expected_lines = map(self.__full_path, self.__read())

        actions = []
        yanks = []
        if len(actual_lines) > len(expected_lines) and set(
            expected_lines
        ).issubset(actual_lines):
            for added_line in set(actual_lines) - set(expected_lines):
                if self.__isdir(added_line):
                    actions.append(MakeDirectory(added_line))
                else:
                    actions.append(Touch(added_line))
        elif len(actual_lines) < len(expected_lines) and set(
            actual_lines
        ).issubset(expected_lines):
            for removed_line in set(expected_lines) - set(actual_lines):
                yanks.append(removed_line)
                if self.__isdir(removed_line):
                    actions.append(RemoveDirectory(removed_line))
                else:
                    actions.append(Remove(removed_line))
        elif len(actual_lines) == len(expected_lines):
            for actual_line, expected_line in zip(
                actual_lines, expected_lines
            ):
                if actual_line != expected_line:
                    actions.append(Move(expected_line, actual_line))
        else:
            print(
                'Ambiguous buffer content. '
                'You must only add, remove or rename in each edit.'
            )
            raise AmbiguousBufferError()

        if actions:
            if yanks:
                Register().yank(yanks)

            history = History()
            for action in actions:
                try:
                    self.current_entry = action.do()
                except (IOError, OSError):
                    print 'Action failed - {}'.format(action)
                else:
                    history.log(action)
            print_actions(*actions)

    def open(self, line):
        '''Open file or directory'''
        direct_buffer = vim.current.buffer
        path = self.__full_path(line)
        if self.__isdir(path):
            # open new direct buffer
            vim.command('DirectList {path}'.format(path=path))
        else:
            # open file
            vim.command('edit {path}'.format(path=path))
        # close last buffer
        vim.command(
            'bwipeout! {buffer_number}'.format(
                buffer_number=direct_buffer.number
            )
        )

    def get_paths(self, firstline, lastline):
        current_buffer = vim.current.buffer
        return map(
            self.__full_path,
            current_buffer[slice(int(firstline) - 1, int(lastline))]
        )

    def __read(self):
        '''Read the filesystem'''
        files = []
        directories = []

        for entry in os.listdir(self.root):
            if os.path.isdir(self.__full_path(entry)):
                directories.append(entry)
            elif os.path.isfile(self.__full_path(entry)):
                files.append(entry)

        lines = []
        lines += [directory + os.path.sep for directory in sorted(directories)]
        lines += sorted(files)
        return lines

    def __full_path(self, entry):
        return os.path.join(self.root, entry)

    def __isdir(self, line):
        return line.endswith(os.path.sep)


class AmbiguousBufferError(Exception):
    pass
