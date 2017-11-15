import os
from action import Action
from action import reverse


class History(object):
    def __init__(self):
        self.undo_filename = '/home/duncan/.direct/undo'
        self.redo_filename = '/home/duncan/.direct/redo'

    def log(self, action):
        self.__push_line(str(action), self.undo_filename)
        open(self.redo_filename, 'w').close()

    def undo(self):
        self.__reverse(self.undo_filename, self.redo_filename)

    def redo(self):
        self.__reverse(self.redo_filename, self.undo_filename)

    def __reverse(self, src_filename, dst_filename):
        line = self.__pop_line(src_filename)
        action = self.__parse_action(line)
        reverse_action = reverse(action)
        reverse_action.write()
        self.__push_line(reverse_action, dst_filename)

    def __push_line(self, line, filename):
        with open(filename, 'a') as file:
            file.write(line)

    def __pop_line(self, filename):
        characters = []
        with open(filename, 'r+') as file:
            file.seek(0, os.SEEK_END)
            cursor = file.tell() - 1

            while cursor > 0:
                cursor -= 1
                file.seek(cursor, os.SEEK_SET)
                character = file.read(1)
                if character == '\n':
                    break
                characters.append(character)

            if cursor > 0:
                file.truncate()

        return ''.join(reversed(characters))

    def __parse_action(self, line):
        words = line.split(' ')
        action_name = words[0]
        for SubAction in Action.__subclasses__():
            if SubAction.__name__ == action_name:
                return SubAction(*words[1:])
