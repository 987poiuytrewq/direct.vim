import os

from action import reverse
from direct import directories


class History(object):
    def __init__(self):
        self.undo_log = ActionLog('undo.log')
        self.redo_log = ActionLog('redo.log')

    def log(self, action):
        self.undo_log.push(action.serialize())
        self.redo_log.truncate()

    def undo(self):
        self.__reverse(self.undo_log, self.redo_log)

    def redo(self):
        self.__reverse(self.redo_log, self.undo_log)

    def __reverse(self, src_log, dst_log):
        reverse_action = reverse(src_log.pop())
        reverse_action.write()
        print(reverse_action)
        dst_log.push(reverse_action.serialize())


class ActionLog(object):
    def __init__(self, filename):
        self.path = os.path.join(directories.history_directory, filename)

    def push(self, line):
        with open(self.path, 'a') as file:
            file.write(line + '\n')

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

        return ''.join(reversed(characters))

    def truncate(self):
        open(self.path, 'w').close()
