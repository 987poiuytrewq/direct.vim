import os
import shutil
import vim


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

        if len(actual_lines) > len(expected_lines):
            for added_line in set(actual_lines) - set(expected_lines):
                if self.__isdir(added_line):
                    os.mkdir(added_line[:-1])
                else:
                    open(added_line, 'w').close()
        elif len(actual_lines) < len(expected_lines):
            for removed_line in set(expected_lines) - set(actual_lines):
                if self.__isdir(removed_line):
                    shutil.rmtree(removed_line[:-1])
                else:
                    os.remove(removed_line)
        else:
            for actual_line, expected_line in zip(
                actual_lines, expected_lines
            ):
                if actual_line != expected_line:
                    shutil.move(
                        expected_line[:-1] if self.__isdir(expected_line) else
                        expected_line, actual_line[:-1]
                        if self.__isdir(actual_line) else actual_line
                    )

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
