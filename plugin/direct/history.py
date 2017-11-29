import os

from action import Action
from action import reverse
from directories import history_directory


class History(object):
    def __init__(self):
        self.undo_log = ActionLog('undo.log')
        self.redo_log = ActionLog('redo.log')

    def log(self, action):
        self.undo_log.push(action)
        self.redo_log.truncate()

    def undo(self):
        self.__reverse(self.undo_log, self.redo_log)

    def redo(self):
        self.__reverse(self.redo_log, self.undo_log)

    def __reverse(self, src_log, dst_log):
        action = src_log.pop()
        reverse_action = reverse(action)
        reverse_action.write()
        print(reverse_action)
        dst_log.push(reverse_action)


class ActionLog(object):
    def __init__(self, filename):
        self.path = os.path.join(history_directory, filename)

    def push(self, action):
        with open(self.path, 'a') as file:
            file.write(action.serialize())

    def pop(self):
        characters = []
        with open(self.path, 'r+') as file:
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

        line = ''.join(reversed(characters))

        return Action.deserialize(line)

    def truncate(self):
        open(self.path, 'w').close()
