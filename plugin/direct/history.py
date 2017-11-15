import os
from action import Action
from action import invert


class History(object):
    def __init__(self):
        self.undo_filename = '/home/duncan/.direct/undo'
        self.redo_filename = '/home/duncan/.direct/redo'

    def log(self, action, filename):
        self.__push_line(str(action), filename)

    def undo(self):
        line = self.__pop_line(self.undo_filename)
        action = self.__parse_action(line)
        inverse_action = invert(action)
        inverse_action.write()
        self.log(inverse_action, self.redo_filename)

    def redo(self):
        line = self.__pop_line(self.redo_filename)
        action = self.__parse_action(line)
        inverse_action = invert(action)
        inverse_action.write()
        self.log(inverse_action, self.undo_filename)

    def __push_line(self, line, filename):
        with open(self.undo_filename, 'a') as undofile:
            undofile.write(line)

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
